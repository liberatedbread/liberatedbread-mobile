// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Rust types mapping to the OpenGreenIoT device spec YAML schema.
//! See the `opengreeniot-protocol-docs` repository — the upstream source of
//! the vendored specs under `rust/tests/specs/` — for the schema and the
//! real-world specs these types must tolerate.

use indexmap::IndexMap;
use serde::Deserialize;
use std::collections::HashMap;

/// Top-level device specification.
///
/// The top level is where protocol-docs specs accumulate metadata and
/// vendor-specific blocks that the mobile core does not (yet) execute:
/// `entities`, `http_endpoints`, `mqtt_topics`, `initialization`, `features`,
/// `protocol_handler`, and bespoke keys like admore's `protobuf` /
/// `state_machine` / `version_fields`. Rather than enumerate every one (and
/// re-reject the next new spec), we drop `deny_unknown_fields` here and sweep
/// all unrecognized top-level keys into `extensions`. `device` stays required;
/// `services` is now optional (WiFi specs carry `http_endpoints`/`mqtt_topics`
/// and no GATT services), so it defaults to an empty vec. Typo detection is
/// preserved on the protocol-execution structs below, not here.
#[derive(Debug, Clone, Deserialize)]
pub struct DeviceSpec {
    pub device: DeviceInfo,
    #[serde(default)]
    pub services: Vec<Service>,
    /// Sensor/control entities the spec declares, each binding a human-facing
    /// name and unit to the characteristic that carries its value.
    ///
    /// This is the block that lets a client render "Internal Temperature 63°F"
    /// instead of a GATT browser, so it is promoted out of `extensions` into a
    /// typed field. Entities are advisory: a spec may declare one whose
    /// `state_characteristic` isn't in `services`, so consumers must resolve
    /// them rather than assume they bind.
    #[serde(default)]
    pub entities: Vec<Entity>,
    /// Parsed-but-ignored top-level extension blocks, preserved verbatim so no
    /// information is lost even though nothing interprets them yet.
    #[serde(flatten)]
    pub extensions: HashMap<String, serde_yaml::Value>,
}

/// A declared sensor or control surface.
///
/// Field set is deliberately small and every field but `name` is optional:
/// across the spec catalogue these blocks are written by hand and vary, so a
/// missing `unit` or an unfamiliar `platform` must not fail the whole parse.
/// Unrecognized keys sweep into `extensions` for the same reason.
#[derive(Debug, Clone, Deserialize)]
pub struct Entity {
    pub name: String,
    #[serde(default)]
    pub platform: Option<String>,
    #[serde(default)]
    pub device_class: Option<String>,
    #[serde(default)]
    pub unit: Option<String>,
    #[serde(default)]
    pub state_characteristic: Option<String>,
    /// Maps entity roles onto the named fields of the characteristic's
    /// `format:` block — e.g. `value: battery_percent` for a sensor, or
    /// `is_on: power_state` for a light. Left untyped because the key set
    /// differs per platform.
    #[serde(default)]
    pub state_mapping: HashMap<String, serde_yaml::Value>,
    #[serde(flatten)]
    pub extensions: HashMap<String, serde_yaml::Value>,
}

impl Entity {
    /// The decoded field carrying this entity's reading.
    ///
    /// A characteristic's `format:` block can decode several fields from one
    /// payload (battery percent alongside a status byte, say); `state_mapping`
    /// says which one is the value. When a spec omits the mapping the caller
    /// falls back to the first decoded field, which is the common single-field
    /// case.
    pub fn value_field(&self) -> Option<&str> {
        self.state_mapping.get("value")?.as_str()
    }

    /// Multiplier applied to the decoded value before display.
    ///
    /// Devices commonly report a fixed-point integer — Ember's mug sends
    /// centidegrees, so `5320` means 53.20 °C — and the spec carries the
    /// conversion as `state_mapping.scale`. Keeping it in the spec is the whole
    /// point: the scaling for a new device arrives as data, not as a patch.
    pub fn value_scale(&self) -> Option<f64> {
        self.state_mapping.get("scale")?.as_f64()
    }
}

impl DeviceSpec {
    /// Find a characteristic by UUID across all services (case-insensitive).
    /// Uses `eq_ignore_ascii_case` so neither side allocates a normalized
    /// copy — UUID strings are pure ASCII so this is correct and cheap.
    pub fn find_characteristic(&self, uuid: &str) -> Option<(&Service, &Characteristic)> {
        self.find_characteristic_where(uuid, |_| true)
    }

    /// Find a characteristic by UUID, preferring a declaration that satisfies
    /// `prefer` and falling back to the first match.
    ///
    /// A UUID usually appears once, but hand-authored specs sometimes declare
    /// the same characteristic twice with different detail:
    /// `airthings-wave-family` lists the SIG temperature and humidity
    /// characteristics in two places, and only the second carries a `format:`
    /// block. Taking the first match blindly lets the stub shadow the real
    /// declaration, and the reading then reports "no format block" — which is
    /// indistinguishable from a genuinely undocumented characteristic.
    fn find_characteristic_where(
        &self,
        uuid: &str,
        prefer: impl Fn(&Characteristic) -> bool,
    ) -> Option<(&Service, &Characteristic)> {
        let mut fallback = None;
        for service in &self.services {
            for characteristic in &service.characteristics {
                if !characteristic.uuid.eq_ignore_ascii_case(uuid) {
                    continue;
                }
                if prefer(characteristic) {
                    return Some((service, characteristic));
                }
                fallback.get_or_insert((service, characteristic));
            }
        }
        fallback
    }

    /// Find a characteristic by UUID, preferring one that carries the byte
    /// layout needed to decode a reading.
    pub fn find_decodable_characteristic(&self, uuid: &str) -> Option<(&Service, &Characteristic)> {
        self.find_characteristic_where(uuid, |c| c.format.is_some())
    }

    /// Find a characteristic by UUID, preferring one that declares commands.
    /// The write-path mirror of [`Self::find_decodable_characteristic`].
    pub fn find_writable_characteristic(&self, uuid: &str) -> Option<(&Service, &Characteristic)> {
        self.find_characteristic_where(uuid, |c| c.commands.is_some())
    }

    /// Entities that actually bind to a characteristic in this spec.
    ///
    /// Specs are hand-authored and some declare an entity whose
    /// `state_characteristic` is absent from `services` (or omit the field
    /// entirely). Those can never produce a reading, so they are filtered here
    /// rather than surfaced as a control that never updates.
    pub fn resolved_entities(&self) -> Vec<(&Entity, &Characteristic)> {
        self.entities
            .iter()
            .filter_map(|entity| {
                let uuid = entity.state_characteristic.as_deref()?;
                let (_, characteristic) = self.find_decodable_characteristic(uuid)?;
                Some((entity, characteristic))
            })
            .collect()
    }
}

/// Device metadata and identification.
///
/// `deny_unknown_fields` was dropped here after vendoring the full catalogue:
/// it rejected 70 of 71 upstream specs outright, over descriptive keys the BLE
/// path never reads (`discovery`, `setup`, `model`, `transport`, `category`,
/// `type`, …). Losing a whole device because it documents its own setup steps
/// is far worse than missing a typo, and the catalogue is meant to be refreshed
/// as data — a new descriptive key upstream must not require a Rust change.
///
/// Unknown keys sweep into `extensions`, matching [`DeviceSpec`]. The named
/// optional fields below are kept typed because something reads them:
/// `variants` (a device family sharing UUIDs but differing in commands) and
/// admore's bespoke `protobuf` / `state_machine` / `version_fields`. Typo
/// detection still applies on the protocol-execution structs further down,
/// where a wrong key would actually change behaviour.
#[derive(Debug, Clone, Deserialize)]
pub struct DeviceInfo {
    pub name: String,
    pub manufacturer: String,
    pub manufacturer_status: ManufacturerStatus,
    pub protocol: Protocol,
    pub notes: Option<String>,
    pub identification: Option<Identification>,
    /// Device variants sharing service UUIDs but differing in command sets.
    #[serde(default)]
    pub variants: Option<serde_yaml::Value>,
    /// Protobuf schema description (admore): message/enum types over NUS.
    #[serde(default)]
    pub protobuf: Option<serde_yaml::Value>,
    /// Connection/UI state-machine description (admore).
    #[serde(default)]
    pub state_machine: Option<serde_yaml::Value>,
    /// Version-field catalogue reported by the device (admore).
    #[serde(default)]
    pub version_fields: Option<serde_yaml::Value>,
    /// Descriptive keys the catalogue carries but this core does not execute —
    /// `discovery`, `setup`, `model`, `transport`, `category`, `type`, and
    /// whatever upstream adds next. Preserved verbatim so nothing is lost.
    #[serde(flatten)]
    pub extensions: HashMap<String, serde_yaml::Value>,
}

/// Why this device needs open-source rescue.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ManufacturerStatus {
    Abandoned,
    /// Manufacturer still active; device documented for interoperability
    /// (e.g. reverse-engineered protocol) rather than abandonment rescue.
    Active,
    Shutdown,
    Unsupported,
}

impl std::fmt::Display for ManufacturerStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ManufacturerStatus::Abandoned => write!(f, "abandoned"),
            ManufacturerStatus::Active => write!(f, "active"),
            ManufacturerStatus::Shutdown => write!(f, "shutdown"),
            ManufacturerStatus::Unsupported => write!(f, "unsupported"),
        }
    }
}

/// Primary communication protocol.
///
/// The catalogue carries transports this core does not execute (`uart`, `can`,
/// `obd2`, …). Rejecting them would make an entire spec unloadable over a field
/// the BLE path never reads, so unknown values are preserved verbatim in
/// [`Protocol::Other`] rather than failing the parse. Callers that only handle
/// BLE match on [`Protocol::Ble`] and ignore the rest.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    Ble,
    Wifi,
    Zigbee,
    Zwave,
    #[serde(untagged)]
    Other(String),
}

impl std::fmt::Display for Protocol {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Protocol::Ble => write!(f, "ble"),
            Protocol::Wifi => write!(f, "wifi"),
            Protocol::Zigbee => write!(f, "zigbee"),
            Protocol::Zwave => write!(f, "zwave"),
            Protocol::Other(raw) => write!(f, "{raw}"),
        }
    }
}

/// How to identify this device during scanning (BLE or WiFi).
///
/// Vendors add their own discovery hints here — admore declares several
/// `local_name_*` variants (DFU, armband, …) beyond `local_name_prefix`, and
/// WiFi specs use `mdns_service_type` / `ssid_prefix` / `default_port`. We name
/// the schema-defined WiFi keys and sweep the rest into `extensions` rather
/// than reject them.
#[derive(Debug, Clone, Deserialize)]
pub struct Identification {
    pub local_name_prefix: Option<String>,
    pub service_uuids: Option<Vec<String>>,
    /// mDNS/Bonjour service type for WiFi discovery (e.g. `_http._tcp`).
    #[serde(default)]
    pub mdns_service_type: Option<String>,
    /// WiFi SSID prefix when the device is in AP mode.
    #[serde(default)]
    pub ssid_prefix: Option<String>,
    /// Default TCP port for the device's local API.
    #[serde(default)]
    pub default_port: Option<u16>,
    /// Other discovery hints (e.g. admore's `local_name_dfu`,
    /// `local_name_armband*`), parsed and preserved but not yet interpreted.
    #[serde(flatten)]
    pub extensions: HashMap<String, serde_yaml::Value>,
}

/// A BLE GATT service.
///
/// Unknown keys sweep into `extensions` rather than failing the parse: the
/// upstream catalogue attaches descriptive keys here (`description`,
/// `verification`, `variants`, vendor envelopes) that do not change how bytes
/// are encoded. Rejecting them cost 16 devices outright. The typed fields
/// below are still the only ones that drive protocol execution.
/// Previously strict — `uuid`/`name`/`characteristics` drive protocol
/// execution, so a typo in any of them should still fail loudly. `notes` is the
/// one documented optional extension (admore annotates services).
#[derive(Debug, Clone, Deserialize)]
pub struct Service {
    pub uuid: String,
    pub name: String,
    #[serde(default)]
    pub characteristics: Vec<Characteristic>,
    /// Free-form documentation about the service.
    #[serde(default)]
    pub notes: Option<String>,

}

/// A BLE GATT characteristic.
///
/// Unknown keys sweep into `extensions` rather than failing the parse: the
/// upstream catalogue attaches descriptive keys here (`description`,
/// `verification`, `variants`, vendor envelopes) that do not change how bytes
/// are encoded. Rejecting them cost 16 devices outright. The typed fields
/// below are still the only ones that drive protocol execution.
/// Previously strict so typos in `uuid`/`properties`/`commands`/
/// `format` (the fields that drive reads/writes) are caught. `notes`,
/// `encryption`, and `framing` are documented optional extensions; the latter
/// two are parsed-and-preserved as opaque values since the mobile core does not
/// yet implement AES or packet framing.
#[derive(Debug, Clone, Deserialize)]
pub struct Characteristic {
    pub uuid: String,
    pub name: String,
    pub properties: Vec<CharacteristicProperty>,
    /// Commands keyed by name, in the order the spec declares them — that
    /// order is what the UI renders, so it must survive parsing.
    pub commands: Option<IndexMap<String, Command>>,
    pub format: Option<Vec<FormatField>>,
    /// Free-form documentation about the characteristic.
    #[serde(default)]
    pub notes: Option<String>,
    /// Encryption declaration (algorithm/key derivation). Not yet executed.
    #[serde(default)]
    pub encryption: Option<serde_yaml::Value>,
    /// Packet framing declaration (length prefix/checksum/chunking). Not yet
    /// executed.
    #[serde(default)]
    pub framing: Option<serde_yaml::Value>,

}

/// BLE characteristic property.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum CharacteristicProperty {
    Read,
    Write,
    WriteWithoutResponse,
    Notify,
    Indicate,
}

/// A named command for a writable characteristic.
///
/// Unknown keys sweep into `extensions` rather than failing the parse: the
/// upstream catalogue attaches descriptive keys here (`description`,
/// `verification`, `variants`, vendor envelopes) that do not change how bytes
/// are encoded. Rejecting them cost 16 devices outright. The typed fields
/// below are still the only ones that drive protocol execution.
/// Previously strict so a typo in `value`/`template`/`parameters`
/// (which build the actual write payload) is caught. `setting_id`, `encoding`,
/// and `payload` are documented optional extensions for higher-level command
/// encodings (admore's protobuf `setting_id`; JSON/TLV `encoding`+`payload`);
/// they are parsed but not yet executed — raw-byte commands still go through
/// `value`/`template`.
#[derive(Debug, Clone, Deserialize)]
pub struct Command {
    pub description: String,
    /// Fixed byte sequence for this command.
    pub value: Option<Vec<u8>>,
    /// Parameterized byte sequence. Strings are parameter references like "{brightness}".
    pub template: Option<Vec<TemplateElement>>,
    /// Parameter definitions for template commands.
    pub parameters: Option<ParameterSet>,
    /// Symbolic setting/enum identifier for protobuf-style commands (admore).
    #[serde(default)]
    pub setting_id: Option<String>,
    /// Payload encoding for non-raw-byte commands: `bytes` | `json` | `tlv`.
    #[serde(default)]
    pub encoding: Option<String>,
    /// Structured payload description for `json`/`tlv` encodings.
    #[serde(default)]
    pub payload: Option<serde_yaml::Value>,

}

/// The `parameters` block of a command.
///
/// This is a map of parameter-name → [`Parameter`], plus a small set of
/// reserved keys that are *not* parameters. `color_order` (e.g. `"rbg"`)
/// declares the color-channel order for commands with color parameters; it is
/// a sibling scalar, not a parameter definition, so it is pulled out explicitly
/// and the remaining keys flatten into `params`.
///
/// `params` is an [`IndexMap`] for the same reason [`Characteristic::commands`]
/// is: declaration order is the order the sliders appear in.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct ParameterSet {
    /// Reserved key: color-channel order (default `"rgb"`). Not a parameter.
    #[serde(default)]
    pub color_order: Option<String>,
    /// Actual parameter definitions, keyed by name.
    #[serde(flatten)]
    pub params: IndexMap<String, Parameter>,

}

/// An element in a command template — either a fixed byte or a parameter reference.
#[derive(Debug, Clone)]
pub enum TemplateElement {
    Byte(u8),
    Param(String),
}

impl<'de> Deserialize<'de> for TemplateElement {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        use serde::de;

        struct TemplateElementVisitor;

        impl<'de> de::Visitor<'de> for TemplateElementVisitor {
            type Value = TemplateElement;

            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("an integer (0-255) or a string like \"{param_name}\"")
            }

            fn visit_i64<E: de::Error>(self, v: i64) -> Result<Self::Value, E> {
                u8::try_from(v)
                    .map(TemplateElement::Byte)
                    .map_err(|_| E::custom(format!("byte value out of range: {v}")))
            }

            fn visit_u64<E: de::Error>(self, v: u64) -> Result<Self::Value, E> {
                u8::try_from(v)
                    .map(TemplateElement::Byte)
                    .map_err(|_| E::custom(format!("byte value out of range: {v}")))
            }

            fn visit_str<E: de::Error>(self, v: &str) -> Result<Self::Value, E> {
                let inner = v
                    .strip_prefix('{')
                    .and_then(|s| s.strip_suffix('}'))
                    .ok_or_else(|| {
                        E::custom(format!(
                            "parameter reference must be wrapped in braces: {v}"
                        ))
                    })?;
                if inner.is_empty() {
                    return Err(E::custom("parameter name cannot be empty"));
                }
                Ok(TemplateElement::Param(inner.to_string()))
            }
        }

        deserializer.deserialize_any(TemplateElementVisitor)
    }
}

/// A command parameter definition.
///
/// Unknown keys sweep into `extensions`: specs annotate parameters with
/// `description` and `default`, which document the parameter without changing
/// how it encodes. `type`/`min`/`max` still bound the encoded value, so
/// a typo here should fail loudly. `allowed`/`labels`/`notes` are documented
/// optional extensions (admore declares enumerated allowed values with UI
/// labels); they are parsed and preserved but do not yet drive validation.
#[derive(Debug, Clone, Deserialize)]
pub struct Parameter {
    #[serde(rename = "type")]
    pub value_type: ValueType,
    pub min: Option<i64>,
    pub max: Option<i64>,
    /// Enumerated set of allowed integer values (admore setting_id commands).
    #[serde(default)]
    pub allowed: Option<Vec<i64>>,
    /// Human-readable labels paired with `allowed`, for UI display.
    #[serde(default)]
    pub labels: Option<Vec<String>>,
    /// Free-form documentation about the parameter.
    #[serde(default)]
    pub notes: Option<String>,

}

/// Binary format field for parsing readable/notifiable characteristic values.
#[derive(Debug, Clone, Deserialize)]
pub struct FormatField {
    pub offset: usize,
    pub length: usize,
    pub name: String,
    #[serde(rename = "type")]
    pub field_type: ValueType,
    /// Optional default value the mock simulator returns for unwritten reads.
    /// Use a YAML scalar matching the field type — e.g. `mock_default: 80` for
    /// numeric types, `mock_default: true` for `bool`. When absent the
    /// simulator falls back to a name-based heuristic (see `mock/simulator.rs`).
    #[serde(default)]
    pub mock_default: Option<serde_yaml::Value>,
    /// Multiplier converting the raw integer into the physical quantity the
    /// field's `unit` names — a Bluetooth SIG temperature characteristic is
    /// `int16` with `scale: 0.01`, so a raw 2350 is 23.5 °C.
    ///
    /// This is the per-field twin of an entity's `state_mapping.scale`. Both
    /// exist upstream: `airthings-wave-family` and `xiaomi-miflora` declare it
    /// here, `ember-mug` declares it on the entity. Ignoring this one made the
    /// affected readings wrong by two orders of magnitude.
    #[serde(default)]
    pub scale: Option<f64>,
    /// Unit symbol for the decoded field, used when the entity that surfaces
    /// this reading does not name one itself.
    #[serde(default)]
    pub unit: Option<String>,
}

/// Supported value types for encoding/decoding.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ValueType {
    Bool,
    Uint8,
    Uint16,
    Int8,
    Int16,
    Int32,
    Uint32,
    Bytes,
    String,
}

impl std::fmt::Display for ValueType {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ValueType::Bool => write!(f, "bool"),
            ValueType::Uint8 => write!(f, "uint8"),
            ValueType::Uint16 => write!(f, "uint16"),
            ValueType::Int8 => write!(f, "int8"),
            ValueType::Int16 => write!(f, "int16"),
            ValueType::Int32 => write!(f, "int32"),
            ValueType::Uint32 => write!(f, "uint32"),
            ValueType::Bytes => write!(f, "bytes"),
            ValueType::String => write!(f, "string"),
        }
    }
}

impl ValueType {
    /// Required byte width for fixed-size types. Returns `None` for
    /// variable-length types (`Bytes`, `String`).
    pub fn fixed_byte_size(&self) -> Option<usize> {
        match self {
            ValueType::Bool | ValueType::Uint8 | ValueType::Int8 => Some(1),
            ValueType::Uint16 | ValueType::Int16 => Some(2),
            ValueType::Int32 | ValueType::Uint32 => Some(4),
            ValueType::Bytes | ValueType::String => None,
        }
    }

    /// Inclusive `[min, max]` range that fits in this type, used to validate
    /// `Parameter.min`/`max` declarations at parse time. Returns `None` for
    /// variable-length types where bounds don't apply.
    pub fn integer_range(&self) -> Option<(i64, i64)> {
        match self {
            ValueType::Bool => Some((0, 1)),
            ValueType::Uint8 => Some((u8::MIN as i64, u8::MAX as i64)),
            ValueType::Uint16 => Some((u16::MIN as i64, u16::MAX as i64)),
            ValueType::Int8 => Some((i8::MIN as i64, i8::MAX as i64)),
            ValueType::Int16 => Some((i16::MIN as i64, i16::MAX as i64)),
            ValueType::Int32 => Some((i32::MIN as i64, i32::MAX as i64)),
            ValueType::Uint32 => Some((0, u32::MAX as i64)),
            ValueType::Bytes | ValueType::String => None,
        }
    }
}

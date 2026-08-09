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
/// `http_endpoints`, `mqtt_topics`, `initialization`, and bespoke keys like
/// admore's `protobuf` / `state_machine` / `version_fields`. Rather than
/// enumerate every one (and re-reject the next new spec), we drop
/// `deny_unknown_fields` here and sweep all unrecognized top-level keys into
/// `extensions`. `device` stays required; `services` is now optional (WiFi
/// specs carry `http_endpoints`/`mqtt_topics` and no GATT services), so it
/// defaults to an empty vec. Typo detection is preserved on the
/// protocol-execution structs below, not here.
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
    /// Named consumer-side handler for protocols that cannot be fully
    /// expressed in YAML (image assembly, custom crypto). Promoted out of
    /// `extensions` because the image-upload path dispatches on it — see
    /// `crate::protocol::daniao` for the first implementation.
    #[serde(default)]
    pub protocol_handler: Option<String>,
    /// High-level capabilities beyond raw GATT reads/writes (`image_upload`,
    /// `firmware_update`, ...). Declarative: each entry says what the device
    /// accepts; whether this crate can drive it depends on
    /// [`DeviceSpec::protocol_handler`] naming an implemented handler.
    #[serde(default)]
    pub features: Vec<Feature>,
    /// Parsed-but-ignored top-level extension blocks, preserved verbatim so no
    /// information is lost even though nothing interprets them yet.
    #[serde(flatten)]
    pub extensions: HashMap<String, serde_yaml::Value>,
}

/// One `features:` entry — a declared high-level capability.
///
/// Every field but `type` is optional and unknown keys sweep into
/// `extensions`: these blocks are hand-written across the catalogue and a new
/// annotation must not fail existing parses.
#[derive(Debug, Clone, Deserialize)]
pub struct Feature {
    #[serde(rename = "type")]
    pub feature_type: String,
    /// Binary format the device expects (e.g. `rgb888`, `gif`, `1bit-bitmap`).
    #[serde(default)]
    pub format: Option<String>,
    #[serde(default)]
    pub max_width: Option<u32>,
    #[serde(default)]
    pub max_height: Option<u32>,
    /// `"fixed"` when max_width/max_height are the panel's actual size,
    /// `"device_reported"` when they are platform bounds and the real
    /// resolution comes from the device at runtime.
    #[serde(default)]
    pub resolution_source: Option<String>,
    /// Whether the device accepts multi-frame sequences (animations), not
    /// just a single static image.
    #[serde(default)]
    pub animation: Option<bool>,
    #[serde(default)]
    pub max_frames: Option<u32>,
    /// Fastest frame flip the device supports, in milliseconds.
    #[serde(default)]
    pub min_frame_interval_ms: Option<u32>,
    #[serde(default)]
    pub default_frame_interval_ms: Option<u32>,
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
    /// Characteristic the entity's writes target when it differs from
    /// `state_characteristic` (spider-farmer's grow light) — and the first
    /// place role commands are looked up when resolving control bindings.
    #[serde(default)]
    pub command_characteristic: Option<String>,
    /// Role → command-name bindings, e.g. `turn_on: power_on` on a switch or
    /// `set_brightness: set_tail_brightness` on a light. Values are untyped
    /// because some specs put prose here instead of a command name (ember's
    /// "restore previous nonzero target temperature"); resolution treats a
    /// value that names no declared command as absent.
    #[serde(default)]
    pub commands: HashMap<String, serde_yaml::Value>,
    /// Advisory capability tags on control entities (`brightness`, `color`,
    /// `on_off`, ...). Untyped for the same tolerance reason as `commands`;
    /// use [`Entity::has_feature`] to query.
    #[serde(default)]
    pub features: Vec<serde_yaml::Value>,
    /// Smallest settable value for a `number` control, in the entity's `unit`
    /// — i.e. *after* the bound field's scale/value_offset, because this
    /// describes the control a user sees rather than the byte on the wire.
    #[serde(default)]
    pub min: Option<f64>,
    /// Largest settable value, in the same decoded terms as [`Self::min`].
    #[serde(default)]
    pub max: Option<f64>,
    /// Control granularity in `unit` terms — the device's real resolution,
    /// which decides whether the UI can express every state it can hold.
    #[serde(default)]
    pub step: Option<f64>,
    /// `climate` spelling of [`Self::min`]/[`Self::max`]/[`Self::step`].
    /// Hotwired's heated gear declares its 0-10 heat level this way.
    #[serde(default)]
    pub min_temp: Option<f64>,
    #[serde(default)]
    pub max_temp: Option<f64>,
    #[serde(default)]
    pub temp_step: Option<f64>,
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

    /// The command name bound to a control role (`turn_on`, `set_brightness`,
    /// ...), when the spec declares one and it is a plain string. Prose values
    /// (ember's switch describes behaviour instead of naming a command) come
    /// back too — the caller decides whether the string names a real command.
    pub fn command_for_role(&self, role: &str) -> Option<&str> {
        self.commands.get(role)?.as_str()
    }

    /// Whether the entity's advisory `features:` list carries a tag.
    pub fn has_feature(&self, feature: &str) -> bool {
        self.features.iter().any(|f| f.as_str() == Some(feature))
    }

    /// The decoded value that means "on" for a switch/binary_sensor
    /// (`state_mapping.on_value`). Ember's charging-base sensor reads a status
    /// byte where exactly 1 means docked.
    pub fn on_value(&self) -> Option<i64> {
        self.state_mapping.get("on_value")?.as_i64()
    }

    /// True when `state_mapping.on_when: nonzero` — any nonzero reading means
    /// "on". Ember's temperature-control switch is on whenever the target
    /// temperature is set at all.
    pub fn on_when_nonzero(&self) -> bool {
        self.state_mapping
            .get("on_when")
            .and_then(|v| v.as_str())
            .is_some_and(|s| s == "nonzero")
    }

    /// The decoded field carrying a light's power state
    /// (`state_mapping.is_on`).
    pub fn is_on_field(&self) -> Option<&str> {
        self.state_mapping.get("is_on")?.as_str()
    }

    /// The decoded field carrying a light's brightness
    /// (`state_mapping.brightness`).
    pub fn brightness_field(&self) -> Option<&str> {
        self.state_mapping.get("brightness")?.as_str()
    }

    /// Smallest settable value, accepting either the `number` spelling or the
    /// `climate` one.
    pub fn setpoint_min(&self) -> Option<f64> {
        self.min.or(self.min_temp)
    }

    /// Largest settable value, in the same decoded terms as
    /// [`Self::setpoint_min`].
    pub fn setpoint_max(&self) -> Option<f64> {
        self.max.or(self.max_temp)
    }

    /// Control granularity, in the same decoded terms as
    /// [`Self::setpoint_min`].
    pub fn setpoint_step(&self) -> Option<f64> {
        self.step.or(self.temp_step)
    }

    /// The decoded fields carrying a light's color, in red/green/blue order
    /// (`state_mapping.color_rgb: {red: ..., green: ..., blue: ...}`).
    pub fn color_rgb_fields(&self) -> Option<[String; 3]> {
        let map = self.state_mapping.get("color_rgb")?.as_mapping()?;
        let get = |key: &str| {
            map.get(serde_yaml::Value::String(key.to_string()))?
                .as_str()
                .map(str::to_owned)
        };
        Some([get("red")?, get("green")?, get("blue")?])
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
    pub(crate) fn find_characteristic_where(
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
/// path never reads (`discovery`, `setup`, `model`, `transport`, `type`, …).
/// Losing a whole device because it documents its own setup steps
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
    /// Broad device class from the schema's closed vocabulary — `light`,
    /// `display`, `sensor`, `motor`, `switch`, `lock`, `tv`, `printer`, and so
    /// on. Promoted out of `extensions` because it is what a consumer draws:
    /// the app's scan list picks a device's icon from it, so without one a
    /// documented device is rendered with the same anonymous radio glyph as a
    /// stranger's earbuds.
    ///
    /// Kept as a `String` rather than a Rust enum on purpose. The vocabulary is
    /// owned by the spec schema and will grow there first, and a consumer that
    /// refuses to parse a spec because it has not heard of `camera` yet loses
    /// the device entirely — where one that carries the string through loses
    /// only the icon. Optional for the same reason: a spec pack cached by an
    /// older build, or one still being written, must keep loading.
    #[serde(default)]
    pub category: Option<String>,
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
    /// `discovery`, `setup`, `model`, `transport`, `type`, and whatever
    /// upstream adds next. Preserved verbatim so nothing is lost.
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
    /// Further names the same family advertises under, for hardware sold as
    /// several rebadged models. Alternatives, not a conjunction: a match on any
    /// one of them means what a `local_name_prefix` match means. Read both
    /// through [`Identification::local_name_prefixes`].
    #[serde(default)]
    pub local_name_prefixes: Option<Vec<String>>,
    pub service_uuids: Option<Vec<String>>,
    /// BLE manufacturer-specific advertisement data (AD type 0xFF).
    #[serde(default)]
    pub manufacturer_data: Option<ManufacturerData>,
    /// IEEE OUI prefixes seen on this device's MAC address, e.g. `C4:7C:8D`.
    ///
    /// The weakest signal the catalogue carries: an OUI belongs to a vendor,
    /// not a product. How weak depends on the block, which is what each entry's
    /// `confidence` says. See
    /// [`MatchConfidence`](crate::api::device_api::MatchConfidence).
    #[serde(default)]
    pub mac_prefixes: Option<Vec<MacPrefix>>,
    /// mDNS/Bonjour service type for WiFi discovery (e.g. `_http._tcp`).
    #[serde(default)]
    pub mdns_service_type: Option<String>,
    /// SSDP/UPnP search targets the device answers to, e.g.
    /// `urn:Belkin:device:controllee:1`. The only way to find hardware with no
    /// meaningful mDNS presence — Wemo, and pre-2020 Hue bridges.
    #[serde(default)]
    pub ssdp_search_targets: Option<Vec<String>>,
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

impl Identification {
    /// Every local name prefix this device family advertises under: the
    /// singular key plus the plural one, deduplicated in declaration order.
    ///
    /// Empty strings are dropped rather than passed on. `"anything"
    /// .starts_with("")` is true, so one would turn the spec into a claim on
    /// every device the scanner sees.
    pub fn local_name_prefixes(&self) -> Vec<String> {
        let mut prefixes: Vec<String> = Vec::new();
        for prefix in self
            .local_name_prefix
            .iter()
            .chain(self.local_name_prefixes.iter().flatten())
        {
            if !prefix.is_empty() && !prefixes.contains(prefix) {
                prefixes.push(prefix.clone());
            }
        }
        prefixes
    }

    /// Every company ID this device family advertises: the primary one plus
    /// any `additional_company_ids`, deduplicated in declaration order.
    pub fn company_ids(&self) -> Vec<u16> {
        let Some(data) = self.manufacturer_data.as_ref() else {
            return Vec::new();
        };
        let mut ids = Vec::new();
        for id in data
            .company_id
            .into_iter()
            .chain(data.additional_company_ids.iter().flatten().copied())
        {
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
        ids
    }
}

/// One MAC prefix, with how much of its block belongs to this device.
///
/// Accepts either a bare string or a `{prefix, confidence, notes}` map, because
/// the catalogue is hand-written and most entries have nothing interesting to
/// say. A bare string means [`MacPrefixConfidence::Low`] — the safe reading,
/// and the right one for a prefix nobody has checked.
#[derive(Debug, Clone, Deserialize)]
#[serde(untagged)]
pub enum MacPrefix {
    Bare(String),
    Detailed {
        prefix: String,
        #[serde(default)]
        confidence: MacPrefixConfidence,
        #[serde(flatten)]
        extensions: HashMap<String, serde_yaml::Value>,
    },
}

impl MacPrefix {
    pub fn prefix(&self) -> &str {
        match self {
            MacPrefix::Bare(prefix) => prefix,
            MacPrefix::Detailed { prefix, .. } => prefix,
        }
    }

    pub fn confidence(&self) -> MacPrefixConfidence {
        match self {
            MacPrefix::Bare(_) => MacPrefixConfidence::Low,
            MacPrefix::Detailed { confidence, .. } => *confidence,
        }
    }
}

/// How much of an address block belongs to this device.
///
/// An OUI names whoever bought the block, which is frequently not who built the
/// product, so the default is deliberately the pessimistic one.
#[derive(Debug, Clone, Copy, Default, Deserialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum MacPrefixConfidence {
    /// The block is shared — subdivided into MA-M/MA-S assignments held by
    /// unrelated companies, or belonging to a third-party radio module's
    /// vendor. Ranks a device, and nothing more.
    #[default]
    Low,
    /// The block really is this manufacturer's, but covers their whole
    /// catalogue: "something this vendor made", not "this device".
    Medium,
    /// The block is used by this device family and effectively nothing else.
    /// Rare, and it needs evidence.
    High,
}

/// The identifying part of a spec's BLE manufacturer-specific advertisement
/// data.
///
/// Unknown keys sweep into `extensions` rather than failing the parse: the
/// catalogue attaches `company_id_hex`, `description`, `format` and
/// `discovery_patterns` here, none of which change who a device is. The
/// payload-level matching rules (offsets, byte patterns) live under the spec's
/// `discovery` block, which this core does not execute.
#[derive(Debug, Clone, Deserialize)]
pub struct ManufacturerData {
    /// Bluetooth SIG company identifier from the advertisement header.
    ///
    /// Note this identifies an advertisement shape rather than a vendor —
    /// squatting on an unassigned ID is common — so it is a weaker signal than
    /// a service UUID.
    #[serde(default)]
    pub company_id: Option<u16>,
    /// Further IDs the same family advertises (older firmware, rebadges),
    /// treated as equivalent to `company_id`.
    #[serde(default)]
    pub additional_company_ids: Option<Vec<u16>>,
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

impl Command {
    /// The fixed byte sequence of an `encoding: bytes` command, when its
    /// `payload.bytes` is a well-formed byte list.
    ///
    /// Govee specs write fixed commands as `encoding: bytes` +
    /// `payload: {bytes: [...]}` instead of the `value:` key — the same
    /// information in a different envelope. Returns `None` for any other
    /// encoding, for a missing/short payload, or for entries outside 0..=255,
    /// so a malformed payload stays "unsupported" rather than sending a
    /// truncated write.
    pub fn payload_bytes(&self) -> Option<Vec<u8>> {
        if self.encoding.as_deref() != Some("bytes") {
            return None;
        }
        let bytes = self.payload.as_ref()?.get("bytes")?.as_sequence()?;
        if bytes.is_empty() {
            return None;
        }
        bytes
            .iter()
            .map(|v| u8::try_from(v.as_u64()?).ok())
            .collect()
    }
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
/// `description`, which documents the parameter without changing how it
/// encodes. `type`/`min`/`max` still bound the encoded value, so
/// a typo here should fail loudly. `allowed`/`labels`/`notes` are documented
/// optional extensions (admore declares enumerated allowed values with UI
/// labels); they are parsed and preserved but do not yet drive validation.
#[derive(Debug, Clone, Deserialize)]
pub struct Parameter {
    #[serde(rename = "type")]
    pub value_type: ValueType,
    pub min: Option<i64>,
    pub max: Option<i64>,
    /// Value the encoder uses when the caller supplies nothing for this
    /// parameter. This is what lets a high-level control send a command
    /// without understanding every protocol byte: elk-bledom's
    /// `set_brightness` takes `seq`, `light_mode` and `flag` alongside the
    /// brightness itself, and the spec defaults all three, so a brightness
    /// slider only needs to provide `brightness`.
    #[serde(default)]
    pub default: Option<i64>,
    /// Enumerated set of allowed integer values (admore setting_id commands).
    #[serde(default)]
    pub allowed: Option<Vec<i64>>,
    /// Human-readable labels paired with `allowed`, for UI display.
    #[serde(default)]
    pub labels: Option<Vec<String>>,
    /// Number semantics of the value this parameter carries, shared with
    /// [`FormatField`]: the client encodes by inverting
    /// `raw = round((value - value_offset) / scale)`, which is why the
    /// transform is linear.
    #[serde(default)]
    pub scale: Option<f64>,
    #[serde(default)]
    pub value_offset: Option<f64>,
    #[serde(default)]
    pub unit: Option<String>,
    /// Free-form documentation about the parameter.
    #[serde(default)]
    pub notes: Option<String>,
}

/// Same rationale as [`FormatField`]'s: only `type` is load-bearing, and the
/// optional set grows with the schema. `Bytes` is the placeholder because it
/// carries no numeric range, so a literal that forgets to state its real type
/// fails validation loudly rather than silently encoding as a byte.
impl Default for Parameter {
    fn default() -> Self {
        Self {
            value_type: ValueType::Bytes,
            min: None,
            max: None,
            default: None,
            allowed: None,
            labels: None,
            scale: None,
            value_offset: None,
            unit: None,
            notes: None,
        }
    }
}

impl Parameter {
    /// Whether this parameter states the meaning of its value rather than
    /// only its width — i.e. carries a transform worth inverting.
    pub fn has_number_semantics(&self) -> bool {
        self.scale.is_some() || self.value_offset.is_some()
    }

    /// Invert the parameter's linear transform to get the raw value a decoded
    /// `value` encodes to. `None` when `scale` is zero (not invertible).
    pub fn invert_transform(&self, value: f64) -> Option<f64> {
        let scale = self.scale.unwrap_or(1.0);
        if scale == 0.0 {
            return None;
        }
        Some(((value - self.value_offset.unwrap_or(0.0)) / scale).round())
    }
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
    /// Additive term applied after [`Self::scale`]:
    /// `value = raw * scale + value_offset`.
    ///
    /// Most real scalings carry one — the automotive `x - 40` idiom, or the
    /// Gerbing heat controller's `raw * 0.5 + 85` °F — and dropping it makes
    /// the reading quietly wrong rather than visibly broken. Named
    /// `value_offset` upstream because bare `offset` already means a byte
    /// position on this struct.
    ///
    /// The transform is linear on purpose: a command parameter carrying the
    /// same semantics is encoded by inverting it,
    /// `raw = round((value - value_offset) / scale)`.
    #[serde(default)]
    pub value_offset: Option<f64>,
    /// Unit symbol for the decoded field, used when the entity that surfaces
    /// this reading does not name one itself.
    #[serde(default)]
    pub unit: Option<String>,
    /// Code table for an enumerated number: raw value → human name, e.g.
    /// Ember's `liquid_state` (`5: heating`) or its C/F display preference.
    /// Keys are integers in YAML; normalized to strings so a consumer never
    /// has to care whether the author wrote `0`, `0x46` or `"0"`.
    #[serde(default, deserialize_with = "de_value_table")]
    pub values: Option<IndexMap<String, String>>,
    /// Whether the wire unit is a constant of the protocol (`fixed`, the
    /// default) or follows a device setting (`device_setting`).
    ///
    /// Confusing the two corrupts every reading: Ember always encodes
    /// centi-°C and its C/F characteristic changes only the display, while the
    /// Inkbird iBBQ transmits raw numbers in whichever unit the device is
    /// currently set to — the same raw 165 is 165 °C or 165 °F.
    #[serde(default)]
    pub unit_source: Option<String>,
    /// Where to learn the unit when [`Self::unit_source`] is `device_setting`.
    /// The schema requires it in that case, so a consumer always has an exit.
    #[serde(default)]
    pub unit_reference: Option<String>,
}

/// Every field but the four that locate and size the value is optional, and
/// the optional set grows as upstream's number-semantics vocabulary does.
/// Written by hand so `ValueType` keeps no arbitrary default of its own; the
/// placeholder here only ever applies to a `..Default::default()` literal,
/// which must then state the type it means.
impl Default for FormatField {
    fn default() -> Self {
        Self {
            offset: 0,
            length: 0,
            name: String::new(),
            field_type: ValueType::Bytes,
            mock_default: None,
            scale: None,
            value_offset: None,
            unit: None,
            values: None,
            unit_source: None,
            unit_reference: None,
        }
    }
}

impl FormatField {
    /// True when this field's unit is not a constant of the protocol, so a
    /// reading rendered with a fixed unit would be a guess.
    pub fn unit_follows_device_setting(&self) -> bool {
        self.unit_source.as_deref() == Some("device_setting")
    }

    /// Apply the field's linear transform: `value = raw * scale +
    /// value_offset`. Returns the raw value unchanged when neither is
    /// declared, which is the common case.
    pub fn apply_transform(&self, raw: f64) -> f64 {
        raw * self.scale.unwrap_or(1.0) + self.value_offset.unwrap_or(0.0)
    }

    /// Invert the linear transform to get the raw value a decoded `value`
    /// encodes to: `raw = round((value - value_offset) / scale)`.
    ///
    /// `None` when `scale` is zero — that transform is not invertible, and
    /// silently substituting 1.0 would write a number the user never asked
    /// for.
    pub fn invert_transform(&self, value: f64) -> Option<f64> {
        let scale = self.scale.unwrap_or(1.0);
        if scale == 0.0 {
            return None;
        }
        Some(((value - self.value_offset.unwrap_or(0.0)) / scale).round())
    }
}

/// Deserialize a `values:` code table, accepting integer, hex-string or
/// string keys and normalizing all of them to decimal strings.
///
/// Authors write `0: standby` (a YAML integer) and `0x46: F` (which YAML
/// parses as the string "0x46", since YAML 1.2 has no hex scalar). Both mean
/// a raw numeric code, so both normalize to the same decimal form a decoded
/// value will be looked up by. Anything genuinely non-numeric (`default:` in
/// upstream's `unit_values`) is kept verbatim rather than rejected.
fn de_value_table<'de, D>(deserializer: D) -> Result<Option<IndexMap<String, String>>, D::Error>
where
    D: serde::Deserializer<'de>,
{
    let Some(raw) =
        Option::<IndexMap<serde_yaml::Value, serde_yaml::Value>>::deserialize(deserializer)?
    else {
        return Ok(None);
    };

    let mut table = IndexMap::with_capacity(raw.len());
    for (key, value) in raw {
        let key = match &key {
            serde_yaml::Value::Number(n) => n.to_string(),
            serde_yaml::Value::Bool(b) => b.to_string(),
            serde_yaml::Value::String(s) => s
                .strip_prefix("0x")
                .or_else(|| s.strip_prefix("0X"))
                .and_then(|hex| i64::from_str_radix(hex, 16).ok())
                .map_or_else(|| s.clone(), |n| n.to_string()),
            other => {
                return Err(serde::de::Error::custom(format!(
                    "value table keys must be scalars, got {other:?}"
                )))
            }
        };
        // Values are names; a YAML author may leave one unquoted and have it
        // parse as a number or bool, so render whatever arrived as text.
        let value = match value {
            serde_yaml::Value::String(s) => s,
            serde_yaml::Value::Number(n) => n.to_string(),
            serde_yaml::Value::Bool(b) => b.to_string(),
            other => {
                return Err(serde::de::Error::custom(format!(
                    "value table entries must be scalars, got {other:?}"
                )))
            }
        };
        table.insert(key, value);
    }
    Ok(Some(table))
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

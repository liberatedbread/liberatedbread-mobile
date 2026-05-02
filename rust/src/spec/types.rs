// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Rust types mapping to the OpenGreenIoT device spec YAML schema.
//! See: opengreeniot/device-specs/schema.json

use serde::Deserialize;
use std::collections::HashMap;

/// Top-level device specification.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceSpec {
    pub device: DeviceInfo,
    pub services: Vec<Service>,
}

impl DeviceSpec {
    /// Find a characteristic by UUID across all services (case-insensitive).
    pub fn find_characteristic(&self, uuid: &str) -> Option<(&Service, &Characteristic)> {
        let target = uuid.to_lowercase();
        self.services.iter().find_map(|svc| {
            svc.characteristics
                .iter()
                .find(|c| c.uuid.to_lowercase() == target)
                .map(|c| (svc, c))
        })
    }
}

/// Device metadata and identification.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceInfo {
    pub name: String,
    pub manufacturer: String,
    pub manufacturer_status: ManufacturerStatus,
    pub protocol: Protocol,
    pub notes: Option<String>,
    pub identification: Option<Identification>,
}

/// Why this device needs open-source rescue.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum ManufacturerStatus {
    Abandoned,
    Shutdown,
    Unsupported,
}

impl std::fmt::Display for ManufacturerStatus {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ManufacturerStatus::Abandoned => write!(f, "abandoned"),
            ManufacturerStatus::Shutdown => write!(f, "shutdown"),
            ManufacturerStatus::Unsupported => write!(f, "unsupported"),
        }
    }
}

/// Primary communication protocol.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    Ble,
    Wifi,
    Zigbee,
    Zwave,
}

impl std::fmt::Display for Protocol {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Protocol::Ble => write!(f, "ble"),
            Protocol::Wifi => write!(f, "wifi"),
            Protocol::Zigbee => write!(f, "zigbee"),
            Protocol::Zwave => write!(f, "zwave"),
        }
    }
}

/// How to identify this device during BLE scanning.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Identification {
    pub local_name_prefix: Option<String>,
    pub service_uuids: Option<Vec<String>>,
}

/// A BLE GATT service.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Service {
    pub uuid: String,
    pub name: String,
    pub characteristics: Vec<Characteristic>,
}

/// A BLE GATT characteristic.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Characteristic {
    pub uuid: String,
    pub name: String,
    pub properties: Vec<CharacteristicProperty>,
    pub commands: Option<HashMap<String, Command>>,
    pub format: Option<Vec<FormatField>>,
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
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Command {
    pub description: String,
    /// Fixed byte sequence for this command.
    pub value: Option<Vec<u8>>,
    /// Parameterized byte sequence. Strings are parameter references like "{brightness}".
    pub template: Option<Vec<TemplateElement>>,
    /// Parameter definitions for template commands.
    pub parameters: Option<HashMap<String, Parameter>>,
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
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Parameter {
    #[serde(rename = "type")]
    pub value_type: ValueType,
    pub min: Option<i64>,
    pub max: Option<i64>,
}

/// Binary format field for parsing readable/notifiable characteristic values.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
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
            ValueType::Bytes | ValueType::String => None,
        }
    }
}

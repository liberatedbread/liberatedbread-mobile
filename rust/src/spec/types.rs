// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Rust types mapping to the OpenGreenIoT device spec YAML schema.
//! See: opengreeniot/device-specs/schema.json

use serde::Deserialize;
use std::collections::HashMap;

/// Top-level device specification.
#[derive(Debug, Clone, Deserialize)]
pub struct DeviceSpec {
    pub device: DeviceInfo,
    pub services: Vec<Service>,
    pub entities: Option<Vec<Entity>>,
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

/// Primary communication protocol.
#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Protocol {
    Ble,
    Wifi,
    Zigbee,
    Zwave,
}

/// How to identify this device during BLE scanning.
#[derive(Debug, Clone, Deserialize)]
pub struct Identification {
    pub local_name_prefix: Option<String>,
    pub service_uuids: Option<Vec<String>>,
}

/// A BLE GATT service.
#[derive(Debug, Clone, Deserialize)]
pub struct Service {
    pub uuid: String,
    pub name: String,
    pub characteristics: Vec<Characteristic>,
}

/// A BLE GATT characteristic.
#[derive(Debug, Clone, Deserialize)]
pub struct Characteristic {
    pub uuid: String,
    pub name: String,
    pub properties: Vec<CharacteristicProperty>,
    pub commands: Option<HashMap<String, Command>>,
    pub format: Option<Vec<FormatField>>,
    /// Encryption required for this characteristic's data.
    pub encryption: Option<EncryptionConfig>,
    /// Packet framing configuration.
    pub framing: Option<FramingConfig>,
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
                if v.starts_with('{') && v.ends_with('}') {
                    Ok(TemplateElement::Param(v[1..v.len() - 1].to_string()))
                } else {
                    Err(E::custom(format!(
                        "parameter reference must be wrapped in braces: {v}"
                    )))
                }
            }
        }

        deserializer.deserialize_any(TemplateElementVisitor)
    }
}

/// A command parameter definition.
#[derive(Debug, Clone, Deserialize)]
pub struct Parameter {
    #[serde(rename = "type")]
    pub value_type: ValueType,
    pub min: Option<i64>,
    pub max: Option<i64>,
}

/// Binary format field for parsing readable/notifiable characteristic values.
#[derive(Debug, Clone, Deserialize)]
pub struct FormatField {
    pub offset: usize,
    pub length: usize,
    pub name: String,
    #[serde(rename = "type")]
    pub field_type: ValueType,
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

/// Encryption configuration for a characteristic or service.
#[derive(Debug, Clone, Deserialize)]
pub struct EncryptionConfig {
    /// Algorithm identifier, e.g., "aes-128-ecb", "aes-128-ofb", "aes-128-ctr".
    pub algorithm: String,
    /// How the encryption key is obtained.
    /// "static" = hardcoded, "handshake" = established via init sequence,
    /// "device-specific" = derived from device identity.
    pub key_derivation: Option<String>,
    /// Static key bytes (hex string), if key_derivation is "static".
    pub static_key: Option<String>,
}

/// Packet framing configuration for a characteristic.
#[derive(Debug, Clone, Deserialize)]
pub struct FramingConfig {
    /// Whether the payload is prefixed with its length.
    pub length_prefix: Option<bool>,
    /// Checksum algorithm: "crc32", "xor", "sum".
    pub checksum: Option<String>,
    /// Maximum chunk size for large payloads (image uploads, etc.).
    pub max_chunk_size: Option<usize>,
}

/// Home Assistant entity mapping (optional, consumed by HA integration).
#[derive(Debug, Clone, Deserialize)]
pub struct Entity {
    pub platform: String,
    pub name: String,
    pub device_class: Option<String>,
    pub unit: Option<String>,
    pub features: Option<Vec<String>>,
    pub state_characteristic: Option<String>,
    pub state_mapping: Option<HashMap<String, serde_yaml::Value>>,
    pub commands: Option<HashMap<String, String>>,
}

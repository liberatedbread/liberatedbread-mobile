// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Public API exposed to Flutter via flutter_rust_bridge.
//! This module defines the FFI boundary — keep types simple and serializable.

use std::collections::HashMap;

use crate::codec::types::DecodedValue;
use crate::protocol::profiles;
use crate::protocol::registry::ProtocolRegistry;
use crate::spec::parser::parse_device_spec;
use crate::spec::types::{CharacteristicProperty, DeviceSpec, ManufacturerStatus, Protocol};

use once_cell::sync::Lazy;

/// Global protocol registry. Initialized once, shared across all API calls.
/// No Mutex needed — `ProtocolRegistry` has no mutable state.
static REGISTRY: Lazy<ProtocolRegistry> = Lazy::new(ProtocolRegistry::new);

// ── DTO types for the FFI boundary ──────────────────────────────────────────
// These are simpler, FRB-friendly versions of the internal types.

/// A parsed device specification, ready for use by the Flutter app.
#[derive(Debug, Clone)]
pub struct DeviceSpecDto {
    pub device_name: String,
    pub manufacturer: String,
    pub manufacturer_status: String,
    pub protocol: String,
    pub notes: Option<String>,
    pub local_name_prefix: Option<String>,
    pub service_uuids: Vec<String>,
    pub services: Vec<ServiceDto>,
}

#[derive(Debug, Clone)]
pub struct ServiceDto {
    pub uuid: String,
    pub name: String,
    pub characteristics: Vec<CharacteristicDto>,
}

#[derive(Debug, Clone)]
pub struct CharacteristicDto {
    pub uuid: String,
    pub name: String,
    pub can_read: bool,
    pub can_write: bool,
    pub can_notify: bool,
    pub commands: Vec<CommandDto>,
    pub format_fields: Vec<FormatFieldDto>,
}

#[derive(Debug, Clone)]
pub struct CommandDto {
    pub name: String,
    pub description: String,
    pub parameters: Vec<ParameterDto>,
    /// true if this is a fixed-value command (no parameters needed).
    pub is_fixed: bool,
}

#[derive(Debug, Clone)]
pub struct ParameterDto {
    pub name: String,
    pub value_type: String,
    pub min: Option<f64>,
    pub max: Option<f64>,
}

#[derive(Debug, Clone)]
pub struct FormatFieldDto {
    pub name: String,
    pub field_type: String,
    pub offset: u32,
    pub length: u32,
}

/// A decoded value from a characteristic read.
#[derive(Debug, Clone)]
pub struct DecodedValueDto {
    pub name: String,
    pub value_type: String,
    pub display: String,
    pub bool_value: Option<bool>,
    pub int_value: Option<i64>,
    pub uint_value: Option<i64>, // FRB doesn't support u64, use i64
    pub string_value: Option<String>,
}

// ── Conversion from internal types ──────────────────────────────────────────

impl From<&DeviceSpec> for DeviceSpecDto {
    fn from(spec: &DeviceSpec) -> Self {
        let ident = spec.device.identification.as_ref();
        Self {
            device_name: spec.device.name.clone(),
            manufacturer: spec.device.manufacturer.clone(),
            manufacturer_status: match spec.device.manufacturer_status {
                ManufacturerStatus::Abandoned => "abandoned".into(),
                ManufacturerStatus::Shutdown => "shutdown".into(),
                ManufacturerStatus::Unsupported => "unsupported".into(),
            },
            protocol: match spec.device.protocol {
                Protocol::Ble => "ble".into(),
                Protocol::Wifi => "wifi".into(),
                Protocol::Zigbee => "zigbee".into(),
                Protocol::Zwave => "zwave".into(),
            },
            notes: spec.device.notes.clone(),
            local_name_prefix: ident.and_then(|i| i.local_name_prefix.clone()),
            service_uuids: ident
                .and_then(|i| i.service_uuids.clone())
                .unwrap_or_default(),
            services: spec
                .services
                .iter()
                .map(|s| ServiceDto {
                    uuid: s.uuid.clone(),
                    name: s.name.clone(),
                    characteristics: s
                        .characteristics
                        .iter()
                        .map(|c| CharacteristicDto {
                            uuid: c.uuid.clone(),
                            name: c.name.clone(),
                            can_read: c.properties.contains(&CharacteristicProperty::Read),
                            can_write: c.properties.contains(&CharacteristicProperty::Write)
                                || c.properties
                                    .contains(&CharacteristicProperty::WriteWithoutResponse),
                            can_notify: c.properties.contains(&CharacteristicProperty::Notify)
                                || c.properties.contains(&CharacteristicProperty::Indicate),
                            commands: c
                                .commands
                                .as_ref()
                                .map(|cmds| {
                                    cmds.iter()
                                        .map(|(name, cmd)| CommandDto {
                                            name: name.clone(),
                                            description: cmd.description.clone(),
                                            is_fixed: cmd.value.is_some(),
                                            parameters: cmd
                                                .parameters
                                                .as_ref()
                                                .map(|params| {
                                                    params
                                                        .iter()
                                                        .map(|(pname, p)| ParameterDto {
                                                            name: pname.clone(),
                                                            value_type: p.value_type.to_string(),
                                                            min: p.min.map(|v| v as f64),
                                                            max: p.max.map(|v| v as f64),
                                                        })
                                                        .collect()
                                                })
                                                .unwrap_or_default(),
                                        })
                                        .collect()
                                })
                                .unwrap_or_default(),
                            format_fields: c
                                .format
                                .as_ref()
                                .map(|fields| {
                                    fields
                                        .iter()
                                        .map(|f| FormatFieldDto {
                                            name: f.name.clone(),
                                            field_type: f.field_type.to_string(),
                                            offset: f.offset as u32,
                                            length: f.length as u32,
                                        })
                                        .collect()
                                })
                                .unwrap_or_default(),
                        })
                        .collect(),
                })
                .collect(),
        }
    }
}

fn decoded_value_to_dto(name: &str, value: &DecodedValue) -> DecodedValueDto {
    let mut dto = DecodedValueDto {
        name: name.into(),
        value_type: match value {
            DecodedValue::Bool(_) => "bool",
            DecodedValue::Int(_) => "int",
            DecodedValue::Uint(_) => "uint",
            DecodedValue::Bytes(_) => "bytes",
            DecodedValue::String(_) => "string",
        }
        .into(),
        display: value.display(),
        bool_value: None,
        int_value: None,
        uint_value: None,
        string_value: None,
    };
    match value {
        DecodedValue::Bool(v) => dto.bool_value = Some(*v),
        DecodedValue::Int(v) => dto.int_value = Some(*v),
        DecodedValue::Uint(v) => dto.uint_value = Some((*v).min(i64::MAX as u64) as i64),
        DecodedValue::Bytes(_) => dto.string_value = Some(value.display()),
        DecodedValue::String(v) => dto.string_value = Some(v.clone()),
    }
    dto
}

// ── Public API functions (exposed to Dart via FRB) ──────────────────────────

/// Parse a device spec from a YAML string and return a DTO.
pub fn load_device_spec(yaml: String) -> anyhow::Result<DeviceSpecDto> {
    let spec = parse_device_spec(&yaml)?;
    Ok(DeviceSpecDto::from(&spec))
}

/// Check if a scanned device matches a spec based on name prefix and/or service UUIDs.
pub fn device_matches_spec(
    spec: &DeviceSpecDto,
    device_name: &str,
    advertised_service_uuids: &[String],
) -> bool {
    // Check name prefix
    if let Some(ref prefix) = spec.local_name_prefix {
        if device_name.starts_with(prefix) {
            return true;
        }
    }

    // Check service UUIDs
    if !spec.service_uuids.is_empty() {
        for spec_uuid in &spec.service_uuids {
            let spec_lower = spec_uuid.to_lowercase();
            if advertised_service_uuids
                .iter()
                .any(|a| a.to_lowercase() == spec_lower)
            {
                return true;
            }
        }
    }

    false
}

/// Find the first matching spec for a scanned device.
pub fn match_device_to_spec(
    specs: Vec<DeviceSpecDto>,
    device_name: String,
    advertised_service_uuids: Vec<String>,
) -> Option<DeviceSpecDto> {
    specs
        .into_iter()
        .find(|spec| device_matches_spec(spec, &device_name, &advertised_service_uuids))
}

/// Encode a named command into bytes for a BLE write.
pub fn encode_command(
    yaml: String,
    char_uuid: String,
    command_name: String,
    params: HashMap<String, f64>,
) -> anyhow::Result<Vec<u8>> {
    let spec = parse_device_spec(&yaml)?;
    let proto = REGISTRY.get_protocol(&spec);
    Ok(proto.encode_command(&char_uuid, &command_name, &params)?)
}

/// Decode raw bytes from a BLE read/notify into named values.
pub fn decode_value(
    yaml: String,
    char_uuid: String,
    bytes: Vec<u8>,
) -> anyhow::Result<Vec<DecodedValueDto>> {
    let spec = parse_device_spec(&yaml)?;
    let proto = REGISTRY.get_protocol(&spec);
    let decoded = proto
        .decode_value(&char_uuid, &bytes)
        .map_err(anyhow::Error::from)?;
    Ok(decoded
        .iter()
        .map(|(name, value)| decoded_value_to_dto(name, value))
        .collect())
}

/// Greet — a simple test function to verify the FRB bridge works.
pub fn greet(name: String) -> String {
    format!("Hello from OpenGreenIoT Rust core, {}!", name)
}

// ── Standard profile types and API ─────────────────────────────────────────

/// Info about a recognized standard Bluetooth profile.
#[derive(Debug, Clone)]
pub struct ProfileInfoDto {
    pub service_uuid: String,
    pub profile_name: String,
    pub characteristics: Vec<ProfileCharacteristicDto>,
}

/// A characteristic within a standard profile.
#[derive(Debug, Clone)]
pub struct ProfileCharacteristicDto {
    pub uuid: String,
    pub name: String,
    pub can_read: bool,
    pub can_write: bool,
    pub can_notify: bool,
}

/// Given a list of discovered service UUIDs, return info about any that
/// match recognized standard Bluetooth profiles (Battery, Device Info, etc.).
///
/// Services that don't match a standard profile are omitted from the result.
pub fn identify_standard_profiles(service_uuids: Vec<String>) -> Vec<ProfileInfoDto> {
    service_uuids
        .iter()
        .filter_map(|uuid| {
            profiles::lookup(uuid).map(|profile| ProfileInfoDto {
                service_uuid: uuid.clone(),
                profile_name: profile.name().to_string(),
                characteristics: profile
                    .characteristics()
                    .into_iter()
                    .map(|c| ProfileCharacteristicDto {
                        uuid: c.uuid,
                        name: c.name,
                        can_read: c.can_read,
                        can_write: c.can_write,
                        can_notify: c.can_notify,
                    })
                    .collect(),
            })
        })
        .collect()
}

/// Decode a characteristic value using a built-in standard profile.
///
/// This does not require a YAML device spec — the profile's format is
/// defined by the Bluetooth specification.
pub fn decode_standard_profile_value(
    service_uuid: String,
    char_uuid: String,
    bytes: Vec<u8>,
) -> anyhow::Result<Vec<DecodedValueDto>> {
    let profile = profiles::lookup(&service_uuid)
        .ok_or_else(|| anyhow::anyhow!("no standard profile for service UUID: {}", service_uuid))?;
    let proto = profile.create_protocol();
    let decoded = proto.decode_value(&char_uuid, &bytes)?;
    Ok(decoded
        .iter()
        .map(|(name, value)| decoded_value_to_dto(name, value))
        .collect())
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_YAML: &str = r#"
device:
  name: "Test Bulb"
  manufacturer: "Test"
  manufacturer_status: "abandoned"
  protocol: "ble"
  identification:
    local_name_prefix: "TEST_"
    service_uuids:
      - "0000fff0-0000-1000-8000-00805f9b34fb"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
        commands:
          power_on:
            description: "Turn on"
            value: [0x01, 0x01]
      - uuid: "0000fff2-0000-1000-8000-00805f9b34fb"
        name: "Status"
        properties: ["read", "notify"]
        format:
          - offset: 0
            length: 1
            name: "power_state"
            type: "bool"
          - offset: 1
            length: 1
            name: "brightness"
            type: "uint8"
"#;

    #[test]
    fn load_spec_dto() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        assert_eq!(dto.device_name, "Test Bulb");
        assert_eq!(dto.manufacturer_status, "abandoned");
        assert_eq!(dto.services.len(), 1);
        assert_eq!(dto.services[0].characteristics.len(), 2);

        let cmd_char = &dto.services[0].characteristics[0];
        assert!(cmd_char.can_write);
        assert!(!cmd_char.can_read);
        assert_eq!(cmd_char.commands.len(), 1);
        assert_eq!(cmd_char.commands[0].name, "power_on");
        assert!(cmd_char.commands[0].is_fixed);
    }

    #[test]
    fn match_by_name_prefix() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        assert!(device_matches_spec(&dto, "TEST_Living_Room", &[]));
        assert!(!device_matches_spec(&dto, "OTHER_Device", &[]));
    }

    #[test]
    fn match_by_service_uuid() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        assert!(device_matches_spec(
            &dto,
            "Unknown",
            &["0000fff0-0000-1000-8000-00805f9b34fb".into()]
        ));
    }

    #[test]
    fn encode_decode_roundtrip() {
        let bytes = encode_command(
            TEST_YAML.into(),
            "0000fff1-0000-1000-8000-00805f9b34fb".into(),
            "power_on".into(),
            HashMap::new(),
        )
        .unwrap();
        assert_eq!(bytes, vec![0x01, 0x01]);

        let values = decode_value(
            TEST_YAML.into(),
            "0000fff2-0000-1000-8000-00805f9b34fb".into(),
            vec![1, 80],
        )
        .unwrap();
        assert_eq!(values.len(), 2);

        let power = values.iter().find(|v| v.name == "power_state").unwrap();
        assert_eq!(power.bool_value, Some(true));

        let brightness = values.iter().find(|v| v.name == "brightness").unwrap();
        assert_eq!(brightness.uint_value, Some(80));
    }

    #[test]
    fn greet_works() {
        assert_eq!(
            greet("World".into()),
            "Hello from OpenGreenIoT Rust core, World!"
        );
    }

    #[test]
    fn identify_battery_and_device_info() {
        let uuids = vec![
            "0000180f-0000-1000-8000-00805f9b34fb".to_string(), // Battery
            "0000180a-0000-1000-8000-00805f9b34fb".to_string(), // Device Info
            "0000fff0-0000-1000-8000-00805f9b34fb".to_string(), // Custom (unknown)
        ];
        let profiles = identify_standard_profiles(uuids);
        assert_eq!(profiles.len(), 2);

        let battery = profiles
            .iter()
            .find(|p| p.profile_name == "Battery Service")
            .unwrap();
        assert_eq!(battery.characteristics.len(), 1);
        assert_eq!(battery.characteristics[0].name, "Battery Level");
        assert!(battery.characteristics[0].can_read);
        assert!(battery.characteristics[0].can_notify);

        let device_info = profiles
            .iter()
            .find(|p| p.profile_name == "Device Information")
            .unwrap();
        assert_eq!(device_info.characteristics.len(), 7);
    }

    #[test]
    fn identify_no_standard_profiles() {
        let uuids = vec!["0000fff0-0000-1000-8000-00805f9b34fb".to_string()];
        let profiles = identify_standard_profiles(uuids);
        assert!(profiles.is_empty());
    }

    #[test]
    fn decode_standard_battery_level() {
        let values =
            decode_standard_profile_value("180f".to_string(), "2a19".to_string(), vec![85])
                .unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].name, "battery_percent");
        assert_eq!(values[0].uint_value, Some(85));
    }

    #[test]
    fn decode_standard_device_info() {
        let values = decode_standard_profile_value(
            "180a".to_string(),
            "2a29".to_string(),
            b"TestCorp".to_vec(),
        )
        .unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].name, "value");
        assert_eq!(values[0].string_value, Some("TestCorp".to_string()));
    }

    #[test]
    fn decode_standard_unknown_service_fails() {
        let result = decode_standard_profile_value("fff0".to_string(), "fff1".to_string(), vec![0]);
        assert!(result.is_err());
    }
}

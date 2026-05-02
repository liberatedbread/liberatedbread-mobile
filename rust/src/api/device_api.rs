// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Public API exposed to Flutter via flutter_rust_bridge.
//! This module defines the FFI boundary — keep types simple and serializable.

use std::collections::HashMap;

use crate::codec::types::DecodedValue;
use crate::protocol::dispatch::select_protocol;
use crate::protocol::profiles;
use crate::spec::parser::parse_device_spec;
use crate::spec::types::{
    Characteristic, CharacteristicProperty, Command, DeviceSpec, FormatField, Parameter, Service,
};

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

/// One match returned by [`match_device_to_spec`]. Callers pick whichever
/// match suits them — sort by `matched_service_uuids.len()`, prefer name-prefix
/// matches, etc.
#[derive(Debug, Clone)]
pub struct MatchResult {
    pub spec: DeviceSpecDto,
    pub matched_by_name_prefix: bool,
    /// The advertised service UUIDs (lowercased) that intersect with the
    /// spec's identification. Empty when no UUIDs matched.
    pub matched_service_uuids: Vec<String>,
}

// ── Conversions from internal types ─────────────────────────────────────────
// All conversions go through `From` for symmetry. The tuple impls
// (`From<(&str, ...)>`) carry a HashMap key into the DTO.

impl From<&DeviceSpec> for DeviceSpecDto {
    fn from(spec: &DeviceSpec) -> Self {
        let ident = spec.device.identification.as_ref();
        Self {
            device_name: spec.device.name.clone(),
            manufacturer: spec.device.manufacturer.clone(),
            manufacturer_status: spec.device.manufacturer_status.to_string(),
            protocol: spec.device.protocol.to_string(),
            notes: spec.device.notes.clone(),
            local_name_prefix: ident.and_then(|i| i.local_name_prefix.clone()),
            service_uuids: ident
                .and_then(|i| i.service_uuids.clone())
                .unwrap_or_default(),
            services: spec.services.iter().map(ServiceDto::from).collect(),
        }
    }
}

impl From<&Service> for ServiceDto {
    fn from(service: &Service) -> Self {
        Self {
            uuid: service.uuid.clone(),
            name: service.name.clone(),
            characteristics: service
                .characteristics
                .iter()
                .map(CharacteristicDto::from)
                .collect(),
        }
    }
}

impl From<&Characteristic> for CharacteristicDto {
    fn from(c: &Characteristic) -> Self {
        Self {
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
                        .map(|(name, cmd)| CommandDto::from((name.as_str(), cmd)))
                        .collect()
                })
                .unwrap_or_default(),
            format_fields: c
                .format
                .as_ref()
                .map(|fields| fields.iter().map(FormatFieldDto::from).collect())
                .unwrap_or_default(),
        }
    }
}

impl From<&FormatField> for FormatFieldDto {
    fn from(f: &FormatField) -> Self {
        Self {
            name: f.name.clone(),
            field_type: f.field_type.to_string(),
            offset: f.offset as u32,
            length: f.length as u32,
        }
    }
}

impl From<(&str, &Command)> for CommandDto {
    fn from((name, cmd): (&str, &Command)) -> Self {
        Self {
            name: name.to_string(),
            description: cmd.description.clone(),
            is_fixed: cmd.value.is_some(),
            parameters: cmd
                .parameters
                .as_ref()
                .map(|params| {
                    params
                        .iter()
                        .map(|(pname, p)| ParameterDto::from((pname.as_str(), p)))
                        .collect()
                })
                .unwrap_or_default(),
        }
    }
}

impl From<(&str, &Parameter)> for ParameterDto {
    fn from((name, p): (&str, &Parameter)) -> Self {
        Self {
            name: name.to_string(),
            value_type: p.value_type.to_string(),
            min: p.min.map(|v| v as f64),
            max: p.max.map(|v| v as f64),
        }
    }
}

impl From<(&str, &DecodedValue)> for DecodedValueDto {
    fn from((name, value): (&str, &DecodedValue)) -> Self {
        let mut dto = Self {
            name: name.to_string(),
            value_type: match value {
                DecodedValue::Bool(_) => "bool",
                DecodedValue::Int(_) => "int",
                DecodedValue::Uint(_) => "uint",
                DecodedValue::Bytes(_) => "bytes",
                DecodedValue::String(_) => "string",
            }
            .to_string(),
            display: value.display(),
            bool_value: None,
            int_value: None,
            uint_value: None,
            string_value: None,
        };
        match value {
            DecodedValue::Bool(v) => dto.bool_value = Some(*v),
            DecodedValue::Int(v) => dto.int_value = Some(*v),
            DecodedValue::Uint(v) => {
                // FRB lacks u64 support; clamp into i64 and, when the
                // clamp actually fired, also surface the truthful value
                // as a string so the UI doesn't silently see i64::MAX.
                if *v > i64::MAX as u64 {
                    dto.string_value = Some(v.to_string());
                }
                dto.uint_value = Some((*v).min(i64::MAX as u64) as i64);
            }
            DecodedValue::Bytes(_) => dto.string_value = Some(value.display()),
            DecodedValue::String(v) => dto.string_value = Some(v.clone()),
        }
        dto
    }
}

// ── Public API functions (exposed to Dart via FRB) ──────────────────────────

/// Parse a device spec from a YAML string and return a DTO.
pub fn load_device_spec(yaml: String) -> anyhow::Result<DeviceSpecDto> {
    let spec = parse_device_spec(&yaml)?;
    Ok(DeviceSpecDto::from(&spec))
}

/// Find every spec matching a scanned device, with the reasons it matched.
///
/// Returns `vec![]` when nothing matches. A spec matches when:
/// - its `local_name_prefix` is a prefix of `device_name`, **or**
/// - any of its `service_uuids` (case-insensitive) appears in `advertised_service_uuids`.
///
/// Both axes are reported separately so the caller can decide how to rank.
pub fn match_device_to_spec(
    specs: Vec<DeviceSpecDto>,
    device_name: String,
    advertised_service_uuids: Vec<String>,
) -> Vec<MatchResult> {
    let advertised_lower: Vec<String> = advertised_service_uuids
        .iter()
        .map(|u| u.to_lowercase())
        .collect();

    specs
        .into_iter()
        .filter_map(|spec| {
            let name_match = spec
                .local_name_prefix
                .as_ref()
                .is_some_and(|prefix| device_name.starts_with(prefix));

            // Return the lowercased intersection. Matches the docstring's
            // contract and gives Dart callers a predictable casing.
            let matched_service_uuids: Vec<String> = spec
                .service_uuids
                .iter()
                .filter_map(|spec_uuid| {
                    let lower = spec_uuid.to_lowercase();
                    advertised_lower.contains(&lower).then_some(lower)
                })
                .collect();

            if name_match || !matched_service_uuids.is_empty() {
                Some(MatchResult {
                    spec,
                    matched_by_name_prefix: name_match,
                    matched_service_uuids,
                })
            } else {
                None
            }
        })
        .collect()
}

/// Encode a named command into bytes for a BLE write.
///
/// Provide either `spec_yaml` (custom device) or `service_uuid` (standard
/// profile — though standard profiles are read-only). When both are supplied,
/// the spec wins — see [`select_protocol`].
pub fn encode_command(
    spec_yaml: Option<String>,
    service_uuid: Option<String>,
    char_uuid: String,
    command_name: String,
    params: HashMap<String, f64>,
) -> anyhow::Result<Vec<u8>> {
    let proto = select_protocol(spec_yaml.as_deref(), service_uuid.as_deref())?;
    Ok(proto.encode_command(&char_uuid, &command_name, &params)?)
}

/// Decode raw bytes from a BLE read/notify into named values.
///
/// Provide either `spec_yaml` (custom device) or `service_uuid` (standard
/// profile). When both are supplied, the spec wins — see [`select_protocol`].
pub fn decode_value(
    spec_yaml: Option<String>,
    service_uuid: Option<String>,
    char_uuid: String,
    bytes: Vec<u8>,
) -> anyhow::Result<Vec<DecodedValueDto>> {
    let proto = select_protocol(spec_yaml.as_deref(), service_uuid.as_deref())?;
    let decoded = proto.decode_value(&char_uuid, &bytes)?;
    Ok(decoded
        .iter()
        .map(|(name, value)| DecodedValueDto::from((name.as_str(), value)))
        .collect())
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
        assert_eq!(dto.protocol, "ble");
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
    fn match_by_name_prefix_only() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        let results = match_device_to_spec(vec![dto], "TEST_Living_Room".into(), vec![]);
        assert_eq!(results.len(), 1);
        assert!(results[0].matched_by_name_prefix);
        assert!(results[0].matched_service_uuids.is_empty());
    }

    #[test]
    fn match_by_service_uuid_only() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        // Advertised UUID uses uppercase to exercise the case-insensitive
        // intersection, then assert the returned form is lowercased.
        let results = match_device_to_spec(
            vec![dto],
            "Unknown".into(),
            vec!["0000FFF0-0000-1000-8000-00805F9B34FB".into()],
        );
        assert_eq!(results.len(), 1);
        assert!(!results[0].matched_by_name_prefix);
        assert_eq!(
            results[0].matched_service_uuids,
            vec!["0000fff0-0000-1000-8000-00805f9b34fb".to_string()]
        );
    }

    #[test]
    fn match_on_both_axes() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        let results = match_device_to_spec(
            vec![dto],
            "TEST_Living_Room".into(),
            vec!["0000fff0-0000-1000-8000-00805f9b34fb".into()],
        );
        assert_eq!(results.len(), 1);
        assert!(results[0].matched_by_name_prefix);
        assert_eq!(results[0].matched_service_uuids.len(), 1);
    }

    #[test]
    fn match_no_results() {
        let dto = load_device_spec(TEST_YAML.into()).unwrap();
        let results = match_device_to_spec(vec![dto], "OTHER_Device".into(), vec![]);
        assert!(results.is_empty());
    }

    #[test]
    fn match_returns_each_matching_spec() {
        let a = load_device_spec(TEST_YAML.into()).unwrap();
        let b = load_device_spec(TEST_YAML.into()).unwrap();
        let results = match_device_to_spec(vec![a, b], "TEST_xx".into(), vec![]);
        assert_eq!(results.len(), 2);
    }

    #[test]
    fn encode_decode_roundtrip_via_spec() {
        let bytes = encode_command(
            Some(TEST_YAML.into()),
            None,
            "0000fff1-0000-1000-8000-00805f9b34fb".into(),
            "power_on".into(),
            HashMap::new(),
        )
        .unwrap();
        assert_eq!(bytes, vec![0x01, 0x01]);

        let values = decode_value(
            Some(TEST_YAML.into()),
            None,
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
    fn decode_via_standard_battery_profile() {
        let values =
            decode_value(None, Some("180f".to_string()), "2a19".to_string(), vec![85]).unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].name, "battery_percent");
        assert_eq!(values[0].uint_value, Some(85));
    }

    #[test]
    fn decode_via_standard_device_info_profile() {
        let values = decode_value(
            None,
            Some("180a".to_string()),
            "2a29".to_string(),
            b"TestCorp".to_vec(),
        )
        .unwrap();
        assert_eq!(values.len(), 1);
        assert_eq!(values[0].name, "value");
        assert_eq!(values[0].string_value, Some("TestCorp".to_string()));
    }

    #[test]
    fn decode_unknown_service_with_no_spec_fails() {
        let result = decode_value(None, Some("fff0".to_string()), "fff1".to_string(), vec![0]);
        assert!(result.is_err());
    }

    #[test]
    fn decode_with_no_spec_or_service_fails() {
        let result = decode_value(None, None, "anything".to_string(), vec![0]);
        assert!(result.is_err());
    }

    #[test]
    fn decoded_uint_within_i64_range_does_not_set_string_value() {
        let dto = DecodedValueDto::from(("battery", &DecodedValue::Uint(85)));
        assert_eq!(dto.uint_value, Some(85));
        assert_eq!(dto.string_value, None);
    }

    #[test]
    fn decoded_uint_above_i64_max_surfaces_truthful_value_as_string() {
        // u64::MAX exceeds i64::MAX; the clamp would silently lie about
        // the value. Surface the original via string_value so the UI can
        // show "18446744073709551615" instead of just i64::MAX.
        let dto = DecodedValueDto::from(("counter", &DecodedValue::Uint(u64::MAX)));
        assert_eq!(dto.uint_value, Some(i64::MAX));
        assert_eq!(dto.string_value, Some(u64::MAX.to_string()));
    }
}

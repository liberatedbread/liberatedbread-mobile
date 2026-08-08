// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Generic protocol implementation driven entirely by a device spec YAML.
//! Works for any device whose protocol is fully described by the spec.

use super::traits::{DeviceProtocol, FieldMeta};
use crate::codec::types::{self, DecodedValues};
use crate::error::ProtocolError;
use crate::spec::types::DeviceSpec;
use std::collections::HashMap;
use std::sync::Arc;

/// A protocol implementation that derives all behavior from a `DeviceSpec`.
pub struct GenericProtocol {
    /// Shared, not owned: `select_protocol` serves every FFI call from a
    /// process-wide cache of `Arc<DeviceSpec>`, and holding the `Arc` here
    /// means constructing a protocol clones a refcount instead of
    /// deep-cloning the whole spec tree on each encode/decode hop.
    spec: Arc<DeviceSpec>,
}

impl GenericProtocol {
    pub fn new(spec: Arc<DeviceSpec>) -> Self {
        Self { spec }
    }
}

impl DeviceProtocol for GenericProtocol {
    fn encode_command(
        &self,
        char_uuid: &str,
        command_name: &str,
        params: &HashMap<String, f64>,
    ) -> Result<Vec<u8>, ProtocolError> {
        let (_, characteristic) = self
            .spec
            .find_writable_characteristic(char_uuid)
            .ok_or_else(|| ProtocolError::CharacteristicNotFound {
                uuid: char_uuid.to_string(),
            })?;

        let commands =
            characteristic
                .commands
                .as_ref()
                .ok_or_else(|| ProtocolError::NoCommands {
                    uuid: char_uuid.to_string(),
                })?;

        let command = commands
            .get(command_name)
            .ok_or_else(|| ProtocolError::CommandNotFound {
                uuid: char_uuid.to_string(),
                command: command_name.to_string(),
            })?;

        types::encode_command(command, params)
    }

    fn decode_value(&self, char_uuid: &str, bytes: &[u8]) -> Result<DecodedValues, ProtocolError> {
        let (_, characteristic) = self
            .spec
            .find_decodable_characteristic(char_uuid)
            .ok_or_else(|| ProtocolError::CharacteristicNotFound {
                uuid: char_uuid.to_string(),
            })?;

        let format = characteristic
            .format
            .as_ref()
            .ok_or_else(|| ProtocolError::NoFormat {
                uuid: char_uuid.to_string(),
            })?;

        types::decode_all_fields(bytes, format)
    }

    fn commands_for_characteristic(&self, char_uuid: &str) -> Vec<String> {
        self.spec
            .find_writable_characteristic(char_uuid)
            .and_then(|(_, c)| c.commands.as_ref())
            .map(|cmds| cmds.keys().cloned().collect())
            .unwrap_or_default()
    }

    fn fields_for_characteristic(&self, char_uuid: &str) -> Vec<String> {
        self.spec
            .find_decodable_characteristic(char_uuid)
            .and_then(|(_, c)| c.format.as_ref())
            .map(|fields| fields.iter().map(|f| f.name.clone()).collect())
            .unwrap_or_default()
    }

    fn field_meta_for_characteristic(&self, char_uuid: &str) -> Vec<FieldMeta> {
        self.spec
            .find_decodable_characteristic(char_uuid)
            .and_then(|(_, c)| c.format.as_ref())
            .map(|fields| {
                fields
                    .iter()
                    .map(|f| FieldMeta {
                        name: f.name.clone(),
                        scale: f.scale,
                        value_offset: f.value_offset,
                        unit: f.unit.clone(),
                        values: f.values.clone(),
                        unit_follows_device_setting: f.unit_follows_device_setting(),
                    })
                    .collect()
            })
            .unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codec::types::DecodedValue;
    use crate::spec::parser::parse_device_spec;

    fn example_spec() -> DeviceSpec {
        parse_device_spec(
            r#"
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
          set_brightness:
            description: "Set brightness"
            template: [0x02, "{brightness}"]
            parameters:
              brightness:
                type: "uint8"
                min: 0
                max: 100
          power_on:
            description: "Turn on"
            value: [0x01, 0x01]
          zone_reset:
            description: "Reset zones"
            value: [0x04, 0x00]
          power_off:
            description: "Turn off"
            value: [0x01, 0x00]
          alarm_test:
            description: "Test the alarm"
            value: [0x05, 0x01]
          fade_stop:
            description: "Stop fading"
            value: [0x06, 0x00]
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
"#,
        )
        .unwrap()
    }

    #[test]
    fn encode_fixed_command() {
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        let bytes = proto
            .encode_command(
                "0000fff1-0000-1000-8000-00805f9b34fb",
                "power_on",
                &HashMap::new(),
            )
            .unwrap();
        assert_eq!(bytes, vec![0x01, 0x01]);
    }

    #[test]
    fn encode_template_command() {
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        let params = HashMap::from([("brightness".into(), 50.0)]);
        let bytes = proto
            .encode_command(
                "0000fff1-0000-1000-8000-00805f9b34fb",
                "set_brightness",
                &params,
            )
            .unwrap();
        assert_eq!(bytes, vec![0x02, 50]);
    }

    #[test]
    fn decode_status() {
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        let values = proto
            .decode_value("0000fff2-0000-1000-8000-00805f9b34fb", &[1, 80])
            .unwrap();
        assert_eq!(values["power_state"], DecodedValue::Bool(true));
        assert_eq!(values["brightness"], DecodedValue::Uint(80));
    }

    /// Asserts declaration order, unsorted.
    ///
    /// Six commands, declared in an order that is neither alphabetical nor
    /// reverse-alphabetical. Size is the point: with two entries a regression
    /// to `HashMap` would still produce the expected order about half the time,
    /// so CI would flake instead of failing. With six there are 720 orders and
    /// only one passes, so losing document order fails essentially every run.
    #[test]
    fn list_commands_keeps_declaration_order() {
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        let cmds = proto.commands_for_characteristic("0000fff1-0000-1000-8000-00805f9b34fb");
        assert_eq!(
            cmds,
            vec![
                "set_brightness",
                "power_on",
                "zone_reset",
                "power_off",
                "alarm_test",
                "fade_stop",
            ]
        );
    }

    #[test]
    fn uuid_matching_is_case_insensitive() {
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        let bytes = proto
            .encode_command(
                "0000FFF1-0000-1000-8000-00805F9B34FB",
                "power_on",
                &HashMap::new(),
            )
            .unwrap();
        assert_eq!(bytes, vec![0x01, 0x01]);
    }

    // ── error paths (M4): each lookup failure must be its own typed error ──

    const UNKNOWN_UUID: &str = "0000dead-0000-1000-8000-00805f9b34fb";
    const COMMAND_UUID: &str = "0000fff1-0000-1000-8000-00805f9b34fb";
    const STATUS_UUID: &str = "0000fff2-0000-1000-8000-00805f9b34fb";

    #[test]
    fn encode_unknown_characteristic_returns_characteristic_not_found() {
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        match proto.encode_command(UNKNOWN_UUID, "power_on", &HashMap::new()) {
            Err(ProtocolError::CharacteristicNotFound { uuid }) => {
                assert_eq!(uuid, UNKNOWN_UUID);
            }
            other => panic!("expected CharacteristicNotFound, got {other:?}"),
        }
    }

    #[test]
    fn decode_unknown_characteristic_returns_characteristic_not_found() {
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        match proto.decode_value(UNKNOWN_UUID, &[1]) {
            Err(ProtocolError::CharacteristicNotFound { uuid }) => {
                assert_eq!(uuid, UNKNOWN_UUID);
            }
            other => panic!("expected CharacteristicNotFound, got {other:?}"),
        }
    }

    #[test]
    fn encode_on_characteristic_without_commands_returns_no_commands() {
        // The Status characteristic declares a format block but no commands.
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        match proto.encode_command(STATUS_UUID, "power_on", &HashMap::new()) {
            Err(ProtocolError::NoCommands { uuid }) => assert_eq!(uuid, STATUS_UUID),
            other => panic!("expected NoCommands, got {other:?}"),
        }
    }

    #[test]
    fn encode_unknown_command_name_returns_command_not_found() {
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        match proto.encode_command(COMMAND_UUID, "self_destruct", &HashMap::new()) {
            Err(ProtocolError::CommandNotFound { uuid, command }) => {
                assert_eq!(uuid, COMMAND_UUID);
                assert_eq!(command, "self_destruct");
            }
            other => panic!("expected CommandNotFound, got {other:?}"),
        }
    }

    #[test]
    fn decode_on_characteristic_without_format_returns_no_format() {
        // The Command characteristic declares commands but no format block.
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        match proto.decode_value(COMMAND_UUID, &[0]) {
            Err(ProtocolError::NoFormat { uuid }) => assert_eq!(uuid, COMMAND_UUID),
            other => panic!("expected NoFormat, got {other:?}"),
        }
    }

    #[test]
    fn fields_for_characteristic_lists_format_names_in_order() {
        let proto = GenericProtocol::new(Arc::new(example_spec()));
        assert_eq!(
            proto.fields_for_characteristic(STATUS_UUID),
            vec!["power_state", "brightness"]
        );
        // No format block and unknown UUID both yield an empty list — the
        // listing API reports "nothing to show", never an error.
        assert!(proto.fields_for_characteristic(COMMAND_UUID).is_empty());
        assert!(proto.fields_for_characteristic(UNKNOWN_UUID).is_empty());
    }
}

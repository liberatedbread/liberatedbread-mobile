// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Generic protocol implementation driven entirely by a device spec YAML.
//! Works for any device whose protocol is fully described by the spec.

use super::traits::DeviceProtocol;
use crate::codec::types::{self, DecodedValues};
use crate::error::ProtocolError;
use crate::spec::types::DeviceSpec;
use std::collections::HashMap;

/// A protocol implementation that derives all behavior from a `DeviceSpec`.
pub struct GenericProtocol {
    spec: DeviceSpec,
}

impl GenericProtocol {
    pub fn new(spec: DeviceSpec) -> Self {
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
        let (_, characteristic) = self.spec.find_characteristic(char_uuid).ok_or_else(|| {
            ProtocolError::CharacteristicNotFound {
                uuid: char_uuid.to_string(),
            }
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
        let (_, characteristic) = self.spec.find_characteristic(char_uuid).ok_or_else(|| {
            ProtocolError::CharacteristicNotFound {
                uuid: char_uuid.to_string(),
            }
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
            .find_characteristic(char_uuid)
            .and_then(|(_, c)| c.commands.as_ref())
            .map(|cmds| cmds.keys().cloned().collect())
            .unwrap_or_default()
    }

    fn fields_for_characteristic(&self, char_uuid: &str) -> Vec<String> {
        self.spec
            .find_characteristic(char_uuid)
            .and_then(|(_, c)| c.format.as_ref())
            .map(|fields| fields.iter().map(|f| f.name.clone()).collect())
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
        let proto = GenericProtocol::new(example_spec());
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
        let proto = GenericProtocol::new(example_spec());
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
        let proto = GenericProtocol::new(example_spec());
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
        let proto = GenericProtocol::new(example_spec());
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
        let proto = GenericProtocol::new(example_spec());
        let bytes = proto
            .encode_command(
                "0000FFF1-0000-1000-8000-00805F9B34FB",
                "power_on",
                &HashMap::new(),
            )
            .unwrap();
        assert_eq!(bytes, vec![0x01, 0x01]);
    }
}

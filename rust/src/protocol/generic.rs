// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Generic protocol implementation driven entirely by a device spec YAML.
//! Works for any device whose protocol is fully described by the spec.

use super::traits::DeviceProtocol;
use crate::codec::types::{self, DecodedValue};
use crate::spec::types::DeviceSpec;
use anyhow::{bail, Result};
use std::collections::HashMap;

/// A protocol implementation that derives all behavior from a `DeviceSpec`.
pub struct GenericProtocol {
    spec: DeviceSpec,
}

impl GenericProtocol {
    pub fn new(spec: DeviceSpec) -> Self {
        Self { spec }
    }

    pub fn spec(&self) -> &DeviceSpec {
        &self.spec
    }
}

impl DeviceProtocol for GenericProtocol {
    fn encode_command(
        &self,
        char_uuid: &str,
        command_name: &str,
        params: &HashMap<String, f64>,
    ) -> Result<Vec<u8>> {
        let char_uuid_lower = char_uuid.to_lowercase();

        for service in &self.spec.services {
            for characteristic in &service.characteristics {
                if characteristic.uuid.to_lowercase() != char_uuid_lower {
                    continue;
                }
                if let Some(ref commands) = characteristic.commands {
                    if let Some(command) = commands.get(command_name) {
                        return types::encode_command(command, params);
                    }
                    bail!(
                        "unknown command '{}' for characteristic {}",
                        command_name,
                        char_uuid
                    );
                }
                bail!("characteristic {} has no commands defined", char_uuid);
            }
        }
        bail!("characteristic {} not found in spec", char_uuid)
    }

    fn decode_value(
        &self,
        char_uuid: &str,
        bytes: &[u8],
    ) -> Result<HashMap<String, DecodedValue>> {
        let char_uuid_lower = char_uuid.to_lowercase();

        for service in &self.spec.services {
            for characteristic in &service.characteristics {
                if characteristic.uuid.to_lowercase() != char_uuid_lower {
                    continue;
                }
                if let Some(ref format) = characteristic.format {
                    return types::decode_all_fields(bytes, format);
                }
                bail!("characteristic {} has no format defined", char_uuid);
            }
        }
        bail!("characteristic {} not found in spec", char_uuid)
    }

    fn commands_for_characteristic(&self, char_uuid: &str) -> Vec<String> {
        let char_uuid_lower = char_uuid.to_lowercase();
        for service in &self.spec.services {
            for characteristic in &service.characteristics {
                if characteristic.uuid.to_lowercase() == char_uuid_lower {
                    return characteristic
                        .commands
                        .as_ref()
                        .map(|c| c.keys().cloned().collect())
                        .unwrap_or_default();
                }
            }
        }
        Vec::new()
    }

    fn fields_for_characteristic(&self, char_uuid: &str) -> Vec<String> {
        let char_uuid_lower = char_uuid.to_lowercase();
        for service in &self.spec.services {
            for characteristic in &service.characteristics {
                if characteristic.uuid.to_lowercase() == char_uuid_lower {
                    return characteristic
                        .format
                        .as_ref()
                        .map(|f| f.iter().map(|field| field.name.clone()).collect())
                        .unwrap_or_default();
                }
            }
        }
        Vec::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
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
          power_on:
            description: "Turn on"
            value: [0x01, 0x01]
          set_brightness:
            description: "Set brightness"
            template: [0x02, "{brightness}"]
            parameters:
              brightness:
                type: "uint8"
                min: 0
                max: 100
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

    #[test]
    fn list_commands() {
        let proto = GenericProtocol::new(example_spec());
        let mut cmds =
            proto.commands_for_characteristic("0000fff1-0000-1000-8000-00805f9b34fb");
        cmds.sort();
        assert_eq!(cmds, vec!["power_on", "set_brightness"]);
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

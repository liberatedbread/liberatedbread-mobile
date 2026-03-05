// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Parse device spec YAML into Rust types.

use super::types::DeviceSpec;
use anyhow::{Context, Result};

/// Parse a device spec from a YAML string.
pub fn parse_device_spec(yaml: &str) -> Result<DeviceSpec> {
    serde_yaml::from_str(yaml).context("failed to parse device spec YAML")
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::types::{CharacteristicProperty, ManufacturerStatus, Protocol, ValueType};

    const EXAMPLE_BULB_YAML: &str = r#"
device:
  name: "Example Smart Bulb"
  manufacturer: "Acme Corp"
  manufacturer_status: "abandoned"
  protocol: "ble"
  notes: "Test fixture"
  identification:
    local_name_prefix: "ACME_"
    service_uuids:
      - "0000fff0-0000-1000-8000-00805f9b34fb"

services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control Service"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
        commands:
          power_on:
            description: "Turn the bulb on"
            value: [0x01, 0x01]
          power_off:
            description: "Turn the bulb off"
            value: [0x01, 0x00]
          set_brightness:
            description: "Set brightness (0-100)"
            template: [0x02, "{brightness}"]
            parameters:
              brightness:
                type: "uint8"
                min: 0
                max: 100
          set_color:
            description: "Set RGB color"
            template: [0x03, "{red}", "{green}", "{blue}"]
            parameters:
              red:
                type: "uint8"
                min: 0
                max: 255
              green:
                type: "uint8"
                min: 0
                max: 255
              blue:
                type: "uint8"
                min: 0
                max: 255

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
          - offset: 2
            length: 1
            name: "red"
            type: "uint8"
          - offset: 3
            length: 1
            name: "green"
            type: "uint8"
          - offset: 4
            length: 1
            name: "blue"
            type: "uint8"

  - uuid: "0000180f-0000-1000-8000-00805f9b34fb"
    name: "Battery Service"
    characteristics:
      - uuid: "00002a19-0000-1000-8000-00805f9b34fb"
        name: "Battery Level"
        properties: ["read", "notify"]
        format:
          - offset: 0
            length: 1
            name: "battery_percent"
            type: "uint8"

entities:
  - platform: "light"
    name: "Bulb"
    features: ["brightness", "color"]
    state_characteristic: "0000fff2-0000-1000-8000-00805f9b34fb"
    commands:
      turn_on: "power_on"
      turn_off: "power_off"
  - platform: "sensor"
    name: "Battery"
    device_class: "battery"
    unit: "%"
    state_characteristic: "00002a19-0000-1000-8000-00805f9b34fb"
"#;

    #[test]
    fn parse_example_bulb() {
        let spec = parse_device_spec(EXAMPLE_BULB_YAML).unwrap();

        assert_eq!(spec.device.name, "Example Smart Bulb");
        assert_eq!(spec.device.manufacturer, "Acme Corp");
        assert_eq!(spec.device.manufacturer_status, ManufacturerStatus::Abandoned);
        assert_eq!(spec.device.protocol, Protocol::Ble);
        assert_eq!(spec.device.notes.as_deref(), Some("Test fixture"));

        let ident = spec.device.identification.as_ref().unwrap();
        assert_eq!(ident.local_name_prefix.as_deref(), Some("ACME_"));
        assert_eq!(ident.service_uuids.as_ref().unwrap().len(), 1);
    }

    #[test]
    fn parse_services() {
        let spec = parse_device_spec(EXAMPLE_BULB_YAML).unwrap();

        assert_eq!(spec.services.len(), 2);

        let control = &spec.services[0];
        assert_eq!(control.name, "Control Service");
        assert_eq!(control.characteristics.len(), 2);

        let cmd_char = &control.characteristics[0];
        assert_eq!(cmd_char.name, "Command");
        assert_eq!(cmd_char.properties, vec![CharacteristicProperty::Write]);

        let commands = cmd_char.commands.as_ref().unwrap();
        assert!(commands.contains_key("power_on"));
        assert!(commands.contains_key("set_brightness"));
        assert!(commands.contains_key("set_color"));

        let set_brightness = &commands["set_brightness"];
        assert!(set_brightness.template.is_some());
        let params = set_brightness.parameters.as_ref().unwrap();
        let brightness_param = &params["brightness"];
        assert_eq!(brightness_param.value_type, ValueType::Uint8);
        assert_eq!(brightness_param.min, Some(0));
        assert_eq!(brightness_param.max, Some(100));
    }

    #[test]
    fn parse_format_fields() {
        let spec = parse_device_spec(EXAMPLE_BULB_YAML).unwrap();

        let status_char = &spec.services[0].characteristics[1];
        assert_eq!(status_char.name, "Status");
        assert_eq!(
            status_char.properties,
            vec![CharacteristicProperty::Read, CharacteristicProperty::Notify]
        );

        let format = status_char.format.as_ref().unwrap();
        assert_eq!(format.len(), 5);
        assert_eq!(format[0].name, "power_state");
        assert_eq!(format[0].field_type, ValueType::Bool);
        assert_eq!(format[0].offset, 0);
        assert_eq!(format[1].name, "brightness");
        assert_eq!(format[1].field_type, ValueType::Uint8);
    }

    #[test]
    fn parse_entities() {
        let spec = parse_device_spec(EXAMPLE_BULB_YAML).unwrap();

        let entities = spec.entities.as_ref().unwrap();
        assert_eq!(entities.len(), 2);
        assert_eq!(entities[0].platform, "light");
        assert_eq!(entities[1].platform, "sensor");
        assert_eq!(entities[1].device_class.as_deref(), Some("battery"));
        assert_eq!(entities[1].unit.as_deref(), Some("%"));
    }
}

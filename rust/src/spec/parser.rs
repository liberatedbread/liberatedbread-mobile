// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Parse device spec YAML into Rust types.

use super::types::{DeviceSpec, FormatField, Parameter};
use crate::error::SpecError;

/// Parse a device spec from a YAML string.
///
/// After deserialization, every characteristic's format fields and command
/// parameters are validated:
/// - Fixed-width format fields (Bool, Uint8/16, Int8/16) must declare the
///   exact `length` for the type — reject otherwise.
/// - Parameter `min`/`max` bounds must fit the declared `type` — reject
///   otherwise (e.g., `type: uint8, max: 300`).
pub fn parse_device_spec(yaml: &str) -> Result<DeviceSpec, SpecError> {
    let spec: DeviceSpec = serde_yaml::from_str(yaml)?;
    validate_spec(&spec)?;
    Ok(spec)
}

fn validate_spec(spec: &DeviceSpec) -> Result<(), SpecError> {
    for service in &spec.services {
        for characteristic in &service.characteristics {
            if let Some(fields) = &characteristic.format {
                for field in fields {
                    validate_format_field(field)?;
                }
            }
            if let Some(commands) = &characteristic.commands {
                for command in commands.values() {
                    if let Some(params) = &command.parameters {
                        for (name, param) in params {
                            validate_parameter(name, param)?;
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

fn validate_format_field(field: &FormatField) -> Result<(), SpecError> {
    if let Some(expected) = field.field_type.fixed_byte_size() {
        if field.length != expected {
            return Err(SpecError::FieldLengthMismatch {
                field_name: field.name.clone(),
                field_type: field.field_type.clone(),
                expected,
                got: field.length,
            });
        }
    }
    Ok(())
}

fn validate_parameter(name: &str, param: &Parameter) -> Result<(), SpecError> {
    let Some((lo, hi)) = param.value_type.integer_range() else {
        return Ok(());
    };
    for (label, bound) in [("min", param.min), ("max", param.max)] {
        let Some(value) = bound else { continue };
        if value < lo || value > hi {
            return Err(SpecError::ParameterRangeOutsideType {
                parameter_name: name.to_string(),
                value_type: param.value_type.clone(),
                bound: label.to_string(),
                value,
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::types::{CharacteristicProperty, ManufacturerStatus, Protocol, ValueType};
    use crate::test_fixtures::make_minimal_spec;

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
"#;

    #[test]
    fn parse_example_bulb() {
        let spec = parse_device_spec(EXAMPLE_BULB_YAML).unwrap();

        assert_eq!(spec.device.name, "Example Smart Bulb");
        assert_eq!(spec.device.manufacturer, "Acme Corp");
        assert_eq!(
            spec.device.manufacturer_status,
            ManufacturerStatus::Abandoned
        );
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
    fn rejects_format_field_with_wrong_length_for_uint16() {
        let yaml = make_minimal_spec(
            r#"        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: bad_uint16
            type: uint16"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::FieldLengthMismatch {
                field_name,
                expected,
                got,
                ..
            }) => {
                assert_eq!(field_name, "bad_uint16");
                assert_eq!(expected, 2);
                assert_eq!(got, 1);
            }
            other => panic!("expected FieldLengthMismatch, got {other:?}"),
        }
    }

    #[test]
    fn allows_variable_length_for_bytes_and_string() {
        let yaml = make_minimal_spec(
            r#"        properties: ["read"]
        format:
          - offset: 0
            length: 5
            name: text
            type: string
          - offset: 5
            length: 3
            name: payload
            type: bytes"#,
        );
        parse_device_spec(&yaml).expect("variable-length fields should parse");
    }

    #[test]
    fn rejects_parameter_max_outside_uint8_range() {
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_brightness:
            description: x
            template: [0x02, "{brightness}"]
            parameters:
              brightness:
                type: uint8
                min: 0
                max: 300"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::ParameterRangeOutsideType {
                parameter_name,
                bound,
                value,
                ..
            }) => {
                assert_eq!(parameter_name, "brightness");
                assert_eq!(bound, "max");
                assert_eq!(value, 300);
            }
            other => panic!("expected ParameterRangeOutsideType, got {other:?}"),
        }
    }

    #[test]
    fn rejects_parameter_min_below_uint8_range() {
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{n}"]
            parameters:
              n:
                type: uint8
                min: -1"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::ParameterRangeOutsideType { bound, value, .. }) => {
                assert_eq!(bound, "min");
                assert_eq!(value, -1);
            }
            other => panic!("expected ParameterRangeOutsideType, got {other:?}"),
        }
    }

    #[test]
    fn rejects_empty_parameter_reference() {
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          weird:
            description: x
            template: [0x01, "{}"]"#,
        );
        let err = parse_device_spec(&yaml).expect_err("'{}' should be rejected");
        let msg = err.to_string().to_lowercase();
        assert!(
            msg.contains("parameter name cannot be empty"),
            "expected empty-name error, got: {err}"
        );
    }

    #[test]
    fn rejects_unknown_field_in_device_block() {
        let yaml = r#"
device:
  name: "x"
  manufacturer: "x"
  manufacturer_status: "abandoned"
  protocol: "ble"
  bogus_field: 1
services: []
"#;
        let err = parse_device_spec(yaml).unwrap_err();
        let msg = err.to_string().to_lowercase();
        assert!(
            msg.contains("unknown field") && msg.contains("bogus_field"),
            "expected unknown-field error, got: {}",
            err
        );
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
}

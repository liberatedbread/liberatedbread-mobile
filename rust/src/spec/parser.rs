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
/// - Fixed-width format fields (Bool, Uint8/16/32, Int8/16/32) must declare a
///   `length` at least as large as the type needs to decode — reject a shorter
///   `length` (it would under-read and panic at decode time). A *longer*
///   `length` is permitted: the schema treats `length` as independent of
///   `type` (some reverse-engineered specs declare a wider field and only the
///   low bytes are meaningful), and decode reads the low `fixed_byte_size`
///   bytes, so it is decode-safe.
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
                // Two fields with the same name make `decode_all_fields`
                // (which keys a HashMap on the field name) silently drop one.
                check_duplicate_names(
                    &characteristic.name,
                    "format field",
                    fields.iter().map(|f| f.name.as_str()),
                )?;
            }
            if let Some(commands) = &characteristic.commands {
                // Command names come from YAML mapping keys, so exact
                // duplicates already collapse during deserialization; catch
                // case-only collisions (e.g. `power_on` vs `Power_On`), which
                // a hostile remote spec could use to smuggle an ambiguous
                // second command past a user reviewing the spec.
                check_duplicate_names(
                    &characteristic.name,
                    "command",
                    commands.keys().map(|k| k.as_str()),
                )?;
                for command in commands.values() {
                    if let Some(params) = &command.parameters {
                        for (name, param) in &params.params {
                            validate_parameter(name, param)?;
                        }
                    }
                }
            }
        }
    }
    Ok(())
}

/// Reject two names that are equal ignoring ASCII case within a single
/// characteristic. Case-insensitive because case-only differences are
/// ambiguous to a human reviewing an untrusted spec and, for format fields,
/// still risk one silently shadowing the other downstream.
fn check_duplicate_names<'a>(
    characteristic: &str,
    kind: &str,
    names: impl Iterator<Item = &'a str>,
) -> Result<(), SpecError> {
    let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
    for name in names {
        if !seen.insert(name.to_ascii_lowercase()) {
            return Err(SpecError::DuplicateName {
                kind: kind.to_string(),
                name: name.to_string(),
                characteristic: characteristic.to_string(),
            });
        }
    }
    Ok(())
}

fn validate_format_field(field: &FormatField) -> Result<(), SpecError> {
    if let Some(expected) = field.field_type.fixed_byte_size() {
        // Only a *too-short* length is an error: decode reads exactly
        // `fixed_byte_size` bytes from the field slice, so `length < expected`
        // would index past the slice and panic. `length > expected` is fine —
        // the schema allows it and the extra trailing bytes are ignored.
        if field.length < expected {
            return Err(SpecError::FieldLengthMismatch {
                field_name: field.name.clone(),
                field_type: field.field_type.clone(),
                expected,
                got: field.length,
            });
        }
    }
    // Catch arithmetic overflow at parse time so downstream consumers
    // (e.g. `mock::simulator::generate_defaults`, which sums offset+length
    // unchecked) can't panic on a malformed spec.
    if field.offset.checked_add(field.length).is_none() {
        return Err(SpecError::FieldOffsetOverflow {
            field_name: field.name.clone(),
            offset: field.offset,
            length: field.length,
        });
    }
    Ok(())
}

fn validate_parameter(name: &str, param: &Parameter) -> Result<(), SpecError> {
    let Some((lo, hi)) = param.value_type.integer_range() else {
        // No numeric range (string/bytes): min/max are meaningless here.
        // Reject rather than silently ignore an author's bound.
        for (label, bound) in [("min", param.min), ("max", param.max)] {
            if bound.is_some() {
                return Err(SpecError::BoundsOnNonNumericType {
                    parameter_name: name.to_string(),
                    value_type: param.value_type.clone(),
                    bound: label.to_string(),
                });
            }
        }
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
    if let (Some(min), Some(max)) = (param.min, param.max) {
        if min > max {
            return Err(SpecError::ParameterBoundsInverted {
                parameter_name: name.to_string(),
                min,
                max,
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
        let brightness_param = &params.params["brightness"];
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
    fn rejects_format_field_offset_length_overflow() {
        // offset = usize::MAX with any non-zero length wraps usize. Catch
        // it at parse time so `mock::simulator::generate_defaults` (which
        // sums offset+length unchecked) can't panic on malformed input.
        let yaml = format!(
            r#"
device:
  name: x
  manufacturer: x
  manufacturer_status: abandoned
  protocol: ble
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: s
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: c
        properties: ["read"]
        format:
          - offset: {}
            length: 5
            name: bad
            type: bytes
"#,
            usize::MAX
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::FieldOffsetOverflow {
                field_name,
                offset,
                length,
            }) => {
                assert_eq!(field_name, "bad");
                assert_eq!(offset, usize::MAX);
                assert_eq!(length, 5);
            }
            other => panic!("expected FieldOffsetOverflow, got {other:?}"),
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
    fn tolerates_overlong_fixed_format_field() {
        // The schema treats `length` as independent of `type` (minimum 1).
        // Some reverse-engineered specs (e.g. chef-iq-sense `cloud_status`)
        // declare a fixed type over a wider field; a length >= the type's
        // byte size is decode-safe and must parse.
        let yaml = make_minimal_spec(
            r#"        properties: ["read"]
        format:
          - offset: 0
            length: 4
            name: cloud_status
            type: int8"#,
        );
        parse_device_spec(&yaml).expect("over-length fixed field should parse");
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
    fn rejects_inverted_parameter_bounds() {
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{n}"]
            parameters:
              n:
                type: uint8
                min: 100
                max: 50"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::ParameterBoundsInverted {
                parameter_name,
                min,
                max,
            }) => {
                assert_eq!(parameter_name, "n");
                assert_eq!(min, 100);
                assert_eq!(max, 50);
            }
            other => panic!("expected ParameterBoundsInverted, got {other:?}"),
        }
    }

    #[test]
    fn rejects_bounds_on_string_parameter_type() {
        // min/max are meaningless on a string parameter and were previously
        // ignored silently; now they must be rejected.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{s}"]
            parameters:
              s:
                type: string
                max: 10"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::BoundsOnNonNumericType {
                parameter_name,
                value_type,
                bound,
            }) => {
                assert_eq!(parameter_name, "s");
                assert_eq!(value_type, ValueType::String);
                assert_eq!(bound, "max");
            }
            other => panic!("expected BoundsOnNonNumericType, got {other:?}"),
        }
    }

    #[test]
    fn rejects_min_bound_on_bytes_parameter_type() {
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{b}"]
            parameters:
              b:
                type: bytes
                min: 0"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::BoundsOnNonNumericType {
                value_type, bound, ..
            }) => {
                assert_eq!(value_type, ValueType::Bytes);
                assert_eq!(bound, "min");
            }
            other => panic!("expected BoundsOnNonNumericType, got {other:?}"),
        }
    }

    #[test]
    fn allows_unbounded_string_parameter() {
        // A string parameter with no min/max is still fine.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{s}"]
            parameters:
              s:
                type: string"#,
        );
        parse_device_spec(&yaml).expect("string param without bounds should parse");
    }

    #[test]
    fn rejects_duplicate_format_field_names() {
        // Two fields named "level" would make decode_all_fields silently drop
        // the first; reject at parse time instead.
        let yaml = make_minimal_spec(
            r#"        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: level
            type: uint8
          - offset: 1
            length: 1
            name: level
            type: uint8"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::DuplicateName {
                kind,
                name,
                characteristic,
            }) => {
                assert_eq!(kind, "format field");
                assert_eq!(name, "level");
                assert_eq!(characteristic, "c");
            }
            other => panic!("expected DuplicateName, got {other:?}"),
        }
    }

    #[test]
    fn rejects_case_only_duplicate_format_field_names() {
        let yaml = make_minimal_spec(
            r#"        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: Level
            type: uint8
          - offset: 1
            length: 1
            name: level
            type: uint8"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::DuplicateName { kind, .. }) => assert_eq!(kind, "format field"),
            other => panic!("expected DuplicateName, got {other:?}"),
        }
    }

    #[test]
    fn rejects_case_only_duplicate_command_names() {
        // Exact-duplicate command keys collapse during YAML deserialization,
        // so the smuggling vector is a case-only collision.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          power_on:
            description: x
            value: [0x01]
          Power_On:
            description: y
            value: [0x02]"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::DuplicateName {
                kind,
                characteristic,
                ..
            }) => {
                assert_eq!(kind, "command");
                assert_eq!(characteristic, "c");
            }
            other => panic!("expected DuplicateName, got {other:?}"),
        }
    }

    #[test]
    fn accepts_distinct_field_and_command_names() {
        // Guard against false positives: distinct names must still parse.
        let yaml = make_minimal_spec(
            r#"        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: power_state
            type: uint8
          - offset: 1
            length: 1
            name: brightness
            type: uint8"#,
        );
        parse_device_spec(&yaml).expect("distinct field names should parse");
    }

    #[test]
    fn accepts_equal_min_and_max() {
        // min == max is a valid degenerate case (a fixed value).
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{n}"]
            parameters:
              n:
                type: uint8
                min: 7
                max: 7"#,
        );
        parse_device_spec(&yaml).expect("min == max should parse");
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
    fn tolerates_reserved_color_order_key_in_parameters() {
        // `color_order` is a reserved sibling of the parameter definitions, not
        // a parameter itself; it must be pulled out and the rest still parse.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_color:
            description: x
            template: [0x03, "{red}", "{green}", "{blue}"]
            parameters:
              color_order: "rbg"
              red:
                type: uint8
                min: 0
                max: 255
              green:
                type: uint8
              blue:
                type: uint8"#,
        );
        let spec = parse_device_spec(&yaml).expect("color_order should be tolerated");
        let cmd = &spec.services[0].characteristics[0]
            .commands
            .as_ref()
            .unwrap()["set_color"];
        let params = cmd.parameters.as_ref().unwrap();
        assert_eq!(params.color_order.as_deref(), Some("rbg"));
        assert_eq!(
            params.params.len(),
            3,
            "color_order must not become a param"
        );
        assert!(params.params.contains_key("red"));
    }

    #[test]
    fn tolerates_characteristic_encryption_framing_and_notes() {
        let yaml = make_minimal_spec(
            r#"        properties: ["write", "notify"]
        notes: "encrypted control channel"
        encryption:
          algorithm: "aes-128-ecb"
          key_derivation: "static"
        framing:
          length_prefix: true
          checksum: "crc32""#,
        );
        let spec = parse_device_spec(&yaml).expect("encryption/framing should be tolerated");
        let ch = &spec.services[0].characteristics[0];
        assert!(ch.notes.is_some());
        assert!(ch.encryption.is_some());
        assert!(ch.framing.is_some());
    }

    #[test]
    fn tolerates_command_encoding_and_payload() {
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_pattern:
            description: x
            encoding: "json"
            payload:
              key: "pattern"
              value_type: "string""#,
        );
        let spec = parse_device_spec(&yaml).expect("encoding/payload should be tolerated");
        let cmd = &spec.services[0].characteristics[0]
            .commands
            .as_ref()
            .unwrap()["set_pattern"];
        assert_eq!(cmd.encoding.as_deref(), Some("json"));
        assert!(cmd.payload.is_some());
    }

    #[test]
    fn tolerates_unknown_top_level_and_missing_services() {
        // Near-future / vendor-specific top-level keys land in the extensions
        // bag instead of being rejected, and `services` is optional.
        let yaml = r#"
device:
  name: x
  manufacturer: x
  manufacturer_status: active
  protocol: wifi
some_future_block:
  foo: bar
http_endpoints:
  - method: GET
    path: /api/status
    name: Status
"#;
        let spec = parse_device_spec(yaml).expect("unknown top-level keys should be tolerated");
        assert!(spec.services.is_empty());
        assert!(spec.extensions.contains_key("some_future_block"));
        assert!(spec.extensions.contains_key("http_endpoints"));
    }

    #[test]
    fn still_rejects_unknown_field_in_characteristic() {
        // Typo detection is preserved on the protocol-execution structs: an
        // unknown key inside a characteristic (which drives reads/writes) must
        // still fail loudly.
        let yaml = make_minimal_spec(
            r#"        properties: ["read"]
        bogus_characteristic_key: 1"#,
        );
        let err = parse_device_spec(&yaml).expect_err("unknown characteristic key should fail");
        let msg = err.to_string().to_lowercase();
        assert!(
            msg.contains("unknown field") && msg.contains("bogus_characteristic_key"),
            "expected unknown-field error, got: {err}"
        );
    }

    #[test]
    fn still_rejects_unknown_field_in_service() {
        // N1: a typo at the service level (drives which GATT service is used)
        // must fail — deny_unknown_fields is preserved on Service.
        let yaml = r#"
device:
  name: x
  manufacturer: x
  manufacturer_status: abandoned
  protocol: ble
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: s
    bogus_service_key: 1
    characteristics: []
"#;
        let err = parse_device_spec(yaml).expect_err("unknown service key should fail");
        let msg = err.to_string().to_lowercase();
        assert!(
            msg.contains("unknown field") && msg.contains("bogus_service_key"),
            "expected unknown-field error, got: {err}"
        );
    }

    #[test]
    fn still_rejects_unknown_field_in_command() {
        // N1: a typo at the command level (e.g. `templte` instead of
        // `template`) would silently drop the write payload — must fail.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          do_thing:
            description: x
            value: [0x01]
            bogus_command_key: 1"#,
        );
        let err = parse_device_spec(&yaml).expect_err("unknown command key should fail");
        let msg = err.to_string().to_lowercase();
        assert!(
            msg.contains("unknown field") && msg.contains("bogus_command_key"),
            "expected unknown-field error, got: {err}"
        );
    }

    #[test]
    fn still_rejects_unknown_field_in_parameter() {
        // N1: a typo in a parameter definition (e.g. `mn` instead of `min`)
        // would silently drop a bound — must fail.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          do_thing:
            description: x
            template: [0x01, "{n}"]
            parameters:
              n:
                type: uint8
                bogus_parameter_key: 1"#,
        );
        let err = parse_device_spec(&yaml).expect_err("unknown parameter key should fail");
        let msg = err.to_string().to_lowercase();
        assert!(
            msg.contains("unknown field") && msg.contains("bogus_parameter_key"),
            "expected unknown-field error, got: {err}"
        );
    }

    #[test]
    fn still_rejects_unknown_field_in_format_field() {
        // N1: a typo in a format field (e.g. `ofset`) would misparse a read
        // layout — must fail.
        let yaml = make_minimal_spec(
            r#"        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: v
            type: uint8
            bogus_format_key: 1"#,
        );
        let err = parse_device_spec(&yaml).expect_err("unknown format-field key should fail");
        let msg = err.to_string().to_lowercase();
        assert!(
            msg.contains("unknown field") && msg.contains("bogus_format_key"),
            "expected unknown-field error, got: {err}"
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

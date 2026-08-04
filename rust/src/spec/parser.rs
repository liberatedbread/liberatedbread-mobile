// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Parse device spec YAML into Rust types.

use super::types::{Command, DeviceSpec, FormatField, Parameter, TemplateElement};
use crate::error::SpecError;

/// Maximum byte position (`offset + length`) a format field may extend to.
///
/// Specs can arrive from arbitrary remote pack URLs, and consumers size
/// buffers from field extents (`mock::simulator::generate_defaults` allocates
/// `max(offset + length)` bytes), so an unbounded `length: 4000000000` would
/// be a spec-controlled multi-gigabyte allocation. 64 KiB is far beyond any
/// real BLE characteristic (the ATT maximum attribute value is 512 bytes)
/// while still being a hard ceiling on what a hostile spec can make us
/// allocate.
const MAX_FIELD_EXTENT: usize = 65_536;

/// Parse a device spec from a YAML string.
///
/// After deserialization the spec is validated; each rule exists to turn a
/// "parses fine, breaks later" failure into a load-time error:
/// - Fixed-width format fields (Bool, Uint8/16/32, Int8/16/32) must declare a
///   `length` at least as large as the type needs to decode — reject a shorter
///   `length` (it would under-read and panic at decode time). A *longer*
///   `length` is permitted: the schema treats `length` as independent of
///   `type` (some reverse-engineered specs declare a wider field and only the
///   low bytes are meaningful), and decode reads the low `fixed_byte_size`
///   bytes, so it is decode-safe.
/// - Format field `offset + length` must not overflow `usize` (downstream
///   consumers sum them unchecked) and must not exceed [`MAX_FIELD_EXTENT`]
///   (consumers allocate buffers that large).
/// - Format field and command names must be unique within a characteristic,
///   including case-only collisions — a duplicate would let one entry
///   silently shadow the other downstream.
/// - Parameter `min`/`max` bounds must fit the declared `type` — reject
///   otherwise (e.g., `type: uint8, max: 300`); reject inverted bounds
///   (`min > max`); and reject bounds on non-numeric types (string/bytes),
///   where they would otherwise be silently ignored.
/// - Every `{param}` reference in a command template must be declared in
///   that command's `parameters` map, so a typo'd reference fails here
///   instead of at write time.
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
                // (whose order-preserving `DecodedValues` overwrites a
                // repeated name in place) silently drop one value.
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
                for (command_name, command) in commands {
                    if let Some(params) = &command.parameters {
                        for (name, param) in &params.params {
                            validate_parameter(name, param)?;
                        }
                    }
                    validate_template_references(command_name, command)?;
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
    let Some(end) = field.offset.checked_add(field.length) else {
        return Err(SpecError::FieldOffsetOverflow {
            field_name: field.name.clone(),
            offset: field.offset,
            length: field.length,
        });
    };
    // Cap the field's extent so a spec cannot direct consumers into a huge
    // allocation (`generate_defaults` allocates `max(offset + length)`
    // bytes). See `MAX_FIELD_EXTENT` for why 64 KiB.
    if end > MAX_FIELD_EXTENT {
        return Err(SpecError::FieldExtentTooLarge {
            field_name: field.name.clone(),
            offset: field.offset,
            length: field.length,
            max: MAX_FIELD_EXTENT,
        });
    }
    Ok(())
}

/// Every `{param}` reference in a command's template must be declared in that
/// command's `parameters` map.
///
/// Without this check a typo'd reference (template says `"{brightnes}"`, the
/// parameters block declares `brightness`) parses cleanly, renders a control
/// in the UI, and only fails at write time with `ParameterMissing` — the
/// worst possible place for a spec author to discover it. The reverse
/// direction (a declared parameter the template never references) stays
/// legal: upstream specs declare documentation-only parameters.
fn validate_template_references(command_name: &str, command: &Command) -> Result<(), SpecError> {
    let Some(template) = &command.template else {
        return Ok(());
    };
    for element in template {
        if let TemplateElement::Param(param_name) = element {
            let declared = command
                .parameters
                .as_ref()
                .is_some_and(|set| set.params.contains_key(param_name.as_str()));
            if !declared {
                return Err(SpecError::UnknownTemplateParameter {
                    command: command_name.to_string(),
                    parameter: param_name.clone(),
                });
            }
        }
    }
    Ok(())
}

fn validate_parameter(name: &str, param: &Parameter) -> Result<(), SpecError> {
    let Some((lo, hi)) = param.value_type.integer_range() else {
        // No numeric range (string/bytes): min/max are meaningless here.
        // Reject rather than silently ignore an author's bound. `allowed`
        // gets the same treatment — its values are integers by schema, so on
        // a non-numeric parameter it cannot describe anything sendable.
        for (label, present) in [
            ("min", param.min.is_some()),
            ("max", param.max.is_some()),
            ("allowed", param.allowed.is_some()),
        ] {
            if present {
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
    // Every `allowed` value must sit within the parameter's EFFECTIVE bounds
    // (explicit min/max, else the type's own range) — the same bounds
    // encode_command enforces per write. Without this check a spec like
    // `type: uint8, max: 100, allowed: [200]` parses clean, the UI builds a
    // dropdown from it, and every visible choice fails at send time. Checked
    // after the min/max validations above so the effective bounds are known
    // to be coherent.
    if let Some(allowed) = &param.allowed {
        let lo_eff = param.min.unwrap_or(lo);
        let hi_eff = param.max.unwrap_or(hi);
        for &value in allowed {
            if value < lo_eff || value > hi_eff {
                return Err(SpecError::AllowedValueOutsideBounds {
                    parameter_name: name.to_string(),
                    value,
                    min: lo_eff,
                    max: hi_eff,
                });
            }
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
    fn rejects_format_field_extent_just_over_cap() {
        // offset + length = MAX_FIELD_EXTENT + 1: one byte past the cap. A
        // huge `length` would otherwise become a spec-controlled allocation
        // in `mock::simulator::generate_defaults`.
        let yaml = make_minimal_spec(&format!(
            r#"        properties: ["read"]
        format:
          - offset: 1
            length: {MAX_FIELD_EXTENT}
            name: huge
            type: bytes"#
        ));
        match parse_device_spec(&yaml) {
            Err(SpecError::FieldExtentTooLarge {
                field_name,
                offset,
                length,
                max,
            }) => {
                assert_eq!(field_name, "huge");
                assert_eq!(offset, 1);
                assert_eq!(length, MAX_FIELD_EXTENT);
                assert_eq!(max, MAX_FIELD_EXTENT);
            }
            other => panic!("expected FieldExtentTooLarge, got {other:?}"),
        }
    }

    #[test]
    fn accepts_format_field_extent_at_cap() {
        // Exactly MAX_FIELD_EXTENT is the largest permitted extent.
        let yaml = make_minimal_spec(&format!(
            r#"        properties: ["read"]
        format:
          - offset: 0
            length: {MAX_FIELD_EXTENT}
            name: big
            type: bytes"#
        ));
        parse_device_spec(&yaml).expect("extent exactly at the cap should parse");
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
        // Upstream reverse-engineered specs may declare a fixed type over a
        // wider field (padded or reserved trailing bytes); a length >= the
        // type's byte size is decode-safe and must parse.
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
    fn rejects_allowed_value_above_explicit_max() {
        // The dropdown the UI builds from `allowed` must only offer values
        // encode_command will accept; a choice outside the effective bounds
        // would fail on every send.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_brightness:
            description: x
            template: [0x02, "{brightness}"]
            parameters:
              brightness:
                type: uint8
                max: 100
                allowed: [0, 50, 200]"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::AllowedValueOutsideBounds {
                parameter_name,
                value,
                min,
                max,
            }) => {
                assert_eq!(parameter_name, "brightness");
                assert_eq!(value, 200);
                assert_eq!(min, 0);
                assert_eq!(max, 100);
            }
            other => panic!("expected AllowedValueOutsideBounds, got {other:?}"),
        }
    }

    #[test]
    fn rejects_allowed_value_outside_type_range() {
        // No explicit bounds: the type's own range is the effective one.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{n}"]
            parameters:
              n:
                type: uint8
                allowed: [0, 300]"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::AllowedValueOutsideBounds {
                value, min, max, ..
            }) => {
                assert_eq!(value, 300);
                assert_eq!(min, 0);
                assert_eq!(max, 255);
            }
            other => panic!("expected AllowedValueOutsideBounds, got {other:?}"),
        }
    }

    #[test]
    fn accepts_allowed_values_at_effective_bounds() {
        // Boundary values are legal choices, exactly as they are for min/max.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{n}"]
            parameters:
              n:
                type: uint8
                min: 10
                max: 100
                allowed: [10, 55, 100]"#,
        );
        parse_device_spec(&yaml).expect("allowed values at the bounds should parse");
    }

    #[test]
    fn rejects_allowed_on_string_parameter() {
        // Same philosophy as min/max on a non-numeric type: reject rather
        // than silently ignore an author's constraint (allowed values are
        // integers by schema, so on a string they describe nothing sendable).
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{s}"]
            parameters:
              s:
                type: string
                allowed: [1]"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::BoundsOnNonNumericType { bound, .. }) => {
                assert_eq!(bound, "allowed");
            }
            other => panic!("expected BoundsOnNonNumericType, got {other:?}"),
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
        // Two fields named "level" would make decode_all_fields (whose
        // DecodedValues overwrites a repeated name in place) silently drop
        // the first one's value; reject at parse time instead.
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
    fn rejects_template_reference_to_undeclared_parameter() {
        // Typo: the template says "{brightnes}" but the declared parameter
        // is "brightness". Must fail at parse time with both names surfaced,
        // not at write time with ParameterMissing.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_brightness:
            description: x
            template: [0x02, "{brightnes}"]
            parameters:
              brightness:
                type: uint8
                min: 0
                max: 100"#,
        );
        let err = parse_device_spec(&yaml).expect_err("typo'd reference should be rejected");
        match &err {
            SpecError::UnknownTemplateParameter { command, parameter } => {
                assert_eq!(command, "set_brightness");
                assert_eq!(parameter, "brightnes");
            }
            other => panic!("expected UnknownTemplateParameter, got {other:?}"),
        }
        let msg = err.to_string();
        assert!(
            msg.contains("set_brightness") && msg.contains("brightnes"),
            "message should name the command and the bad reference, got: {msg}"
        );
    }

    #[test]
    fn rejects_template_reference_with_no_parameters_block() {
        // The same authoring bug in its most extreme form: a template that
        // references a parameter while declaring none at all.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{n}"]"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::UnknownTemplateParameter { command, parameter }) => {
                assert_eq!(command, "set");
                assert_eq!(parameter, "n");
            }
            other => panic!("expected UnknownTemplateParameter, got {other:?}"),
        }
    }

    /// Unknown descriptive keys must not fail the parse.
    ///
    /// This test previously asserted the opposite. It was flipped when the full
    /// spec catalogue was vendored: strictness here rejected 70 of 71 upstream
    /// specs over keys like `discovery`, `setup` and `model` that the BLE path
    /// never reads. Losing a device over a descriptive key is a worse failure
    /// than missing a typo, and the catalogue is meant to be refreshed as data.
    #[test]
    fn tolerates_unknown_field_in_device_block() {
        let yaml = r#"
device:
  name: "x"
  manufacturer: "x"
  manufacturer_status: "abandoned"
  protocol: "ble"
  bogus_field: 1
services: []
"#;
        let spec = parse_device_spec(yaml).expect("descriptive keys must not fail the parse");
        assert_eq!(spec.device.name, "x");
        assert!(
            spec.device.extensions.contains_key("bogus_field"),
            "unknown device keys should be preserved in the extensions bag"
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
    fn tolerates_unknown_field_in_characteristic() {
        // Typo detection is preserved on the protocol-execution structs: an
        let yaml = make_minimal_spec(
            r#"        properties: ["read"]
        bogus_characteristic_key: 1"#,
        );
        let spec =
            parse_device_spec(&yaml).expect("a descriptive key here must not fail the parse");
        assert_eq!(spec.device.name, "x");
    }

    #[test]
    fn tolerates_unknown_field_in_service() {
        // N1: a typo at the service level (drives which GATT service is used)
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
        let spec = parse_device_spec(yaml).expect("a descriptive key here must not fail the parse");
        assert_eq!(spec.device.name, "x");
    }

    #[test]
    fn tolerates_unknown_field_in_command() {
        // N1: a typo at the command level (e.g. `templte` instead of
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          do_thing:
            description: x
            value: [0x01]
            bogus_command_key: 1"#,
        );
        let spec =
            parse_device_spec(&yaml).expect("a descriptive key here must not fail the parse");
        assert_eq!(spec.device.name, "x");
    }

    #[test]
    fn tolerates_unknown_field_in_parameter() {
        // N1: a typo in a parameter definition (e.g. `mn` instead of `min`)
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
        let spec =
            parse_device_spec(&yaml).expect("a descriptive key here must not fail the parse");
        assert_eq!(spec.device.name, "x");
    }

    #[test]
    fn tolerates_unknown_field_in_format_field() {
        // N1: a typo in a format field (e.g. `ofset`) would misparse a read
        let yaml = make_minimal_spec(
            r#"        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: v
            type: uint8
            bogus_format_key: 1"#,
        );
        let spec =
            parse_device_spec(&yaml).expect("a descriptive key here must not fail the parse");
        assert_eq!(spec.device.name, "x");
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

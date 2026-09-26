// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Parse device spec YAML into Rust types.

use super::types::{AutoRole, Command, DeviceSpec, FormatField, Parameter, TemplateElement};
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
/// - An `auto` role must fit the parameter's declared `type` — a two-byte
///   `crc16_modbus` on a `uint8` would compute fine and then fail encoding
///   on every send, complaining about a value the author never wrote.
///
/// One normalisation runs alongside: a command declaring both `value` and
/// `template` keeps the template and loses the value
/// ([`prefer_template_over_value`]).
pub fn parse_device_spec(yaml: &str) -> Result<DeviceSpec, SpecError> {
    let mut spec: DeviceSpec = serde_yaml::from_str(yaml)?;
    hoist_device_nested_capabilities(&mut spec);
    prefer_template_over_value(&mut spec);
    validate_spec(&spec)?;
    Ok(spec)
}

/// Drop the `value` of any command that also declares a `template`.
///
/// The two are rival envelopes for the same bytes, and every consumer used
/// to settle the rivalry on its own: the encoder sent `value`, the entity
/// binder called the command fixed, and the DTO still listed the template's
/// parameters — so the raw command browser drew zone/red/green/blue sliders
/// for xkglow-chrome's `set_rgb_color` and Send wrote the fixed bytes
/// (zone 0, pure red) whatever the user chose. Deciding it once, here, is
/// what makes those consumers agree.
///
/// Template over value, and normalising rather than rejecting, because:
/// - The template is the fuller statement. It says what varies and how,
///   and the parameters beside it are the author's promise that a user can
///   choose those bytes. A `value` beside it can only ever be one filling
///   of the template — xkglow's is exactly the template with zone 0 and
///   red 255 — so nothing the author wrote is lost.
/// - Rejecting would cost the whole spec for one redundant line. The
///   catalogue is vendored unmodified and the Dart loader skips an
///   unparseable spec, so a load-time error here is a missing device, not
///   a corrected one. The remaining damage — the light entity's `turn_on`
///   role, which the fixed bytes used to serve, now needs a parameter the
///   spec gives no default for and stops resolving — is the honest reading
///   of that spec, and the upstream fix (a separate fixed `turn_on`, a
///   `default` on `zone`) is filed in SPECS_TO_FIX.md.
///
/// `codec::types::encode_command_with_bytes` restates the same preference
/// for a hand-built `Command`, so the two cannot drift.
fn prefer_template_over_value(spec: &mut DeviceSpec) {
    for service in &mut spec.services {
        for characteristic in &mut service.characteristics {
            let Some(commands) = &mut characteristic.commands else {
                continue;
            };
            for command in commands.values_mut() {
                if command.template.is_some() {
                    command.value = None;
                }
            }
        }
    }
}

/// Read `features` and `protocol_handler` from under `device:` when the top
/// level declares neither.
///
/// The schema puts both at the top level, but part of the catalogue nests
/// them under `device:` — cat-printer, fichero-d11-printer and niimbot-d110
/// at the time of writing — where the schema's open `device` block accepts
/// them without complaint. Dropped on the floor, a declared image-upload
/// capability never reaches the DTO and the device renders as if it had
/// none, which is the one outcome the "declarative capability, honest
/// encodable flag" split exists to prevent. A top-level declaration always
/// wins; a nested block of some other shape is left alone rather than
/// failing the spec (this is a tolerance rule, not a second schema).
fn hoist_device_nested_capabilities(spec: &mut DeviceSpec) {
    if spec.protocol_handler.is_none() {
        spec.protocol_handler = spec
            .device
            .extensions
            .get("protocol_handler")
            .and_then(|v| v.as_str())
            .map(str::to_owned);
    }
    if spec.features.is_empty() {
        if let Some(nested) = spec.device.extensions.get("features") {
            if let Ok(features) = serde_yaml::from_value(nested.clone()) {
                spec.features = features;
            }
        }
    }
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

/// An `auto` role must fit the type the parameter declares.
///
/// The encoder fills these in itself and then pushes the result through the
/// ordinary numeric path, so the declared `type` is what places the bytes. A
/// mismatch is invisible in the YAML and fatal on the wire: `auto:
/// crc16_modbus` on a `uint8` computes a two-byte CRC and then fails
/// `coerce_param` with an out-of-range complaint about a value the spec
/// author never wrote — at send time, in front of the device, with nothing
/// in the message pointing at the type declaration that caused it.
///
/// The whole catalogue already complies (`checksum`/`xor_checksum` on
/// `uint8`, `crc16_modbus` on `uint16`, `sequence` on `uint16`), so this
/// pins today's specs and catches tomorrow's typo at load.
fn validate_auto_role(name: &str, param: &Parameter) -> Result<(), SpecError> {
    let Some(role) = param.auto else {
        return Ok(());
    };
    if role == AutoRole::PacketLength {
        // The length is patched in after the packet is built, into a slot
        // reserved by width — so a variable-width type has nothing to
        // reserve. The encoder says the same thing; saying it here names the
        // spec instead of the send.
        if param.value_type.fixed_byte_size().is_none() {
            return Err(SpecError::AutoLengthOnVariableWidthType {
                parameter_name: name.to_string(),
                value_type: param.value_type.clone(),
            });
        }
        return Ok(());
    }
    let Some((_, holds)) = param.value_type.integer_range() else {
        return Err(SpecError::AutoRoleOnNonNumericType {
            parameter_name: name.to_string(),
            role: role.to_string(),
            value_type: param.value_type.clone(),
        });
    };
    // The widest value each role can produce. `sequence` is the caller's
    // counter rather than a computed value, so it has no ceiling of its own —
    // being numeric at all is the whole requirement.
    let emits = match role {
        AutoRole::Checksum
        | AutoRole::XorChecksum
        | AutoRole::SubtractChecksum
        | AutoRole::Crc8 => u8::MAX as i64,
        AutoRole::Crc16Modbus => u16::MAX as i64,
        AutoRole::Sequence | AutoRole::PacketLength => return Ok(()),
    };
    if emits > holds {
        return Err(SpecError::AutoRoleTooWideForType {
            parameter_name: name.to_string(),
            role: role.to_string(),
            value_type: param.value_type.clone(),
            emits,
            holds,
        });
    }
    Ok(())
}

/// `default` is mutually exclusive with `source` and with `auto`.
///
/// All three answer one question — what goes on the wire when the caller
/// supplies nothing — and they answer it with different instructions, so a
/// parameter carrying two of them has no correct reading. The schema states
/// the `default`/`source` half outright ("a parameter carrying both lets a
/// renderer quietly substitute the constant when the stored value is
/// missing — which for a password parameter means sending a wrong password
/// instead of failing at 'not paired'"). The `auto` half is the same bug
/// with the encoder in the stored value's place: `encode_command` resolves a
/// supplied value, then the `auto` role, and never reaches the default — so
/// a spec that wrote one was describing a frame this crate does not send,
/// and nothing said so.
///
/// Rejected rather than resolved by precedence because there is no honest
/// precedence to pick: whichever way a consumer breaks the tie, half the
/// specs written this way get the other one. No vendored spec declares
/// either pairing today, so this costs the catalogue nothing and catches the
/// first one at load.
fn validate_default_exclusivity(name: &str, param: &Parameter) -> Result<(), SpecError> {
    if param.default.is_none() {
        return Ok(());
    }
    let conflict = if param.source.is_some() {
        "source"
    } else if param.auto.is_some() {
        "auto"
    } else {
        return Ok(());
    };
    Err(SpecError::DefaultWithConflictingSource {
        parameter_name: name.to_string(),
        conflict: conflict.to_string(),
    })
}

fn validate_parameter(name: &str, param: &Parameter) -> Result<(), SpecError> {
    validate_auto_role(name, param)?;
    validate_default_exclusivity(name, param)?;
    let Some((lo, hi)) = param.value_type.integer_range() else {
        // No numeric range (string/bytes): min/max are meaningless here.
        // Reject rather than silently ignore an author's bound. `allowed`
        // gets the same treatment — its values are integers by schema, so on
        // a non-numeric parameter it cannot describe anything sendable.
        // `default` likewise: the encoder would try to coerce it to an
        // integer width and fail at send time.
        for (label, present) in [
            ("min", param.min.is_some()),
            ("max", param.max.is_some()),
            ("allowed", param.allowed.is_some()),
            ("values", param.values.is_some()),
            ("default", param.default.is_some()),
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
    for (label, bound) in [
        ("min", param.min.map(|v| v as f64)),
        ("max", param.max.map(|v| v as f64)),
        // `default` is a `number` in the schema where `min`/`max` are
        // `integer`, so it is bounded as one — the comparison is the same,
        // and a fractional default that sits inside the range is left for
        // `coerce_param` to refuse by name at send time rather than costing
        // the whole spec here.
        ("default", param.default),
    ] {
        let Some(value) = bound else { continue };
        if value < lo as f64 || value > hi as f64 {
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
    //
    // The `values` code table gets the same treatment, for the same reason:
    // `Parameter::allowed_with_labels` offers its keys as choices when the
    // parameter states no `allowed`, so an out-of-range key is a dropdown
    // entry that fails encoding exactly as an out-of-range `allowed` would.
    {
        let lo_eff = param.min.unwrap_or(lo);
        let hi_eff = param.max.unwrap_or(hi);
        let offered = param
            .allowed_with_labels()
            .into_iter()
            .flatten()
            .map(|(value, _)| value);
        for value in offered {
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
    // The default must satisfy the same effective bounds encode_command
    // enforces per write, or every send relying on it would fail — and the
    // failure would surface as a broken control, not a broken spec.
    if let Some(default) = param.default {
        let lo_eff = param.min.unwrap_or(lo);
        let hi_eff = param.max.unwrap_or(hi);
        if default < lo_eff as f64 || default > hi_eff as f64 {
            return Err(SpecError::DefaultOutsideBounds {
                parameter_name: name.to_string(),
                value: default,
                min: lo_eff,
                max: hi_eff,
            });
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codec::types::encode_command;
    use crate::spec::types::{CharacteristicProperty, ManufacturerStatus, Protocol, ValueType};
    use crate::test_fixtures::make_minimal_spec;
    use std::collections::HashMap;

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
                assert_eq!(value, 300.0);
            }
            other => panic!("expected ParameterRangeOutsideType, got {other:?}"),
        }
    }

    #[test]
    fn rejects_a_parameter_that_is_both_sourced_and_defaulted() {
        // The schema forbids the pair outright: `source` says the real value
        // lives in the credential store and a send without it must FAIL,
        // `default` says substitute this constant. Accepting both let the
        // encoder send the constant — a wrong password instead of an honest
        // "not paired yet".
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          verify_password:
            description: x
            template: [0x0a, "{password}"]
            parameters:
              password:
                type: uint8
                source: "credential:device_password"
                default: 0"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::DefaultWithConflictingSource {
                parameter_name,
                conflict,
            }) => {
                assert_eq!(parameter_name, "password");
                assert_eq!(conflict, "source");
            }
            other => panic!("expected DefaultWithConflictingSource, got {other:?}"),
        }
    }

    #[test]
    fn rejects_a_parameter_that_is_both_auto_and_defaulted() {
        // Same contradiction with the encoder in the credential store's
        // place: `encode_command` resolves the auto role and never reaches
        // the default, so the frame the spec described is not the frame that
        // goes out, and nothing said so.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          go:
            description: x
            template: [0xf7, "{speed}", "{checksum}"]
            parameters:
              speed:
                type: uint8
              checksum:
                type: uint8
                auto: checksum
                default: 0"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::DefaultWithConflictingSource {
                parameter_name,
                conflict,
            }) => {
                assert_eq!(parameter_name, "checksum");
                assert_eq!(conflict, "auto");
            }
            other => panic!("expected DefaultWithConflictingSource, got {other:?}"),
        }
    }

    #[test]
    fn a_default_written_as_a_float_parses_and_encodes() {
        // The schema types `default` a `number`, so `2.0` is the same raw
        // value as `2` and must not be a type error — one that cost the WHOLE
        // spec, and with it the device.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_mode:
            description: x
            template: [0x01, "{mode}"]
            parameters:
              mode:
                type: uint8
                default: 2.0"#,
        );
        let spec = parse_device_spec(&yaml).expect("a float-spelled default should parse");
        let command = &spec.services[0].characteristics[0]
            .commands
            .as_ref()
            .expect("commands")["set_mode"];
        assert_eq!(
            encode_command(command, &HashMap::new()).expect("encodes from the default"),
            vec![0x01, 0x02]
        );
    }

    #[test]
    fn a_fractional_default_costs_its_own_send_and_not_the_spec() {
        // A raw wire value cannot be 2.5, but the spec is still a device: the
        // parameter fails by name at send time, where the message can say
        // which one, instead of taking every other command down at load.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_mode:
            description: x
            template: [0x01, "{mode}"]
            parameters:
              mode:
                type: uint8
                default: 2.5"#,
        );
        let spec = parse_device_spec(&yaml).expect("the spec should still load");
        let command = &spec.services[0].characteristics[0]
            .commands
            .as_ref()
            .expect("commands")["set_mode"];
        let err = encode_command(command, &HashMap::new()).expect_err("2.5 is not a wire value");
        assert!(
            err.to_string().contains("mode"),
            "the failure should name the parameter: {err}"
        );
    }

    #[test]
    fn a_values_code_table_is_read_as_the_parameters_choices() {
        // Nine catalogue parameters spell their enumeration `values`; read as
        // nothing, each drew a 0..255 slider over a two-value switch.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_light_on_off:
            description: x
            template: [0x04, "{state}"]
            parameters:
              state:
                type: uint8
                values:
                  0: "off"
                  1: "on""#,
        );
        let spec = parse_device_spec(&yaml).expect("a values table should parse");
        let command = &spec.services[0].characteristics[0]
            .commands
            .as_ref()
            .expect("commands")["set_light_on_off"];
        let state = &command.parameters.as_ref().expect("parameters").params["state"];
        assert_eq!(
            state.allowed_with_labels(),
            Some(vec![
                (0, Some("off".to_string())),
                (1, Some("on".to_string()))
            ])
        );
    }

    #[test]
    fn a_values_key_outside_the_type_is_refused_like_an_allowed_value() {
        // The keys are offered as choices, so they are held to the same bound
        // `allowed` is: every visible choice must be one the device accepts.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_mode:
            description: x
            template: [0x04, "{mode}"]
            parameters:
              mode:
                type: uint8
                max: 3
                values:
                  0: "auto"
                  9: "impossible""#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::AllowedValueOutsideBounds { value, max, .. }) => {
                assert_eq!(value, 9);
                assert_eq!(max, 3);
            }
            other => panic!("expected AllowedValueOutsideBounds, got {other:?}"),
        }
    }

    #[test]
    fn allowed_wins_over_values_and_borrows_its_labels() {
        // `allowed` is the schema's key and the one the bounds check walks;
        // a `values` table beside it can only supply names.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_mode:
            description: x
            template: [0x04, "{mode}"]
            parameters:
              mode:
                type: uint8
                allowed: [0, 1]
                values:
                  0: "auto"
                  1: "manual"
                  2: "not offered""#,
        );
        let spec = parse_device_spec(&yaml).expect("both spellings together should parse");
        let command = &spec.services[0].characteristics[0]
            .commands
            .as_ref()
            .expect("commands")["set_mode"];
        let mode = &command.parameters.as_ref().expect("parameters").params["mode"];
        assert_eq!(
            mode.allowed_with_labels(),
            Some(vec![
                (0, Some("auto".to_string())),
                (1, Some("manual".to_string()))
            ]),
            "the `values` table labels the values `allowed` lists, and adds none"
        );
    }

    #[test]
    fn mismatched_labels_are_dropped_rather_than_mispaired() {
        // Zipping short would attach the wrong name to a value the device
        // really acts on; the raw number is the honest fallback.
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_mode:
            description: x
            template: [0x04, "{mode}"]
            parameters:
              mode:
                type: uint8
                allowed: [0, 1, 2]
                labels: ["auto", "manual"]"#,
        );
        let spec = parse_device_spec(&yaml).expect("a mismatched spec still loads");
        let command = &spec.services[0].characteristics[0]
            .commands
            .as_ref()
            .expect("commands")["set_mode"];
        let mode = &command.parameters.as_ref().expect("parameters").params["mode"];
        assert_eq!(
            mode.allowed_with_labels(),
            Some(vec![(0, None), (1, None), (2, None)]),
            "an unpairable label list names nothing, and says so"
        );
    }

    #[test]
    fn labels_name_a_min_max_range_one_per_value() {
        // A contiguous set is written as a range; `allowed` is for gaps. So
        // `min: 1, max: 4` with four labels is a four-way choice, min first,
        // and a count that does not match the range names nothing.
        let parse = |labels: &str| {
            let yaml = make_minimal_spec(&format!(
                r#"        properties: ["write"]
        commands:
          request:
            description: x
            template: [0x82, "{{param}}"]
            parameters:
              param:
                type: uint8
                min: 1
                max: 4
                labels: {labels}"#
            ));
            let spec = parse_device_spec(&yaml).expect("a labelled range parses");
            let command = &spec.services[0].characteristics[0]
                .commands
                .as_ref()
                .expect("commands")["request"];
            command.parameters.as_ref().expect("parameters").params["param"].allowed_with_labels()
        };
        assert_eq!(
            parse(r#"["temperature", "humidity", "pressure", "co2"]"#),
            Some(vec![
                (1, Some("temperature".to_string())),
                (2, Some("humidity".to_string())),
                (3, Some("pressure".to_string())),
                (4, Some("co2".to_string())),
            ])
        );
        assert_eq!(parse(r#"["temperature", "humidity"]"#), None);
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
    fn rejects_default_outside_effective_bounds() {
        // The encoder trusts the default on every send that omits the
        // parameter, so a default outside min/max would make every such send
        // fail — surface it at load time instead.
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
                default: 200"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::DefaultOutsideBounds {
                parameter_name,
                value,
                min,
                max,
            }) => {
                assert_eq!(parameter_name, "brightness");
                assert_eq!(value, 200.0);
                assert_eq!(min, 0);
                assert_eq!(max, 100);
            }
            other => panic!("expected DefaultOutsideBounds, got {other:?}"),
        }
    }

    #[test]
    fn rejects_default_outside_type_range() {
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{n}"]
            parameters:
              n:
                type: uint8
                default: 300"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::ParameterRangeOutsideType { bound, value, .. }) => {
                assert_eq!(bound, "default");
                assert_eq!(value, 300.0);
            }
            other => panic!("expected ParameterRangeOutsideType, got {other:?}"),
        }
    }

    #[test]
    fn rejects_default_on_string_parameter() {
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set:
            description: x
            template: [0x01, "{s}"]
            parameters:
              s:
                type: string
                default: 1"#,
        );
        match parse_device_spec(&yaml) {
            Err(SpecError::BoundsOnNonNumericType { bound, .. }) => {
                assert_eq!(bound, "default");
            }
            other => panic!("expected BoundsOnNonNumericType, got {other:?}"),
        }
    }

    #[test]
    fn accepts_default_at_effective_bounds() {
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
                default: 10"#,
        );
        parse_device_spec(&yaml).expect("a default at the bound should parse");
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
                assert_eq!(value, -1.0);
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

    /// Build a one-command spec whose single parameter carries `auto: role`
    /// on the declared `ty`.
    fn spec_with_auto(ty: &str, role: &str) -> String {
        make_minimal_spec(&format!(
            r#"        properties: ["write"]
        commands:
          send:
            description: x
            template: [0x01, "{{tail}}"]
            parameters:
              tail:
                type: {ty}
                auto: {role}"#
        ))
    }

    /// A two-byte CRC declared as a one-byte field is a spec bug that used to
    /// surface at SEND time, as an out-of-range complaint about a value the
    /// author never wrote — with nothing in the message pointing at the type
    /// declaration that caused it.
    #[test]
    fn rejects_a_crc16_that_does_not_fit_its_declared_type() {
        let err = parse_device_spec(&spec_with_auto("uint8", "crc16_modbus"))
            .expect_err("a 16-bit crc does not fit a uint8");
        let msg = err.to_string();
        assert!(msg.contains("crc16_modbus"), "{msg}");
        assert!(msg.contains("65535"), "the message says how wide: {msg}");
        assert!(msg.contains("255"), "and what the type holds: {msg}");
    }

    /// A one-byte checksum on `int8` holds only 127 — the same failure, one
    /// signedness away, and just as invisible in the YAML.
    #[test]
    fn rejects_a_checksum_on_a_type_that_cannot_hold_255() {
        for role in ["checksum", "xor_checksum"] {
            parse_device_spec(&spec_with_auto("int8", role))
                .expect_err("a byte checksum does not fit an int8");
        }
    }

    /// The catalogue's own pairings must keep parsing: this rule pins today's
    /// specs as much as it catches tomorrow's typo.
    #[test]
    fn accepts_the_auto_role_and_type_pairings_the_catalogue_uses() {
        for (ty, role) in [
            ("uint8", "checksum"),
            ("uint8", "xor_checksum"),
            ("uint16", "crc16_modbus"),
            ("uint16", "sequence"),
            ("uint32", "packet_length"),
        ] {
            parse_device_spec(&spec_with_auto(ty, role))
                .unwrap_or_else(|e| panic!("{ty} + {role} should parse: {e}"));
        }
    }

    /// `packet_length` is patched into a slot reserved by width, so a
    /// variable-width type has nothing to reserve. The encoder already said
    /// so; saying it at load names the spec instead of the send.
    #[test]
    fn rejects_a_packet_length_on_a_variable_width_type() {
        let err = parse_device_spec(&spec_with_auto("varint", "packet_length"))
            .expect_err("a varint reserves no fixed slot");
        assert!(err.to_string().contains("fixed width"), "{err}");
    }

    /// An `auto` role on a `bytes` parameter has no number to fill in at all.
    #[test]
    fn rejects_an_auto_role_on_a_non_numeric_type() {
        let err = parse_device_spec(&spec_with_auto("bytes", "sequence"))
            .expect_err("a bytes parameter carries no number");
        assert!(err.to_string().contains("no number"), "{err}");
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
    fn a_stale_color_order_key_does_not_cost_the_whole_spec() {
        // `color_order` was a reserved sibling of the parameter definitions
        // until upstream removed it: the template already states the channel
        // order by naming {red}/{green}/{blue} in the sequence the bytes go
        // out, so the two could disagree with nothing to say which won.
        //
        // A third-party spec pack pinned to the older schema still carries it,
        // and its value is a string where a parameter definition is a map. The
        // point of this test is that the mismatch costs that one key and not
        // the device: without the absorbing field, serde hands "rbg" to
        // Parameter's deserializer and the error fails the entire parse.
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
        let spec = parse_device_spec(&yaml).expect("a stale color_order must not fail the spec");
        let cmd = &spec.services[0].characteristics[0]
            .commands
            .as_ref()
            .unwrap()["set_color"];
        let params = cmd.parameters.as_ref().unwrap();
        assert_eq!(
            params.params.len(),
            3,
            "color_order must not become a param"
        );
        assert!(params.params.contains_key("red"));
        // The channel order the encoder actually walks is the template's, and
        // it is unchanged by the retired key claiming otherwise.
        assert_eq!(
            encode_command(
                cmd,
                &HashMap::from([
                    ("red".to_string(), 1.0),
                    ("green".to_string(), 2.0),
                    ("blue".to_string(), 3.0),
                ])
            )
            .expect("encodes"),
            vec![0x03, 1, 2, 3],
        );
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

    /// xkglow-chrome's `set_rgb_color` declares a fixed `value` AND a
    /// parameterised `template`. The template wins at load time, so every
    /// consumer downstream sees one parameterised command: the encoder
    /// fills it from the caller's values instead of writing the fixed
    /// bytes, and nothing calls it fixed.
    #[test]
    fn template_wins_when_a_command_declares_both_value_and_template() {
        let yaml = make_minimal_spec(
            r#"        properties: ["write"]
        commands:
          set_rgb_color:
            description: Set solid RGB colour for a zone
            value: [0x00, 0x00, 0x04, 0xFF, 0x00, 0x00]
            template: [0x00, "{zone}", 0x04, "{red}", "{green}", "{blue}"]
            parameters:
              zone: { type: uint8, min: 0, max: 255 }
              red: { type: uint8, min: 0, max: 255 }
              green: { type: uint8, min: 0, max: 255 }
              blue: { type: uint8, min: 0, max: 255 }"#,
        );
        let spec = parse_device_spec(&yaml).expect("both envelopes must still load");
        let cmd = spec.services[0].characteristics[0]
            .commands
            .as_ref()
            .unwrap()
            .get("set_rgb_color")
            .unwrap();
        assert!(cmd.value.is_none(), "the fixed value must be dropped");
        assert!(cmd.template.is_some());

        let params = HashMap::from([
            ("zone".to_string(), 1.0),
            ("red".to_string(), 10.0),
            ("green".to_string(), 20.0),
            ("blue".to_string(), 30.0),
        ]);
        assert_eq!(
            encode_command(cmd, &params).unwrap(),
            vec![0x00, 0x01, 0x04, 10, 20, 30]
        );
    }

    /// The normalisation is scoped to the conflict: a plain fixed command
    /// keeps its `value`, a plain templated one is untouched.
    #[test]
    fn a_lone_value_or_template_is_left_alone() {
        let spec = parse_device_spec(EXAMPLE_BULB_YAML).unwrap();
        let commands = spec.services[0].characteristics[0]
            .commands
            .as_ref()
            .unwrap();
        assert_eq!(
            commands.get("power_on").unwrap().value,
            Some(vec![0x01, 0x01])
        );
        let dim = commands.get("set_brightness").unwrap();
        assert!(dim.value.is_none());
        assert!(dim.template.is_some());
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

    /// The shape cat-printer, fichero-d11 and niimbot ship: `features` and
    /// `protocol_handler` under `device:` where the schema's open block
    /// swallows them. Both must reach the typed fields.
    const DEVICE_NESTED_YAML: &str = r#"
device:
  name: "Nested Printer"
  manufacturer: "Nobody"
  manufacturer_status: "unsupported"
  protocol: "ble"
  features:
    - type: "image_upload"
      max_width: 384
      format: "1bit-bitmap"
  protocol_handler: "nested_handler"
services: []
"#;

    #[test]
    fn device_nested_features_and_handler_are_hoisted() {
        let spec = parse_device_spec(DEVICE_NESTED_YAML).unwrap();
        assert_eq!(spec.protocol_handler.as_deref(), Some("nested_handler"));
        assert_eq!(spec.features.len(), 1);
        assert_eq!(spec.features[0].feature_type, "image_upload");
        assert_eq!(spec.features[0].max_width, Some(384));
        // Preserved verbatim under device too — nothing is lost.
        assert!(spec.device.extensions.contains_key("features"));
    }

    #[test]
    fn top_level_declarations_win_over_device_nested_ones() {
        let yaml = format!(
            "{DEVICE_NESTED_YAML}\nprotocol_handler: \"top_handler\"\nfeatures:\n  - type: \"firmware_update\"\n"
        );
        let spec = parse_device_spec(&yaml).unwrap();
        assert_eq!(spec.protocol_handler.as_deref(), Some("top_handler"));
        assert_eq!(spec.features.len(), 1);
        assert_eq!(spec.features[0].feature_type, "firmware_update");
    }

    #[test]
    fn a_device_features_block_of_another_shape_is_ignored_not_fatal() {
        // A plain string list (an entity-style capability tag list) is not
        // a feature list; it must neither hoist nor fail the spec.
        let yaml = DEVICE_NESTED_YAML.replace(
            "  features:\n    - type: \"image_upload\"\n      max_width: 384\n      format: \"1bit-bitmap\"\n",
            "  features: [brightness, effect]\n",
        );
        let spec = parse_device_spec(&yaml).unwrap();
        assert!(spec.features.is_empty());
        assert_eq!(spec.protocol_handler.as_deref(), Some("nested_handler"));
    }
}

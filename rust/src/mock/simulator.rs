// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Mock device simulator — generates realistic fake BLE readings
//! for development and testing without real hardware.

use crate::spec::types::{FormatField, ValueType};
use std::collections::HashMap;

/// Simulated state for one connected mock device.
#[derive(Default)]
pub struct MockDeviceState {
    /// Written characteristic values (keyed by char UUID).
    written: HashMap<String, Vec<u8>>,
}

impl MockDeviceState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Store a written value for a characteristic.
    pub fn write(&mut self, char_uuid: &str, value: Vec<u8>) {
        // ASCII-lowercase per crate convention (SEV2 §2.5): UUIDs are pure
        // ASCII, and `read`/`read_raw` must normalize keys identically.
        self.written.insert(char_uuid.to_ascii_lowercase(), value);
    }

    /// Generate a mock read value for a characteristic based on its format spec.
    /// If a value was previously written to this characteristic, returns that.
    /// Otherwise generates plausible defaults.
    pub fn read(&self, char_uuid: &str, format: &[FormatField]) -> Vec<u8> {
        let key = char_uuid.to_ascii_lowercase();

        // Return last written value if available
        if let Some(written) = self.written.get(&key) {
            return written.clone();
        }

        // Generate default values based on format
        generate_defaults(format)
    }

    /// Generate a mock read value for a characteristic that has no format spec.
    /// Returns the previously written value if there is one, otherwise a
    /// zero-filled buffer of `length` bytes (the caller falls back to raw hex
    /// display either way).
    pub fn read_raw(&self, char_uuid: &str, length: usize) -> Vec<u8> {
        let key = char_uuid.to_ascii_lowercase();
        if let Some(written) = self.written.get(&key) {
            return written.clone();
        }
        vec![0u8; length]
    }
}

/// Generate plausible default bytes for a set of format fields.
///
/// Lookup order per field: explicit `mock_default` from the spec → name-based
/// heuristic for the field's value type → 0.
fn generate_defaults(fields: &[FormatField]) -> Vec<u8> {
    let total_len = fields
        .iter()
        .map(|f| f.offset + f.length)
        .max()
        .unwrap_or(0);
    let mut bytes = vec![0u8; total_len];

    for field in fields {
        let slice = &mut bytes[field.offset..field.offset + field.length];

        // 1. Try the explicit `mock_default` from the spec.
        if let Some(val) = field
            .mock_default
            .as_ref()
            .and_then(|v| coerce_mock_default(v, &field.field_type))
        {
            write_value(slice, val, &field.field_type);
            continue;
        }

        // 2. Fall back to the name-based heuristic. The value goes through
        // `write_value` (never a direct full-slice copy) because `length`
        // may legally exceed the type's byte width — see `write_value`.
        //
        // A declared `scale` says what a raw count means, so work back from a
        // plausible physical reading instead of guessing at the count:
        // Airthings' temperature is `scale: 0.01`, and a reader that applies
        // the scale would turn the unscaled 220 into 2.2 °C. Without a scale
        // nothing in the spec says what the units are, so the historical raw
        // constants stand.
        let heuristic: Option<i64> = match (&field.field_type, field.scale) {
            (ValueType::Bool, _) => Some(1), // default: on
            (
                ValueType::Uint8
                | ValueType::Uint16
                | ValueType::Int8
                | ValueType::Int16
                | ValueType::Int32
                | ValueType::Uint32,
                Some(scale),
            ) => Some(raw_for_physical(nominal_for_name(&field.name), scale)),
            (ValueType::Uint8, None) => Some(default_uint8_for_name(&field.name) as i64),
            (ValueType::Uint16, None) => Some(default_uint16_for_name(&field.name) as i64),
            (ValueType::Int8, None) => Some(22),   // ~22°C
            (ValueType::Int16, None) => Some(220), // 22.0 if scaled
            // 32-bit fields with no scale, and the non-numeric types, stay zero.
            (ValueType::Int32 | ValueType::Uint32, None)
            | (ValueType::Bytes | ValueType::String, _) => None,
        };
        if let Some(val) = heuristic {
            write_value(slice, val, &field.field_type);
        }
    }

    bytes
}

/// Try to interpret a YAML scalar as the integer payload for a field type.
///
/// Returns `None` for type mismatches *and* for numbers that don't fit in
/// the declared type's range — both cases fall through to the name-based
/// heuristic. Spec authors who write nonsense like `mock_default: 999` on
/// a `uint8` field get the heuristic value, not a silently-wrapped byte.
/// `Bytes` and `String` fields don't accept `mock_default` at all (they
/// have no integer representation), so they always return `None` here.
fn coerce_mock_default(val: &serde_yaml::Value, ty: &ValueType) -> Option<i64> {
    match (val, ty) {
        (serde_yaml::Value::Bool(b), ValueType::Bool) => Some(if *b { 1 } else { 0 }),
        (serde_yaml::Value::Number(n), _) => {
            let raw = n.as_i64()?;
            let (min, max) = ty.integer_range()?;
            (min..=max).contains(&raw).then_some(raw)
        }
        _ => None,
    }
}

/// Write `val` into the low bytes of `slice`, honoring the byte width and
/// little-endian layout of `ty`.
///
/// `slice` is the field's full `length` extent and may legally be *longer*
/// than the type's fixed width — the parser deliberately tolerates over-long
/// fixed fields (`type: uint16, length: 3`, e.g. padded/reserved trailing
/// bytes), so only the low `fixed_byte_size()` bytes are written and the tail
/// stays zero, mirroring how `decode_field` reads only the low bytes. A
/// whole-slice `copy_from_slice` here panics on exactly those specs, and this
/// code is reachable from Dart via `mock_read_characteristic` on remote
/// spec-pack YAML (H1). `slice` is never *shorter* than the fixed width: the
/// parser rejects that at load time (`FieldLengthMismatch`).
fn write_value(slice: &mut [u8], val: i64, ty: &ValueType) {
    match ty {
        ValueType::Bool => slice[0] = if val == 0 { 0 } else { 1 },
        ValueType::Uint8 => slice[0] = val as u8,
        ValueType::Int8 => slice[0] = val as i8 as u8,
        ValueType::Uint16 => slice[..2].copy_from_slice(&(val as u16).to_le_bytes()),
        ValueType::Int16 => slice[..2].copy_from_slice(&(val as i16).to_le_bytes()),
        ValueType::Int32 => slice[..4].copy_from_slice(&(val as i32).to_le_bytes()),
        ValueType::Uint32 => slice[..4].copy_from_slice(&(val as u32).to_le_bytes()),
        ValueType::Bytes | ValueType::String => {} // mock_default is ignored for these
    }
}

fn default_uint8_for_name(name: &str) -> u8 {
    let lower = name.to_lowercase();
    if lower.contains("brightness") {
        80
    } else if lower.contains("battery") || lower.contains("percent") {
        85
    } else if lower.contains("red") {
        255
    } else if lower.contains("green") {
        180
    } else if lower.contains("blue") {
        50
    } else if lower.contains("speed") {
        128
    } else {
        50
    }
}

/// A plausible reading in the field's own unit, chosen by name.
///
/// The counterpart to [`default_uint16_for_name`] for specs that declare a
/// `scale`: that one guesses at a raw count, this one names the physical value
/// and lets [`raw_for_physical`] derive the count the device would send.
fn nominal_for_name(name: &str) -> f64 {
    let lower = name.to_lowercase();
    if lower.contains("temp") {
        22.0
    } else if lower.contains("humid") {
        55.0
    } else if lower.contains("lux") || lower.contains("light") {
        500.0
    } else if lower.contains("battery") || lower.contains("percent") {
        85.0
    } else {
        100.0
    }
}

/// Invert a spec's `scale` to get the raw count a device would report for
/// `physical`. A non-positive or non-finite scale is meaningless as a
/// multiplier, so the physical value passes through unchanged rather than
/// producing an infinity.
fn raw_for_physical(physical: f64, scale: f64) -> i64 {
    if scale.is_finite() && scale > 0.0 {
        (physical / scale).round() as i64
    } else {
        physical.round() as i64
    }
}

fn default_uint16_for_name(name: &str) -> u16 {
    let lower = name.to_lowercase();
    if lower.contains("temp") {
        2200 // 22.00°C if scaled
    } else if lower.contains("humid") {
        5500 // 55.00% if scaled
    } else if lower.contains("lux") || lower.contains("light") {
        500
    } else {
        100
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_then_read() {
        let mut state = MockDeviceState::new();
        let uuid = "0000fff1-0000-1000-8000-00805f9b34fb";
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "power_state".into(),
            field_type: ValueType::Bool,
            ..Default::default()
        }];

        // Before write, get defaults
        let bytes = state.read(uuid, &fields);
        assert_eq!(bytes, vec![1]); // default: on

        // After write, get written value
        state.write(uuid, vec![0]);
        let bytes = state.read(uuid, &fields);
        assert_eq!(bytes, vec![0]);
    }

    #[test]
    fn defaults_are_sensible() {
        let fields = vec![
            FormatField {
                offset: 0,
                length: 1,
                name: "power_state".into(),
                field_type: ValueType::Bool,
                ..Default::default()
            },
            FormatField {
                offset: 1,
                length: 1,
                name: "brightness".into(),
                field_type: ValueType::Uint8,
                ..Default::default()
            },
            FormatField {
                offset: 2,
                length: 1,
                name: "battery_percent".into(),
                field_type: ValueType::Uint8,
                ..Default::default()
            },
        ];
        let bytes = generate_defaults(&fields);
        assert_eq!(bytes[0], 1); // bool: on
        assert_eq!(bytes[1], 80); // brightness: 80
        assert_eq!(bytes[2], 85); // battery: 85
    }

    #[test]
    fn mock_default_overrides_heuristic_for_uint8() {
        // Field name "brightness" would heuristically default to 80; the
        // explicit `mock_default: 99` should win.
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "brightness".into(),
            field_type: ValueType::Uint8,
            mock_default: Some(serde_yaml::Value::Number(99.into())),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![99]);
    }

    #[test]
    fn mock_default_true_for_bool() {
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "power".into(),
            field_type: ValueType::Bool,
            mock_default: Some(serde_yaml::Value::Bool(true)),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![1]);
    }

    #[test]
    fn mock_default_false_for_bool() {
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "power".into(),
            field_type: ValueType::Bool,
            mock_default: Some(serde_yaml::Value::Bool(false)),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![0]);
    }

    #[test]
    fn mock_default_wrong_type_falls_back_to_heuristic() {
        // String value on a uint8 field — coerce returns None, heuristic kicks in.
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "brightness".into(),
            field_type: ValueType::Uint8,
            mock_default: Some(serde_yaml::Value::String("nope".into())),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![80]); // heuristic for "brightness"
    }

    #[test]
    fn mock_default_out_of_range_falls_back_to_heuristic() {
        // 999 doesn't fit in uint8 — must fall back to heuristic, not wrap to 231.
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "brightness".into(),
            field_type: ValueType::Uint8,
            mock_default: Some(serde_yaml::Value::Number(999.into())),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![80]); // heuristic, not 999 % 256
    }

    #[test]
    fn mock_default_negative_for_uint_falls_back_to_heuristic() {
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "brightness".into(),
            field_type: ValueType::Uint8,
            mock_default: Some(serde_yaml::Value::Number((-1).into())),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![80]); // heuristic, not 255
    }

    #[test]
    fn mock_default_int16_below_range_falls_back() {
        // i16 minimum is -32768; -40000 wraps if cast unchecked.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temp".into(),
            field_type: ValueType::Int16,
            mock_default: Some(serde_yaml::Value::Number((-40000).into())),
            ..Default::default()
        }];
        // Heuristic for Int16: 220 LE → [0xDC, 0x00].
        assert_eq!(generate_defaults(&fields), vec![0xDC, 0x00]);
    }

    #[test]
    fn mock_default_two_for_bool_falls_back_to_heuristic() {
        // Bool's integer range is 0..=1; anything else falls back.
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "power".into(),
            field_type: ValueType::Bool,
            mock_default: Some(serde_yaml::Value::Number(2.into())),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![1]); // heuristic: bool default-on
    }

    #[test]
    fn mock_default_uint16_le() {
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "lux".into(),
            field_type: ValueType::Uint16,
            mock_default: Some(serde_yaml::Value::Number(1234.into())),
            ..Default::default()
        }];
        // 1234 = 0x04D2, little-endian = [0xD2, 0x04]
        assert_eq!(generate_defaults(&fields), vec![0xD2, 0x04]);
    }

    #[test]
    fn scaled_field_defaults_to_a_plausible_physical_reading() {
        // A SIG temperature characteristic is int16 in hundredths of a degree.
        // The simulator has to send the raw count for ~22 C (2200), because the
        // reader now applies the spec's scale — sending 220 would demo a 2.2 C
        // room.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temperature".into(),
            field_type: ValueType::Int16,
            scale: Some(0.01),
            unit: Some("C".into()),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 2200i16.to_le_bytes().to_vec());
    }

    #[test]
    fn unscaled_field_keeps_its_raw_default() {
        // With no declared scale nothing says what the count means, so the
        // historical constant stands rather than a guess.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temperature".into(),
            field_type: ValueType::Int16,
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 220i16.to_le_bytes().to_vec());
    }

    #[test]
    fn mock_default_still_wins_over_a_declared_scale() {
        // An explicit `mock_default` is the spec author speaking directly; the
        // scale-aware heuristic must not override it.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temperature".into(),
            field_type: ValueType::Int16,
            mock_default: Some(serde_yaml::Value::Number(1234.into())),
            scale: Some(0.01),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 1234i16.to_le_bytes().to_vec());
    }

    #[test]
    fn nonsense_scale_does_not_produce_an_infinite_raw_value() {
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temperature".into(),
            field_type: ValueType::Int16,
            scale: Some(0.0),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 22i16.to_le_bytes().to_vec());
    }

    /// H1 regression: the parser deliberately tolerates a fixed-width type
    /// over a longer field (`type: uint16, length: 3`), so the simulator must
    /// write only the low `fixed_byte_size()` bytes and leave the tail zero —
    /// a whole-slice `copy_from_slice` panics on exactly those specs, and
    /// this path is reachable from Dart via `mock_read_characteristic`.
    /// Covers both the heuristic path and the `mock_default` → `write_value`
    /// path.
    #[test]
    fn overlong_fixed_fields_write_low_bytes_only() {
        struct Case {
            label: &'static str,
            field: FormatField,
            want: Vec<u8>,
        }
        let cases = [
            Case {
                label: "uint16 over 3 bytes, heuristic value",
                field: FormatField {
                    offset: 0,
                    length: 3,
                    name: "lux".into(), // heuristic: 500 = 0x01F4
                    field_type: ValueType::Uint16,
                    ..Default::default()
                },
                want: vec![0xF4, 0x01, 0x00],
            },
            Case {
                label: "uint16 over 3 bytes, mock_default (write_value path)",
                field: FormatField {
                    offset: 0,
                    length: 3,
                    name: "lux".into(),
                    field_type: ValueType::Uint16,
                    mock_default: Some(serde_yaml::Value::Number(0x1234.into())),
                    ..Default::default()
                },
                want: vec![0x34, 0x12, 0x00],
            },
            Case {
                label: "int16 over 4 bytes, heuristic value",
                field: FormatField {
                    offset: 0,
                    length: 4,
                    name: "reading".into(), // Int16 heuristic: 220 = 0x00DC
                    field_type: ValueType::Int16,
                    ..Default::default()
                },
                want: vec![0xDC, 0x00, 0x00, 0x00],
            },
            Case {
                label: "uint32 over 8 bytes, mock_default (write_value path)",
                field: FormatField {
                    offset: 0,
                    length: 8,
                    name: "counter".into(),
                    field_type: ValueType::Uint32,
                    mock_default: Some(serde_yaml::Value::Number(0xAABB_CCDDi64.into())),
                    ..Default::default()
                },
                want: vec![0xDD, 0xCC, 0xBB, 0xAA, 0, 0, 0, 0],
            },
            Case {
                label: "uint32 over 8 bytes, no default stays all zeros",
                field: FormatField {
                    offset: 0,
                    length: 8,
                    name: "counter".into(),
                    field_type: ValueType::Uint32,
                    ..Default::default()
                },
                want: vec![0; 8],
            },
        ];
        for Case { label, field, want } in cases {
            assert_eq!(
                generate_defaults(std::slice::from_ref(&field)),
                want,
                "{label}"
            );
        }
    }

    #[test]
    fn read_raw_returns_zero_buffer_then_written_value() {
        let mut state = MockDeviceState::new();
        let uuid = "0000FFF9-0000-1000-8000-00805F9B34FB";

        // No prior write: a zero buffer of exactly the requested length.
        assert_eq!(state.read_raw(uuid, 4), vec![0u8; 4]);

        // After a write, the stored value comes back verbatim (regardless of
        // the requested fallback length). Write lowercase / read uppercase to
        // pin the ASCII-lowercased key normalization shared by write/read.
        state.write(&uuid.to_ascii_lowercase(), vec![9, 8, 7]);
        assert_eq!(state.read_raw(uuid, 4), vec![9, 8, 7]);
    }
}

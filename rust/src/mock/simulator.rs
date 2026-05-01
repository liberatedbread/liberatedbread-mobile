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
        self.written.insert(char_uuid.to_lowercase(), value);
    }

    /// Generate a mock read value for a characteristic based on its format spec.
    /// If a value was previously written to this characteristic, returns that.
    /// Otherwise generates plausible defaults.
    pub fn read(&self, char_uuid: &str, format: &[FormatField]) -> Vec<u8> {
        let key = char_uuid.to_lowercase();

        // Return last written value if available
        if let Some(written) = self.written.get(&key) {
            return written.clone();
        }

        // Generate default values based on format
        generate_defaults(format)
    }

    /// Generate a mock read value for a characteristic that has no format spec.
    /// Returns an empty vec (the caller should fall back to raw hex display).
    pub fn read_raw(&self, char_uuid: &str, length: usize) -> Vec<u8> {
        let key = char_uuid.to_lowercase();
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

        // 2. Fall back to the name-based heuristic.
        match field.field_type {
            ValueType::Bool => slice[0] = 1, // default: on
            ValueType::Uint8 => slice[0] = default_uint8_for_name(&field.name),
            ValueType::Uint16 => {
                let val = default_uint16_for_name(&field.name);
                slice.copy_from_slice(&val.to_le_bytes());
            }
            ValueType::Int8 => slice[0] = 22, // ~22°C
            ValueType::Int16 => {
                let val: i16 = 220; // 22.0 if scaled
                slice.copy_from_slice(&val.to_le_bytes());
            }
            ValueType::Bytes | ValueType::String => {} // leave as zeros
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

/// Write `val` into `slice` honoring the byte width and endianness of `ty`.
/// `slice` must already be the correct length for `ty` (caller's invariant).
fn write_value(slice: &mut [u8], val: i64, ty: &ValueType) {
    match ty {
        ValueType::Bool => slice[0] = if val == 0 { 0 } else { 1 },
        ValueType::Uint8 => slice[0] = val as u8,
        ValueType::Int8 => slice[0] = val as i8 as u8,
        ValueType::Uint16 => slice.copy_from_slice(&(val as u16).to_le_bytes()),
        ValueType::Int16 => slice.copy_from_slice(&(val as i16).to_le_bytes()),
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
            mock_default: None,
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
                mock_default: None,
            },
            FormatField {
                offset: 1,
                length: 1,
                name: "brightness".into(),
                field_type: ValueType::Uint8,
                mock_default: None,
            },
            FormatField {
                offset: 2,
                length: 1,
                name: "battery_percent".into(),
                field_type: ValueType::Uint8,
                mock_default: None,
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
        }];
        // 1234 = 0x04D2, little-endian = [0xD2, 0x04]
        assert_eq!(generate_defaults(&fields), vec![0xD2, 0x04]);
    }
}

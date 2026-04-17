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
fn generate_defaults(fields: &[FormatField]) -> Vec<u8> {
    let total_len = fields
        .iter()
        .map(|f| f.offset + f.length)
        .max()
        .unwrap_or(0);
    let mut bytes = vec![0u8; total_len];

    for field in fields {
        let slice = &mut bytes[field.offset..field.offset + field.length];
        match field.field_type {
            ValueType::Bool => slice[0] = 1, // default: on
            ValueType::Uint8 => {
                // Pick a sensible default based on field name
                slice[0] = default_uint8_for_name(&field.name);
            }
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
            },
            FormatField {
                offset: 1,
                length: 1,
                name: "brightness".into(),
                field_type: ValueType::Uint8,
            },
            FormatField {
                offset: 2,
                length: 1,
                name: "battery_percent".into(),
                field_type: ValueType::Uint8,
            },
        ];
        let bytes = generate_defaults(&fields);
        assert_eq!(bytes[0], 1); // bool: on
        assert_eq!(bytes[1], 80); // brightness: 80
        assert_eq!(bytes[2], 85); // battery: 85
    }
}

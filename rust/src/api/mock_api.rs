// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Mock API for generating fake BLE device data.
//! Used by the Flutter mock BLE service when running in demo mode.

use crate::mock::simulator::MockDeviceState;
use crate::spec::parser::parse_device_spec;
use std::collections::{HashMap, HashSet};
use std::sync::{LazyLock, Mutex};

// Global mock state, keyed by device ID.
// This is intentionally simple — a single Mutex map.
// FRB calls are sequential from the Flutter UI thread anyway.
static MOCK_STATES: LazyLock<Mutex<HashMap<String, MockDeviceState>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Tracks `(char_uuid, error_message)` pairs we've already complained about,
/// so a recurring spec parse failure (every BLE poll on a broken YAML) only
/// logs once instead of spamming stderr. Cleared by [`mock_reset`].
static WARNED_SPEC_FAILURES: LazyLock<Mutex<HashSet<(String, String)>>> =
    LazyLock::new(|| Mutex::new(HashSet::new()));

/// Fallback buffer length when a spec has no `format` for the requested
/// characteristic. Chosen small enough to be cheap, large enough to show
/// "something" in the hex display.
const FALLBACK_RAW_READ_LEN: usize = 4;

/// Reset all mock device state. Call when starting a new mock session.
pub fn mock_reset() {
    MOCK_STATES
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
    WARNED_SPEC_FAILURES
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .clear();
}

/// Simulate reading a characteristic value for a mock device.
///
/// Uses the device spec to determine the format and generate appropriate
/// bytes. Spec parse failures are logged once per `(char_uuid, message)`
/// pair to stderr — repeated reads against a broken YAML won't spam — and
/// the read falls back to a fixed-length zero buffer.
pub fn mock_read_characteristic(
    device_id: String,
    char_uuid: String,
    spec_yaml: String,
) -> Vec<u8> {
    let mut states = MOCK_STATES.lock().unwrap_or_else(|e| e.into_inner());
    let state = states.entry(device_id).or_default();

    match parse_device_spec(&spec_yaml) {
        Ok(spec) => {
            if let Some((_, characteristic)) = spec.find_characteristic(&char_uuid) {
                if let Some(ref format) = characteristic.format {
                    return state.read(&char_uuid, format);
                }
            }
        }
        Err(e) => warn_spec_failure_once(&char_uuid, &e.to_string()),
    }

    // No usable format — return a fixed-length zero buffer.
    state.read_raw(&char_uuid, FALLBACK_RAW_READ_LEN)
}

fn warn_spec_failure_once(char_uuid: &str, message: &str) {
    let key = (char_uuid.to_string(), message.to_string());
    let mut warned = WARNED_SPEC_FAILURES
        .lock()
        .unwrap_or_else(|e| e.into_inner());
    if warned.insert(key) {
        eprintln!(
            "[opengreeniot] mock_read_characteristic: failed to parse spec YAML for {char_uuid}: {message}; falling back to zero buffer"
        );
    }
}

/// Simulate writing a characteristic value for a mock device.
pub fn mock_write_characteristic(device_id: String, char_uuid: String, value: Vec<u8>) {
    let mut states = MOCK_STATES.lock().unwrap_or_else(|e| e.into_inner());
    let state = states.entry(device_id).or_default();
    state.write(&char_uuid, value);
}

#[cfg(test)]
mod tests {
    use super::*;

    const TEST_YAML: &str = r#"
device:
  name: "Test"
  manufacturer: "Test"
  manufacturer_status: "abandoned"
  protocol: "ble"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "0000fff2-0000-1000-8000-00805f9b34fb"
        name: "Status"
        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: "power_state"
            type: "bool"
          - offset: 1
            length: 1
            name: "brightness"
            type: "uint8"
"#;

    #[test]
    fn mock_read_returns_defaults() {
        mock_reset();
        let bytes = mock_read_characteristic(
            "device1".into(),
            "0000fff2-0000-1000-8000-00805f9b34fb".into(),
            TEST_YAML.into(),
        );
        assert_eq!(bytes.len(), 2);
        assert_eq!(bytes[0], 1); // bool default: on
        assert_eq!(bytes[1], 80); // brightness default
    }

    #[test]
    fn mock_read_falls_back_to_zero_buffer_when_format_missing() {
        mock_reset();
        // Characteristic UUID that isn't in the spec → no format → fallback.
        let bytes = mock_read_characteristic(
            "device1".into(),
            "0000ffff-0000-1000-8000-00805f9b34fb".into(),
            TEST_YAML.into(),
        );
        assert_eq!(bytes, vec![0; FALLBACK_RAW_READ_LEN]);
    }

    #[test]
    fn mock_write_then_read() {
        mock_reset();
        let device_id = "device2".to_string();
        let char_uuid = "0000fff2-0000-1000-8000-00805f9b34fb".to_string();

        mock_write_characteristic(device_id.clone(), char_uuid.clone(), vec![0, 50]);

        let bytes = mock_read_characteristic(device_id, char_uuid, TEST_YAML.into());
        assert_eq!(bytes, vec![0, 50]);
    }
}

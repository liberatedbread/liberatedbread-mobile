// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Battery Service (0x180F) — standard Bluetooth SIG profile.
//!
//! This profile has a single characteristic:
//! - Battery Level (0x2A19): uint8, 0-100%, read + notify.

use crate::codec::types::DecodedValue;
use crate::error::ProtocolError;
use crate::protocol::traits::DeviceProtocol;
use std::collections::HashMap;

/// Standard Battery Level characteristic UUID (short form for matching).
const BATTERY_LEVEL_UUID_SHORT: &str = "2a19";

/// Battery Service protocol controller.
#[derive(Default)]
pub struct BatteryServiceProtocol;

impl BatteryServiceProtocol {
    pub fn new() -> Self {
        Self
    }

    /// Check if a characteristic UUID matches the Battery Level characteristic.
    fn is_battery_level(char_uuid: &str) -> bool {
        super::normalize_uuid(char_uuid) == BATTERY_LEVEL_UUID_SHORT
    }
}

impl DeviceProtocol for BatteryServiceProtocol {
    fn encode_command(
        &self,
        _char_uuid: &str,
        _command_name: &str,
        _params: &HashMap<String, f64>,
    ) -> Result<Vec<u8>, ProtocolError> {
        Err(ProtocolError::ProfileReadOnly)
    }

    fn decode_value(
        &self,
        char_uuid: &str,
        bytes: &[u8],
    ) -> Result<HashMap<String, DecodedValue>, ProtocolError> {
        if !Self::is_battery_level(char_uuid) {
            return Err(ProtocolError::CharacteristicNotFound {
                uuid: char_uuid.to_string(),
            });
        }

        if bytes.is_empty() {
            return Err(ProtocolError::BufferTooShort {
                needed: 1,
                got: 0,
            });
        }

        let mut result = HashMap::new();
        result.insert(
            "battery_percent".to_string(),
            DecodedValue::Uint(bytes[0] as u64),
        );
        Ok(result)
    }

    fn commands_for_characteristic(&self, _char_uuid: &str) -> Vec<String> {
        Vec::new()
    }

    fn fields_for_characteristic(&self, char_uuid: &str) -> Vec<String> {
        if Self::is_battery_level(char_uuid) {
            vec!["battery_percent".to_string()]
        } else {
            Vec::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_battery_level() {
        let proto = BatteryServiceProtocol::new();
        let values = proto
            .decode_value("00002a19-0000-1000-8000-00805f9b34fb", &[85])
            .unwrap();
        assert_eq!(values["battery_percent"], DecodedValue::Uint(85));
    }

    #[test]
    fn decode_battery_level_short_uuid() {
        let proto = BatteryServiceProtocol::new();
        let values = proto.decode_value("2a19", &[42]).unwrap();
        assert_eq!(values["battery_percent"], DecodedValue::Uint(42));
    }

    #[test]
    fn decode_battery_level_zero() {
        let proto = BatteryServiceProtocol::new();
        let values = proto.decode_value("2A19", &[0]).unwrap();
        assert_eq!(values["battery_percent"], DecodedValue::Uint(0));
    }

    #[test]
    fn decode_battery_level_full() {
        let proto = BatteryServiceProtocol::new();
        let values = proto.decode_value("2a19", &[100]).unwrap();
        assert_eq!(values["battery_percent"], DecodedValue::Uint(100));
    }

    #[test]
    fn decode_empty_buffer_fails() {
        let proto = BatteryServiceProtocol::new();
        assert!(proto.decode_value("2a19", &[]).is_err());
    }

    #[test]
    fn decode_unknown_char_fails() {
        let proto = BatteryServiceProtocol::new();
        assert!(proto.decode_value("2a00", &[50]).is_err());
    }

    #[test]
    fn encode_fails_read_only() {
        let proto = BatteryServiceProtocol::new();
        assert!(proto
            .encode_command("2a19", "anything", &HashMap::new())
            .is_err());
    }

    #[test]
    fn fields_for_battery_level() {
        let proto = BatteryServiceProtocol::new();
        assert_eq!(
            proto.fields_for_characteristic("2a19"),
            vec!["battery_percent"]
        );
    }

    #[test]
    fn fields_for_unknown_char() {
        let proto = BatteryServiceProtocol::new();
        assert!(proto.fields_for_characteristic("2a00").is_empty());
    }
}

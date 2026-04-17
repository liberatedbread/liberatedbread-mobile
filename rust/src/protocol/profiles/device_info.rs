// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Device Information Service (0x180A) — standard Bluetooth SIG profile.
//!
//! All characteristics are read-only UTF-8 strings, except System ID
//! which is 8 bytes decoded as hex.

use crate::codec::types::{bytes_to_hex, DecodedValue};
use crate::error::ProtocolError;
use crate::protocol::traits::DeviceProtocol;
use std::collections::HashMap;

/// Device Information Service protocol controller.
#[derive(Default)]
pub struct DeviceInfoProtocol;

impl DeviceInfoProtocol {
    pub fn new() -> Self {
        Self
    }

    /// Find the field name for a characteristic UUID, or None.
    fn field_name(char_uuid: &str) -> Option<&'static str> {
        let normalized = super::normalize_uuid(char_uuid);
        super::DEVICE_INFO_CHARS
            .iter()
            .find(|(uuid, _, _, _)| *uuid == normalized)
            .map(|(_, field_name, _, _)| *field_name)
    }
}

impl DeviceProtocol for DeviceInfoProtocol {
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
        let name =
            Self::field_name(char_uuid).ok_or_else(|| ProtocolError::CharacteristicNotFound {
                uuid: char_uuid.to_string(),
            })?;

        let value = if name == "system_id" {
            DecodedValue::String(bytes_to_hex(bytes, ":"))
        } else {
            let s = std::str::from_utf8(bytes)
                .map(|s| s.trim_end_matches('\0').to_string())
                .unwrap_or_else(|_| bytes_to_hex(bytes, " "));
            DecodedValue::String(s)
        };

        let mut result = HashMap::new();
        result.insert("value".to_string(), value);
        Ok(result)
    }

    fn commands_for_characteristic(&self, _char_uuid: &str) -> Vec<String> {
        Vec::new()
    }

    fn fields_for_characteristic(&self, char_uuid: &str) -> Vec<String> {
        if Self::field_name(char_uuid).is_some() {
            vec!["value".to_string()]
        } else {
            Vec::new()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decode_manufacturer_name() {
        let proto = DeviceInfoProtocol::new();
        let values = proto
            .decode_value("00002a29-0000-1000-8000-00805f9b34fb", b"Acme Corp")
            .unwrap();
        assert_eq!(
            values["value"],
            DecodedValue::String("Acme Corp".to_string())
        );
    }

    #[test]
    fn decode_model_number_short_uuid() {
        let proto = DeviceInfoProtocol::new();
        let values = proto.decode_value("2a24", b"Model-X").unwrap();
        assert_eq!(values["value"], DecodedValue::String("Model-X".to_string()));
    }

    #[test]
    fn decode_firmware_revision() {
        let proto = DeviceInfoProtocol::new();
        let values = proto.decode_value("2A26", b"v1.2.3").unwrap();
        assert_eq!(values["value"], DecodedValue::String("v1.2.3".to_string()));
    }

    #[test]
    fn decode_system_id_hex() {
        let proto = DeviceInfoProtocol::new();
        let values = proto
            .decode_value("2a23", &[0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
            .unwrap();
        assert_eq!(
            values["value"],
            DecodedValue::String("01:02:03:04:05:06:07:08".to_string())
        );
    }

    #[test]
    fn decode_strips_null_terminator() {
        let proto = DeviceInfoProtocol::new();
        let values = proto.decode_value("2a29", b"Acme\0\0").unwrap();
        assert_eq!(values["value"], DecodedValue::String("Acme".to_string()));
    }

    #[test]
    fn decode_unknown_char_fails() {
        let proto = DeviceInfoProtocol::new();
        assert!(proto.decode_value("2a00", b"test").is_err());
    }

    #[test]
    fn encode_fails_read_only() {
        let proto = DeviceInfoProtocol::new();
        assert!(proto
            .encode_command("2a29", "anything", &HashMap::new())
            .is_err());
    }

    #[test]
    fn all_known_characteristics() {
        let proto = DeviceInfoProtocol::new();
        for (uuid, _, _, _) in super::super::DEVICE_INFO_CHARS {
            assert_eq!(proto.fields_for_characteristic(uuid), vec!["value"]);
        }
    }
}

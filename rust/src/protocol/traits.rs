// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Device protocol trait — the interface every device protocol must implement.

use crate::codec::types::DecodedValue;
use crate::error::ProtocolError;
use std::collections::HashMap;

/// A device protocol knows how to encode commands and decode responses
/// for a specific BLE device.
pub trait DeviceProtocol: Send + Sync {
    /// Encode a named command with parameters into bytes for a BLE write.
    fn encode_command(
        &self,
        char_uuid: &str,
        command_name: &str,
        params: &HashMap<String, f64>,
    ) -> Result<Vec<u8>, ProtocolError>;

    /// Decode raw bytes from a BLE read/notify into named values.
    fn decode_value(
        &self,
        char_uuid: &str,
        bytes: &[u8],
    ) -> Result<HashMap<String, DecodedValue>, ProtocolError>;

    /// List available command names for a characteristic.
    fn commands_for_characteristic(&self, char_uuid: &str) -> Vec<String>;

    /// List format field names for a characteristic.
    fn fields_for_characteristic(&self, char_uuid: &str) -> Vec<String>;
}

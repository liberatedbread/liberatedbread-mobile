// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Device protocol trait — the interface every device protocol must implement.

use crate::codec::types::DecodedValue;
use crate::error::ProtocolError;
use std::collections::HashMap;

/// A command to send during device initialization (e.g., handshake steps).
#[derive(Debug, Clone)]
pub struct InitCommand {
    pub service_uuid: String,
    pub char_uuid: String,
    pub value: Vec<u8>,
    /// Optional delay in milliseconds before sending the next init command.
    pub delay_ms: Option<u64>,
}

/// A device protocol knows how to encode commands and decode responses
/// for a specific BLE device.
///
/// Required methods handle the core encode/decode logic.
/// Optional lifecycle hooks (with default no-op implementations) allow
/// device-specific protocols to hook into connection events.
pub trait DeviceProtocol: Send + Sync {
    // ── Required: core protocol logic ────────────────────────────────

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

    // ── Optional: lifecycle hooks ────────────────────────────────────

    /// Whether this device needs an initialization sequence after connection.
    /// If true, the app should call `on_connect()` and send the returned
    /// commands before normal operation.
    fn requires_initialization(&self) -> bool {
        false
    }

    /// Called after BLE connection is established.
    /// Returns a sequence of commands to send for device initialization
    /// (e.g., encryption handshake, mode selection).
    fn on_connect(&self) -> Vec<InitCommand> {
        vec![]
    }

    /// Called before BLE disconnect. Can be used for cleanup
    /// (e.g., sending a "goodbye" command).
    fn on_disconnect(&self) {}
}

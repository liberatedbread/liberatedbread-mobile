// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Device protocol trait — the interface every device protocol must implement.

use crate::codec::types::DecodedValues;
use crate::error::ProtocolError;
use std::collections::HashMap;

/// How a decoded field should be presented, as declared by the spec.
///
/// Separate from the decoded value itself because decoding stays lossless: the
/// raw integer the device sent is still available, and the caller applies the
/// conversion. A reading is only meaningful with both halves — raw 2350 with
/// `scale: 0.01` and `unit: "°C"` is 23.5 °C.
#[derive(Debug, Clone, PartialEq)]
pub struct FieldMeta {
    pub name: String,
    pub scale: Option<f64>,
    pub unit: Option<String>,
}

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
    fn decode_value(&self, char_uuid: &str, bytes: &[u8]) -> Result<DecodedValues, ProtocolError>;

    /// List available command names for a characteristic, in the order the
    /// spec declares them. Callers must not sort: the order is the author's.
    fn commands_for_characteristic(&self, char_uuid: &str) -> Vec<String>;

    /// List format field names for a characteristic, in `format` order (which
    /// is also the device's byte order). Callers must not sort.
    fn fields_for_characteristic(&self, char_uuid: &str) -> Vec<String>;

    /// Presentation metadata for each format field, in the same order as
    /// [`Self::fields_for_characteristic`].
    ///
    /// Defaults to empty: the built-in SIG profiles decode fixed layouts that
    /// carry no spec-declared scaling, so only the spec-driven protocol has
    /// anything to report here.
    fn field_meta_for_characteristic(&self, _char_uuid: &str) -> Vec<FieldMeta> {
        Vec::new()
    }
}

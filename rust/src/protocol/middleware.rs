// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Protocol middleware for cross-cutting concerns.
//!
//! Middleware wraps a `DeviceProtocol` to transparently handle encryption,
//! packet framing, checksums, and similar transport-level concerns.
//!
//! This is a skeleton — concrete middleware implementations will be added
//! as devices that need encryption or framing are reverse-engineered.

use super::traits::DeviceProtocol;
use crate::codec::types::DecodedValue;
use crate::error::ProtocolError;
use std::collections::HashMap;

/// A middleware that passes all calls through to the inner protocol unchanged.
///
/// This serves as the base for future middleware that will intercept
/// encode/decode calls to add encryption, framing, or checksums.
pub struct PassthroughMiddleware<P: DeviceProtocol> {
    inner: P,
}

impl<P: DeviceProtocol> PassthroughMiddleware<P> {
    pub fn new(inner: P) -> Self {
        Self { inner }
    }
}

impl<P: DeviceProtocol> DeviceProtocol for PassthroughMiddleware<P> {
    fn encode_command(
        &self,
        char_uuid: &str,
        command_name: &str,
        params: &HashMap<String, f64>,
    ) -> Result<Vec<u8>, ProtocolError> {
        self.inner.encode_command(char_uuid, command_name, params)
    }

    fn decode_value(
        &self,
        char_uuid: &str,
        bytes: &[u8],
    ) -> Result<HashMap<String, DecodedValue>, ProtocolError> {
        self.inner.decode_value(char_uuid, bytes)
    }

    fn commands_for_characteristic(&self, char_uuid: &str) -> Vec<String> {
        self.inner.commands_for_characteristic(char_uuid)
    }

    fn fields_for_characteristic(&self, char_uuid: &str) -> Vec<String> {
        self.inner.fields_for_characteristic(char_uuid)
    }

    fn requires_initialization(&self) -> bool {
        self.inner.requires_initialization()
    }

    fn on_connect(&self) -> Vec<super::traits::InitCommand> {
        self.inner.on_connect()
    }

    fn on_disconnect(&self) {
        self.inner.on_disconnect()
    }
}

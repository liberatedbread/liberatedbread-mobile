// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Crate-wide error types.

/// Errors that occur during protocol encoding, decoding, or lookup.
#[derive(Debug, thiserror::Error)]
pub enum ProtocolError {
    #[error("characteristic not found: {uuid}")]
    CharacteristicNotFound { uuid: String },

    #[error("characteristic {uuid} has no commands defined")]
    NoCommands { uuid: String },

    #[error("command '{command}' not found for characteristic {uuid}")]
    CommandNotFound { uuid: String, command: String },

    #[error("characteristic {uuid} has no format defined")]
    NoFormat { uuid: String },

    #[error("buffer too short: needed {needed} bytes, got {got}")]
    BufferTooShort { needed: usize, got: usize },

    #[error("encoding failed: {0}")]
    EncodingFailed(String),

    #[error("missing required parameter: {0}")]
    ParameterMissing(String),

    #[error("parameter '{name}' value {value} out of range [{min}, {max}]")]
    ParameterOutOfRange {
        name: String,
        value: f64,
        min: f64,
        max: f64,
    },

    #[error("command has neither value nor template")]
    EmptyCommand,

    #[error("standard profile does not support commands")]
    ProfileReadOnly,

    #[error("no protocol available: provide either a spec_yaml or a known service_uuid")]
    NoProtocolForRequest,

    #[error("failed to parse device spec: {0}")]
    SpecParse(#[from] SpecError),
}

/// Errors that occur during device spec parsing.
#[derive(Debug, thiserror::Error)]
pub enum SpecError {
    #[error("failed to parse device spec YAML: {0}")]
    YamlParse(#[from] serde_yaml::Error),
}

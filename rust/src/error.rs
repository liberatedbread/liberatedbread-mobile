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

    #[error("missing required parameter: {0}")]
    ParameterMissing(String),

    #[error("parameter '{name}' value {value} out of range [{min}, {max}]")]
    ParameterOutOfRange {
        name: String,
        value: f64,
        min: f64,
        max: f64,
    },

    #[error("parameter '{name}' value {value} is invalid: {reason}")]
    ParameterInvalid {
        name: String,
        value: f64,
        reason: String,
    },

    #[error("value type {ty} cannot be used as an encode parameter")]
    UnsupportedParameterType { ty: crate::spec::types::ValueType },

    #[error("command has neither value nor template")]
    EmptyCommand,

    #[error("command uses setting_id or encoding, which are not supported by the legacy encoder — use typed controls instead")]
    UnsupportedCommandEncoding,

    #[error("standard profile does not support commands")]
    ProfileReadOnly,

    #[error("no protocol available: provide either a spec_yaml or a known service_uuid")]
    NoProtocolForRequest,

    #[error("field offset+length overflows usize: offset={offset}, length={length}")]
    FieldOffsetOverflow { offset: usize, length: usize },

    #[error("failed to parse device spec: {0}")]
    SpecParse(#[from] SpecError),
}

/// Errors that occur during device spec parsing.
#[derive(Debug, thiserror::Error)]
pub enum SpecError {
    #[error("failed to parse device spec YAML: {0}")]
    YamlParse(#[from] serde_yaml::Error),

    #[error(
        "format field '{field_name}' has length {got} but type {field_type} requires at least {expected}"
    )]
    FieldLengthMismatch {
        field_name: String,
        field_type: crate::spec::types::ValueType,
        expected: usize,
        got: usize,
    },

    #[error("format field '{field_name}' offset+length overflows usize: offset={offset}, length={length}")]
    FieldOffsetOverflow {
        field_name: String,
        offset: usize,
        length: usize,
    },

    #[error(
        "parameter '{parameter_name}' {bound} value {value} does not fit in declared type {value_type}"
    )]
    ParameterRangeOutsideType {
        parameter_name: String,
        value_type: crate::spec::types::ValueType,
        bound: String,
        value: i64,
    },

    #[error("parameter '{parameter_name}' has min={min} > max={max}; bounds are inverted")]
    ParameterBoundsInverted {
        parameter_name: String,
        min: i64,
        max: i64,
    },

    #[error(
        "parameter '{parameter_name}' declares a {bound} bound but type {value_type} has no numeric range"
    )]
    BoundsOnNonNumericType {
        parameter_name: String,
        value_type: crate::spec::types::ValueType,
        bound: String,
    },

    #[error("duplicate {kind} name '{name}' in characteristic '{characteristic}'")]
    DuplicateName {
        kind: String,
        name: String,
        characteristic: String,
    },
}

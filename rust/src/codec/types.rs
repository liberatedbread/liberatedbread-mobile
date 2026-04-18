// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Byte-level encoding and decoding for BLE characteristic values.

use crate::error::ProtocolError;
use crate::spec::types::{Command, FormatField, Parameter, TemplateElement, ValueType};
use std::collections::HashMap;

/// Format bytes as a hex string with the given separator.
pub(crate) fn bytes_to_hex(bytes: &[u8], sep: &str) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect::<Vec<_>>()
        .join(sep)
}

/// A decoded value from a characteristic read.
#[derive(Debug, Clone, PartialEq)]
pub enum DecodedValue {
    Bool(bool),
    Int(i64),
    Uint(u64),
    Bytes(Vec<u8>),
    String(String),
}

impl DecodedValue {
    /// Return a human-readable string representation.
    pub fn display(&self) -> String {
        match self {
            DecodedValue::Bool(v) => if *v { "on" } else { "off" }.to_string(),
            DecodedValue::Int(v) => v.to_string(),
            DecodedValue::Uint(v) => v.to_string(),
            DecodedValue::Bytes(v) => bytes_to_hex(v, " "),
            DecodedValue::String(v) => v.clone(),
        }
    }
}

/// Decode a single format field from a byte buffer.
pub fn decode_field(bytes: &[u8], field: &FormatField) -> Result<DecodedValue, ProtocolError> {
    let end = field
        .offset
        .checked_add(field.length)
        .ok_or(ProtocolError::BufferTooShort {
            needed: usize::MAX,
            got: bytes.len(),
        })?;
    if bytes.len() < end {
        return Err(ProtocolError::BufferTooShort {
            needed: end,
            got: bytes.len(),
        });
    }

    let slice = &bytes[field.offset..end];

    match field.field_type {
        ValueType::Bool => Ok(DecodedValue::Bool(slice[0] != 0)),
        ValueType::Uint8 => Ok(DecodedValue::Uint(slice[0] as u64)),
        ValueType::Uint16 => Ok(DecodedValue::Uint(
            u16::from_le_bytes([slice[0], slice[1]]) as u64
        )),
        ValueType::Int8 => Ok(DecodedValue::Int(slice[0] as i8 as i64)),
        ValueType::Int16 => Ok(DecodedValue::Int(
            i16::from_le_bytes([slice[0], slice[1]]) as i64
        )),
        ValueType::Bytes => Ok(DecodedValue::Bytes(slice.to_vec())),
        ValueType::String => {
            let s = std::str::from_utf8(slice)
                .map(|s| s.trim_end_matches('\0').to_string())
                .unwrap_or_else(|_| bytes_to_hex(slice, " "));
            Ok(DecodedValue::String(s))
        }
    }
}

/// Decode all format fields from a characteristic value.
pub fn decode_all_fields(
    bytes: &[u8],
    fields: &[FormatField],
) -> Result<HashMap<String, DecodedValue>, ProtocolError> {
    let mut result = HashMap::new();
    for field in fields {
        result.insert(field.name.clone(), decode_field(bytes, field)?);
    }
    Ok(result)
}

/// Encode a command to bytes for a BLE write.
///
/// For fixed commands, returns the `value` directly.
/// For templated commands, substitutes parameter values.
pub fn encode_command(
    command: &Command,
    params: &HashMap<String, f64>,
) -> Result<Vec<u8>, ProtocolError> {
    if let Some(ref value) = command.value {
        return Ok(value.clone());
    }

    let template = command
        .template
        .as_ref()
        .ok_or(ProtocolError::EmptyCommand)?;
    let param_defs = command.parameters.as_ref();

    let mut bytes = Vec::new();
    for element in template {
        match element {
            TemplateElement::Byte(b) => bytes.push(*b),
            TemplateElement::Param(name) => {
                let val = params
                    .get(name.as_str())
                    .ok_or_else(|| ProtocolError::ParameterMissing(name.clone()))?;
                let def = param_defs.and_then(|d| d.get(name.as_str()));
                if let Some(def) = def {
                    validate_param_range(name, *val, def)?;
                }
                let param_type = def.map(|d| &d.value_type).unwrap_or(&ValueType::Uint8);
                encode_param_bytes(*val, param_type, &mut bytes)?;
            }
        }
    }
    Ok(bytes)
}

/// Validate that `val` is within `[def.min, def.max]` if either bound is set.
fn validate_param_range(name: &str, val: f64, def: &Parameter) -> Result<(), ProtocolError> {
    let min_f = def.min.map(|m| m as f64);
    let max_f = def.max.map(|m| m as f64);
    let out_of_range = min_f.is_some_and(|m| val < m) || max_f.is_some_and(|m| val > m);
    if out_of_range {
        return Err(ProtocolError::ParameterOutOfRange {
            name: name.to_string(),
            value: val,
            min: min_f.unwrap_or(f64::NEG_INFINITY),
            max: max_f.unwrap_or(f64::INFINITY),
        });
    }
    Ok(())
}

/// Append `val` to `bytes` encoded per the given parameter type.
fn encode_param_bytes(
    val: f64,
    param_type: &ValueType,
    bytes: &mut Vec<u8>,
) -> Result<(), ProtocolError> {
    match param_type {
        ValueType::Uint8 => bytes.push(val as u8),
        ValueType::Uint16 => bytes.extend_from_slice(&(val as u16).to_le_bytes()),
        ValueType::Int8 => bytes.push(val as i8 as u8),
        ValueType::Int16 => bytes.extend_from_slice(&(val as i16).to_le_bytes()),
        _ => {
            return Err(ProtocolError::EncodingFailed(format!(
                "unsupported parameter type for encoding: {param_type}"
            )));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::types::Parameter;

    #[test]
    fn decode_bool_field() {
        let field = FormatField {
            offset: 0,
            length: 1,
            name: "power".into(),
            field_type: ValueType::Bool,
        };
        assert_eq!(
            decode_field(&[1], &field).unwrap(),
            DecodedValue::Bool(true)
        );
        assert_eq!(
            decode_field(&[0], &field).unwrap(),
            DecodedValue::Bool(false)
        );
    }

    #[test]
    fn decode_uint8_field() {
        let field = FormatField {
            offset: 1,
            length: 1,
            name: "brightness".into(),
            field_type: ValueType::Uint8,
        };
        assert_eq!(
            decode_field(&[0x00, 0x64], &field).unwrap(),
            DecodedValue::Uint(100)
        );
    }

    #[test]
    fn decode_uint16_le() {
        let field = FormatField {
            offset: 0,
            length: 2,
            name: "value".into(),
            field_type: ValueType::Uint16,
        };
        // 0x0100 in little-endian = 256
        assert_eq!(
            decode_field(&[0x00, 0x01], &field).unwrap(),
            DecodedValue::Uint(256)
        );
    }

    #[test]
    fn decode_all() {
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
                name: "red".into(),
                field_type: ValueType::Uint8,
            },
        ];
        let bytes = &[1, 80, 255];
        let result = decode_all_fields(bytes, &fields).unwrap();
        assert_eq!(result["power_state"], DecodedValue::Bool(true));
        assert_eq!(result["brightness"], DecodedValue::Uint(80));
        assert_eq!(result["red"], DecodedValue::Uint(255));
    }

    #[test]
    fn decode_int8_field() {
        let field = FormatField {
            offset: 0,
            length: 1,
            name: "temp".into(),
            field_type: ValueType::Int8,
        };
        // -10 as i8 = 0xF6
        assert_eq!(
            decode_field(&[0xF6], &field).unwrap(),
            DecodedValue::Int(-10)
        );
        assert_eq!(decode_field(&[22], &field).unwrap(), DecodedValue::Int(22));
    }

    #[test]
    fn decode_int16_le() {
        let field = FormatField {
            offset: 0,
            length: 2,
            name: "temp".into(),
            field_type: ValueType::Int16,
        };
        // -1000 as i16 in LE = [0x18, 0xFC]
        assert_eq!(
            decode_field(&[0x18, 0xFC], &field).unwrap(),
            DecodedValue::Int(-1000)
        );
    }

    #[test]
    fn decode_bytes_field() {
        let field = FormatField {
            offset: 0,
            length: 3,
            name: "payload".into(),
            field_type: ValueType::Bytes,
        };
        assert_eq!(
            decode_field(&[0xDE, 0xAD, 0xBE], &field).unwrap(),
            DecodedValue::Bytes(vec![0xDE, 0xAD, 0xBE])
        );
    }

    #[test]
    fn decode_string_field() {
        let field = FormatField {
            offset: 0,
            length: 5,
            name: "label".into(),
            field_type: ValueType::String,
        };
        assert_eq!(
            decode_field(b"hello", &field).unwrap(),
            DecodedValue::String("hello".into())
        );
        // Null-terminated string
        assert_eq!(
            decode_field(b"hi\0\0\0", &field).unwrap(),
            DecodedValue::String("hi".into())
        );
    }

    #[test]
    fn decode_buffer_too_short() {
        let field = FormatField {
            offset: 2,
            length: 3,
            name: "data".into(),
            field_type: ValueType::Uint8,
        };
        assert!(decode_field(&[0x00, 0x01], &field).is_err());
    }

    #[test]
    fn encode_fixed_command() {
        let cmd = Command {
            description: "power on".into(),
            value: Some(vec![0x01, 0x01]),
            template: None,
            parameters: None,
        };
        let bytes = encode_command(&cmd, &HashMap::new()).unwrap();
        assert_eq!(bytes, vec![0x01, 0x01]);
    }

    #[test]
    fn encode_template_command() {
        let cmd = Command {
            description: "set brightness".into(),
            value: None,
            template: Some(vec![
                TemplateElement::Byte(0x02),
                TemplateElement::Param("brightness".into()),
            ]),
            parameters: Some(HashMap::from([(
                "brightness".into(),
                Parameter {
                    value_type: ValueType::Uint8,
                    min: Some(0),
                    max: Some(100),
                },
            )])),
        };
        let params = HashMap::from([("brightness".into(), 75.0)]);
        let bytes = encode_command(&cmd, &params).unwrap();
        assert_eq!(bytes, vec![0x02, 75]);
    }

    #[test]
    fn encode_rejects_out_of_range() {
        let cmd = Command {
            description: "set brightness".into(),
            value: None,
            template: Some(vec![
                TemplateElement::Byte(0x02),
                TemplateElement::Param("brightness".into()),
            ]),
            parameters: Some(HashMap::from([(
                "brightness".into(),
                Parameter {
                    value_type: ValueType::Uint8,
                    min: Some(0),
                    max: Some(100),
                },
            )])),
        };
        let params = HashMap::from([("brightness".into(), 150.0)]);
        assert!(encode_command(&cmd, &params).is_err());
    }
}

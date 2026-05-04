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
        .ok_or(ProtocolError::FieldOffsetOverflow {
            offset: field.offset,
            length: field.length,
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

/// A parameter value coerced into a typed integer ready for byte encoding.
///
/// Internal-only — the FFI keeps `HashMap<String, f64>` (FRB constraint).
/// `coerce_param` is the bridge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum TypedParam {
    U8(u8),
    U16(u16),
    I8(i8),
    I16(i16),
}

/// Encode a command to bytes for a BLE write.
///
/// For fixed commands, returns the `value` directly without consulting any
/// parameters — fixed commands are by definition parameterless.
///
/// For templated commands, every `{param}` placeholder is looked up in
/// `params`, validated against the parameter's declared type and `min`/`max`
/// bounds, and encoded little-endian per the type's byte width.
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
                let typed = coerce_param(*val, param_type, name)?;
                append_typed(&mut bytes, typed);
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

/// Coerce an `f64` parameter value into the integer width its declared type
/// requires. Rejects:
/// - NaN or infinity (`ParameterInvalid`)
/// - fractional values like `1.5` (`ParameterInvalid`)
/// - values outside the declared type's range (`ParameterOutOfRange`)
/// - declared types with no integer representation (`UnsupportedParameterType`)
pub(crate) fn coerce_param(
    val: f64,
    ty: &ValueType,
    name: &str,
) -> Result<TypedParam, ProtocolError> {
    if !val.is_finite() {
        return Err(ProtocolError::ParameterInvalid {
            name: name.to_string(),
            value: val,
            reason: "value is NaN or infinity".into(),
        });
    }
    if val.fract() != 0.0 {
        return Err(ProtocolError::ParameterInvalid {
            name: name.to_string(),
            value: val,
            reason: "value has a fractional component".into(),
        });
    }

    let as_int = val as i64;
    let oor = || ProtocolError::ParameterOutOfRange {
        name: name.to_string(),
        value: val,
        min: ty
            .integer_range()
            .map(|(lo, _)| lo as f64)
            .unwrap_or(f64::NEG_INFINITY),
        max: ty
            .integer_range()
            .map(|(_, hi)| hi as f64)
            .unwrap_or(f64::INFINITY),
    };

    match ty {
        ValueType::Uint8 => u8::try_from(as_int).map(TypedParam::U8).map_err(|_| oor()),
        ValueType::Uint16 => u16::try_from(as_int)
            .map(TypedParam::U16)
            .map_err(|_| oor()),
        ValueType::Int8 => i8::try_from(as_int).map(TypedParam::I8).map_err(|_| oor()),
        ValueType::Int16 => i16::try_from(as_int)
            .map(TypedParam::I16)
            .map_err(|_| oor()),
        other => Err(ProtocolError::UnsupportedParameterType { ty: other.clone() }),
    }
}

fn append_typed(bytes: &mut Vec<u8>, val: TypedParam) {
    match val {
        TypedParam::U8(v) => bytes.push(v),
        TypedParam::I8(v) => bytes.push(v as u8),
        TypedParam::U16(v) => bytes.extend_from_slice(&v.to_le_bytes()),
        TypedParam::I16(v) => bytes.extend_from_slice(&v.to_le_bytes()),
    }
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
            mock_default: None,
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
            mock_default: None,
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
            mock_default: None,
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
                mock_default: None,
            },
            FormatField {
                offset: 1,
                length: 1,
                name: "brightness".into(),
                field_type: ValueType::Uint8,
                mock_default: None,
            },
            FormatField {
                offset: 2,
                length: 1,
                name: "red".into(),
                field_type: ValueType::Uint8,
                mock_default: None,
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
            mock_default: None,
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
            mock_default: None,
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
            mock_default: None,
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
            mock_default: None,
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
    fn decode_offset_overflow_returns_typed_error() {
        let field = FormatField {
            offset: usize::MAX,
            length: 1,
            name: "boom".into(),
            field_type: ValueType::Uint8,
            mock_default: None,
        };
        match decode_field(&[0u8; 4], &field) {
            Err(ProtocolError::FieldOffsetOverflow { offset, length }) => {
                assert_eq!(offset, usize::MAX);
                assert_eq!(length, 1);
            }
            other => panic!("expected FieldOffsetOverflow, got {other:?}"),
        }
    }

    #[test]
    fn decode_buffer_too_short() {
        let field = FormatField {
            offset: 2,
            length: 3,
            name: "data".into(),
            field_type: ValueType::Uint8,
            mock_default: None,
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

    // ── coerce_param edge cases ─────────────────────────────────────────────

    fn brightness_cmd() -> Command {
        Command {
            description: "set".into(),
            value: None,
            template: Some(vec![
                TemplateElement::Byte(0x02),
                TemplateElement::Param("n".into()),
            ]),
            parameters: Some(HashMap::from([(
                "n".into(),
                Parameter {
                    value_type: ValueType::Uint8,
                    min: None,
                    max: None,
                },
            )])),
        }
    }

    fn assert_invalid(result: Result<Vec<u8>, ProtocolError>, want_reason: &str) {
        match result {
            Err(ProtocolError::ParameterInvalid { reason, .. }) => {
                assert!(
                    reason.contains(want_reason),
                    "expected reason containing {want_reason:?}, got {reason:?}"
                );
            }
            other => panic!("expected ParameterInvalid({want_reason:?}), got {other:?}"),
        }
    }

    #[test]
    fn coerce_rejects_nan() {
        let params = HashMap::from([("n".into(), f64::NAN)]);
        assert_invalid(encode_command(&brightness_cmd(), &params), "NaN");
    }

    #[test]
    fn coerce_rejects_positive_infinity() {
        let params = HashMap::from([("n".into(), f64::INFINITY)]);
        assert_invalid(encode_command(&brightness_cmd(), &params), "infinity");
    }

    #[test]
    fn coerce_rejects_negative_infinity() {
        let params = HashMap::from([("n".into(), f64::NEG_INFINITY)]);
        assert_invalid(encode_command(&brightness_cmd(), &params), "infinity");
    }

    #[test]
    fn coerce_rejects_fractional_value() {
        let params = HashMap::from([("n".into(), 1.5)]);
        assert_invalid(encode_command(&brightness_cmd(), &params), "fractional");
    }

    #[test]
    fn coerce_rejects_out_of_range_u8_high() {
        let params = HashMap::from([("n".into(), 256.0)]);
        match encode_command(&brightness_cmd(), &params) {
            Err(ProtocolError::ParameterOutOfRange { value, .. }) => {
                assert_eq!(value, 256.0);
            }
            other => panic!("expected ParameterOutOfRange, got {other:?}"),
        }
    }

    #[test]
    fn coerce_rejects_out_of_range_u8_low() {
        let params = HashMap::from([("n".into(), -1.0)]);
        match encode_command(&brightness_cmd(), &params) {
            Err(ProtocolError::ParameterOutOfRange { value, .. }) => {
                assert_eq!(value, -1.0);
            }
            other => panic!("expected ParameterOutOfRange, got {other:?}"),
        }
    }

    #[test]
    fn coerce_accepts_exact_u8_bounds() {
        let params_lo = HashMap::from([("n".into(), 0.0)]);
        assert_eq!(
            encode_command(&brightness_cmd(), &params_lo).unwrap(),
            vec![0x02, 0]
        );
        let params_hi = HashMap::from([("n".into(), 255.0)]);
        assert_eq!(
            encode_command(&brightness_cmd(), &params_hi).unwrap(),
            vec![0x02, 255]
        );
    }

    #[test]
    fn coerce_accepts_exact_i8_bounds() {
        let cmd = Command {
            description: "set".into(),
            value: None,
            template: Some(vec![TemplateElement::Param("n".into())]),
            parameters: Some(HashMap::from([(
                "n".into(),
                Parameter {
                    value_type: ValueType::Int8,
                    min: None,
                    max: None,
                },
            )])),
        };
        let lo = HashMap::from([("n".into(), -128.0)]);
        assert_eq!(encode_command(&cmd, &lo).unwrap(), vec![0x80]);
        let hi = HashMap::from([("n".into(), 127.0)]);
        assert_eq!(encode_command(&cmd, &hi).unwrap(), vec![0x7F]);
    }

    #[test]
    fn fixed_value_command_skips_parameter_validation() {
        // Regression: fixed commands have no template and no params. They
        // should encode unchanged regardless of what's in the params map.
        let cmd = Command {
            description: "power on".into(),
            value: Some(vec![0x01, 0x01]),
            template: None,
            parameters: None,
        };
        // Even pathological parameter values should be ignored.
        let params = HashMap::from([("nonsense".into(), f64::NAN)]);
        let bytes = encode_command(&cmd, &params).unwrap();
        assert_eq!(bytes, vec![0x01, 0x01]);
    }
}

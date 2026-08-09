// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Byte-level encoding and decoding for BLE characteristic values.

use crate::error::ProtocolError;
use crate::spec::types::{
    AutoRole, Command, Endianness, FormatField, Parameter, TemplateElement, ValueType,
};
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

/// A characteristic's decoded fields, in the order the characteristic lays them
/// out.
///
/// A `HashMap` would be the obvious container, but `format` order is meaningful
/// — it is how the device packs the value, and how the UI lists it — and a
/// `HashMap` hands callers a different order on every process start, so the
/// same device's readout shuffles between app launches.
///
/// Name lookups (`values["brightness"]`, `get`, `contains_key`) are spelled
/// like a map's but are a **linear scan** over the underlying `Vec`, so they
/// are O(n), not O(1). That is fine here: a characteristic's `format` is a
/// handful of fields (the largest bundled spec has five), and every caller
/// either iterates the whole thing or looks up one field.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct DecodedValues(Vec<(String, DecodedValue)>);

impl DecodedValues {
    pub fn new() -> Self {
        Self(Vec::new())
    }

    /// Append `name` -> `value`. A repeated name overwrites in place, so the
    /// first occurrence's position wins (matching a map's "one entry per key").
    pub fn insert(&mut self, name: String, value: DecodedValue) {
        match self.0.iter_mut().find(|(existing, _)| *existing == name) {
            Some(slot) => slot.1 = value,
            None => self.0.push((name, value)),
        }
    }

    pub fn get(&self, name: &str) -> Option<&DecodedValue> {
        self.0
            .iter()
            .find(|(existing, _)| existing == name)
            .map(|(_, value)| value)
    }

    pub fn contains_key(&self, name: &str) -> bool {
        self.get(name).is_some()
    }

    pub fn iter(&self) -> std::slice::Iter<'_, (String, DecodedValue)> {
        self.0.iter()
    }

    pub fn len(&self) -> usize {
        self.0.len()
    }

    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl std::ops::Index<&str> for DecodedValues {
    type Output = DecodedValue;

    fn index(&self, name: &str) -> &DecodedValue {
        self.get(name)
            .unwrap_or_else(|| panic!("no decoded field named {name}"))
    }
}

impl<'a> IntoIterator for &'a DecodedValues {
    type Item = &'a (String, DecodedValue);
    type IntoIter = std::slice::Iter<'a, (String, DecodedValue)>;

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

/// Decode a single format field from a byte buffer.
///
/// No validated-spec precondition: parser-validated fields always satisfy
/// `length >= fixed_byte_size`, but this function is `pub` and may be handed a
/// hand-constructed [`FormatField`] that never went through
/// `parse_device_spec`, so a field slice shorter than the type's fixed width
/// is reported as [`ProtocolError::BufferTooShort`] (with slice-relative
/// `needed`/`got`) rather than panicking on the index below.
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

    // Guard the fixed-width reads below: they index the low
    // `fixed_byte_size` bytes of the field slice, which only exists when the
    // declared `length` is at least that wide.
    if let Some(fixed) = field.field_type.fixed_byte_size() {
        if slice.len() < fixed {
            return Err(ProtocolError::BufferTooShort {
                needed: fixed,
                got: slice.len(),
            });
        }
    }

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
        ValueType::Int32 => {
            Ok(DecodedValue::Int(
                i32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]) as i64,
            ))
        }
        ValueType::Uint32 => {
            Ok(DecodedValue::Uint(
                u32::from_le_bytes([slice[0], slice[1], slice[2], slice[3]]) as u64,
            ))
        }
        ValueType::Bytes => Ok(DecodedValue::Bytes(slice.to_vec())),
        ValueType::String => {
            // Non-UTF-8 bytes in a `string` field fall back to a
            // space-separated hex rendering inside `DecodedValue::String`
            // (not `Bytes`), so the UI still shows *something* legible for a
            // device that lies about its encoding. Callers that need to
            // distinguish real text from the fallback must check the bytes
            // themselves — the DecodedValue variant alone cannot tell them.
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
) -> Result<DecodedValues, ProtocolError> {
    let mut result = DecodedValues::new();
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
    U32(u32),
    I8(i8),
    I16(i16),
    I32(i32),
}

/// Encode a command to bytes for a BLE write.
///
/// For fixed commands, returns the `value` directly without consulting any
/// parameters — fixed commands are by definition parameterless.
///
/// For templated commands, every `{param}` placeholder is looked up in
/// `params`, validated against the parameter's declared type and `min`/`max`
/// bounds, and encoded little-endian per the type's byte width.
/// The higher-level encoding a command declares when it has no raw-byte
/// `value`/`template`, or `None` when the command is byte-encodable (or is
/// simply empty, which is a spec error rather than an unsupported encoding).
///
/// Single source of truth: `encode_command` rejects on it and `CommandDto`
/// flags the UI from it, so the encoder and the control can never disagree.
pub fn unsupported_encoding_kind(command: &Command) -> Option<String> {
    if command.value.is_some() || command.template.is_some() {
        return None;
    }
    // `encoding: bytes` + `payload.bytes` is a fixed byte write in a
    // different envelope (govee specs), so it is encodable; the same
    // encoding with a missing or malformed payload is not — there is
    // nothing to send.
    if command.payload_bytes().is_some() {
        return None;
    }
    if let Some(enc) = command.encoding.as_deref() {
        return Some(enc.to_string());
    }
    if command.setting_id.is_some() {
        return Some("protobuf setting_id".to_string());
    }
    if command.payload.is_some() {
        return Some("structured payload".to_string());
    }
    None
}

pub fn encode_command(
    command: &Command,
    params: &HashMap<String, f64>,
) -> Result<Vec<u8>, ProtocolError> {
    if let Some(ref value) = command.value {
        return Ok(value.clone());
    }
    if let Some(bytes) = command.payload_bytes() {
        return Ok(bytes);
    }

    // Commands with setting_id or encoding need typed-control handlers
    // (protobuf, JSON, TLV); the legacy raw-byte encoder cannot serve them.
    // The kind rides along in the error so the failure names the encoding
    // the command actually wanted, not just "something unsupported".
    if let Some(kind) = unsupported_encoding_kind(command) {
        return Err(ProtocolError::UnsupportedCommandEncoding(kind));
    }

    let template = command
        .template
        .as_ref()
        .ok_or(ProtocolError::EmptyCommand)?;
    let param_defs = command.parameters.as_ref();

    // First pass: the packet's total encoded length, needed to fill any
    // `auto: packet_length` transport field. Fixed-width parameters contribute
    // their type's width; variable-width ones (bytes/string) contribute 0 here,
    // which is moot — they cannot be supplied through the f64 param map and fail
    // the encode below anyway.
    let total_len: usize = template
        .iter()
        .map(|element| match element {
            TemplateElement::Byte(_) => 1,
            TemplateElement::Param(name) => param_defs
                .and_then(|d| d.params.get(name.as_str()))
                .map(|d| &d.value_type)
                .unwrap_or(&ValueType::Uint8)
                .fixed_byte_size()
                .unwrap_or(0),
        })
        .sum();

    let mut bytes = Vec::new();
    for element in template {
        match element {
            TemplateElement::Byte(b) => bytes.push(*b),
            TemplateElement::Param(name) => {
                let def = param_defs.and_then(|d| d.params.get(name.as_str()));
                // Resolution order: auto roles are the encoder's (a supplied
                // packet_length is ignored — it can only be redundant or wrong;
                // a supplied sequence is honored so stateful callers can
                // increment); otherwise a supplied value wins, then the spec's
                // default, then the parameter is genuinely missing. The
                // supplied-then-default fallback is what lets a high-level
                // control (brightness slider, color picker) send only the
                // parameters it owns while protocol bytes like `seq`/`flag`
                // come from the spec.
                let val = match def.and_then(|d| d.auto) {
                    Some(AutoRole::PacketLength) => total_len as f64,
                    Some(AutoRole::Sequence) => params.get(name.as_str()).copied().unwrap_or(0.0),
                    None => match params.get(name.as_str()) {
                        Some(v) => *v,
                        None => def
                            .and_then(|d| d.default)
                            .map(|d| d as f64)
                            .ok_or_else(|| ProtocolError::ParameterMissing(name.clone()))?,
                    },
                };
                if let Some(def) = def {
                    validate_param_range(name, val, def)?;
                }
                let param_type = def.map(|d| &d.value_type).unwrap_or(&ValueType::Uint8);
                let typed = coerce_param(val, param_type, name)?;
                let big_endian = matches!(def.and_then(|d| d.endianness), Some(Endianness::Big));
                append_typed(&mut bytes, typed, big_endian);
            }
        }
    }
    Ok(bytes)
}

/// The low byte of a command's `auto: sequence` parameter as resolved by
/// [`encode_command`] (supplied value, else 0), or 0 when the command declares
/// none. Fragment framings reuse it as the packet serial so the serial tracks
/// the message counter when a stateful caller supplies one.
pub fn sequence_low_byte(command: &Command, params: &HashMap<String, f64>) -> u8 {
    command
        .parameters
        .as_ref()
        .and_then(|defs| {
            defs.params
                .iter()
                .find(|(_, def)| def.auto == Some(AutoRole::Sequence))
                .map(|(name, _)| params.get(name.as_str()).copied().unwrap_or(0.0))
        })
        .map(|v| (v as i64 & 0xFF) as u8)
        .unwrap_or(0)
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
    // Accept values that are integers to within a small tolerance: params
    // arrive as f64 across the FFI, so an exact integer can show up as e.g.
    // 254.9999999997. Anything genuinely fractional (1.5) is still rejected,
    // and range validation below still bounds the rounded result.
    if (val - val.round()).abs() > 1e-9 {
        return Err(ProtocolError::ParameterInvalid {
            name: name.to_string(),
            value: val,
            reason: "value has a fractional component".into(),
        });
    }

    let as_int = val.round() as i64;
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
        // `bool` encodes as a single 0/1 byte. `ValueType::Bool` reports an
        // integer_range of (0, 1), so the parser accepts `type: bool`
        // template parameters — the encoder must accept them too, or
        // `CommandDto::is_encodable` would advertise a command that can
        // never actually encode.
        ValueType::Bool => match as_int {
            0 | 1 => Ok(TypedParam::U8(as_int as u8)),
            _ => Err(oor()),
        },
        ValueType::Uint8 => u8::try_from(as_int).map(TypedParam::U8).map_err(|_| oor()),
        ValueType::Uint16 => u16::try_from(as_int)
            .map(TypedParam::U16)
            .map_err(|_| oor()),
        ValueType::Uint32 => u32::try_from(as_int)
            .map(TypedParam::U32)
            .map_err(|_| oor()),
        ValueType::Int8 => i8::try_from(as_int).map(TypedParam::I8).map_err(|_| oor()),
        ValueType::Int16 => i16::try_from(as_int)
            .map(TypedParam::I16)
            .map_err(|_| oor()),
        ValueType::Int32 => i32::try_from(as_int)
            .map(TypedParam::I32)
            .map_err(|_| oor()),
        other => Err(ProtocolError::UnsupportedParameterType { ty: other.clone() }),
    }
}

/// Encode one numeric value as the little-endian bytes of `ty`.
///
/// The direct-write counterpart of [`encode_command`]: a `number` entity
/// whose spec nominates a writable characteristic with a single-field format
/// has no command to place its bytes, so the value *is* the payload. Range
/// and integrality are checked exactly as a template parameter's would be, so
/// an out-of-range setpoint fails here rather than on the wire.
pub fn encode_scalar(value: f64, ty: &ValueType, name: &str) -> Result<Vec<u8>, ProtocolError> {
    let mut bytes = Vec::new();
    // Setpoint scalars have no endianness declaration of their own; keep the
    // established little-endian behavior for multi-byte widths.
    append_typed(&mut bytes, coerce_param(value, ty, name)?, false);
    Ok(bytes)
}

fn append_typed(bytes: &mut Vec<u8>, val: TypedParam, big_endian: bool) {
    macro_rules! push {
        ($v:expr) => {
            if big_endian {
                bytes.extend_from_slice(&$v.to_be_bytes())
            } else {
                bytes.extend_from_slice(&$v.to_le_bytes())
            }
        };
    }
    match val {
        TypedParam::U8(v) => bytes.push(v),
        TypedParam::I8(v) => bytes.push(v as u8),
        TypedParam::U16(v) => push!(v),
        TypedParam::I16(v) => push!(v),
        TypedParam::U32(v) => push!(v),
        TypedParam::I32(v) => push!(v),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::types::{Parameter, ParameterSet};

    /// Build a bare parameter with only a type and optional bounds; the
    /// documentation-only extension fields default to `None`.
    fn param(value_type: ValueType, min: Option<i64>, max: Option<i64>) -> Parameter {
        Parameter {
            value_type,
            min,
            max,
            ..Default::default()
        }
    }

    /// Wrap named parameters into a [`ParameterSet`] with no reserved keys.
    fn pset(entries: impl IntoIterator<Item = (&'static str, Parameter)>) -> ParameterSet {
        ParameterSet {
            color_order: None,
            params: entries
                .into_iter()
                .map(|(name, p)| (name.to_string(), p))
                .collect(),
        }
    }

    #[test]
    fn decode_bool_field() {
        let field = FormatField {
            offset: 0,
            length: 1,
            name: "power".into(),
            field_type: ValueType::Bool,
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
                ..Default::default()
            },
            FormatField {
                offset: 1,
                length: 1,
                name: "brightness".into(),
                field_type: ValueType::Uint8,
                ..Default::default()
            },
            FormatField {
                offset: 2,
                length: 1,
                name: "red".into(),
                field_type: ValueType::Uint8,
                ..Default::default()
            },
        ];
        let bytes = &[1, 80, 255];
        let result = decode_all_fields(bytes, &fields).unwrap();
        assert_eq!(result["power_state"], DecodedValue::Bool(true));
        assert_eq!(result["brightness"], DecodedValue::Uint(80));
        assert_eq!(result["red"], DecodedValue::Uint(255));

        // Order follows the spec's `format` list, not a hash seed, so the UI
        // lists the fields the same way on every launch.
        let names: Vec<&str> = result.iter().map(|(name, _)| name.as_str()).collect();
        assert_eq!(names, ["power_state", "brightness", "red"]);
    }

    #[test]
    fn decode_int8_field() {
        let field = FormatField {
            offset: 0,
            length: 1,
            name: "temp".into(),
            field_type: ValueType::Int8,
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            ..Default::default()
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
            setting_id: None,
            encoding: None,
            payload: None,
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
            parameters: Some(pset([(
                "brightness",
                param(ValueType::Uint8, Some(0), Some(100)),
            )])),
            setting_id: None,
            encoding: None,
            payload: None,
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
            parameters: Some(pset([(
                "brightness",
                param(ValueType::Uint8, Some(0), Some(100)),
            )])),
            setting_id: None,
            encoding: None,
            payload: None,
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
            parameters: Some(pset([("n", param(ValueType::Uint8, None, None))])),
            setting_id: None,
            encoding: None,
            payload: None,
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
    fn coerce_accepts_near_integer_float() {
        // An exact integer can arrive across the FFI with tiny float error;
        // it should round to the intended byte, not be rejected as fractional.
        let params = HashMap::from([("n".into(), 254.9999999997)]);
        assert_eq!(
            encode_command(&brightness_cmd(), &params).unwrap(),
            vec![0x02, 255]
        );
        let params_low = HashMap::from([("n".into(), 0.0000000003)]);
        assert_eq!(
            encode_command(&brightness_cmd(), &params_low).unwrap(),
            vec![0x02, 0]
        );
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
            parameters: Some(pset([("n", param(ValueType::Int8, None, None))])),
            setting_id: None,
            encoding: None,
            payload: None,
        };
        let lo = HashMap::from([("n".into(), -128.0)]);
        assert_eq!(encode_command(&cmd, &lo).unwrap(), vec![0x80]);
        let hi = HashMap::from([("n".into(), 127.0)]);
        assert_eq!(encode_command(&cmd, &hi).unwrap(), vec![0x7F]);
    }

    #[test]
    fn encode_int32_param_little_endian() {
        // M1: int32 must be encodable, not just decodable. -2 → 0xFE_FF_FF_FF LE.
        let cmd = Command {
            description: "set".into(),
            value: None,
            template: Some(vec![TemplateElement::Param("n".into())]),
            parameters: Some(pset([("n", param(ValueType::Int32, None, None))])),
            setting_id: None,
            encoding: None,
            payload: None,
        };
        let params = HashMap::from([("n".into(), -2.0)]);
        assert_eq!(
            encode_command(&cmd, &params).unwrap(),
            vec![0xFE, 0xFF, 0xFF, 0xFF]
        );
        // A large positive admore setting value (2000) round-trips too.
        let params = HashMap::from([("n".into(), 2000.0)]);
        assert_eq!(
            encode_command(&cmd, &params).unwrap(),
            2000i32.to_le_bytes().to_vec()
        );
    }

    #[test]
    fn encode_uint32_param_little_endian() {
        let cmd = Command {
            description: "set".into(),
            value: None,
            template: Some(vec![TemplateElement::Param("n".into())]),
            parameters: Some(pset([("n", param(ValueType::Uint32, None, None))])),
            setting_id: None,
            encoding: None,
            payload: None,
        };
        let params = HashMap::from([("n".into(), 4_000_000_000.0)]);
        assert_eq!(
            encode_command(&cmd, &params).unwrap(),
            4_000_000_000u32.to_le_bytes().to_vec()
        );
    }

    #[test]
    fn coerce_accepts_exact_i32_bounds() {
        assert_eq!(
            coerce_param(i32::MIN as f64, &ValueType::Int32, "n").unwrap(),
            TypedParam::I32(i32::MIN)
        );
        assert_eq!(
            coerce_param(i32::MAX as f64, &ValueType::Int32, "n").unwrap(),
            TypedParam::I32(i32::MAX)
        );
        // Just outside i32 range is rejected.
        assert!(matches!(
            coerce_param(i32::MAX as f64 + 1.0, &ValueType::Int32, "n"),
            Err(ProtocolError::ParameterOutOfRange { .. })
        ));
    }

    #[test]
    fn coerce_accepts_exact_u32_bounds() {
        assert_eq!(
            coerce_param(0.0, &ValueType::Uint32, "n").unwrap(),
            TypedParam::U32(0)
        );
        assert_eq!(
            coerce_param(u32::MAX as f64, &ValueType::Uint32, "n").unwrap(),
            TypedParam::U32(u32::MAX)
        );
        assert!(matches!(
            coerce_param(-1.0, &ValueType::Uint32, "n"),
            Err(ProtocolError::ParameterOutOfRange { .. })
        ));
    }

    #[test]
    fn decode_uint32_le() {
        let field = FormatField {
            offset: 0,
            length: 4,
            name: "value".into(),
            field_type: ValueType::Uint32,
            ..Default::default()
        };
        // 0xFFFFFFFF LE = 4294967295
        assert_eq!(
            decode_field(&[0xFF, 0xFF, 0xFF, 0xFF], &field).unwrap(),
            DecodedValue::Uint(4_294_967_295)
        );
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
            setting_id: None,
            encoding: None,
            payload: None,
        };
        // Even pathological parameter values should be ignored.
        let params = HashMap::from([("nonsense".into(), f64::NAN)]);
        let bytes = encode_command(&cmd, &params).unwrap();
        assert_eq!(bytes, vec![0x01, 0x01]);
    }

    // ── encoder error paths (M4) ────────────────────────────────────────────

    /// A command with only a description — every optional field `None`.
    /// Tests mutate exactly the field under test.
    fn bare_cmd() -> Command {
        Command {
            description: "test".into(),
            value: None,
            template: None,
            parameters: None,
            setting_id: None,
            encoding: None,
            payload: None,
        }
    }

    #[test]
    fn encode_unsupported_encoding_error_names_the_kind() {
        // Table: how the command opts out of raw bytes → the kind the error
        // must carry. Precedence mirrors `unsupported_encoding_kind`:
        // a declared `encoding` wins over `setting_id`, which wins over
        // a bare `payload`.
        let cases: Vec<(&str, Command, &str)> = vec![
            (
                "encoding: json",
                {
                    let mut c = bare_cmd();
                    c.encoding = Some("json".into());
                    c
                },
                "json",
            ),
            (
                "setting_id only",
                {
                    let mut c = bare_cmd();
                    c.setting_id = Some("LOS_TAIL_LIGHT_BRIGHTNESS".into());
                    c
                },
                "protobuf setting_id",
            ),
            (
                "payload only",
                {
                    let mut c = bare_cmd();
                    c.payload = Some(serde_yaml::Value::Null);
                    c
                },
                "structured payload",
            ),
        ];
        for (label, cmd, want_kind) in cases {
            let err = encode_command(&cmd, &HashMap::new())
                .expect_err("commands without value/template must not encode");
            match &err {
                ProtocolError::UnsupportedCommandEncoding(kind) => {
                    assert_eq!(kind, want_kind, "{label}: wrong kind");
                }
                other => panic!("{label}: expected UnsupportedCommandEncoding, got {other:?}"),
            }
            // The whole point of carrying the kind: the rendered message
            // names the encoding the command wanted.
            assert!(
                err.to_string().contains(want_kind),
                "{label}: message should name '{want_kind}', got: {err}"
            );
        }
    }

    #[test]
    fn encode_command_with_neither_value_nor_template_is_empty_command() {
        match encode_command(&bare_cmd(), &HashMap::new()) {
            Err(ProtocolError::EmptyCommand) => (),
            other => panic!("expected EmptyCommand, got {other:?}"),
        }
    }

    /// govee's fixed-command envelope: `encoding: bytes` + `payload.bytes` is
    /// the same information as `value:`, and must encode identically.
    #[test]
    fn encode_payload_bytes_command_returns_fixed_bytes() {
        let mut cmd = bare_cmd();
        cmd.encoding = Some("bytes".into());
        cmd.payload = Some(serde_yaml::from_str("{bytes: [51, 1, 255, 205]}").unwrap());

        assert_eq!(
            unsupported_encoding_kind(&cmd),
            None,
            "a well-formed payload.bytes command is encodable"
        );
        assert_eq!(
            encode_command(&cmd, &HashMap::new()).unwrap(),
            vec![51, 1, 255, 205]
        );
    }

    /// A malformed `payload.bytes` must stay unsupported, not send a
    /// truncated or reinterpreted write. Table over the ways it goes wrong:
    /// no payload at all (obd2's `encoding: bytes` commands), a payload
    /// without `bytes`, an empty list, and entries outside 0..=255.
    #[test]
    fn malformed_payload_bytes_stays_unsupported() {
        let cases: Vec<(&str, Option<&str>)> = vec![
            ("no payload", None),
            ("payload without bytes key", Some("{ascii: ATZ}")),
            ("empty bytes list", Some("{bytes: []}")),
            ("byte out of range", Some("{bytes: [51, 300]}")),
            ("non-integer byte", Some("{bytes: [51, hi]}")),
        ];
        for (label, payload) in cases {
            let mut cmd = bare_cmd();
            cmd.encoding = Some("bytes".into());
            cmd.payload = payload.map(|p| serde_yaml::from_str(p).unwrap());
            assert_eq!(
                unsupported_encoding_kind(&cmd).as_deref(),
                Some("bytes"),
                "{label}: must stay unsupported"
            );
            match encode_command(&cmd, &HashMap::new()) {
                Err(ProtocolError::UnsupportedCommandEncoding(kind)) => {
                    assert_eq!(kind, "bytes", "{label}");
                }
                other => panic!("{label}: expected UnsupportedCommandEncoding, got {other:?}"),
            }
        }
    }

    /// elk-bledom's template shape: protocol bytes (`seq`, `flag`) carry
    /// spec-declared defaults, so a caller owning only `brightness` can send.
    fn defaulted_cmd() -> Command {
        Command {
            description: "brightness with defaulted protocol bytes".into(),
            value: None,
            template: Some(vec![
                TemplateElement::Byte(0x7E),
                TemplateElement::Param("seq".into()),
                TemplateElement::Param("brightness".into()),
                TemplateElement::Param("flag".into()),
                TemplateElement::Byte(0xEF),
            ]),
            parameters: Some(pset([
                ("seq", {
                    let mut p = param(ValueType::Uint8, None, None);
                    p.default = Some(0);
                    p
                }),
                ("brightness", param(ValueType::Uint8, Some(0), Some(100))),
                ("flag", {
                    let mut p = param(ValueType::Uint8, None, None);
                    p.default = Some(16);
                    p
                }),
            ])),
            setting_id: None,
            encoding: None,
            payload: None,
        }
    }

    #[test]
    fn encode_template_fills_missing_params_from_declared_defaults() {
        let params = HashMap::from([("brightness".to_string(), 42.0)]);
        assert_eq!(
            encode_command(&defaulted_cmd(), &params).unwrap(),
            vec![0x7E, 0x00, 42, 16, 0xEF]
        );
    }

    #[test]
    fn encode_caller_value_overrides_declared_default() {
        let params = HashMap::from([("brightness".to_string(), 42.0), ("flag".to_string(), 1.0)]);
        assert_eq!(
            encode_command(&defaulted_cmd(), &params).unwrap(),
            vec![0x7E, 0x00, 42, 1, 0xEF]
        );
    }

    #[test]
    fn encode_undefaulted_missing_param_still_errors() {
        // `brightness` has no default, so omitting it keeps failing loudly —
        // defaults must not paper over genuinely missing input.
        let params = HashMap::from([("flag".to_string(), 1.0)]);
        match encode_command(&defaulted_cmd(), &params) {
            Err(ProtocolError::ParameterMissing(name)) => assert_eq!(name, "brightness"),
            other => panic!("expected ParameterMissing, got {other:?}"),
        }
    }

    #[test]
    fn encode_missing_parameter_returns_parameter_missing() {
        // brightness_cmd's template references "n"; supply nothing.
        match encode_command(&brightness_cmd(), &HashMap::new()) {
            Err(ProtocolError::ParameterMissing(name)) => assert_eq!(name, "n"),
            other => panic!("expected ParameterMissing, got {other:?}"),
        }
    }

    #[test]
    fn encode_string_typed_parameter_is_unsupported() {
        // A `string` template parameter parses (it is only bounds that are
        // rejected on non-numeric types) but has no integer representation,
        // so encoding must fail with the offending type named.
        let mut cmd = bare_cmd();
        cmd.template = Some(vec![TemplateElement::Param("s".into())]);
        cmd.parameters = Some(pset([("s", param(ValueType::String, None, None))]));
        let params = HashMap::from([("s".into(), 1.0)]);
        match encode_command(&cmd, &params) {
            Err(ProtocolError::UnsupportedParameterType { ty }) => {
                assert_eq!(ty, ValueType::String);
            }
            other => panic!("expected UnsupportedParameterType, got {other:?}"),
        }
    }

    // ── bool parameters (M2) ────────────────────────────────────────────────

    fn bool_cmd() -> Command {
        let mut cmd = bare_cmd();
        cmd.template = Some(vec![
            TemplateElement::Byte(0x0A),
            TemplateElement::Param("on".into()),
        ]);
        cmd.parameters = Some(pset([("on", param(ValueType::Bool, None, None))]));
        cmd
    }

    #[test]
    fn encode_bool_parameter_as_single_byte() {
        // M2: `type: bool` passes parse-time validation (integer_range is
        // (0, 1)), so the encoder must accept it too — one byte, 0 or 1.
        for (input, want) in [(0.0, 0u8), (1.0, 1u8)] {
            let params = HashMap::from([("on".into(), input)]);
            assert_eq!(
                encode_command(&bool_cmd(), &params).unwrap(),
                vec![0x0A, want],
                "bool {input} should encode as byte {want}"
            );
        }
    }

    #[test]
    fn encode_bool_parameter_rejects_out_of_range() {
        let params = HashMap::from([("on".into(), 2.0)]);
        match encode_command(&bool_cmd(), &params) {
            Err(ProtocolError::ParameterOutOfRange {
                value, min, max, ..
            }) => {
                assert_eq!(value, 2.0);
                assert_eq!(min, 0.0);
                assert_eq!(max, 1.0);
            }
            other => panic!("expected ParameterOutOfRange, got {other:?}"),
        }
    }

    #[test]
    fn decode_fixed_type_shorter_than_width_errors_instead_of_panicking() {
        // The parser rejects `uint16` with length 1 at load time, but
        // `decode_field` is `pub` — a hand-constructed field must produce an
        // error, not an out-of-bounds panic on `slice[1]`.
        let field = FormatField {
            offset: 0,
            length: 1,
            name: "bad".into(),
            field_type: ValueType::Uint16,
            ..Default::default()
        };
        // The buffer is plenty long; the *declared field* is what's too
        // short, so needed/got are slice-relative.
        match decode_field(&[0xAA, 0xBB, 0xCC, 0xDD], &field) {
            Err(ProtocolError::BufferTooShort { needed, got }) => {
                assert_eq!(needed, 2);
                assert_eq!(got, 1);
            }
            other => panic!("expected BufferTooShort, got {other:?}"),
        }
    }
}

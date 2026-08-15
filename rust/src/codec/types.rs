// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Byte-level encoding and decoding for BLE characteristic values.

use crate::error::ProtocolError;
use crate::spec::types::{
    AutoRole, Characteristic, Command, Endianness, FormatField, Parameter, TemplateElement,
    ValueType,
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

    // The spec's `endianness`, defaulting to little — BLE's convention, the
    // schema's default, and what this decoder assumed unconditionally before
    // the key was honoured. Only the multi-byte integers consult it: a single
    // byte has no order, and `bytes`/`string` are sequences the device already
    // laid out.
    let two = |a: [u8; 2]| {
        if field.is_big_endian() {
            [a[1], a[0]]
        } else {
            a
        }
    };
    let four = |a: [u8; 4]| {
        if field.is_big_endian() {
            [a[3], a[2], a[1], a[0]]
        } else {
            a
        }
    };

    match field.field_type {
        ValueType::Bool => Ok(DecodedValue::Bool(slice[0] != 0)),
        ValueType::Uint8 => Ok(DecodedValue::Uint(slice[0] as u64)),
        ValueType::Uint16 => Ok(DecodedValue::Uint(
            u16::from_le_bytes(two([slice[0], slice[1]])) as u64,
        )),
        ValueType::Int8 => Ok(DecodedValue::Int(slice[0] as i8 as i64)),
        ValueType::Int16 => Ok(DecodedValue::Int(
            i16::from_le_bytes(two([slice[0], slice[1]])) as i64,
        )),
        ValueType::Int32 => {
            Ok(DecodedValue::Int(
                i32::from_le_bytes(four([slice[0], slice[1], slice[2], slice[3]])) as i64,
            ))
        }
        ValueType::Uint32 => {
            Ok(DecodedValue::Uint(
                u32::from_le_bytes(four([slice[0], slice[1], slice[2], slice[3]])) as u64,
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
        ValueType::Varint => {
            // Unsigned LEB128. Format fields rarely declare varint, but keep
            // decode symmetric with the encoder rather than erroring.
            let mut v: u64 = 0;
            let mut shift = 0u32;
            for &b in slice {
                v |= u64::from(b & 0x7F) << shift;
                if b & 0x80 == 0 {
                    break;
                }
                shift += 7;
                // A u64 varint is at most 10 bytes; stop before the shift would
                // overflow (a malformed over-long continuation must not panic
                // the decode of an incoming notification).
                if shift >= 64 {
                    break;
                }
            }
            Ok(DecodedValue::Uint(v))
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
    /// A protobuf base-128 varint value (unsigned). Emitted variable-width,
    /// endianness-independent.
    Varint(u64),
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
/// Why this command cannot be sent as raw bytes on THIS characteristic, or
/// `None` when it can.
///
/// [`unsupported_encoding_kind`] answers the same question about the command
/// alone. That is not enough: a characteristic can declare an `encryption` or
/// `framing` transform that every payload written to it must pass through, and
/// this crate executes neither. Seeblue's commands are the case — their
/// templates are the packet, and the SEEBlue envelope (header, length,
/// sequence, protocol id, checksum) is the characteristic's job — so writing a
/// template's bytes straight to the characteristic sends a packet the device
/// will not answer.
///
/// The entity-binding path has always applied this rule. The generic
/// typed-command path did not, so a spec whose transform lives one level up
/// reached the UI as an ordinary sendable command.
pub fn unsupported_write_kind(
    characteristic: &Characteristic,
    command: &Command,
) -> Option<String> {
    if characteristic.encryption.is_some() {
        return Some("characteristic encryption".to_string());
    }
    if characteristic.framing.is_some() {
        // A framing scheme this build actually executes is not a blocker: the
        // generic encoder wraps the template's bytes in it (see
        // `protocol::image_upload::frame_command`). Anything else — a scheme
        // this build does not implement, or a framing block that names no
        // scheme at all (coolledx's length prefix) — makes a raw write wrong.
        let scheme = framing_scheme_name(characteristic);
        let implemented = scheme.as_deref().is_some_and(implemented_framing_scheme);
        if !implemented {
            let label = scheme.unwrap_or_else(|| "framing".to_string());
            return Some(format!("characteristic framing ({label})"));
        }
    }
    // Checked here rather than inside `unsupported_encoding_kind` so the
    // low-level encoder keeps reporting the precise
    // `UnsupportedParameterType` for a caller that reaches it directly. This
    // is the capability question — may the UI offer a Send at all — and the
    // answer is no.
    unsupported_parameter_kind(command).or_else(|| unsupported_encoding_kind(command))
}

/// Canonical name of the one fragment-framing scheme this build executes
/// (Daniao's `[serial][total][remaining][tag]` DDP header). Defined here, at
/// the codec layer, so the encodability gates ([`unsupported_write_kind`],
/// `spec::bindings::needs_unimplemented_transform`) and the protocol-layer
/// fragment registry (`protocol::image_upload`) all name the same string
/// without the codec depending on the protocol crate. `protocol::daniao`
/// re-exports this as its `FRAGMENT_SCHEME`.
pub const DANIAO_FRAGMENT_SCHEME: &str = "daniao_fragment";

/// Whether `name` is a framing scheme this build wraps packets in, rather than
/// merely parses. A characteristic whose `framing.scheme` is implemented is
/// sendable through the generic encoder; an unknown one is not.
pub fn implemented_framing_scheme(name: &str) -> bool {
    matches!(name, DANIAO_FRAGMENT_SCHEME)
}

/// The `framing.scheme` a characteristic declares, if it declares a framing
/// block naming one. The block is stored untyped (most devices have none), so
/// this reads the one field the gates care about.
pub fn framing_scheme_name(characteristic: &Characteristic) -> Option<String> {
    characteristic
        .framing
        .as_ref()?
        .get("scheme")
        .and_then(|v| v.as_str())
        .map(str::to_string)
}

/// A template parameter whose declared type the encoder cannot carry.
///
/// The FFI passes parameters as `HashMap<String, f64>`, so a `bytes` or
/// `string` parameter has no representation: `coerce_param` rejects it with
/// `UnsupportedParameterType`. Without this check a command like Fardriver's
/// `write_parameter` — whose `data` is 1-26 raw octets — reports itself
/// encodable, the UI enables Send, and every press fails after the user has
/// filled in the form.
///
/// Only parameters the template actually references count. A spec may declare
/// a parameter it does not use, and an unused `bytes` definition costs the
/// command nothing.
fn unsupported_parameter_kind(command: &Command) -> Option<String> {
    let template = command.template.as_ref()?;
    let defs = command.parameters.as_ref()?;
    for element in template {
        let TemplateElement::Param(name) = element else {
            continue;
        };
        let def = defs.params.get(name.as_str())?;
        if !def.value_type.is_encodable_param() {
            return Some(format!("{} parameter '{name}'", def.value_type));
        }
    }
    None
}

pub fn unsupported_encoding_kind(command: &Command) -> Option<String> {
    if command.value.is_some() || command.template.is_some() {
        return None;
    }
    // `encoding: bytes` + `payload.bytes` is a fixed byte write filed under
    // the wrong key, so it is still encodable; the same encoding with a
    // missing or malformed payload is not — there is nothing to send. The
    // spec schema rejects that key now; see Command::payload_bytes for why
    // the reader stays anyway.
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
    encode_command_with_bytes(command, params, &HashMap::new())
}

/// Like [`encode_command`], but a Rust caller can also supply values for
/// `bytes`-typed template parameters (a `{payload}` a protobuf/CRC builder
/// produced). The header, message-type and framing still come from the spec
/// template — only the opaque payload is filled here. The FFI's numeric-only
/// param map cannot carry these, which is why they stay a Rust-side entry
/// point (set_playlist, and any other command whose payload this crate builds).
pub fn encode_command_with_bytes(
    command: &Command,
    params: &HashMap<String, f64>,
    bytes_params: &HashMap<String, Vec<u8>>,
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

    // `auto: packet_length` needs the TOTAL encoded length, but a variable-width
    // param (a protobuf `varint`) before or after it means the total is not
    // known until every element is emitted. So reserve fixed-width zero
    // placeholders for length fields, then patch them once the packet is built.
    let mut bytes = Vec::new();
    let mut length_fixups: Vec<(usize, usize, bool)> = Vec::new(); // (offset, width, be)
    for element in template {
        match element {
            TemplateElement::Byte(b) => bytes.push(*b),
            TemplateElement::Param(name) => {
                let def = param_defs.and_then(|d| d.params.get(name.as_str()));
                let big_endian = matches!(def.and_then(|d| d.endianness), Some(Endianness::Big));
                if def.and_then(|d| d.auto) == Some(AutoRole::PacketLength) {
                    let width = def
                        .map(|d| &d.value_type)
                        .unwrap_or(&ValueType::Uint8)
                        .fixed_byte_size()
                        .ok_or_else(|| ProtocolError::ParameterInvalid {
                            name: name.clone(),
                            value: 0.0,
                            reason: "auto: packet_length must be a fixed-width type".into(),
                        })?;
                    length_fixups.push((bytes.len(), width, big_endian));
                    bytes.resize(bytes.len() + width, 0);
                    continue;
                }
                // A `bytes` template param (an opaque payload a Rust builder
                // produced) is appended verbatim — it has no numeric coercion.
                if matches!(def.map(|d| &d.value_type), Some(ValueType::Bytes)) {
                    let payload = bytes_params
                        .get(name.as_str())
                        .ok_or_else(|| ProtocolError::ParameterMissing(name.clone()))?;
                    bytes.extend_from_slice(payload);
                    continue;
                }
                // Resolution order: `auto: sequence` is the encoder's (a
                // supplied value is honored so stateful callers can increment);
                // `auto: checksum` is computed from the bytes emitted so far
                // (a supplied value is honored too, so stateless callers are
                // not forced to recompute); otherwise a supplied value wins,
                // then the spec's default, then the parameter is genuinely
                // missing. The supplied-then-default fallback lets a
                // high-level control (brightness slider, color picker) send
                // only the parameters it owns while protocol bytes like
                // `seq`/`flag` come from the spec.
                let val = match def.and_then(|d| d.auto) {
                    Some(AutoRole::Sequence) => params.get(name.as_str()).copied().unwrap_or(0.0),
                    Some(AutoRole::Checksum) => match params.get(name.as_str()) {
                        Some(v) => *v,
                        None => {
                            compute_checksum(&bytes, def.expect("auto implies a def"), name)? as f64
                        }
                    },
                    _ => match params.get(name.as_str()) {
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
                append_typed(&mut bytes, typed, big_endian);
            }
        }
    }

    // Patch the total length into every reserved packet_length field.
    let total = bytes.len();
    for (offset, width, big_endian) in length_fixups {
        // Refuse to silently truncate: a length that doesn't fit the field
        // would put a wrong length on the wire and make the device mis-parse.
        let capacity = if width >= 8 {
            u64::MAX
        } else {
            (1u64 << (width * 8)) - 1
        };
        if total as u64 > capacity {
            return Err(ProtocolError::ParameterInvalid {
                name: "packet_length".to_string(),
                value: total as f64,
                reason: format!("packet length {total} does not fit the {width}-byte length field"),
            });
        }
        let le = (total as u64).to_le_bytes();
        for i in 0..width {
            let src = if big_endian { width - 1 - i } else { i };
            bytes[offset + i] = le[src];
        }
    }
    Ok(bytes)
}

/// Compute the byte an `auto: checksum` parameter emits: the sum of every
/// frame byte from `checksum_start` (default 1) up to the current end of the
/// buffer, mod 256, then XORed with `checksum_xor` (default 0).
///
/// `emitted` is the frame built so far — the checksum byte itself is not yet
/// in it, so "up to but not including the checksum position" falls out of the
/// call site. `checksum_start` beyond the emitted length is a spec error
/// (`ParameterInvalid`), not a silent zero-sum over an empty range: a frame
/// whose checksum never sees its bytes fails on the device in a way nobody
/// can debug from the app.
fn compute_checksum(emitted: &[u8], def: &Parameter, name: &str) -> Result<u8, ProtocolError> {
    let start = def.checksum_start.unwrap_or(1);
    if emitted.len() <= start {
        return Err(ProtocolError::ParameterInvalid {
            name: name.to_string(),
            value: start as f64,
            reason: format!(
                "checksum_start {start} leaves nothing to sum (only {} bytes emitted)",
                emitted.len()
            ),
        });
    }
    let sum: u32 = emitted[start..].iter().map(|b| u32::from(*b)).sum();
    // `checksum_xor` is i64 like every spec number; only its low byte can
    // affect a one-byte checksum, so mask rather than reject a wider value.
    let xor = (def.checksum_xor.unwrap_or(0) & 0xFF) as u8;
    Ok((sum % 256) as u8 ^ xor)
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
        ValueType::Varint => u32::try_from(as_int)
            .map(|v| TypedParam::Varint(v as u64))
            .map_err(|_| oor()),
        other => Err(ProtocolError::UnsupportedParameterType { ty: other.clone() }),
    }
}

/// Encode one numeric value as the bytes of `ty`.
///
/// The direct-write counterpart of [`encode_command`]: a `number` entity
/// whose spec nominates a writable characteristic with a single-field format
/// has no command to place its bytes, so the value *is* the payload. Range
/// and integrality are checked exactly as a template parameter's would be, so
/// an out-of-range setpoint fails here rather than on the wire.
///
/// `big_endian` is the format field's own declaration: the byte order the
/// decode side already honors must be the one the write takes, or a big
/// -endian uint16 setpoint reads correctly and writes byte-swapped.
pub fn encode_scalar(
    value: f64,
    ty: &ValueType,
    name: &str,
    big_endian: bool,
) -> Result<Vec<u8>, ProtocolError> {
    let mut bytes = Vec::new();
    append_typed(&mut bytes, coerce_param(value, ty, name)?, big_endian);
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
        // Protobuf base-128 varint: 7 bits per byte, high bit = "more".
        // Byte order is intrinsic, so `big_endian` does not apply.
        TypedParam::Varint(mut v) => loop {
            let byte = (v & 0x7F) as u8;
            v >>= 7;
            if v == 0 {
                bytes.push(byte);
                break;
            }
            bytes.push(byte | 0x80);
        },
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

    /// Wrap named parameters into a [`ParameterSet`].
    fn pset(entries: impl IntoIterator<Item = (&'static str, Parameter)>) -> ParameterSet {
        ParameterSet {
            retired_color_order: None,
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

    /// The same bytes, both ways round, for every multi-byte width.
    ///
    /// `endianness` is a spec key the decoder ignored until recently: six
    /// fields in the catalogue declared it, all saying `little`, so nothing
    /// decoded wrong and nothing would have reported it if it had. That is the
    /// hazard worth pinning — a byte-swapped reading is not obviously broken,
    /// it is a different plausible number, so only a test comparing the two
    /// orders can tell them apart.
    #[test]
    fn decode_honours_declared_endianness() {
        fn field(ty: ValueType, endianness: Option<&str>) -> FormatField {
            FormatField {
                offset: 0,
                length: ty.fixed_byte_size().unwrap(),
                name: "value".into(),
                field_type: ty,
                endianness: endianness.map(str::to_string),
                ..Default::default()
            }
        }

        let two = &[0x00, 0x01];
        // 0x0100: 256 read low-byte-first, 1 read high-byte-first. Both are
        // ordinary sensor readings, which is the whole problem.
        assert_eq!(
            decode_field(two, &field(ValueType::Uint16, None)).unwrap(),
            DecodedValue::Uint(256)
        );
        assert_eq!(
            decode_field(two, &field(ValueType::Uint16, Some("little"))).unwrap(),
            DecodedValue::Uint(256)
        );
        assert_eq!(
            decode_field(two, &field(ValueType::Uint16, Some("big"))).unwrap(),
            DecodedValue::Uint(1)
        );

        // Signed widths swap the same way, and the sign follows the swap: the
        // high byte is the one that carries it.
        assert_eq!(
            decode_field(&[0x00, 0xFF], &field(ValueType::Int16, None)).unwrap(),
            DecodedValue::Int(-256)
        );
        assert_eq!(
            decode_field(&[0xFF, 0x00], &field(ValueType::Int16, Some("big"))).unwrap(),
            DecodedValue::Int(-256)
        );

        let four = &[0x01, 0x02, 0x03, 0x04];
        assert_eq!(
            decode_field(four, &field(ValueType::Uint32, None)).unwrap(),
            DecodedValue::Uint(0x0403_0201)
        );
        assert_eq!(
            decode_field(four, &field(ValueType::Uint32, Some("big"))).unwrap(),
            DecodedValue::Uint(0x0102_0304)
        );
        assert_eq!(
            decode_field(four, &field(ValueType::Int32, Some("big"))).unwrap(),
            DecodedValue::Int(0x0102_0304)
        );

        // A single byte has no order to get wrong, and `bytes` is a sequence
        // the device already laid out — neither may be reversed by the key.
        assert_eq!(
            decode_field(&[0x7F], &field(ValueType::Uint8, Some("big"))).unwrap(),
            DecodedValue::Uint(0x7F)
        );
        let blob = FormatField {
            offset: 0,
            length: 3,
            name: "blob".into(),
            field_type: ValueType::Bytes,
            endianness: Some("big".into()),
            ..Default::default()
        };
        assert_eq!(
            decode_field(&[1, 2, 3], &blob).unwrap(),
            DecodedValue::Bytes(vec![1, 2, 3])
        );
    }

    /// An unrecognised spelling reads as the default rather than failing.
    ///
    /// The alternative — rejecting the field — turns a typo in one line of one
    /// spec into a device that will not load, and "little" is the answer that
    /// was being given before the key was honoured at all.
    #[test]
    fn an_unrecognised_endianness_falls_back_to_little() {
        let field = FormatField {
            offset: 0,
            length: 2,
            name: "value".into(),
            field_type: ValueType::Uint16,
            endianness: Some("BIG".into()),
            ..Default::default()
        };
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
            locate: None,
            advanced: false,
            advanced_reason: None,
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
            locate: None,
            advanced: false,
            advanced_reason: None,
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
            locate: None,
            advanced: false,
            advanced_reason: None,
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
            locate: None,
            advanced: false,
            advanced_reason: None,
        }
    }

    #[test]
    fn varint_param_and_auto_packet_length_account_for_width() {
        // A DNX-style header: [0xF0][len: auto packet_length, u16 BE][0x08]
        // [brightness: varint]. The length field must include the varint's
        // width, which changes with the value.
        let cmd = Command {
            description: "brightness".into(),
            value: None,
            template: Some(vec![
                TemplateElement::Byte(0xF0),
                TemplateElement::Param("len".into()),
                TemplateElement::Byte(0x08),
                TemplateElement::Param("brightness".into()),
            ]),
            parameters: Some(pset([
                (
                    "len",
                    Parameter {
                        value_type: ValueType::Uint16,
                        endianness: Some(Endianness::Big),
                        auto: Some(AutoRole::PacketLength),
                        ..Default::default()
                    },
                ),
                (
                    "brightness",
                    Parameter {
                        value_type: ValueType::Varint,
                        min: Some(1),
                        max: Some(255),
                        ..Default::default()
                    },
                ),
            ])),
            setting_id: None,
            encoding: None,
            payload: None,
            locate: None,
            advanced: false,
            advanced_reason: None,
        };
        // 200 -> two-byte varint [0xC8, 0x01], total length 6 (BE in len).
        let bytes = encode_command(&cmd, &HashMap::from([("brightness".into(), 200.0)])).unwrap();
        assert_eq!(bytes, vec![0xF0, 0x00, 0x06, 0x08, 0xC8, 0x01]);
        // 100 -> single-byte varint [0x64], total length 5.
        let bytes = encode_command(&cmd, &HashMap::from([("brightness".into(), 100.0)])).unwrap();
        assert_eq!(bytes, vec![0xF0, 0x00, 0x05, 0x08, 0x64]);
        // 256 is out of the varint param's declared max (255).
        assert!(encode_command(&cmd, &HashMap::from([("brightness".into(), 256.0)])).is_err());
    }

    #[test]
    fn packet_length_that_overflows_the_field_is_rejected() {
        // A uint8 auto:packet_length field with a packet longer than 255 bytes
        // must error, not silently truncate the length.
        let mut template = vec![TemplateElement::Param("len".into())];
        template.extend((0..300).map(|_| TemplateElement::Byte(0)));
        let cmd = Command {
            description: "x".into(),
            value: None,
            template: Some(template),
            parameters: Some(pset([(
                "len",
                Parameter {
                    value_type: ValueType::Uint8,
                    auto: Some(AutoRole::PacketLength),
                    ..Default::default()
                },
            )])),
            setting_id: None,
            encoding: None,
            payload: None,
            locate: None,
            advanced: false,
            advanced_reason: None,
        };
        assert!(matches!(
            encode_command(&cmd, &HashMap::new()),
            Err(ProtocolError::ParameterInvalid { .. })
        ));
    }

    // ── auto: checksum ──────────────────────────────────────────────────────

    /// The KingSmith WalkingPad frame shape: a header the checksum skips
    /// (`checksum_start` defaults to 1), one caller-owned parameter, and a
    /// trailing checksum byte the encoder computes.
    fn treadmill_cmd(checksum: Parameter) -> Command {
        Command {
            description: "set speed".into(),
            value: None,
            template: Some(vec![
                TemplateElement::Byte(0xF7),
                TemplateElement::Byte(0xA2),
                TemplateElement::Byte(0x01),
                TemplateElement::Param("speed".into()),
                TemplateElement::Param("checksum".into()),
                TemplateElement::Byte(0xFD),
            ]),
            parameters: Some(pset([
                ("speed", param(ValueType::Uint8, Some(0), Some(60))),
                ("checksum", checksum),
            ])),
            setting_id: None,
            encoding: None,
            payload: None,
            locate: None,
            advanced: false,
            advanced_reason: None,
        }
    }

    fn checksum_param() -> Parameter {
        Parameter {
            value_type: ValueType::Uint8,
            auto: Some(AutoRole::Checksum),
            ..Default::default()
        }
    }

    #[test]
    fn checksum_sums_from_index_one_by_default() {
        // KingSmith set_speed at 30: bytes so far F7 A2 01 1E, sum from
        // index 1 is A2+01+1E = 0xC1.
        let cmd = treadmill_cmd(checksum_param());
        let params = HashMap::from([("speed".into(), 30.0)]);
        assert_eq!(
            encode_command(&cmd, &params).unwrap(),
            vec![0xF7, 0xA2, 0x01, 0x1E, 0xC1, 0xFD]
        );
    }

    #[test]
    fn checksum_xor_is_applied_after_the_sum() {
        // The UREVO variant of the same protocol XORs the sum with 0x5A.
        // Template 02 {b} {c} {chk} 03 with b=0x53, c=0x0A: sum from index 1
        // is 0x5D, 0x5D ^ 0x5A = 0x07.
        let cmd = Command {
            description: "x".into(),
            value: None,
            template: Some(vec![
                TemplateElement::Byte(0x02),
                TemplateElement::Param("b".into()),
                TemplateElement::Param("c".into()),
                TemplateElement::Param("chk".into()),
                TemplateElement::Byte(0x03),
            ]),
            parameters: Some(pset([
                ("b", param(ValueType::Uint8, None, None)),
                ("c", param(ValueType::Uint8, None, None)),
                (
                    "chk",
                    Parameter {
                        checksum_xor: Some(0x5A),
                        ..checksum_param()
                    },
                ),
            ])),
            setting_id: None,
            encoding: None,
            payload: None,
            locate: None,
            advanced: false,
            advanced_reason: None,
        };
        let params = HashMap::from([("b".into(), 0x53 as f64), ("c".into(), 0x0A as f64)]);
        assert_eq!(
            encode_command(&cmd, &params).unwrap(),
            vec![0x02, 0x53, 0x0A, 0x07, 0x03]
        );
    }

    #[test]
    fn checksum_honors_a_caller_supplied_value() {
        // Like `auto: sequence`, a caller that already knows the checksum
        // (a stateful or passthrough caller) is not forced to recompute it.
        let cmd = treadmill_cmd(checksum_param());
        let params = HashMap::from([("speed".into(), 30.0), ("checksum".into(), 0x99 as f64)]);
        assert_eq!(
            encode_command(&cmd, &params).unwrap(),
            vec![0xF7, 0xA2, 0x01, 0x1E, 0x99, 0xFD]
        );
    }

    #[test]
    fn checksum_start_beyond_emitted_length_errors() {
        // The checksum comes first in the template but `checksum_start` skips
        // past every byte emitted so far — a spec error that must fail loudly
        // rather than emit a checksum over nothing.
        let cmd = treadmill_cmd(Parameter {
            checksum_start: Some(6),
            ..checksum_param()
        });
        let params = HashMap::from([("speed".into(), 30.0)]);
        match encode_command(&cmd, &params) {
            Err(ProtocolError::ParameterInvalid { name, reason, .. }) => {
                assert_eq!(name, "checksum");
                assert!(reason.contains("checksum_start"), "got: {reason}");
            }
            other => panic!("expected ParameterInvalid, got {other:?}"),
        }
    }

    #[test]
    fn varint_decode_does_not_panic_on_overlong_continuation() {
        // 12 continuation bytes (all high-bit set) must not overflow the shift.
        let field = FormatField {
            offset: 0,
            length: 12,
            name: "v".into(),
            field_type: ValueType::Varint,
            ..Default::default()
        };
        let decoded = decode_field(&[0x80; 12], &field);
        assert!(decoded.is_ok());
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
            locate: None,
            advanced: false,
            advanced_reason: None,
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
            locate: None,
            advanced: false,
            advanced_reason: None,
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
            locate: None,
            advanced: false,
            advanced_reason: None,
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
            locate: None,
            advanced: false,
            advanced_reason: None,
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
            locate: None,
            advanced: false,
            advanced_reason: None,
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
            locate: None,
            advanced: false,
            advanced_reason: None,
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

    #[test]
    fn encode_scalar_honors_declared_byte_order() {
        // A direct-write setpoint must take the byte order the field
        // declares — the decode side already honors it, and a field that
        // reads correctly but writes byte-swapped would set 0x012C (300)
        // as 0x2C01 (11265).
        let le = encode_scalar(300.0, &ValueType::Uint16, "target", false).unwrap();
        assert_eq!(le, vec![0x2C, 0x01]);
        let be = encode_scalar(300.0, &ValueType::Uint16, "target", true).unwrap();
        assert_eq!(be, vec![0x01, 0x2C]);
    }
}

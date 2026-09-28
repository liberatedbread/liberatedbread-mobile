// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Mock device simulator — generates realistic fake BLE readings
//! for development and testing without real hardware.

use crate::spec::types::{FormatField, ValueType};
use std::collections::HashMap;

/// Simulated state for one connected mock device.
#[derive(Default)]
pub struct MockDeviceState {
    /// Written characteristic values (keyed by char UUID).
    written: HashMap<String, Vec<u8>>,
    /// What the demo bulb has been told to do, laid over its status reads.
    bulb: BulbCommands,
}

/// The example bulb's Command (write) and Status (read) characteristics —
/// `vendor/protocol-specs/device-specs/examples/example-bulb.yaml`, the spec
/// behind demo mode's lights.
const BULB_COMMAND_UUID: &str = "0000fff1-0000-1000-8000-00805f9b34fb";
const BULB_STATUS_UUID: &str = "0000fff2-0000-1000-8000-00805f9b34fb";

/// Commands the demo bulb has applied. A real bulb's status follows its
/// commands; without this the next poll re-read the untouched defaults and
/// the user's Off looked like it never happened. Kept as an overlay rather
/// than a status buffer because the status defaults come from the spec's
/// format, which only `read` is given.
#[derive(Default)]
struct BulbCommands {
    power: Option<u8>,
    brightness: Option<u8>,
    rgb: Option<[u8; 3]>,
}

impl BulbCommands {
    /// Record one example-bulb command: `01 pp` power, `02 bb` brightness,
    /// `03 rr gg bb` colour. Anything else is not a bulb command and changes
    /// nothing.
    fn apply(&mut self, value: &[u8]) {
        match *value {
            [0x01, power] => self.power = Some(power),
            [0x02, brightness] => self.brightness = Some(brightness),
            [0x03, r, g, b] => self.rgb = Some([r, g, b]),
            _ => {}
        }
    }

    /// Lay the applied commands over status bytes (power, brightness, r, g,
    /// b at offsets 0..5), leaving any byte the buffer lacks alone.
    fn overlay(&self, status: &mut [u8]) {
        let mut set = |i: usize, v: Option<u8>| {
            if let (Some(slot), Some(v)) = (status.get_mut(i), v) {
                *slot = v;
            }
        };
        set(0, self.power);
        set(1, self.brightness);
        if let Some([r, g, b]) = self.rgb {
            set(2, Some(r));
            set(3, Some(g));
            set(4, Some(b));
        }
    }
}

/// Whether `format` is the example bulb's Status layout — power_state (bool)
/// then brightness, red, green, blue (uint8), one byte each at offsets 0..5 —
/// the bytes [`BulbCommands::overlay`] writes. Only then is the overlay the
/// device's own behaviour rather than a guess from a shared UUID.
fn is_bulb_status(format: &[FormatField]) -> bool {
    const LAYOUT: [(&str, ValueType); 5] = [
        ("power_state", ValueType::Bool),
        ("brightness", ValueType::Uint8),
        ("red", ValueType::Uint8),
        ("green", ValueType::Uint8),
        ("blue", ValueType::Uint8),
    ];
    LAYOUT.iter().enumerate().all(|(offset, (name, ty))| {
        format
            .iter()
            .any(|f| f.offset == offset && f.length == 1 && f.name == *name && f.field_type == *ty)
    })
}

impl MockDeviceState {
    pub fn new() -> Self {
        Self::default()
    }

    /// Store a written value for a characteristic.
    pub fn write(&mut self, char_uuid: &str, value: Vec<u8>) {
        // ASCII-lowercase per crate convention (SEV2 §2.5): UUIDs are pure
        // ASCII, and `read`/`read_raw` must normalize keys identically.
        let key = char_uuid.to_ascii_lowercase();
        if key == BULB_COMMAND_UUID {
            self.bulb.apply(&value);
        } else if key == BULB_STATUS_UUID {
            // A direct status write replaces the whole state, commands included.
            self.bulb = BulbCommands::default();
        }
        self.written.insert(key, value);
    }

    /// Generate a mock read value for a characteristic based on its format spec.
    /// If a value was previously written to this characteristic, returns that.
    /// Otherwise generates plausible defaults.
    pub fn read(&self, char_uuid: &str, format: &[FormatField]) -> Vec<u8> {
        let key = char_uuid.to_ascii_lowercase();

        // Return last written value if available, else plausible defaults.
        let mut bytes = match self.written.get(&key) {
            Some(written) => written.clone(),
            None => generate_defaults(format),
        };
        // The UUID alone does not make a bulb: fff1/fff2 are the catalogue's
        // most reused vendor UUIDs, and an Inkbird's fff2 is a temperature.
        // Without the format check a `02 1e` config write to its fff1 would
        // rewrite the temperature's high byte on the next read.
        if key == BULB_STATUS_UUID && is_bulb_status(format) {
            // A short directly-written status stays short: the overlay only
            // sets the bytes it has, the same rule as MockBleService's Dart
            // fallback, so the two paths read back the same bytes.
            self.bulb.overlay(&mut bytes);
        }
        bytes
    }

    /// Generate a mock read value for a characteristic that has no format spec.
    /// Returns the previously written value if there is one, otherwise a
    /// zero-filled buffer of `length` bytes (the caller falls back to raw hex
    /// display either way).
    pub fn read_raw(&self, char_uuid: &str, length: usize) -> Vec<u8> {
        let key = char_uuid.to_ascii_lowercase();
        if let Some(written) = self.written.get(&key) {
            return written.clone();
        }
        vec![0u8; length]
    }
}

/// Generate plausible default bytes for a set of format fields.
///
/// Lookup order per field: explicit `mock_default` from the spec → name-based
/// heuristic for the field's value type → 0.
fn generate_defaults(fields: &[FormatField]) -> Vec<u8> {
    let total_len = fields
        .iter()
        .map(|f| f.offset + f.length)
        .max()
        .unwrap_or(0);
    let mut bytes = vec![0u8; total_len];

    for field in fields {
        let slice = &mut bytes[field.offset..field.offset + field.length];

        // 1. Try the explicit `mock_default` from the spec.
        if let Some(val) = field
            .mock_default
            .as_ref()
            .and_then(|v| coerce_mock_default(v, &field.field_type))
        {
            write_value(slice, val, &field.field_type, field.is_big_endian());
            continue;
        }

        // 2. Fall back to the name-based heuristic. The value goes through
        // `write_value` (never a direct full-slice copy) because `length`
        // may legally exceed the type's byte width — see `write_value`.
        //
        // A declared transform (`scale`/`value_offset`) says what a raw count
        // means, so work back from a plausible physical reading instead of
        // guessing at the count: Airthings' temperature is `scale: 0.01`, and
        // a reader that applies the scale would turn the unscaled 220 into
        // 2.2 °C. The offset matters as much as the scale — the Wave Mini's
        // temperature is centikelvin (`scale: 0.01, value_offset: -273.15`),
        // and inverting only the scale would demo a −251 °C living room.
        // Without a transform nothing in the spec says what the units are, so
        // the historical raw constants stand.
        let transform = match (field.scale, field.value_offset) {
            (None, None) => None,
            (scale, offset) => Some((scale.unwrap_or(1.0), offset.unwrap_or(0.0))),
        };
        let heuristic: Option<i64> = match (&field.field_type, transform) {
            (ValueType::Bool, _) => Some(1), // default: on
            (
                ValueType::Uint8
                | ValueType::Uint16
                | ValueType::Int8
                | ValueType::Int16
                | ValueType::Int32
                | ValueType::Uint24
                | ValueType::Uint32
                | ValueType::Varint,
                Some((scale, offset)),
            ) => Some(raw_for_physical(nominal_for(field), scale, offset)),
            (ValueType::Uint8, None) => Some(default_uint8_for_name(&field.name) as i64),
            (ValueType::Uint16, None) => Some(default_uint16_for_name(&field.name) as i64),
            (ValueType::Int8, None) => Some(22),   // ~22°C
            (ValueType::Int16, None) => Some(220), // 22.0 if scaled
            // 24/32-bit and varint fields with no transform, and the
            // non-numeric types, stay zero.
            (
                ValueType::Int32 | ValueType::Uint24 | ValueType::Uint32 | ValueType::Varint,
                None,
            )
            | (ValueType::Bytes | ValueType::String, _) => None,
        };
        if let Some(val) = heuristic {
            write_value(slice, val, &field.field_type, field.is_big_endian());
        }
    }

    bytes
}

/// Try to interpret a YAML scalar as the integer payload for a field type.
///
/// Returns `None` for type mismatches *and* for numbers that don't fit in
/// the declared type's range — both cases fall through to the name-based
/// heuristic. Spec authors who write nonsense like `mock_default: 999` on
/// a `uint8` field get the heuristic value, not a silently-wrapped byte.
/// `Bytes` and `String` fields don't accept `mock_default` at all (they
/// have no integer representation), so they always return `None` here.
fn coerce_mock_default(val: &serde_yaml::Value, ty: &ValueType) -> Option<i64> {
    match (val, ty) {
        (serde_yaml::Value::Bool(b), ValueType::Bool) => Some(if *b { 1 } else { 0 }),
        (serde_yaml::Value::Number(n), _) => {
            let raw = n.as_i64()?;
            let (min, max) = ty.integer_range()?;
            (min..=max).contains(&raw).then_some(raw)
        }
        _ => None,
    }
}

/// Write `val` into the low bytes of `slice`, honoring the byte width of `ty`
/// and the field's declared byte order.
///
/// `slice` is the field's full `length` extent and may legally be *longer*
/// than the type's fixed width — the parser deliberately tolerates over-long
/// fixed fields (`type: uint16, length: 3`, e.g. padded/reserved trailing
/// bytes), so only the low `fixed_byte_size()` bytes are written and the tail
/// stays zero, mirroring how `decode_field` reads only the low bytes. A
/// whole-slice `copy_from_slice` here panics on exactly those specs, and this
/// code is reachable from Dart via `mock_read_characteristic` on remote
/// spec-pack YAML (H1). `slice` is never *shorter* than the fixed width: the
/// parser rejects that at load time (`FieldLengthMismatch`).
///
/// `big_endian` is `FormatField::is_big_endian`, the same flag `decode_field`
/// reads with. Writing little-endian regardless demoed the Beurer cuff's
/// big-endian `systolic_sfloat` (a plausible 100) as 25600 mmHg: the mock
/// encoded one order and the decoder read the other.
fn write_value(slice: &mut [u8], val: i64, ty: &ValueType, big_endian: bool) {
    fn put<const N: usize>(slice: &mut [u8], le: [u8; N], be: [u8; N], big: bool) {
        slice[..N].copy_from_slice(if big { &be } else { &le });
    }
    match ty {
        ValueType::Bool => slice[0] = if val == 0 { 0 } else { 1 },
        ValueType::Uint8 => slice[0] = val as u8,
        ValueType::Int8 => slice[0] = val as i8 as u8,
        ValueType::Uint16 => {
            let v = val as u16;
            put(slice, v.to_le_bytes(), v.to_be_bytes(), big_endian)
        }
        ValueType::Int16 => {
            let v = val as i16;
            put(slice, v.to_le_bytes(), v.to_be_bytes(), big_endian)
        }
        ValueType::Int32 => {
            let v = val as i32;
            put(slice, v.to_le_bytes(), v.to_be_bytes(), big_endian)
        }
        ValueType::Uint32 => {
            let v = val as u32;
            put(slice, v.to_le_bytes(), v.to_be_bytes(), big_endian)
        }
        // The low three bytes of the value — the same widen-and-drop the
        // codec's own emitter (`append_typed`) does. Big-endian, those are
        // the LAST three bytes of the u32's big-endian encoding, not the
        // first.
        ValueType::Uint24 => {
            let v = val as u32;
            let le = v.to_le_bytes();
            let be = v.to_be_bytes();
            put(
                slice,
                [le[0], le[1], le[2]],
                [be[1], be[2], be[3]],
                big_endian,
            )
        }
        // mock_default is ignored for these (variable/opaque width).
        ValueType::Varint | ValueType::Bytes | ValueType::String => {}
    }
}

fn default_uint8_for_name(name: &str) -> u8 {
    let lower = name.to_lowercase();
    if lower.contains("brightness") {
        80
    } else if lower.contains("battery") || lower.contains("percent") {
        85
    } else if lower.contains("red") {
        255
    } else if lower.contains("green") {
        180
    } else if lower.contains("blue") {
        50
    } else if lower.contains("speed") {
        128
    } else {
        50
    }
}

/// A plausible reading in the field's own decoded unit, chosen by name — and
/// for pressure by declared unit too, since "plausible" differs by three
/// orders of magnitude between hPa and Pa.
///
/// The counterpart to [`default_uint16_for_name`] for specs that declare a
/// transform: that one guesses at a raw count, this one names the physical
/// value and lets [`raw_for_physical`] derive the count the device would
/// send.
fn nominal_for(field: &FormatField) -> f64 {
    let lower = field.name.to_lowercase();
    let unit = field
        .unit
        .as_deref()
        .unwrap_or_default()
        .to_ascii_lowercase();
    // "dew" before "temp": a dew point IS a temperature, but a 22 °C dew
    // point would demo a swamp.
    if lower.contains("dew") {
        12.0
    } else if lower.contains("temp") {
        22.0
    } else if lower.contains("humid") {
        55.0
    } else if lower.contains("lux") || lower.contains("light") {
        500.0
    } else if lower.contains("battery") || lower.contains("percent") {
        85.0
    } else if lower.contains("pressure") {
        // Sea-level atmosphere, in whichever unit the spec declares.
        // "hpa" is checked first because it contains "pa".
        if unit.contains("hpa") || unit.contains("mbar") {
            1013.0
        } else if unit.contains("kpa") {
            101.3
        } else if unit.contains("pa") {
            101300.0
        } else {
            100.0
        }
    } else {
        100.0
    }
}

/// Invert a spec's transform to get the raw count a device would report for
/// `physical`: `raw = (physical - offset) / scale`, the inverse of
/// [`crate::codec::number::apply_transform`]. A non-positive or non-finite scale is
/// meaningless as a divisor, so the physical value passes through unchanged
/// rather than producing an infinity.
fn raw_for_physical(physical: f64, scale: f64, offset: f64) -> i64 {
    let offset = if offset.is_finite() { offset } else { 0.0 };
    if scale.is_finite() && scale > 0.0 {
        ((physical - offset) / scale).round() as i64
    } else {
        physical.round() as i64
    }
}

fn default_uint16_for_name(name: &str) -> u16 {
    let lower = name.to_lowercase();
    if lower.contains("temp") {
        2200 // 22.00°C if scaled
    } else if lower.contains("humid") {
        5500 // 55.00% if scaled
    } else if lower.contains("lux") || lower.contains("light") {
        500
    } else if lower.contains("radon") {
        // A healthy-house 55 Bq/m³ (the fields are raw becquerels): the demo
        // should look like a home, not an incident.
        55
    } else if lower.contains("co2") {
        650 // occupied-room ppm
    } else if lower.contains("voc") {
        120 // ppb
    } else {
        100
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn write_then_read() {
        let mut state = MockDeviceState::new();
        let uuid = "0000fff1-0000-1000-8000-00805f9b34fb";
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "power_state".into(),
            field_type: ValueType::Bool,
            ..Default::default()
        }];

        // Before write, get defaults
        let bytes = state.read(uuid, &fields);
        assert_eq!(bytes, vec![1]); // default: on

        // After write, get written value
        state.write(uuid, vec![0]);
        let bytes = state.read(uuid, &fields);
        assert_eq!(bytes, vec![0]);
    }

    fn parse(yaml: &str) -> crate::spec::types::DeviceSpec {
        crate::spec::parser::parse_device_spec(yaml).unwrap()
    }

    /// The vendored example bulb, the spec behind demo mode's lights. Read
    /// from the YAML, not rebuilt by hand, so a spec change to the offsets
    /// fails these tests instead of leaving them green over a broken demo.
    fn example_bulb() -> crate::spec::types::DeviceSpec {
        parse(include_str!(
            "../../../vendor/protocol-specs/device-specs/examples/example-bulb.yaml"
        ))
    }

    /// The example bulb's Status format: power, brightness, r, g, b.
    fn bulb_status_format() -> Vec<FormatField> {
        example_bulb()
            .find_decodable_characteristic(BULB_STATUS_UUID)
            .and_then(|(_, c)| c.format.clone())
            .expect("example-bulb declares a Status format")
    }

    /// The opcodes `BulbCommands::apply` understands are the ones the spec's
    /// commands encode; a drift in either would make demo Off a no-op.
    #[test]
    fn bulb_opcodes_match_the_vendored_spec() {
        use crate::codec::types::encode_command;
        let spec = example_bulb();
        let (_, command_char) = spec
            .find_characteristic_where(BULB_COMMAND_UUID, |c| c.commands.is_some())
            .expect("example-bulb declares a Command characteristic");
        let commands = command_char.commands.as_ref().unwrap();
        let encode = |name: &str, params: &[(&str, f64)]| {
            let params = params.iter().map(|(k, v)| (k.to_string(), *v)).collect();
            encode_command(&commands[name], &params).unwrap()
        };
        let mut state = MockDeviceState::new();
        let format = bulb_status_format();
        state.write(BULB_COMMAND_UUID, encode("power_off", &[]));
        state.write(
            BULB_COMMAND_UUID,
            encode("set_brightness", &[("brightness", 30.0)]),
        );
        state.write(
            BULB_COMMAND_UUID,
            encode("set_color", &[("red", 1.0), ("green", 2.0), ("blue", 3.0)]),
        );
        assert_eq!(state.read(BULB_STATUS_UUID, &format), vec![0, 30, 1, 2, 3]);
        state.write(BULB_COMMAND_UUID, encode("power_on", &[]));
        assert_eq!(state.read(BULB_STATUS_UUID, &format), vec![1, 30, 1, 2, 3]);
    }

    /// fff1/fff2 are shared by a dozen catalogue specs. A bulb-shaped write
    /// to an Inkbird's fff1 config used to rewrite byte 1 of the temperature
    /// its fff2 reads back.
    #[test]
    fn a_non_bulb_fff2_is_not_overlaid() {
        let inkbird = parse(include_str!(
            "../../../vendor/protocol-specs/device-specs/devices/inkbird-ibs-th.yaml"
        ));
        let format = inkbird
            .find_decodable_characteristic(BULB_STATUS_UUID)
            .and_then(|(_, c)| c.format.clone())
            .expect("inkbird-ibs-th declares an fff2 format");
        let mut state = MockDeviceState::new();
        let before = state.read(BULB_STATUS_UUID, &format);
        state.write(BULB_COMMAND_UUID, vec![0x02, 0x1e]);
        state.write(BULB_COMMAND_UUID, vec![0x01, 0x00]);
        assert_eq!(state.read(BULB_STATUS_UUID, &format), before);
    }

    /// A short direct status write stays short, and a command sets only the
    /// bytes it has, exactly as the Dart fallback's test ("a short bulb
    /// status stays short, as in the simulator") pins; the two paths
    /// disagreed on this before.
    #[test]
    fn short_status_write_stays_short() {
        let mut state = MockDeviceState::new();
        let format = bulb_status_format();
        state.write(BULB_STATUS_UUID, vec![0]);
        state.write(BULB_COMMAND_UUID, vec![0x02, 30]);
        assert_eq!(state.read(BULB_STATUS_UUID, &format), vec![0]);
        state.write(BULB_COMMAND_UUID, vec![0x01, 1]);
        assert_eq!(state.read(BULB_STATUS_UUID, &format), vec![1]);
    }

    #[test]
    fn bulb_status_follows_its_commands() {
        let mut state = MockDeviceState::new();
        let format = bulb_status_format();
        assert_eq!(
            state.read(BULB_STATUS_UUID, &format),
            vec![1, 80, 255, 180, 50]
        );

        // Demo mode's Off used to be undone by the next status poll.
        state.write(BULB_COMMAND_UUID, vec![0x01, 0x00]);
        assert_eq!(
            state.read(BULB_STATUS_UUID, &format),
            vec![0, 80, 255, 180, 50]
        );

        state.write(BULB_COMMAND_UUID, vec![0x02, 30]);
        state.write(BULB_COMMAND_UUID, vec![0x03, 1, 2, 3]);
        // Case differs from the constant: keys are normalized.
        state.write(&BULB_COMMAND_UUID.to_ascii_uppercase(), vec![0x01, 0x01]);
        assert_eq!(state.read(BULB_STATUS_UUID, &format), vec![1, 30, 1, 2, 3]);
    }

    #[test]
    fn bulb_ignores_what_is_not_a_command() {
        let mut state = MockDeviceState::new();
        let format = bulb_status_format();
        // Wrong length for its opcode, and an unknown opcode.
        state.write(BULB_COMMAND_UUID, vec![0x01]);
        state.write(BULB_COMMAND_UUID, vec![0x03, 1, 2]);
        state.write(BULB_COMMAND_UUID, vec![0x09, 0x00]);
        assert_eq!(
            state.read(BULB_STATUS_UUID, &format),
            vec![1, 80, 255, 180, 50]
        );
    }

    #[test]
    fn defaults_are_sensible() {
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
                name: "battery_percent".into(),
                field_type: ValueType::Uint8,
                ..Default::default()
            },
        ];
        let bytes = generate_defaults(&fields);
        assert_eq!(bytes[0], 1); // bool: on
        assert_eq!(bytes[1], 80); // brightness: 80
        assert_eq!(bytes[2], 85); // battery: 85
    }

    #[test]
    fn mock_default_overrides_heuristic_for_uint8() {
        // Field name "brightness" would heuristically default to 80; the
        // explicit `mock_default: 99` should win.
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "brightness".into(),
            field_type: ValueType::Uint8,
            mock_default: Some(serde_yaml::Value::Number(99.into())),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![99]);
    }

    #[test]
    fn mock_default_true_for_bool() {
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "power".into(),
            field_type: ValueType::Bool,
            mock_default: Some(serde_yaml::Value::Bool(true)),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![1]);
    }

    #[test]
    fn mock_default_false_for_bool() {
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "power".into(),
            field_type: ValueType::Bool,
            mock_default: Some(serde_yaml::Value::Bool(false)),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![0]);
    }

    #[test]
    fn mock_default_wrong_type_falls_back_to_heuristic() {
        // String value on a uint8 field — coerce returns None, heuristic kicks in.
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "brightness".into(),
            field_type: ValueType::Uint8,
            mock_default: Some(serde_yaml::Value::String("nope".into())),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![80]); // heuristic for "brightness"
    }

    #[test]
    fn mock_default_out_of_range_falls_back_to_heuristic() {
        // 999 doesn't fit in uint8 — must fall back to heuristic, not wrap to 231.
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "brightness".into(),
            field_type: ValueType::Uint8,
            mock_default: Some(serde_yaml::Value::Number(999.into())),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![80]); // heuristic, not 999 % 256
    }

    #[test]
    fn mock_default_negative_for_uint_falls_back_to_heuristic() {
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "brightness".into(),
            field_type: ValueType::Uint8,
            mock_default: Some(serde_yaml::Value::Number((-1).into())),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![80]); // heuristic, not 255
    }

    #[test]
    fn mock_default_int16_below_range_falls_back() {
        // i16 minimum is -32768; -40000 wraps if cast unchecked.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temp".into(),
            field_type: ValueType::Int16,
            mock_default: Some(serde_yaml::Value::Number((-40000).into())),
            ..Default::default()
        }];
        // Heuristic for Int16: 220 LE → [0xDC, 0x00].
        assert_eq!(generate_defaults(&fields), vec![0xDC, 0x00]);
    }

    #[test]
    fn mock_default_two_for_bool_falls_back_to_heuristic() {
        // Bool's integer range is 0..=1; anything else falls back.
        let fields = vec![FormatField {
            offset: 0,
            length: 1,
            name: "power".into(),
            field_type: ValueType::Bool,
            mock_default: Some(serde_yaml::Value::Number(2.into())),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), vec![1]); // heuristic: bool default-on
    }

    #[test]
    fn mock_default_uint16_le() {
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "lux".into(),
            field_type: ValueType::Uint16,
            mock_default: Some(serde_yaml::Value::Number(1234.into())),
            ..Default::default()
        }];
        // 1234 = 0x04D2, little-endian = [0xD2, 0x04]
        assert_eq!(generate_defaults(&fields), vec![0xD2, 0x04]);
    }

    /// A big-endian field is mocked in big-endian order, so the value the
    /// simulator chose is the value `decode_field` reads back. Before, every
    /// width was written little-endian: 1234 read back as 0xD204 = 53764.
    #[test]
    fn big_endian_fields_round_trip_through_decode_field() {
        use crate::codec::types::{decode_field, DecodedValue};
        let big = |name: &str, ty: ValueType, length: usize, default: Option<i64>| FormatField {
            offset: 0,
            length,
            name: name.into(),
            field_type: ty,
            endianness: Some("big".into()),
            mock_default: default.map(|d| serde_yaml::Value::Number(d.into())),
            ..Default::default()
        };
        let pinned = big("lux", ValueType::Uint16, 2, Some(1234));
        assert_eq!(
            generate_defaults(std::slice::from_ref(&pinned)),
            vec![0x04, 0xD2]
        );

        let uint24 = big("count", ValueType::Uint24, 3, Some(0x0A0B0C));
        assert_eq!(
            generate_defaults(std::slice::from_ref(&uint24)),
            vec![0x0A, 0x0B, 0x0C]
        );

        // The heuristic path too: the Beurer cuff's `systolic_sfloat` shape.
        let heuristic = big("systolic_sfloat", ValueType::Uint16, 2, None);
        let int16 = big("t", ValueType::Int16, 2, Some(-300));
        let int32 = big("e", ValueType::Int32, 4, Some(-70000));
        let uint32 = big("u", ValueType::Uint32, 4, Some(3_000_000_000));
        for (field, want) in [
            (&pinned, 1234.0),
            (&uint24, f64::from(0x0A0B0Cu32)),
            (&heuristic, 100.0),
            (&int16, -300.0),
            (&int32, -70000.0),
            (&uint32, 3_000_000_000.0),
        ] {
            let bytes = generate_defaults(std::slice::from_ref(field));
            let got = match decode_field(&bytes, field).unwrap() {
                DecodedValue::Uint(v) => v as f64,
                DecodedValue::Int(v) => v as f64,
                other => panic!("{}: unexpected {other:?}", field.name),
            };
            assert_eq!(got, want, "{} round-trips big-endian", field.name);
        }
    }

    #[test]
    fn scaled_field_defaults_to_a_plausible_physical_reading() {
        // A SIG temperature characteristic is int16 in hundredths of a degree.
        // The simulator has to send the raw count for ~22 C (2200), because the
        // reader now applies the spec's scale — sending 220 would demo a 2.2 C
        // room.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temperature".into(),
            field_type: ValueType::Int16,
            scale: Some(0.01),
            unit: Some("C".into()),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 2200i16.to_le_bytes().to_vec());
    }

    #[test]
    fn unscaled_field_keeps_its_raw_default() {
        // With no declared scale nothing says what the count means, so the
        // historical constant stands rather than a guess.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temperature".into(),
            field_type: ValueType::Int16,
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 220i16.to_le_bytes().to_vec());
    }

    #[test]
    fn mock_default_still_wins_over_a_declared_scale() {
        // An explicit `mock_default` is the spec author speaking directly; the
        // scale-aware heuristic must not override it.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temperature".into(),
            field_type: ValueType::Int16,
            mock_default: Some(serde_yaml::Value::Number(1234.into())),
            scale: Some(0.01),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 1234i16.to_le_bytes().to_vec());
    }

    #[test]
    fn nonsense_scale_does_not_produce_an_infinite_raw_value() {
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temperature".into(),
            field_type: ValueType::Int16,
            scale: Some(0.0),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 22i16.to_le_bytes().to_vec());
    }

    #[test]
    fn value_offset_is_inverted_too() {
        // The Wave Mini's temperature is centikelvin: `scale: 0.01,
        // value_offset: -273.15`. Inverting only the scale would send the
        // count for 22 centi-units — which a reader decodes to −251 °C.
        // raw = (22 − (−273.15)) / 0.01 = 29515.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temperature".into(),
            field_type: ValueType::Uint16,
            scale: Some(0.01),
            value_offset: Some(-273.15),
            unit: Some("°C".into()),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 29515u16.to_le_bytes().to_vec());
    }

    #[test]
    fn offset_only_transform_still_lands_on_the_nominal_reading() {
        // A field with `value_offset` but no `scale` decodes as `raw + offset`,
        // so the simulator must send `nominal − offset` rather than fall back
        // to a raw constant the offset would then distort.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "temperature".into(),
            field_type: ValueType::Int16,
            value_offset: Some(-40.0),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 62i16.to_le_bytes().to_vec());
    }

    #[test]
    fn pressure_nominal_follows_the_declared_unit() {
        // "Plausible" pressure spans three orders of magnitude depending on
        // unit. The SIG pressure characteristic (uint32, 0.1 Pa resolution,
        // spec'd here as scale 0.001 → hPa) should demo sea level, not the
        // stratosphere.
        let hpa = FormatField {
            offset: 0,
            length: 4,
            name: "pressure".into(),
            field_type: ValueType::Uint32,
            scale: Some(0.001),
            unit: Some("hPa".into()),
            ..Default::default()
        };
        assert_eq!(
            generate_defaults(std::slice::from_ref(&hpa)),
            1_013_000u32.to_le_bytes().to_vec()
        );

        // Airthings' combined packet declares pressure in raw pascals at
        // scale 2 — 50650 × 2 = 101300 Pa, sea level again.
        let pa = FormatField {
            offset: 0,
            length: 2,
            name: "pressure".into(),
            field_type: ValueType::Uint16,
            scale: Some(2.0),
            unit: Some("Pa".into()),
            ..Default::default()
        };
        assert_eq!(
            generate_defaults(std::slice::from_ref(&pa)),
            50650u16.to_le_bytes().to_vec()
        );
    }

    #[test]
    fn air_quality_fields_default_to_healthy_home_values() {
        // Radon/CO₂/VOC fields carry no scale (raw counts are the unit), so
        // they take the uint16 name defaults. The demo should look like a
        // home, not an incident — and 100 Bq/m³ sat exactly on the radon
        // "fair" line.
        let field = |name: &str| FormatField {
            offset: 0,
            length: 2,
            name: name.into(),
            field_type: ValueType::Uint16,
            ..Default::default()
        };
        for (name, want) in [
            ("radon_24h_avg", 55u16),
            ("radon_longterm_avg", 55),
            ("co2", 650),
            ("voc", 120),
        ] {
            assert_eq!(
                generate_defaults(std::slice::from_ref(&field(name))),
                want.to_le_bytes().to_vec(),
                "{name}"
            );
        }
    }

    #[test]
    fn dew_point_reads_as_dew_point_not_room_temperature() {
        // "dew_point" contains no "temp", but the rule is ordered anyway:
        // a dew-point field must not take the 22 °C room nominal, which
        // would demo a swamp.
        let fields = vec![FormatField {
            offset: 0,
            length: 2,
            name: "dew_point".into(),
            field_type: ValueType::Int16,
            scale: Some(0.01),
            unit: Some("°C".into()),
            ..Default::default()
        }];
        assert_eq!(generate_defaults(&fields), 1200i16.to_le_bytes().to_vec());
    }

    /// H1 regression: the parser deliberately tolerates a fixed-width type
    /// over a longer field (`type: uint16, length: 3`), so the simulator must
    /// write only the low `fixed_byte_size()` bytes and leave the tail zero —
    /// a whole-slice `copy_from_slice` panics on exactly those specs, and
    /// this path is reachable from Dart via `mock_read_characteristic`.
    /// Covers both the heuristic path and the `mock_default` → `write_value`
    /// path.
    #[test]
    fn overlong_fixed_fields_write_low_bytes_only() {
        struct Case {
            label: &'static str,
            field: FormatField,
            want: Vec<u8>,
        }
        let cases = [
            Case {
                label: "uint16 over 3 bytes, heuristic value",
                field: FormatField {
                    offset: 0,
                    length: 3,
                    name: "lux".into(), // heuristic: 500 = 0x01F4
                    field_type: ValueType::Uint16,
                    ..Default::default()
                },
                want: vec![0xF4, 0x01, 0x00],
            },
            Case {
                label: "uint16 over 3 bytes, mock_default (write_value path)",
                field: FormatField {
                    offset: 0,
                    length: 3,
                    name: "lux".into(),
                    field_type: ValueType::Uint16,
                    mock_default: Some(serde_yaml::Value::Number(0x1234.into())),
                    ..Default::default()
                },
                want: vec![0x34, 0x12, 0x00],
            },
            Case {
                label: "int16 over 4 bytes, heuristic value",
                field: FormatField {
                    offset: 0,
                    length: 4,
                    name: "reading".into(), // Int16 heuristic: 220 = 0x00DC
                    field_type: ValueType::Int16,
                    ..Default::default()
                },
                want: vec![0xDC, 0x00, 0x00, 0x00],
            },
            Case {
                label: "uint32 over 8 bytes, mock_default (write_value path)",
                field: FormatField {
                    offset: 0,
                    length: 8,
                    name: "counter".into(),
                    field_type: ValueType::Uint32,
                    mock_default: Some(serde_yaml::Value::Number(0xAABB_CCDDi64.into())),
                    ..Default::default()
                },
                want: vec![0xDD, 0xCC, 0xBB, 0xAA, 0, 0, 0, 0],
            },
            Case {
                label: "uint32 over 8 bytes, no default stays all zeros",
                field: FormatField {
                    offset: 0,
                    length: 8,
                    name: "counter".into(),
                    field_type: ValueType::Uint32,
                    ..Default::default()
                },
                want: vec![0; 8],
            },
        ];
        for Case { label, field, want } in cases {
            assert_eq!(
                generate_defaults(std::slice::from_ref(&field)),
                want,
                "{label}"
            );
        }
    }

    #[test]
    fn read_raw_returns_zero_buffer_then_written_value() {
        let mut state = MockDeviceState::new();
        let uuid = "0000FFF9-0000-1000-8000-00805F9B34FB";

        // No prior write: a zero buffer of exactly the requested length.
        assert_eq!(state.read_raw(uuid, 4), vec![0u8; 4]);

        // After a write, the stored value comes back verbatim (regardless of
        // the requested fallback length). Write lowercase / read uppercase to
        // pin the ASCII-lowercased key normalization shared by write/read.
        state.write(&uuid.to_ascii_lowercase(), vec![9, 8, 7]);
        assert_eq!(state.read_raw(uuid, 4), vec![9, 8, 7]);
    }
}

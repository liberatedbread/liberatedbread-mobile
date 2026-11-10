// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! AC Infinity UIS controllers: climate and port state over BLE, read-only.
//!
//! The `acinfinity-uis-controller` spec's `protocol_details.frame` states the
//! A5 envelope and `controller_stream` the status frame. Dart owns GATT.
//!
//! ```text
//! frame:  [a5][00][len u16][seq u16][crc16 of bytes 0-5][00][opcode][payload][crc16 from the 00]
//! status: [1e ff 02 09][kind][body length][flags][selected port][climate][port blocks]
//! ```
//!
//! Three status layouts, chosen the way the spec chooses them: by the
//! advertisement's device type and protocol revision (manufacturer payload
//! bytes 12 and 11). The multi-port controller's (`controller_stream.layout`),
//! the one below revision 5 (`controller_stream.legacy_layout`), and the power
//! strip's AI-family frame (`power_strip_stream`). The spec prints a frame for
//! the first alone, and only for four ports; none of the three has been run
//! against hardware here. A field the spec does not state for a layout is left
//! empty, never borrowed from another layout.
//!
//! READ-ONLY BY CONSTRUCTION, and this is the one that needs it most: every
//! port can switch a heater or a humidifier. The envelope builder is private
//! and its only public caller builds opcode 0x01, a read of a fixed selector
//! list. A write (0x03) and the undocumented reset (0x08) have no path out of
//! this file. Settings are not a special case: whether a single settings item
//! is even safe to write is an open question in the spec.

use crate::error::ProtocolError;

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "acinfinity_a5";

pub const SERVICE: &str = "70d51000-2c7f-4e75-ae8a-d758951ce4e0";
pub const COMMAND_CHARACTERISTIC: &str = "70d51001-2c7f-4e75-ae8a-d758951ce4e0";
pub const NOTIFY_CHARACTERISTIC: &str = "70d51002-2c7f-4e75-ae8a-d758951ce4e0";

const OPCODE_READ: u8 = 0x01;
const STREAM_MARKER: [u8; 4] = [0x1e, 0xff, 0x02, 0x09];
const FRAME_OVERHEAD: usize = 12;
const NO_READING: u16 = 0x8000;
const EMPTY_PORT: u16 = 0xffff;
const SELECTOR_OFF_LEVEL: u8 = 0x11;
const SELECTOR_ON_LEVEL: u8 = 0x12;
const FIRST_PORT_BLOCK: usize = 22;
const PORT_BLOCK: usize = 8;

/// The controller layout's frame sizes: four ports (captured) and eight. The
/// spec's Controller 69 Pro+ variant states 22 + 8 x 8 = 86 with ports 5-8
/// continuing the stride from byte 54, inferred from the four-port layout and
/// never captured, which is why ports 5-8 carry a caveat.
const FOUR_PORT_FRAME: usize = 54;
const EIGHT_PORT_FRAME: usize = 86;

/// `legacy_layout`: 4-byte port records from byte 18, below revision 5.
const FIRST_LEGACY_RECORD: usize = 18;
const LEGACY_RECORD: usize = 4;
const LEGACY_BELOW_REVISION: u8 = 5;
const MAX_PORTS: usize = 8;

/// `power_strip_stream`: the expanded header's fixed part, and record sizes.
const STRIP_HEADER: usize = 13;
const STRIP_RECORD: usize = 10;
const STRIP_SENSOR: usize = 4;
const STRIP_CALIBRATION: usize = 3;

/// `advertisement.payload_lengths`, and where the revision and type sit.
const ADVERT_LENGTHS: [usize; 2] = [17, 27];
const ADVERT_REVISION: usize = 11;
const ADVERT_TYPE: usize = 12;

const FIVE_TO_EIGHT_CAVEAT: &str = "Ports 5-8 are read by the layout the spec \
    infers for eight-port controllers (the four-port stride continued). No \
    eight-port frame has been captured.";
const LEGACY_CAVEAT: &str = "Read by the layout the spec gives for controllers \
    below protocol revision 5, from app analysis only; no such frame has been \
    captured. That layout states no output, fault or empty-port bits, so none \
    are shown.";
const STRIP_CAVEAT: &str = "Read by the power-strip layout the spec reports \
    from app analysis; no strip frame is printed in it. Outlets are numbered \
    by record position, which one source disputes, and their mode values are \
    not given.";
/// Largest frame the reassembler holds. The longest the spec mentions is the
/// 233-byte `read_everything` reply; a length past this is not a frame.
const MAX_FRAME: usize = 1024;

/// Which of the spec's status layouts a frame was read by.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AcInfinityLayout {
    /// `controller_stream.layout`: multi-port controllers at revision 5 or
    /// later, 8-byte port blocks from byte 22.
    Controller,
    /// `controller_stream.legacy_layout`: below revision 5, 4-byte port
    /// records from byte 18. App analysis only.
    LegacyController,
    /// `power_strip_stream`: the UIS power strip's AI-family frame, read by
    /// its expanded header.
    PowerStrip,
}

/// One port, or strip outlet, of the status stream. A field is `None` where
/// the layout that carried it does not state it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcInfinityPortDto {
    /// The 1-based physical port, or the strip outlet by record position.
    pub port: u8,
    /// False when nothing is plugged in; on the controller layout the spec
    /// says the rest of the block is then meaningless, so it stays empty.
    /// `None` on the legacy layout, which states no empty-port value.
    pub occupied: Option<bool>,
    pub load_id: Option<u16>,
    /// The load-type table's text; `None` for a code the table omits.
    pub load_type: Option<String>,
    /// Output level 0-10. `None` for a value outside that range.
    pub level: Option<u8>,
    pub output_on: Option<bool>,
    pub fault: Option<bool>,
    pub overcurrent: Option<bool>,
    pub mode_code: u8,
    /// The mode table's text; `None` for a code the table omits, and always on
    /// the strip, whose mode values the spec does not give.
    pub mode: Option<String>,
}

/// One of the power strip's sensor records.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcInfinitySensorDto {
    pub sensor_id: u8,
    /// The sensor-id table's text; `None` for an id the table omits.
    pub name: Option<String>,
    pub unit: Option<String>,
    /// The scaled value in hundredths, so the record's x10 to x0.01 scales
    /// all stay integers. `None` is the spec's "no reading".
    pub value_hundredths: Option<i32>,
    /// How many decimals the record's accuracy carries (0-2).
    pub decimals: u8,
}

/// A decoded status frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcInfinityStatusDto {
    pub layout: AcInfinityLayout,
    /// `None` where the layout does not state it.
    pub display_celsius: Option<bool>,
    pub selected_port: Option<u8>,
    /// Hundredths of a degree C, of a percent and of a kPa. `None` is the
    /// spec's "no probe" value, and always on the strip, which reports
    /// [`Self::sensors`] instead. Integers so the screen rounds, not this file.
    pub temperature_centi_c: Option<i16>,
    pub humidity_centi_percent: Option<i16>,
    pub vpd_centi_kpa: Option<i16>,
    pub ports: Vec<AcInfinityPortDto>,
    /// The strip's sensor records; empty on the controller layouts.
    pub sensors: Vec<AcInfinitySensorDto>,
    /// What this reading rests on that nobody has captured, for the screen to
    /// say. `None` for the four-port controller frame.
    pub caveat: Option<String>,
}

/// The stored levels `get_model_data` answers with for one port.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcInfinityStoredDto {
    pub port: u8,
    pub off_level: Option<u8>,
    /// As read: the level at revision 7 and below, or a packed manual and
    /// maximum level above it. The revision is not known here, so it is not
    /// interpreted.
    pub on_level_raw: Option<u8>,
}

/// What a batch of notification bytes assembled into, and what is left over.
/// The buffers go back in with the next chunk.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct AcInfinityFeedDto {
    pub frame_buffer: Vec<u8>,
    pub status_buffer: Vec<u8>,
    pub frames: Vec<Vec<u8>>,
}

fn malformed(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::MalformedReply(reason.into())
}

/// CRC-16/CCITT-FALSE: polynomial 0x1021, init 0xffff, no reflection.
fn crc16(data: &[u8]) -> u16 {
    let mut crc = 0xffffu16;
    for byte in data {
        crc ^= u16::from(*byte) << 8;
        for _ in 0..8 {
            crc = if crc & 0x8000 != 0 {
                (crc << 1) ^ 0x1021
            } else {
                crc << 1
            };
        }
    }
    crc
}

/// Wrap an inner span in the envelope. Private on purpose: this would frame a
/// write as readily as a read, so it is reachable only through
/// [`encode_get_model_data`].
fn envelope(inner: &[u8], sequence: u16) -> Vec<u8> {
    let payload = inner.len() - 2;
    let mut out = Vec::with_capacity(inner.len() + 10);
    out.extend_from_slice(&[0xa5, 0x00]);
    out.extend_from_slice(&(payload as u16).to_be_bytes());
    out.extend_from_slice(&sequence.to_be_bytes());
    let head = crc16(&out);
    out.extend_from_slice(&head.to_be_bytes());
    out.extend_from_slice(inner);
    out.extend_from_slice(&crc16(inner).to_be_bytes());
    out
}

/// `get_model_data`: one port's stored mode and parameters. Opcode 0x01, the
/// spec's fixed selector list, and the only frame this module sends.
pub fn encode_get_model_data(port: u8, sequence: u16) -> Result<Vec<u8>, ProtocolError> {
    if !(1..=8).contains(&port) {
        return Err(ProtocolError::ParameterOutOfRange {
            name: "port".to_string(),
            value: f64::from(port),
            min: 1.0,
            max: 8.0,
        });
    }
    Ok(envelope(
        &[
            0x00,
            OPCODE_READ,
            0x10,
            0x11,
            SELECTOR_ON_LEVEL,
            0x13,
            0x14,
            0x15,
            0x16,
            0x17,
            0xff,
            port,
        ],
        sequence,
    ))
}

/// A checked A5 frame's sequence, opcode and payload. Both CRCs, the length,
/// and the a5 00..a5 1f family the spec says a reply can carry in byte 1.
fn checked_frame(frame: &[u8]) -> Result<(u16, u8, &[u8]), ProtocolError> {
    if frame.len() < FRAME_OVERHEAD {
        return Err(ProtocolError::BufferTooShort {
            needed: FRAME_OVERHEAD,
            got: frame.len(),
        });
    }
    if frame[0] != 0xa5 || frame[1] > 0x1f {
        return Err(malformed("not an A5 frame"));
    }
    let payload = usize::from(u16::from_be_bytes([frame[2], frame[3]]));
    if frame.len() != payload + FRAME_OVERHEAD {
        return Err(malformed(format!(
            "a {payload} byte payload does not fit a {} byte frame",
            frame.len()
        )));
    }
    if crc16(&frame[..6]) != u16::from_be_bytes([frame[6], frame[7]]) {
        return Err(malformed("the head CRC does not match"));
    }
    let tail = frame.len() - 2;
    if crc16(&frame[8..tail]) != u16::from_be_bytes([frame[tail], frame[tail + 1]]) {
        return Err(malformed("the tail CRC does not match"));
    }
    if frame[8] != 0 {
        return Err(malformed("byte 8 of an A5 frame is zero"));
    }
    Ok((
        u16::from_be_bytes([frame[4], frame[5]]),
        frame[9],
        &frame[10..tail],
    ))
}

/// Decode the reply to [`encode_get_model_data`]. The reply is matched as the
/// spec says to, on echoed sequence and opcode, and must name the same port.
pub fn decode_model_data(
    frame: &[u8],
    sequence: u16,
    port: u8,
) -> Result<AcInfinityStoredDto, ProtocolError> {
    let (echoed, opcode, payload) = checked_frame(frame)?;
    if echoed != sequence || opcode != OPCODE_READ {
        return Err(malformed(format!(
            "seq {echoed} opcode 0x{opcode:02x} does not answer seq {sequence}"
        )));
    }
    let mut stored = AcInfinityStoredDto {
        port,
        off_level: None,
        on_level_raw: None,
    };
    let mut rest = payload;
    loop {
        match rest {
            [] => return Err(malformed("the reply has no port trailer")),
            [0xff, trailer] => {
                if *trailer != port {
                    return Err(malformed(format!(
                        "the reply names port {trailer}, not {port}"
                    )));
                }
                return Ok(stored);
            }
            [selector, length, tail @ ..] => {
                let length = usize::from(*length);
                if tail.len() < length {
                    return Err(malformed(format!(
                        "selector 0x{selector:02x} promises {length} bytes"
                    )));
                }
                let (value, after) = tail.split_at(length);
                match (*selector, value) {
                    (SELECTOR_OFF_LEVEL, [level]) => stored.off_level = Some(*level),
                    (SELECTOR_ON_LEVEL, [level]) => stored.on_level_raw = Some(*level),
                    _ => {}
                }
                rest = after;
            }
            _ => return Err(malformed("the reply ends inside an item")),
        }
    }
}

fn reading(high: u8, low: u8) -> Option<i16> {
    let raw = u16::from_be_bytes([high, low]);
    (raw != NO_READING).then_some(raw as i16)
}

/// The notify format's `portN_mode` values.
fn mode_name(code: u8) -> Option<&'static str> {
    Some(match code {
        1 => "off",
        2 => "on",
        3 => "auto",
        4 => "countdown, then on",
        5 => "countdown, then off",
        6 => "cycle",
        7 => "schedule",
        8 => "VPD",
        _ => return None,
    })
}

/// The notify format's `portN_load_type` values. The app's table is reported,
/// and upstream's controller captures read 0 throughout.
fn load_type_name(code: u8) -> Option<&'static str> {
    Some(match code {
        0 => "not reported",
        1 | 129 => "light",
        2 | 130 => "humidifier",
        3 | 131 => "dehumidifier",
        4 | 132 => "heater",
        5 | 133 => "air conditioner",
        6 | 7 | 134 | 135 => "fan",
        128 => "outlet",
        _ => return None,
    })
}

/// `power_strip_stream.sensor_record` ids. The records do not state VPD's
/// unit, so it is left out.
fn sensor_name(id: u8) -> Option<(&'static str, Option<&'static str>)> {
    Some(match id {
        0 => ("probe temperature", Some("°F")),
        1 => ("probe temperature", Some("°C")),
        2 => ("probe humidity", Some("%")),
        3 => ("probe VPD", None),
        4 => ("zone temperature", Some("°F")),
        5 => ("zone temperature", Some("°C")),
        6 => ("zone humidity", Some("%")),
        7 => ("zone VPD", None),
        _ => return None,
    })
}

/// An empty port whose every other field is unstated.
fn empty_port(port: u8) -> AcInfinityPortDto {
    AcInfinityPortDto {
        port,
        occupied: Some(false),
        load_id: None,
        load_type: None,
        level: None,
        output_on: None,
        fault: None,
        overcurrent: None,
        mode_code: 0,
        mode: None,
    }
}

fn level_of(raw: u8) -> Option<u8> {
    (raw <= 10).then_some(raw)
}

/// `controller_stream.layout`: [load id u16 BE, ff ff = empty][run bits 7-6,
/// level bits 5-2, output on bit 1, fault bit 0][overcurrent bit 7, program
/// bits 6-4, mode bits 3-0][3 unresolved bytes][load type].
fn port_block(port: u8, block: &[u8; PORT_BLOCK]) -> AcInfinityPortDto {
    let load_id = u16::from_be_bytes([block[0], block[1]]);
    if load_id == EMPTY_PORT {
        return empty_port(port);
    }
    let state = block[2];
    let mode = block[3];
    AcInfinityPortDto {
        port,
        occupied: Some(true),
        load_id: Some(load_id),
        load_type: load_type_name(block[7]).map(str::to_string),
        level: level_of((state >> 2) & 0x0f),
        output_on: Some(state & 0x02 != 0),
        fault: Some(state & 0x01 != 0),
        overcurrent: Some(mode & 0x80 != 0),
        mode_code: mode & 0x0f,
        mode: mode_name(mode & 0x0f).map(str::to_string),
    }
}

/// `controller_stream.legacy_layout`: [load id u16 BE][state][level high
/// nibble, mode low nibble]. The state byte's bits, an empty-port value and a
/// load type are not stated, so they stay `None`. The mode nibble is named by
/// the port-mode table, which the spec numbers the same as `set_port_mode`.
fn legacy_record(port: u8, record: &[u8; LEGACY_RECORD]) -> AcInfinityPortDto {
    let mode = record[3] & 0x0f;
    AcInfinityPortDto {
        port,
        occupied: None,
        load_id: Some(u16::from_be_bytes([record[0], record[1]])),
        load_type: None,
        level: level_of(record[3] >> 4),
        output_on: None,
        fault: None,
        overcurrent: None,
        mode_code: mode,
        mode: mode_name(mode).map(str::to_string),
    }
}

/// `power_strip_stream.port_record`: [id u16 BE, 0xff first byte = nothing
/// connected][second id u16 BE][load type][state: level bits 5-2, output on
/// bit 1, fault bit 0][mode, low 5 bits][3 unresolved bytes]. The relay state
/// is read whether or not a load is connected: unlike the controller block,
/// the spec does not call the rest of an unconnected record meaningless.
fn strip_record(outlet: u8, record: &[u8; STRIP_RECORD]) -> AcInfinityPortDto {
    let occupied = record[0] != 0xff;
    let state = record[5];
    AcInfinityPortDto {
        port: outlet,
        occupied: Some(occupied),
        load_id: occupied.then(|| u16::from_be_bytes([record[0], record[1]])),
        load_type: occupied
            .then(|| load_type_name(record[4]))
            .flatten()
            .map(str::to_string),
        level: level_of((state >> 2) & 0x0f),
        output_on: Some(state & 0x02 != 0),
        fault: Some(state & 0x01 != 0),
        overcurrent: None,
        mode_code: record[6] & 0x1f,
        mode: None,
    }
}

/// `power_strip_stream.sensor_record`: [sensor id][flags, accuracy in bits
/// 6-5][value int16 BE], scaled x10, x1, x0.1 or x0.01 by accuracy 0-3.
fn sensor_record(record: &[u8; STRIP_SENSOR]) -> AcInfinitySensorDto {
    let accuracy = (record[1] >> 5) & 0x03;
    let to_hundredths = [1000, 100, 10, 1][usize::from(accuracy)];
    let (name, unit) = sensor_name(record[0]).unzip();
    AcInfinitySensorDto {
        sensor_id: record[0],
        name: name.map(str::to_string),
        unit: unit.flatten().map(str::to_string),
        value_hundredths: reading(record[2], record[3]).map(|v| i32::from(v) * to_hundredths),
        decimals: accuracy.saturating_sub(1),
    }
}

/// The advertisement's protocol revision and device type, from the
/// manufacturer payload after the company id. Any other length says nothing.
fn identity(advertisement: &[u8]) -> Option<(u8, u8)> {
    ADVERT_LENGTHS
        .contains(&advertisement.len())
        .then(|| (advertisement[ADVERT_REVISION], advertisement[ADVERT_TYPE]))
}

/// `device.variants`: the types the app routes through the 69 Pro's
/// multi-port path, and the AI-family power strips.
const MULTI_PORT_TYPES: [u8; 9] = [7, 8, 9, 11, 12, 16, 17, 18, 23];
const STRIP_TYPES: [u8; 2] = [21, 22];

/// Decode a status stream frame by the layout the unit's advertisement picks.
///
/// `advertisement` is the manufacturer payload for company 0x0902, after the
/// company id. A power-strip type is read by `power_strip_stream`; a
/// multi-port controller below revision 5 by the legacy layout, and at 5 or
/// later by the controller layout. Without an advertisement only the
/// controller layout's own sizes are read, as before: the other two cannot be
/// told apart from it by length. Single-port and AI-series types, whose
/// stream the spec does not state, are refused.
pub fn decode_status(
    frame: &[u8],
    advertisement: Option<&[u8]>,
) -> Result<AcInfinityStatusDto, ProtocolError> {
    if frame.len() < 6 {
        return Err(ProtocolError::BufferTooShort {
            needed: 6,
            got: frame.len(),
        });
    }
    if frame[..4] != STREAM_MARKER {
        return Err(malformed("not a status frame"));
    }
    if frame.len() != 6 + usize::from(frame[5]) {
        return Err(malformed(format!(
            "body length {} does not fit a {} byte frame",
            frame[5],
            frame.len()
        )));
    }
    match advertisement.and_then(identity) {
        Some((_, kind)) if STRIP_TYPES.contains(&kind) => decode_strip(frame),
        Some((revision, kind)) if MULTI_PORT_TYPES.contains(&kind) => {
            if revision < LEGACY_BELOW_REVISION {
                decode_legacy(frame)
            } else {
                decode_controller(frame)
            }
        }
        Some((_, kind)) => Err(malformed(format!(
            "device type {kind} streams a layout the spec does not state"
        ))),
        None => decode_controller(frame),
    }
}

fn decode_controller(frame: &[u8]) -> Result<AcInfinityStatusDto, ProtocolError> {
    if frame.len() != FOUR_PORT_FRAME && frame.len() != EIGHT_PORT_FRAME {
        return Err(malformed(format!(
            "a {} byte status frame is not the multi-port controller layout",
            frame.len()
        )));
    }
    let ports = frame[FIRST_PORT_BLOCK..]
        .as_chunks::<PORT_BLOCK>()
        .0
        .iter()
        .enumerate()
        .map(|(index, block)| port_block(index as u8 + 1, block))
        .collect();
    Ok(AcInfinityStatusDto {
        layout: AcInfinityLayout::Controller,
        display_celsius: Some(frame[6] & 0x80 != 0),
        selected_port: Some(frame[7] & 0x0f),
        temperature_centi_c: reading(frame[8], frame[9]),
        humidity_centi_percent: reading(frame[10], frame[11]),
        vpd_centi_kpa: reading(frame[12], frame[13]),
        ports,
        sensors: Vec::new(),
        caveat: (frame.len() == EIGHT_PORT_FRAME).then(|| FIVE_TO_EIGHT_CAVEAT.to_string()),
    })
}

/// "Same climate fields" is all the legacy layout says of the header, so the
/// display flag and selected port at bytes 6-7 are not read.
fn decode_legacy(frame: &[u8]) -> Result<AcInfinityStatusDto, ProtocolError> {
    let records = frame.len().saturating_sub(FIRST_LEGACY_RECORD);
    if records == 0 || !records.is_multiple_of(LEGACY_RECORD) || records / LEGACY_RECORD > MAX_PORTS
    {
        return Err(malformed(format!(
            "a {} byte status frame is not 4-byte port records from byte 18",
            frame.len()
        )));
    }
    let ports = frame[FIRST_LEGACY_RECORD..]
        .as_chunks::<LEGACY_RECORD>()
        .0
        .iter()
        .enumerate()
        .map(|(index, record)| legacy_record(index as u8 + 1, record))
        .collect();
    Ok(AcInfinityStatusDto {
        layout: AcInfinityLayout::LegacyController,
        display_celsius: None,
        selected_port: None,
        temperature_centi_c: reading(frame[8], frame[9]),
        humidity_centi_percent: reading(frame[10], frame[11]),
        vpd_centi_kpa: reading(frame[12], frame[13]),
        ports,
        sensors: Vec::new(),
        caveat: Some(LEGACY_CAVEAT.to_string()),
    })
}

/// The expanded header only: byte 7 low 6 bits count sensor records, byte 11
/// high nibble port records (record 0 is the strip) and low nibble the
/// selected port, byte 12 low nibble 3-byte calibration records from byte 13.
/// The spec's own check, 13 + records x 10 + sensors x 4 + calibration x 3,
/// must give the frame length. The original header form ("the counts sit in
/// byte 8 and byte 9 instead") is not stated fully enough to read, so a frame
/// failing the check is refused.
fn decode_strip(frame: &[u8]) -> Result<AcInfinityStatusDto, ProtocolError> {
    if frame.len() < STRIP_HEADER {
        return Err(ProtocolError::BufferTooShort {
            needed: STRIP_HEADER,
            got: frame.len(),
        });
    }
    let sensors = usize::from(frame[7] & 0x3f);
    let records = usize::from(frame[11] >> 4);
    let calibration = usize::from(frame[12] & 0x0f);
    let first_record = STRIP_HEADER + calibration * STRIP_CALIBRATION;
    let first_sensor = first_record + records * STRIP_RECORD;
    let expected = first_sensor + sensors * STRIP_SENSOR;
    if records == 0 || expected != frame.len() {
        return Err(malformed(format!(
            "a {} byte strip frame is not the expanded header, whose counts \
             promise {expected} bytes",
            frame.len()
        )));
    }
    let ports = frame[first_record..first_sensor]
        .as_chunks::<STRIP_RECORD>()
        .0
        .iter()
        .enumerate()
        .skip(1)
        .map(|(index, record)| strip_record(index as u8, record))
        .collect();
    let sensors = frame[first_sensor..]
        .as_chunks::<STRIP_SENSOR>()
        .0
        .iter()
        .map(sensor_record)
        .collect();
    Ok(AcInfinityStatusDto {
        layout: AcInfinityLayout::PowerStrip,
        display_celsius: None,
        selected_port: Some(frame[11] & 0x0f),
        temperature_centi_c: None,
        humidity_centi_percent: None,
        vpd_centi_kpa: None,
        ports,
        sensors,
        caveat: Some(STRIP_CAVEAT.to_string()),
    })
}

/// How long a frame starting with `buffer` will be, once that is known.
fn frame_length(buffer: &[u8]) -> Option<usize> {
    if buffer.first() == Some(&0xa5) {
        let length = buffer.get(2..4)?;
        Some(usize::from(u16::from_be_bytes([length[0], length[1]])) + FRAME_OVERHEAD)
    } else {
        buffer.get(5).map(|body| 6 + usize::from(*body))
    }
}

/// Take any complete frame off the front of `buffer`. Whatever it holds past
/// the frame is handed back to be routed as a fresh chunk. A claimed length
/// past [`MAX_FRAME`] discards the buffer: that is not a frame, and it must
/// not stall the reassembler for good.
fn drain(buffer: &mut Vec<u8>, frames: &mut Vec<Vec<u8>>) -> Vec<u8> {
    let Some(length) = frame_length(buffer) else {
        return Vec::new();
    };
    if length > MAX_FRAME {
        buffer.clear();
        return Vec::new();
    }
    if buffer.len() < length {
        return Vec::new();
    }
    let rest = buffer.split_off(length);
    frames.push(std::mem::take(buffer));
    rest
}

/// Reassemble notifications. "Both may be split across ATT packets", and a
/// status frame can land while a reply is pending, so the spec asks for two
/// buffers: a chunk that opens a frame goes to its own, a chunk that opens
/// nothing continues whichever is waiting, and a chunk that does neither is
/// dropped.
pub fn feed(frame_buffer: &[u8], status_buffer: &[u8], chunk: &[u8]) -> AcInfinityFeedDto {
    let mut out = AcInfinityFeedDto {
        frame_buffer: frame_buffer.to_vec(),
        status_buffer: status_buffer.to_vec(),
        frames: Vec::new(),
    };
    let mut pending = chunk.to_vec();
    while !pending.is_empty() {
        let opens_status = pending.starts_with(&STREAM_MARKER);
        let opens_frame = pending[0] == 0xa5 && out.frame_buffer.is_empty();
        let target = if opens_status {
            out.status_buffer.clear();
            &mut out.status_buffer
        } else if opens_frame {
            &mut out.frame_buffer
        } else if !out.status_buffer.is_empty() {
            &mut out.status_buffer
        } else if !out.frame_buffer.is_empty() {
            &mut out.frame_buffer
        } else {
            break;
        };
        target.extend_from_slice(&pending);
        pending = drain(target, &mut out.frames);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(text: &str) -> Vec<u8> {
        text.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect()
    }

    const CONSTRUCTED_STATUS: &str = "1e ff 02 09 07 30 80 01 08 ca 15 7c 00 7a 00 00 00 01 00 00 00 00 27 10 da 02 00 00 00 00 2e e0 00 01 00 00 00 00 ff ff 00 01 00 00 00 00 ff ff 00 01 00 00 00 00";

    /// The frames in this file are copied by hand; a spec refresh that changes
    /// one should fail here rather than leave these tests proving an old format.
    #[test]
    fn the_literal_frames_are_the_ones_the_spec_prints() {
        let text = std::fs::read_to_string(format!(
            "{}/../vendor/protocol-specs/device-specs/devices/acinfinity-uis-controller.yaml",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap();
        // The spec folds the status example across lines.
        let folded: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
        for vector in [
            CONSTRUCTED_STATUS,
            "a5 00 00 0a 00 00 6b f8 00 01 10 11 12 13 14 15 16 17 ff 01 ff 2b",
            "a5 1c 00 06 00 00 91 e8 00 03 10 00 12 00 ff 01 16 29",
            "a5 00 00 05 00 24 23 2f 00 01 11 12 51 ff 02 a6 e9",
        ] {
            assert!(folded.contains(vector), "{vector} is not in the spec");
        }
    }

    /// `frame.crc.check`.
    #[test]
    fn the_crc_matches_its_check_value() {
        assert_eq!(crc16(b"123456789"), 0x29b1);
    }

    /// Every full frame in `test_vectors`, rebuilt from its inner span. Most
    /// are writes, built here by the private envelope only to prove the CRCs
    /// against the spec's bytes: no public path reaches it with a write.
    #[test]
    fn the_envelope_reproduces_every_spec_vector() {
        for (sequence, frame) in [
            (
                0x0000u16,
                "a5 00 00 05 00 00 47 c9 00 03 10 01 06 ff 01 ec be",
            ),
            (
                0x0000,
                "a5 00 00 0a 00 00 6b f8 00 01 10 11 12 13 14 15 16 17 ff 01 ff 2b",
            ),
            (0x0102, "a5 00 00 05 01 02 54 ba 00 03 10 01 01 ff 02 59 4d"),
            (0xffff, "a5 00 00 05 ff ff 5a c6 00 03 10 01 01 ff 02 59 4d"),
            (0x0103, "a5 00 00 05 01 03 44 9b 00 03 10 01 02 ff 03 10 3c"),
            (0x0010, "a5 00 00 05 00 10 55 f8 00 03 12 01 05 ff 01 f1 6d"),
            (
                0x0007,
                "a5 00 00 08 00 07 75 7f 00 03 51 04 03 0e 08 00 ff 02 26 3a",
            ),
            (
                0x0020,
                "a5 00 00 0e 00 20 93 5a 00 03 13 0a 08 56 1e 20 00 64 00 20 00 00 ff 01 db 7b",
            ),
            (
                0x0021,
                "a5 00 00 08 00 21 31 db 00 03 17 04 07 00 13 00 ff 04 fc 56",
            ),
            (
                0x0022,
                "a5 00 00 0c 00 22 dd 78 00 03 16 08 00 00 03 84 00 00 0a 8c ff 01 6f 2b",
            ),
            (
                0x0023,
                "a5 00 00 08 00 23 11 99 00 03 15 04 00 00 1c 20 ff 02 89 5f",
            ),
            (0x0024, "a5 00 00 05 00 24 23 2f 00 01 11 12 51 ff 02 a6 e9"),
        ] {
            let frame = bytes(frame);
            let inner = &frame[8..frame.len() - 2];
            assert_eq!(envelope(inner, sequence), frame);
            // The same bytes pass the decoder's checks.
            let (echoed, opcode, _) = checked_frame(&frame).unwrap();
            assert_eq!(echoed, sequence);
            assert_eq!(opcode, frame[9]);
        }
    }

    #[test]
    fn the_only_public_frame_is_the_specs_read() {
        assert_eq!(
            encode_get_model_data(1, 0).unwrap(),
            bytes("a5 00 00 0a 00 00 6b f8 00 01 10 11 12 13 14 15 16 17 ff 01 ff 2b")
        );
        assert!(encode_get_model_data(0, 0).is_err());
        assert!(encode_get_model_data(9, 0).is_err());
    }

    /// Opcode 0x01 and the same selectors whatever the port and sequence.
    #[test]
    fn every_request_this_module_builds_is_a_read() {
        for port in 1..=8u8 {
            for sequence in [0u16, 1, 0x0102, 0xffff] {
                let frame = encode_get_model_data(port, sequence).unwrap();
                assert_eq!(frame[9], OPCODE_READ, "opcode");
                assert_eq!(
                    frame[10..frame.len() - 2],
                    [0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0xff, port]
                );
            }
        }
    }

    /// `ack_mode_and_level_port1`, whose head CRC is over the reply's own byte
    /// 1: a captured reply the checks have to accept.
    #[test]
    fn the_captured_reply_frame_passes_its_crcs() {
        let frame = bytes("a5 1c 00 06 00 00 91 e8 00 03 10 00 12 00 ff 01 16 29");
        let (sequence, opcode, payload) = checked_frame(&frame).unwrap();
        assert_eq!(sequence, 0);
        assert_eq!(opcode, 0x03);
        assert_eq!(payload, bytes("10 00 12 00 ff 01"));
    }

    #[test]
    fn a_damaged_frame_is_refused() {
        let good = bytes("a5 1c 00 06 00 00 91 e8 00 03 10 00 12 00 ff 01 16 29");
        // Head CRC, tail CRC, a payload bit, a length.
        for index in [6, 16, 11, 3] {
            let mut bad = good.clone();
            bad[index] ^= 0x01;
            assert!(checked_frame(&bad).is_err(), "byte {index}");
        }
        let mut high = good.clone();
        high[1] = 0x20;
        assert!(checked_frame(&high).is_err());
        assert!(checked_frame(&good[..8]).is_err());
        assert!(checked_frame(&[]).is_err());
    }

    /// `controller_stream.constructed_example`, every value it states.
    #[test]
    fn the_constructed_status_example_decodes() {
        let status = decode_status(&bytes(CONSTRUCTED_STATUS), None).unwrap();
        assert_eq!(status.layout, AcInfinityLayout::Controller);
        assert_eq!(status.display_celsius, Some(true));
        assert_eq!(status.selected_port, Some(1));
        assert_eq!(status.temperature_centi_c, Some(2250));
        assert_eq!(status.humidity_centi_percent, Some(5500));
        assert_eq!(status.vpd_centi_kpa, Some(122));
        assert_eq!(status.caveat, None);
        assert!(status.sensors.is_empty());
        assert_eq!(status.ports.len(), 4);

        let one = &status.ports[0];
        assert_eq!(one.occupied, Some(true));
        assert_eq!(one.load_id, Some(10000));
        assert_eq!(one.level, Some(6));
        assert_eq!(one.output_on, Some(true));
        assert_eq!(one.fault, Some(false));
        assert_eq!(one.mode_code, 2);
        assert_eq!(one.mode.as_deref(), Some("on"));

        let two = &status.ports[1];
        assert_eq!(two.occupied, Some(true));
        assert_eq!(two.load_id, Some(12000));
        assert_eq!(two.output_on, Some(false));
        assert_eq!(two.mode.as_deref(), Some("off"));

        assert_eq!(status.ports[2].occupied, Some(false));
        assert_eq!(status.ports[2].load_id, None);
        assert_eq!(status.ports[3].output_on, None);
    }

    #[test]
    fn no_probe_is_absent_and_a_negative_reading_is_not() {
        let mut frame = bytes(CONSTRUCTED_STATUS);
        frame[8..14].copy_from_slice(&[0x80, 0x00, 0x80, 0x00, 0x80, 0x00]);
        let status = decode_status(&frame, None).unwrap();
        assert_eq!(status.temperature_centi_c, None);
        assert_eq!(status.humidity_centi_percent, None);
        assert_eq!(status.vpd_centi_kpa, None);

        frame[8..10].copy_from_slice(&[0xff, 0x9c]);
        assert_eq!(
            decode_status(&frame, None).unwrap().temperature_centi_c,
            Some(-100)
        );
    }

    #[test]
    fn a_heater_and_a_fault_are_reported() {
        let mut frame = bytes(CONSTRUCTED_STATUS);
        frame[29] = 4;
        frame[24] = 0xdb;
        frame[25] = 0x82;
        let port = &decode_status(&frame, None).unwrap().ports[0];
        assert_eq!(port.load_type.as_deref(), Some("heater"));
        assert_eq!(port.fault, Some(true));
        assert_eq!(port.overcurrent, Some(true));
        assert_eq!(port.mode_code, 2);

        frame[25] = 0x09;
        frame[29] = 200;
        frame[24] = 0xfc;
        let port = &decode_status(&frame, None).unwrap().ports[0];
        assert_eq!(port.mode, None);
        assert_eq!(port.mode_code, 9);
        assert_eq!(port.load_type, None);
        assert_eq!(port.level, None);
    }

    /// A manufacturer payload of the spec's 17-byte form: identity, name
    /// suffix, then the protocol revision (11) and device type (12).
    fn advert(revision: u8, kind: u8) -> Vec<u8> {
        let mut payload = vec![0u8; 17];
        payload[ADVERT_REVISION] = revision;
        payload[ADVERT_TYPE] = kind;
        payload
    }

    /// SYNTHETIC: built for this test from the Controller 69 Pro+ variant's
    /// statement (22 + 8 x 8 = 86 bytes, ports 5-8 continuing the 8-byte
    /// stride from byte 54) and `controller_stream.layout`. No eight-port
    /// frame has been captured; this proves the decoder follows the stated
    /// layout, not that a 69 Pro+ sends it.
    fn synthetic_eight_port() -> Vec<u8> {
        let mut frame = bytes(CONSTRUCTED_STATUS);
        frame[5] = 80;
        frame.extend_from_slice(&bytes(concat!(
            // Port 5: load 5000, level 3, output on, auto, humidifier.
            "13 88 0e 03 00 00 00 02 ",
            // Port 6: empty.
            "ff ff 00 01 00 00 00 00 ",
            // Port 7: load 1, level 0, fault, overcurrent + off, heater.
            "00 01 01 81 00 00 00 84 ",
            // Port 8: load 10000, level 10, output on, cycle, fan.
            "27 10 2a 06 00 00 00 06",
        )));
        frame
    }

    #[test]
    fn synthetic_eight_port_frame_decodes_ports_five_to_eight() {
        let frame = synthetic_eight_port();
        assert_eq!(frame.len(), EIGHT_PORT_FRAME);
        for advertisement in [None, Some(advert(7, 18))] {
            let status = decode_status(&frame, advertisement.as_deref()).unwrap();
            assert_eq!(status.layout, AcInfinityLayout::Controller);
            assert_eq!(status.ports.len(), 8);
            assert!(status.caveat.as_deref().unwrap().contains("Ports 5-8"));
            // Ports 1-4 read exactly as the four-port example.
            assert_eq!(status.ports[0].load_id, Some(10000));
            assert_eq!(status.ports[3].occupied, Some(false));

            let five = &status.ports[4];
            assert_eq!(five.port, 5);
            assert_eq!(five.load_id, Some(5000));
            assert_eq!(five.level, Some(3));
            assert_eq!(five.output_on, Some(true));
            assert_eq!(five.mode.as_deref(), Some("auto"));
            assert_eq!(five.load_type.as_deref(), Some("humidifier"));

            assert_eq!(status.ports[5].occupied, Some(false));

            let seven = &status.ports[6];
            assert_eq!(seven.fault, Some(true));
            assert_eq!(seven.overcurrent, Some(true));
            assert_eq!(seven.output_on, Some(false));
            assert_eq!(seven.mode.as_deref(), Some("off"));
            assert_eq!(seven.load_type.as_deref(), Some("heater"));

            let eight = &status.ports[7];
            assert_eq!(eight.port, 8);
            assert_eq!(eight.level, Some(10));
            assert_eq!(eight.mode.as_deref(), Some("cycle"));
            assert_eq!(eight.load_type.as_deref(), Some("fan"));
        }
    }

    /// SYNTHETIC: built for this test from `controller_stream.legacy_layout`
    /// alone ("same climate fields, 4-byte port records from byte 18 ([load
    /// id u16 BE][state][level high nibble, mode low nibble])"), which is app
    /// analysis. Bytes 6-7 and 14-17 carry values the decoder must not read.
    const SYNTHETIC_LEGACY: &str = concat!(
        "1e ff 02 09 07 1c 80 01 08 ca 15 7c 00 7a 00 00 00 01 ",
        "27 10 5a 62 ",
        "2e e0 00 01 ",
        "ff ff 00 00 ",
        "00 05 00 b3",
    );

    #[test]
    fn synthetic_legacy_frame_decodes_by_the_stated_layout_only() {
        let frame = bytes(SYNTHETIC_LEGACY);
        assert_eq!(frame.len(), 34);
        let status = decode_status(&frame, Some(&advert(4, 7))).unwrap();
        assert_eq!(status.layout, AcInfinityLayout::LegacyController);
        assert!(status.caveat.as_deref().unwrap().contains("revision 5"));
        assert_eq!(status.display_celsius, None);
        assert_eq!(status.selected_port, None);
        assert_eq!(status.temperature_centi_c, Some(2250));
        assert_eq!(status.humidity_centi_percent, Some(5500));
        assert_eq!(status.vpd_centi_kpa, Some(122));
        assert_eq!(status.ports.len(), 4);

        let one = &status.ports[0];
        assert_eq!(one.load_id, Some(10000));
        assert_eq!(one.level, Some(6));
        assert_eq!(one.mode.as_deref(), Some("on"));
        // The state byte's bits are not stated, so 0x5a says nothing.
        assert_eq!(one.output_on, None);
        assert_eq!(one.fault, None);
        assert_eq!(one.overcurrent, None);
        assert_eq!(one.occupied, None);
        assert_eq!(one.load_type, None);

        assert_eq!(status.ports[1].mode.as_deref(), Some("off"));
        assert_eq!(status.ports[1].level, Some(0));
        // No empty-port value is stated: ff ff is reported, not interpreted.
        assert_eq!(status.ports[2].load_id, Some(0xffff));
        assert_eq!(status.ports[2].occupied, None);
        assert_eq!(status.ports[2].mode, None);
        assert_eq!(status.ports[3].level, None, "11 is past the 0-10 range");
        assert_eq!(status.ports[3].mode.as_deref(), Some("auto"));
    }

    /// The legacy layout is chosen by revision, so without one it is refused,
    /// and a legacy unit's frame of the controller's length is not misread.
    #[test]
    fn the_legacy_layout_needs_a_revision_below_five() {
        let frame = bytes(SYNTHETIC_LEGACY);
        assert!(decode_status(&frame, None).is_err());
        assert!(decode_status(&frame, Some(&advert(5, 7))).is_err());
        assert!(decode_status(&frame, Some(&advert(7, 11))).is_err());
        // 54 bytes would be nine legacy records: more ports than any unit.
        let controller = bytes(CONSTRUCTED_STATUS);
        assert!(decode_status(&controller, Some(&advert(4, 11))).is_err());
        assert!(decode_status(&controller, Some(&advert(5, 11))).is_ok());
    }

    /// SYNTHETIC: built for this test from `power_strip_stream`'s expanded
    /// header, port record and sensor record, sized as upstream's capture is
    /// (9 records, 6 sensors, 4 calibration records: 13 + 90 + 24 + 12 = 139).
    /// Not a capture. Outlets 1, 2 and 5 carry the light, fan and humidifier
    /// the spec says upstream's capture shows, in the `3d b8 ff ff` form its
    /// numbering note describes; the other bytes are invented.
    fn synthetic_strip() -> Vec<u8> {
        let frame = bytes(concat!(
            // Header: kind 0c, body 133, 6 sensors, 9 records + selected
            // outlet 3, 4 calibration records.
            "1e ff 02 09 0c 85 00 06 00 00 00 93 04 ",
            // Calibration: 4 x 3 bytes, not decoded.
            "00 00 00 00 00 00 00 00 00 00 00 00 ",
            // Record 0, the strip itself: skipped.
            "00 00 00 00 00 02 01 00 00 00 ",
            // Outlet 1: light, on, mode 1.
            "3d b8 ff ff 81 02 01 00 00 00 ",
            // Outlet 2: fan, off.
            "3d b8 ff ff 86 00 01 00 00 00 ",
            // Outlet 3: nothing connected, relay on.
            "ff ff ff ff 00 02 00 00 00 00 ",
            // Outlet 4: nothing connected, fault.
            "ff ff ff ff 00 01 00 00 00 00 ",
            // Outlet 5: humidifier, on, mode 0x1f (the 5-bit field's top).
            "3d b8 ff ff 82 02 ff 00 00 00 ",
            "ff ff ff ff 00 00 00 00 00 00 ",
            "ff ff ff ff 00 00 00 00 00 00 ",
            "ff ff ff ff 00 00 00 00 00 00 ",
            // Sensors: 79.00 F (x0.01), 22.5 C (x0.1), 55 % (x1), VPD with
            // no reading, zone 80 F (x10), an id the table omits.
            "00 60 1e dc ",
            "01 40 00 e1 ",
            "02 20 00 37 ",
            "03 60 80 00 ",
            "04 00 00 08 ",
            "09 60 ff 9c",
        ));
        assert_eq!(frame.len(), 139);
        frame
    }

    #[test]
    fn synthetic_strip_frame_decodes_outlets_and_sensors() {
        let frame = synthetic_strip();
        for kind in STRIP_TYPES {
            let status = decode_status(&frame, Some(&advert(3, kind))).unwrap();
            assert_eq!(status.layout, AcInfinityLayout::PowerStrip);
            assert!(status
                .caveat
                .as_deref()
                .unwrap()
                .contains("record position"));
            assert_eq!(status.selected_port, Some(3));
            assert_eq!(status.display_celsius, None);
            assert_eq!(status.temperature_centi_c, None);
            assert_eq!(status.ports.len(), 8);

            let one = &status.ports[0];
            assert_eq!(one.port, 1);
            assert_eq!(one.occupied, Some(true));
            assert_eq!(one.load_id, Some(0x3db8));
            assert_eq!(one.load_type.as_deref(), Some("light"));
            assert_eq!(one.output_on, Some(true));
            assert_eq!(one.fault, Some(false));
            assert_eq!(one.overcurrent, None);
            assert_eq!(one.mode_code, 1);
            assert_eq!(one.mode, None, "the strip's mode values are not given");

            assert_eq!(status.ports[1].load_type.as_deref(), Some("fan"));
            assert_eq!(status.ports[1].output_on, Some(false));

            let three = &status.ports[2];
            assert_eq!(three.occupied, Some(false));
            assert_eq!(three.load_id, None);
            assert_eq!(three.output_on, Some(true));
            assert_eq!(status.ports[3].fault, Some(true));

            let five = &status.ports[4];
            assert_eq!(five.load_type.as_deref(), Some("humidifier"));
            assert_eq!(five.mode_code, 0x1f);
            assert_eq!(status.ports[7].port, 8);

            let sensors = &status.sensors;
            assert_eq!(sensors.len(), 6);
            assert_eq!(sensors[0].name.as_deref(), Some("probe temperature"));
            assert_eq!(sensors[0].unit.as_deref(), Some("°F"));
            assert_eq!(sensors[0].value_hundredths, Some(7900));
            assert_eq!(sensors[0].decimals, 2);
            assert_eq!(sensors[1].unit.as_deref(), Some("°C"));
            assert_eq!(sensors[1].value_hundredths, Some(2250));
            assert_eq!(sensors[1].decimals, 1);
            assert_eq!(sensors[2].unit.as_deref(), Some("%"));
            assert_eq!(sensors[2].value_hundredths, Some(5500));
            assert_eq!(sensors[2].decimals, 0);
            assert_eq!(sensors[3].name.as_deref(), Some("probe VPD"));
            assert_eq!(sensors[3].unit, None);
            assert_eq!(sensors[3].value_hundredths, None);
            assert_eq!(sensors[4].name.as_deref(), Some("zone temperature"));
            assert_eq!(sensors[4].value_hundredths, Some(8000));
            assert_eq!(sensors[5].sensor_id, 9);
            assert_eq!(sensors[5].name, None);
            assert_eq!(sensors[5].value_hundredths, Some(-100));
        }
    }

    #[test]
    fn a_strip_frame_failing_the_header_check_is_refused() {
        let good = synthetic_strip();
        let strip = advert(3, 22);
        // One calibration record fewer, one sensor fewer, no records at all.
        for (index, value) in [(12, 0x03), (7, 0x05), (11, 0x03)] {
            let mut bad = good.clone();
            bad[index] = value;
            assert!(decode_status(&bad, Some(&strip)).is_err(), "byte {index}");
        }
        // The controller layout is never read off a strip.
        let controller = bytes(CONSTRUCTED_STATUS);
        assert!(decode_status(&controller, Some(&strip)).is_err());
        // And the strip's frame is not read without knowing it is a strip.
        assert!(decode_status(&good, None).is_err());
        assert!(decode_status(&good, Some(&advert(7, 11))).is_err());
    }

    #[test]
    fn types_whose_stream_is_not_stated_are_refused() {
        let frame = bytes(CONSTRUCTED_STATUS);
        // Single-port, AI-series, a thermo-hygrometer.
        for kind in [1, 2, 19, 20, 51, 3] {
            assert!(
                decode_status(&frame, Some(&advert(7, kind))).is_err(),
                "type {kind}"
            );
        }
        // A payload of neither stated length says nothing about the unit.
        let mut odd = advert(4, 22);
        odd.push(0);
        assert!(decode_status(&frame, Some(&odd)).is_ok());
    }

    #[test]
    fn malformed_frames_are_refused() {
        assert!(decode_status(&[], None).is_err());
        assert!(decode_status(&[0x1e, 0xff], None).is_err());
        assert!(decode_status(&[0xde; 54], None).is_err());
        let good = bytes(CONSTRUCTED_STATUS);
        assert!(decode_status(&good[..40], None).is_err());
        let strip = advert(3, 22);
        assert!(decode_status(&synthetic_strip()[..12], Some(&strip)).is_err());
        let mut short = good[..12].to_vec();
        short[5] = 6;
        assert!(decode_status(&short, Some(&strip)).is_err());
        assert!(decode_status(&short, Some(&advert(4, 7))).is_err());
    }

    fn model_data_reply(sequence: u16, port: u8, items: &str) -> Vec<u8> {
        let mut inner = vec![0x00, OPCODE_READ];
        inner.extend_from_slice(&bytes(items));
        inner.extend_from_slice(&[0xff, port]);
        let mut frame = envelope(&inner, sequence);
        frame[1] = 0x17;
        let head = crc16(&frame[..6]);
        frame[6..8].copy_from_slice(&head.to_be_bytes());
        frame
    }

    #[test]
    fn stored_levels_decode_and_are_matched_to_the_request() {
        let reply = model_data_reply(
            9,
            2,
            "10 01 02 11 01 00 12 01 6a 16 08 00 00 03 84 00 00 0a 8c",
        );
        let stored = decode_model_data(&reply, 9, 2).unwrap();
        assert_eq!(stored.port, 2);
        assert_eq!(stored.off_level, Some(0));
        assert_eq!(stored.on_level_raw, Some(0x6a));

        assert!(decode_model_data(&reply, 10, 2).is_err(), "another seq");
        assert!(decode_model_data(&reply, 9, 3).is_err(), "another port");
    }

    #[test]
    fn a_broken_item_list_is_refused() {
        // An item promising more than it carries, and no trailer at all.
        let reply = model_data_reply(1, 1, "11 05 00");
        assert!(decode_model_data(&reply, 1, 1).is_err());
        let mut inner = vec![0x00, OPCODE_READ, 0x11, 0x01, 0x00];
        let bare = envelope(&inner, 1);
        assert!(decode_model_data(&bare, 1, 1).is_err());
        inner.push(0x11);
        let cut = envelope(&inner, 1);
        assert!(decode_model_data(&cut, 1, 1).is_err());
    }

    #[test]
    fn a_status_frame_reassembles_across_chunks() {
        let frame = bytes(CONSTRUCTED_STATUS);
        let first = feed(&[], &[], &frame[..20]);
        assert!(first.frames.is_empty());
        assert_eq!(first.status_buffer.len(), 20);
        let second = feed(&first.frame_buffer, &first.status_buffer, &frame[20..]);
        assert_eq!(second.frames, vec![frame]);
        assert!(second.status_buffer.is_empty());
    }

    /// The reason for two buffers: status keeps arriving mid-reply.
    #[test]
    fn a_status_frame_landing_inside_a_reply_does_not_corrupt_it() {
        let status = bytes(CONSTRUCTED_STATUS);
        let reply = model_data_reply(1, 1, "11 01 00 12 01 05");
        let a = feed(&[], &[], &reply[..6]);
        let b = feed(&a.frame_buffer, &a.status_buffer, &status);
        assert_eq!(b.frames, vec![status.clone()]);
        assert_eq!(b.frame_buffer, reply[..6]);
        let c = feed(&b.frame_buffer, &b.status_buffer, &reply[6..]);
        assert_eq!(c.frames, vec![reply]);
    }

    #[test]
    fn two_frames_in_one_chunk_both_come_out() {
        let status = bytes(CONSTRUCTED_STATUS);
        let reply = model_data_reply(1, 1, "11 01 00");
        let mut chunk = reply.clone();
        chunk.extend_from_slice(&status);
        let fed = feed(&[], &[], &chunk);
        assert_eq!(fed.frames, vec![reply, status]);
    }

    #[test]
    fn noise_is_dropped_and_a_mad_length_does_not_wedge_the_buffer() {
        let dropped = feed(&[], &[], &[0xde, 0xad]);
        assert!(dropped.frames.is_empty());
        assert!(dropped.frame_buffer.is_empty());
        assert!(dropped.status_buffer.is_empty());

        let mad = feed(&[], &[], &[0xa5, 0x00, 0xff, 0xff, 0x00, 0x00]);
        assert!(mad.frame_buffer.is_empty());
        let status = bytes(CONSTRUCTED_STATUS);
        let after = feed(&mad.frame_buffer, &mad.status_buffer, &status);
        assert_eq!(after.frames, vec![status]);
    }
}

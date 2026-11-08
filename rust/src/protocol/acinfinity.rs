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
const DECLARED_PORTS: usize = 4;

/// The controller layout's frame sizes: four ports (captured) and eight
/// (22 + 8 x 8, which the spec infers and does not declare).
const FOUR_PORT_FRAME: usize = 54;
const EIGHT_PORT_FRAME: usize = 86;

/// Largest frame the reassembler holds. The longest the spec mentions is the
/// 233-byte `read_everything` reply; a length past this is not a frame.
const MAX_FRAME: usize = 1024;

/// One port of the status stream.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcInfinityPortDto {
    /// The 1-based physical port.
    pub port: u8,
    /// False when nothing is plugged in; the spec says the rest of the block
    /// is then meaningless, so the rest stays empty here.
    pub occupied: bool,
    pub load_id: Option<u16>,
    /// The load-type table's text; `None` for a code the table omits.
    pub load_type: Option<String>,
    /// Output level 0-10. `None` for a value outside that range.
    pub level: Option<u8>,
    pub output_on: bool,
    pub fault: bool,
    pub overcurrent: bool,
    pub mode_code: u8,
    /// The mode table's text; `None` for a code the table omits.
    pub mode: Option<String>,
}

/// A decoded status frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcInfinityStatusDto {
    pub display_celsius: bool,
    pub selected_port: u8,
    /// Hundredths of a degree C, of a percent and of a kPa. `None` is the
    /// spec's "no probe" value. Integers so the screen rounds, not this file.
    pub temperature_centi_c: Option<i16>,
    pub humidity_centi_percent: Option<i16>,
    pub vpd_centi_kpa: Option<i16>,
    pub ports: Vec<AcInfinityPortDto>,
    /// Ports 5-8 of an eight-port frame, left undecoded because the spec
    /// infers their layout and nobody has captured it.
    pub undecoded_ports: u8,
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

fn port_block(port: u8, block: &[u8]) -> AcInfinityPortDto {
    let load_id = u16::from_be_bytes([block[0], block[1]]);
    if load_id == EMPTY_PORT {
        return AcInfinityPortDto {
            port,
            occupied: false,
            load_id: None,
            load_type: None,
            level: None,
            output_on: false,
            fault: false,
            overcurrent: false,
            mode_code: 0,
            mode: None,
        };
    }
    let state = block[2];
    let mode = block[3];
    let level = (state >> 2) & 0x0f;
    AcInfinityPortDto {
        port,
        occupied: true,
        load_id: Some(load_id),
        load_type: load_type_name(block[7]).map(str::to_string),
        level: (level <= 10).then_some(level),
        output_on: state & 0x02 != 0,
        fault: state & 0x01 != 0,
        overcurrent: mode & 0x80 != 0,
        mode_code: mode & 0x0f,
        mode: mode_name(mode & 0x0f).map(str::to_string),
    }
}

/// Decode a status stream frame, by the multi-port controller layout.
///
/// Only that layout. The power strip's AI-family frame (139 bytes) and the
/// older 4-byte port records must not be read with this table, as the spec
/// warns, and they have no literal vector to hold a decoder to, so they are
/// refused with a reason rather than read wrongly.
pub fn decode_status(frame: &[u8]) -> Result<AcInfinityStatusDto, ProtocolError> {
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
    if frame.len() != FOUR_PORT_FRAME && frame.len() != EIGHT_PORT_FRAME {
        return Err(malformed(format!(
            "a {} byte status frame is not the multi-port controller layout",
            frame.len()
        )));
    }
    let ports = frame[FIRST_PORT_BLOCK..]
        .chunks_exact(PORT_BLOCK)
        .take(DECLARED_PORTS)
        .enumerate()
        .map(|(index, block)| port_block(index as u8 + 1, block))
        .collect();
    Ok(AcInfinityStatusDto {
        display_celsius: frame[6] & 0x80 != 0,
        selected_port: frame[7] & 0x0f,
        temperature_centi_c: reading(frame[8], frame[9]),
        humidity_centi_percent: reading(frame[10], frame[11]),
        vpd_centi_kpa: reading(frame[12], frame[13]),
        ports,
        undecoded_ports: if frame.len() == EIGHT_PORT_FRAME {
            4
        } else {
            0
        },
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
        let status = decode_status(&bytes(CONSTRUCTED_STATUS)).unwrap();
        assert!(status.display_celsius);
        assert_eq!(status.selected_port, 1);
        assert_eq!(status.temperature_centi_c, Some(2250));
        assert_eq!(status.humidity_centi_percent, Some(5500));
        assert_eq!(status.vpd_centi_kpa, Some(122));
        assert_eq!(status.undecoded_ports, 0);
        assert_eq!(status.ports.len(), 4);

        let one = &status.ports[0];
        assert!(one.occupied);
        assert_eq!(one.load_id, Some(10000));
        assert_eq!(one.level, Some(6));
        assert!(one.output_on);
        assert!(!one.fault);
        assert_eq!(one.mode_code, 2);
        assert_eq!(one.mode.as_deref(), Some("on"));

        let two = &status.ports[1];
        assert!(two.occupied);
        assert_eq!(two.load_id, Some(12000));
        assert!(!two.output_on);
        assert_eq!(two.mode.as_deref(), Some("off"));

        assert!(!status.ports[2].occupied);
        assert_eq!(status.ports[2].load_id, None);
        assert!(!status.ports[3].output_on);
    }

    #[test]
    fn no_probe_is_absent_and_a_negative_reading_is_not() {
        let mut frame = bytes(CONSTRUCTED_STATUS);
        frame[8..14].copy_from_slice(&[0x80, 0x00, 0x80, 0x00, 0x80, 0x00]);
        let status = decode_status(&frame).unwrap();
        assert_eq!(status.temperature_centi_c, None);
        assert_eq!(status.humidity_centi_percent, None);
        assert_eq!(status.vpd_centi_kpa, None);

        frame[8..10].copy_from_slice(&[0xff, 0x9c]);
        assert_eq!(
            decode_status(&frame).unwrap().temperature_centi_c,
            Some(-100)
        );
    }

    #[test]
    fn a_heater_and_a_fault_are_reported() {
        let mut frame = bytes(CONSTRUCTED_STATUS);
        frame[29] = 4;
        frame[24] = 0xdb;
        frame[25] = 0x82;
        let port = &decode_status(&frame).unwrap().ports[0];
        assert_eq!(port.load_type.as_deref(), Some("heater"));
        assert!(port.fault);
        assert!(port.overcurrent);
        assert_eq!(port.mode_code, 2);

        frame[25] = 0x09;
        frame[29] = 200;
        frame[24] = 0xfc;
        let port = &decode_status(&frame).unwrap().ports[0];
        assert_eq!(port.mode, None);
        assert_eq!(port.mode_code, 9);
        assert_eq!(port.load_type, None);
        assert_eq!(port.level, None);
    }

    /// Ports 5-8 of the Pro+ are inferred by the spec and never captured.
    #[test]
    fn an_eight_port_frame_decodes_the_declared_ports_and_says_so() {
        let mut frame = bytes(CONSTRUCTED_STATUS);
        frame[5] = 80;
        frame.extend_from_slice(&[0xff; 32]);
        let status = decode_status(&frame).unwrap();
        assert_eq!(status.ports.len(), 4);
        assert_eq!(status.undecoded_ports, 4);
    }

    #[test]
    fn other_layouts_are_refused_rather_than_misread() {
        // The power strip's 139-byte frame.
        let mut strip = vec![0u8; 139];
        strip[..4].copy_from_slice(&STREAM_MARKER);
        strip[4] = 0x0c;
        strip[5] = 133;
        assert!(decode_status(&strip).is_err());
        // The legacy 4-byte records: 18 + 4 x 4.
        let mut legacy = vec![0u8; 34];
        legacy[..4].copy_from_slice(&STREAM_MARKER);
        legacy[5] = 28;
        assert!(decode_status(&legacy).is_err());
        // Garbage and truncation.
        assert!(decode_status(&[]).is_err());
        assert!(decode_status(&[0x1e, 0xff]).is_err());
        assert!(decode_status(&[0xde; 54]).is_err());
        let good = bytes(CONSTRUCTED_STATUS);
        assert!(decode_status(&good[..40]).is_err());
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

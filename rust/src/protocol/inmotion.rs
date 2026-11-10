// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! INMOTION V2 electric unicycles, telemetry only —
//! `protocol_handler: "inmotion_euc"` (`inmotion-euc.yaml`,
//! `payload_formats.V2_*` and `protocol_details.v2`).
//!
//! ```text
//! frame = AA AA | escaped(flags, len, command, data..., xor)
//!   escape: A5 before any AA or A5 after the header (55 is not special)
//!   len   = command + data;   xor = flags ^ len ^ command ^ data...
//!   replies set bit 7 of the command (0x04 -> 0x84)
//! ```
//!
//! # A moving vehicle
//!
//! What a wheel does with a write while someone rides it is not established
//! (the spec's remaining unknowns), so nothing that changes the wheel can be
//! built here. [`encode_read`] takes an [`InMotionRead`] — car type, board
//! versions, real-time, total statistics — and builds those four requests
//! only; `protocol::readonly` refuses every spec command to the generic
//! encoders, and the headlight, beep, lock, ride modes, calibration, transport
//! mode and power-off stay listed and refused.
//!
//! # Which wheels
//!
//! The V2 protocol only, and only through the layouts the spec states, picked
//! by `protocol_details.v2_layout_selection`. A V11's layout depends on its
//! main-board version, so its real-time data is not read until the versions
//! reply has said which. Fields the spec marks "unsure" are left out. Legacy
//! wheels (V5, V8, V10, Glide 3) speak another framing and are not read by
//! this module. Nothing here has been run against hardware.

use crate::error::ProtocolError;

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "inmotion_euc";

pub const V2_SERVICE: &str = "6e400001-b5a3-f393-e0a9-e50e24dcca9e";
pub const V2_WRITE: &str = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
pub const V2_NOTIFY: &str = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";
/// The legacy notify service. A wheel with it and no V2 service is legacy.
pub const LEGACY_SERVICE: &str = "0000ffe0-0000-1000-8000-00805f9b34fb";

const HEADER: [u8; 2] = [0xAA, 0xAA];
const ESCAPE: u8 = 0xA5;
const FLAGS_INITIAL: u8 = 0x11;
const FLAGS_DEFAULT: u8 = 0x14;
const CMD_MAIN_INFO: u8 = 0x02;
const CMD_REALTIME: u8 = 0x04;
const CMD_TOTAL_STATS: u8 = 0x11;
const REPLY_BIT: u8 = 0x80;
/// One frame's unescaped body can be no longer than the one-byte `len` allows.
const MAX_BUFFER: usize = 1024;

/// The requests this app sends a wheel. All four ask; none changes anything.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InMotionRead {
    CarType,
    Versions,
    RealTime,
    TotalStats,
}

/// The real-time layout a wheel's data is read with.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InMotionLayout {
    V11Early,
    V11From14,
    V12,
    V13,
    V14Family,
}

/// What one reply turned out to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InMotionFrameKind {
    CarType,
    Versions,
    RealTime,
    TotalStats,
    /// A well-formed frame this app does not read.
    Other,
}

/// One whole frame, unescaped and checked: its flags, command (reply bit
/// masked off) and data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InMotionFrameDto {
    pub kind: InMotionFrameKind,
    pub flags: u8,
    pub command: u8,
    pub data: Vec<u8>,
}

/// What a feed of notification bytes produced: the whole frames, and the
/// bytes kept for the next chunk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InMotionFeedDto {
    pub frames: Vec<InMotionFrameDto>,
    pub buffer: Vec<u8>,
    /// Frames dropped for a bad checksum, so a reader can tell a link
    /// carrying garbage from a quiet one.
    pub dropped: u32,
}

/// A car-type reply read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InMotionModelDto {
    pub code: u32,
    /// The model's name, or `None` for a code the spec does not list.
    pub name: Option<String>,
    /// The layout its real-time data is read with, when the model alone says
    /// (every listed model but the V11, which needs its main-board version).
    pub layout: Option<InMotionLayout>,
}

/// A board version, as the versions reply spells it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct InMotionVersionDto {
    pub major: u8,
    pub minor: u8,
    pub patch: u16,
}

#[derive(Debug, Clone, PartialEq)]
pub struct InMotionVersionsDto {
    pub driver: InMotionVersionDto,
    pub main: InMotionVersionDto,
    pub ble: InMotionVersionDto,
}

/// Real-time telemetry. Only what the layout states firmly is set.
#[derive(Debug, Clone, PartialEq)]
pub struct InMotionTelemetryDto {
    pub layout: InMotionLayout,
    pub voltage_v: f64,
    pub current_a: f64,
    /// Negative when rolling backwards.
    pub speed_kmh: f64,
    pub battery_percent: Option<f64>,
    pub trip_km: Option<f64>,
    pub remaining_km: Option<f64>,
    /// The limit the wheel is enforcing right now.
    pub speed_limit_kmh: Option<f64>,
    pub mos_temperature_c: Option<i32>,
    pub motor_temperature_c: Option<i32>,
    pub board_temperature_c: Option<i32>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct InMotionTotalsDto {
    pub total_km: f64,
    pub ride_time_s: u32,
    pub power_on_time_s: u32,
}

fn malformed(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::MalformedReply(reason.into())
}

fn escape_into(out: &mut Vec<u8>, byte: u8) {
    if byte == 0xAA || byte == ESCAPE {
        out.push(ESCAPE);
    }
    out.push(byte);
}

/// One frame around `command` and `data`, escaped, checksum included.
fn frame(flags: u8, command: u8, data: &[u8]) -> Vec<u8> {
    let len = (data.len() + 1) as u8;
    let checksum = data.iter().fold(flags ^ len ^ command, |acc, b| acc ^ b);
    let mut out = HEADER.to_vec();
    for byte in [flags, len, command]
        .into_iter()
        .chain(data.iter().copied())
        .chain([checksum])
    {
        escape_into(&mut out, byte);
    }
    out
}

/// The bytes of one read request.
pub fn encode_read(read: InMotionRead) -> Vec<u8> {
    match read {
        InMotionRead::CarType => frame(FLAGS_INITIAL, CMD_MAIN_INFO, &[0x01]),
        InMotionRead::Versions => frame(FLAGS_INITIAL, CMD_MAIN_INFO, &[0x06]),
        InMotionRead::RealTime => frame(FLAGS_DEFAULT, CMD_REALTIME, &[]),
        InMotionRead::TotalStats => frame(FLAGS_DEFAULT, CMD_TOTAL_STATS, &[]),
    }
}

/// Add `chunk` to `buffer` and take out every whole frame. Bytes before a
/// header are dropped; a frame whose checksum fails is dropped and counted.
pub fn feed(buffer: &[u8], chunk: &[u8]) -> InMotionFeedDto {
    let mut stream = buffer.to_vec();
    stream.extend_from_slice(chunk);
    let mut frames = Vec::new();
    let mut dropped = 0;
    loop {
        let Some(start) = stream.windows(2).position(|w| w == HEADER) else {
            // Keep a lone trailing AA: it may be half a header.
            let keep = usize::from(stream.last() == Some(&0xAA));
            stream.drain(..stream.len() - keep);
            break;
        };
        stream.drain(..start);
        // Unescape after the header until flags, len, len bytes and the
        // checksum are in hand.
        let mut body = Vec::new();
        let mut i = HEADER.len();
        let mut complete = false;
        let mut restart = None;
        while i < stream.len() {
            let mut byte = stream[i];
            if byte == ESCAPE {
                let Some(&next) = stream.get(i + 1) else {
                    break;
                };
                byte = next;
                i += 1;
            } else if byte == 0xAA && stream.get(i + 1) == Some(&0xAA) {
                // An unescaped header inside a frame: this one was cut short.
                restart = Some(i);
                break;
            }
            body.push(byte);
            i += 1;
            if body.len() >= 2 && body.len() == usize::from(body[1]) + 3 {
                complete = true;
                break;
            }
        }
        if let Some(at) = restart {
            dropped += 1;
            stream.drain(..at);
            continue;
        }
        if !complete {
            if stream.len() > MAX_BUFFER {
                stream.clear();
            }
            break;
        }
        stream.drain(..i);
        let (checksum, rest) = body.split_last().expect("at least three bytes");
        if rest.iter().fold(0u8, |acc, b| acc ^ b) != *checksum || body[1] == 0 {
            dropped += 1;
            continue;
        }
        let flags = body[0];
        let command = body[2] & !REPLY_BIT;
        let data = body[3..body.len() - 1].to_vec();
        let kind = match (command, data.first()) {
            (CMD_MAIN_INFO, Some(0x01)) => InMotionFrameKind::CarType,
            (CMD_MAIN_INFO, Some(0x06)) => InMotionFrameKind::Versions,
            (CMD_REALTIME, _) => InMotionFrameKind::RealTime,
            (CMD_TOTAL_STATS, _) => InMotionFrameKind::TotalStats,
            _ => InMotionFrameKind::Other,
        };
        frames.push(InMotionFrameDto {
            kind,
            flags,
            command,
            data,
        });
    }
    InMotionFeedDto {
        frames,
        buffer: stream,
        dropped,
    }
}

/// `protocol_details.v2.model_codes`.
const MODELS: &[(u32, &str)] = &[
    (61, "V11"),
    (62, "V11Y"),
    (71, "V12 HS"),
    (72, "V12 HT"),
    (73, "V12 Pro"),
    (81, "V13"),
    (82, "V13 Pro"),
    (91, "V14 50GB"),
    (92, "V14 50S"),
    (111, "V12S"),
    (121, "V9"),
];

fn layout_of_model(code: u32) -> Option<InMotionLayout> {
    match code {
        71..=73 => Some(InMotionLayout::V12),
        81 | 82 => Some(InMotionLayout::V13),
        91 | 92 | 62 | 121 | 111 => Some(InMotionLayout::V14Family),
        _ => None,
    }
}

/// A car-type reply's data (`01 main_series series type ...`).
pub fn decode_car_type(data: &[u8]) -> Result<InMotionModelDto, ProtocolError> {
    let [0x01, _, series, kind, ..] = data[..] else {
        return Err(malformed("a car-type reply is 01 then three bytes"));
    };
    let code = u32::from(series) * 10 + u32::from(kind);
    Ok(InMotionModelDto {
        code,
        name: MODELS
            .iter()
            .find(|(c, _)| *c == code)
            .map(|(_, name)| name.to_string()),
        layout: layout_of_model(code),
    })
}

fn version_at(data: &[u8], at: usize) -> Option<InMotionVersionDto> {
    let bytes = data.get(at..at + 4)?;
    Some(InMotionVersionDto {
        patch: u16::from_le_bytes([bytes[0], bytes[1]]),
        minor: bytes[2],
        major: bytes[3],
    })
}

/// A versions reply's data (`06 ...`).
pub fn decode_versions(data: &[u8]) -> Result<InMotionVersionsDto, ProtocolError> {
    if data.first() != Some(&0x06) {
        return Err(malformed("a versions reply starts 06"));
    }
    let short = || malformed("a versions reply carries three versions");
    Ok(InMotionVersionsDto {
        driver: version_at(data, 2).ok_or_else(short)?,
        main: version_at(data, 11).ok_or_else(short)?,
        ble: version_at(data, 20).ok_or_else(short)?,
    })
}

/// The layout a model's real-time data is read with. A V11 needs its
/// main-board version; without one there is no answer.
pub fn layout_for(model_code: u32, main: Option<InMotionVersionDto>) -> Option<InMotionLayout> {
    if model_code == 61 {
        // The spec's rule as written: below 1.4 is "major below 2 and minor
        // below 4".
        let main = main?;
        return Some(if main.major < 2 && main.minor < 4 {
            InMotionLayout::V11Early
        } else {
            InMotionLayout::V11From14
        });
    }
    layout_of_model(model_code)
}

fn u16_at(data: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_le_bytes([*data.get(at)?, *data.get(at + 1)?]))
}

fn i16_at(data: &[u8], at: usize) -> Option<i16> {
    u16_at(data, at).map(|v| v as i16)
}

fn hundredths(raw: Option<u16>) -> Option<f64> {
    raw.map(|v| f64::from(v) / 100.0)
}

/// uint8 minus 176 °C; a raw 0 is no sensor.
fn temperature(data: &[u8], at: usize) -> Option<i32> {
    data.get(at)
        .filter(|raw| **raw != 0)
        .map(|raw| i32::from(*raw) - 176)
}

/// One real-time reply's data under `layout`.
pub fn decode_realtime(
    layout: InMotionLayout,
    data: &[u8],
) -> Result<InMotionTelemetryDto, ProtocolError> {
    use InMotionLayout::*;
    // Every layout's last firm field: the reply must reach it.
    let needed = match layout {
        V11Early => 21,
        V11From14 => 46,
        V12 => 44,
        V13 | V14Family => 62,
    };
    if data.len() < needed {
        return Err(malformed(format!(
            "a {layout:?} real-time reply is at least {needed} bytes, and this one is {}",
            data.len()
        )));
    }
    let base = |speed_at: usize| -> Option<(f64, f64, f64)> {
        Some((
            f64::from(u16_at(data, 0)?) / 100.0,
            f64::from(i16_at(data, 2)?) / 100.0,
            f64::from(i16_at(data, speed_at)?) / 100.0,
        ))
    };
    let pack_mean = || -> Option<f64> {
        let (a, b) = (u16_at(data, 34)?, u16_at(data, 36)?);
        Some((f64::from(a) + f64::from(b)) / 200.0)
    };
    let short = || malformed("real-time reply ended early");
    let telemetry = match layout {
        V11Early => {
            let (voltage_v, current_a, speed_kmh) = base(4).ok_or_else(short)?;
            InMotionTelemetryDto {
                layout,
                voltage_v,
                current_a,
                speed_kmh,
                battery_percent: data.get(16).map(|b| f64::from(b & 0x7F)),
                trip_km: hundredths(u16_at(data, 12)),
                remaining_km: hundredths(u16_at(data, 14)),
                speed_limit_kmh: hundredths(u16_at(data, 28)),
                mos_temperature_c: temperature(data, 17),
                motor_temperature_c: temperature(data, 18),
                board_temperature_c: temperature(data, 20),
            }
        }
        V11From14 => {
            let (voltage_v, current_a, speed_kmh) = base(4).ok_or_else(short)?;
            InMotionTelemetryDto {
                layout,
                voltage_v,
                current_a,
                speed_kmh,
                battery_percent: hundredths(u16_at(data, 28)),
                trip_km: hundredths(u16_at(data, 26)),
                remaining_km: hundredths(u16_at(data, 30)),
                speed_limit_kmh: hundredths(u16_at(data, 34)),
                mos_temperature_c: temperature(data, 42),
                motor_temperature_c: temperature(data, 43),
                board_temperature_c: temperature(data, 45),
            }
        }
        V12 => {
            let (voltage_v, current_a, speed_kmh) = base(4).ok_or_else(short)?;
            InMotionTelemetryDto {
                layout,
                voltage_v,
                current_a,
                speed_kmh,
                battery_percent: hundredths(u16_at(data, 24)),
                trip_km: hundredths(u16_at(data, 22)),
                remaining_km: hundredths(u16_at(data, 26)),
                speed_limit_kmh: hundredths(u16_at(data, 30)),
                mos_temperature_c: temperature(data, 40),
                motor_temperature_c: temperature(data, 41),
                board_temperature_c: temperature(data, 43),
            }
        }
        // The V13's trip distance is marked unsure, and neither states a
        // remaining range: both are left out rather than guessed.
        V13 => {
            let (voltage_v, current_a, speed_kmh) = base(8).ok_or_else(short)?;
            InMotionTelemetryDto {
                layout,
                voltage_v,
                current_a,
                speed_kmh,
                battery_percent: pack_mean(),
                trip_km: None,
                remaining_km: None,
                speed_limit_kmh: hundredths(u16_at(data, 40)),
                mos_temperature_c: temperature(data, 58),
                motor_temperature_c: temperature(data, 59),
                board_temperature_c: temperature(data, 61),
            }
        }
        V14Family => {
            let (voltage_v, current_a, speed_kmh) = base(8).ok_or_else(short)?;
            InMotionTelemetryDto {
                layout,
                voltage_v,
                current_a,
                speed_kmh,
                battery_percent: pack_mean(),
                trip_km: hundredths(u16_at(data, 28)),
                remaining_km: None,
                speed_limit_kmh: hundredths(u16_at(data, 40)),
                mos_temperature_c: temperature(data, 58),
                motor_temperature_c: temperature(data, 59),
                board_temperature_c: temperature(data, 61),
            }
        }
    };
    Ok(telemetry)
}

/// A total-statistics reply's data.
pub fn decode_totals(data: &[u8]) -> Result<InMotionTotalsDto, ProtocolError> {
    let word = |at: usize| -> Option<u32> {
        Some(u32::from_le_bytes(data.get(at..at + 4)?.try_into().ok()?))
    };
    let short = || malformed("a total-statistics reply is at least 20 bytes");
    Ok(InMotionTotalsDto {
        total_km: f64::from(word(0).ok_or_else(short)?) / 100.0,
        ride_time_s: word(12).ok_or_else(short)?,
        power_on_time_s: word(16).ok_or_else(short)?,
    })
}

/// Why this wheel is not read, from the services it carries, or `None`.
pub fn refuses_wheel(service_uuids: &[String]) -> Option<String> {
    let has = |uuid: &str| service_uuids.iter().any(|s| s.eq_ignore_ascii_case(uuid));
    if has(V2_SERVICE) {
        return None;
    }
    Some(if has(LEGACY_SERVICE) {
        "This looks like a legacy InMotion wheel (V5, V8, V10 or Glide 3). This \
         app reads the V2 wheels only."
            .to_string()
    } else {
        "This wheel does not carry the InMotion V2 service.".to_string()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn hex(text: &str) -> Vec<u8> {
        let text: String = text.split_whitespace().collect();
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
            .collect()
    }

    fn one(frame: &str) -> InMotionFrameDto {
        let fed = feed(&[], &hex(frame));
        assert_eq!(fed.dropped, 0, "{frame}");
        assert_eq!(fed.frames.len(), 1, "{frame}");
        fed.frames.into_iter().next().unwrap()
    }

    fn close(a: f64, b: f64) -> bool {
        (a - b).abs() < 1e-9
    }

    /// The four requests are byte for byte the spec's own commands, and the
    /// car-type one is `test_vectors.v2_car_type_request`.
    #[test]
    fn the_requests_are_the_specs() {
        assert_eq!(encode_read(InMotionRead::CarType), hex("aaaa1102020110"));
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../vendor/protocol-specs/device-specs/devices/inmotion-euc.yaml"
        );
        let spec = parse_device_spec(&std::fs::read_to_string(path).unwrap()).unwrap();
        let commands = spec
            .services
            .iter()
            .flat_map(|s| &s.characteristics)
            .find(|c| c.uuid == V2_WRITE)
            .and_then(|c| c.commands.as_ref())
            .unwrap();
        for (read, name) in [
            (InMotionRead::CarType, "v2_request_car_type"),
            (InMotionRead::Versions, "v2_request_versions"),
            (InMotionRead::RealTime, "v2_request_realtime"),
            (InMotionRead::TotalStats, "v2_request_total_stats"),
        ] {
            assert_eq!(Some(encode_read(read)), commands[name].value, "{name}");
        }
    }

    #[test]
    fn car_type_vector() {
        let frame = one("aaaa110882010206010201009c");
        assert_eq!(frame.kind, InMotionFrameKind::CarType);
        assert_eq!(frame.flags, 0x11);
        let model = decode_car_type(&frame.data).unwrap();
        assert_eq!(model.code, 61);
        assert_eq!(model.name.as_deref(), Some("V11"));
        assert_eq!(model.layout, None, "a V11 needs its main-board version");
    }

    #[test]
    fn versions_vector() {
        let frame = one("aaaa111d820622080004030f000602214000010110000602230d00010107000001f3");
        assert_eq!(frame.kind, InMotionFrameKind::Versions);
        let versions = decode_versions(&frame.data).unwrap();
        let v = |major, minor, patch| InMotionVersionDto {
            major,
            minor,
            patch,
        };
        assert_eq!(versions.driver, v(3, 4, 8));
        assert_eq!(versions.main, v(1, 1, 64));
        assert_eq!(versions.ble, v(1, 1, 13));
        assert_eq!(
            layout_for(61, Some(versions.main)),
            Some(InMotionLayout::V11Early)
        );
        assert_eq!(
            layout_for(61, Some(v(1, 4, 0))),
            Some(InMotionLayout::V11From14)
        );
        assert_eq!(layout_for(61, None), None);
        assert_eq!(layout_for(73, None), Some(InMotionLayout::V12));
        assert_eq!(layout_for(999, None), None);
    }

    /// `payload_formats.V2_RealTime_V11_Early.example`.
    #[test]
    fn realtime_v11_early_vector() {
        let frame = one(
            "aaaa143184e61eeb0561094a11ae04a004df01402958cbb000ce004a010000d4ff7c15641900000000492b00000000000000000000c6",
        );
        assert_eq!(frame.kind, InMotionFrameKind::RealTime);
        let t = decode_realtime(InMotionLayout::V11Early, &frame.data).unwrap();
        assert!(close(t.voltage_v, 79.10));
        assert!(close(t.current_a, 15.15));
        assert!(close(t.speed_kmh, 24.01));
        assert_eq!(t.battery_percent, Some(88.0));
        assert!(close(t.trip_km.unwrap(), 4.79));
        assert!(close(t.remaining_km.unwrap(), 105.60));
        assert_eq!(t.mos_temperature_c, Some(27));
        assert_eq!(t.board_temperature_c, Some(30));
        assert!(close(t.speed_limit_kmh.unwrap(), 55.00));
    }

    /// `test_vectors.v2_realtime_reply_escaped_v11`: an escaped data byte and
    /// an escaped checksum.
    #[test]
    fn realtime_escaped_vector() {
        let frame = one(
            "aaaa1431843020a5a50068025207870080009400882c5fc4b000d7001000f4ff2b037c1564190000d9d9492b00000000000000000000a5a5",
        );
        let t = decode_realtime(InMotionLayout::V11Early, &frame.data).unwrap();
        assert!(close(t.voltage_v, 82.40));
        assert!(close(t.current_a, 1.65));
        assert!(close(t.speed_kmh, 6.16));
    }

    /// `test_vectors.v2_realtime_reply_v11_1_4`.
    #[test]
    fn realtime_v11_from_1_4_vector() {
        let frame = one(
            "aaaa1445842d1d10000000efff070000000000000000002b0300000000000000008a149612e02e8813641900000000cbb000cccad1000028000000000049140000000000000000000021",
        );
        let t = decode_realtime(InMotionLayout::V11From14, &frame.data).unwrap();
        assert!(close(t.voltage_v, 74.69));
        assert!(close(t.speed_kmh, 0.0));
        assert!(close(t.battery_percent.unwrap(), 52.58));
        assert_eq!(t.mos_temperature_c, Some(27));
        assert_eq!(t.board_temperature_c, Some(28));
    }

    /// `payload_formats.V2_TotalStats.example`: 278.80 km, ride 16:23:00,
    /// power-on 96:32:23.
    #[test]
    fn total_stats_vector() {
        let frame = one("aaaa141991e86c000066191c002db2040064e60000974d050000c7df01a4");
        assert_eq!(frame.kind, InMotionFrameKind::TotalStats);
        let totals = decode_totals(&frame.data).unwrap();
        assert!(close(totals.total_km, 278.80));
        assert_eq!(totals.ride_time_s, 16 * 3600 + 23 * 60);
        assert_eq!(totals.power_on_time_s, 96 * 3600 + 32 * 60 + 23);
    }

    #[test]
    fn frames_split_across_notifications_and_garbage_between_them() {
        let whole = hex("aaaa110882010206010201009c");
        let first = feed(&[], &[&[0x00, 0x13][..], &whole[..5]].concat());
        assert!(first.frames.is_empty());
        let second = feed(&first.buffer, &[&whole[5..], &whole[..]].concat());
        assert_eq!(second.frames.len(), 2);
        assert_eq!(second.dropped, 0);
    }

    #[test]
    fn a_bad_checksum_is_dropped_and_counted() {
        let mut bad = hex("aaaa110882010206010201009c");
        *bad.last_mut().unwrap() ^= 1;
        let fed = feed(&[], &bad);
        assert!(fed.frames.is_empty());
        assert_eq!(fed.dropped, 1);
        // And a frame cut short by the next header.
        let cut = [
            &hex("aaaa1108820102")[..],
            &hex("aaaa110882010206010201009c")[..],
        ]
        .concat();
        let fed = feed(&[], &cut);
        assert_eq!(fed.frames.len(), 1);
        assert_eq!(fed.dropped, 1);
    }

    #[test]
    fn short_replies_are_refused() {
        assert!(decode_realtime(InMotionLayout::V12, &[0; 43]).is_err());
        assert!(decode_car_type(&[0x01, 0x02]).is_err());
        assert!(decode_versions(&[0x06; 10]).is_err());
        assert!(decode_totals(&[0; 19]).is_err());
    }

    #[test]
    fn a_legacy_wheel_is_refused() {
        let legacy = vec![
            LEGACY_SERVICE.to_string(),
            "0000ffe5-0000-1000-8000-00805f9b34fb".to_string(),
        ];
        assert!(refuses_wheel(&legacy).unwrap().contains("legacy"));
        let v2 = vec![V2_SERVICE.to_uppercase(), LEGACY_SERVICE.to_string()];
        assert!(refuses_wheel(&v2).is_none());
    }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! Yummly T1 + P1 (XW2) probe temperatures over BLE, read-only.
//!
//! The `yummly-smart-thermometer` spec's `payload_formats.Xw2Frame` states the
//! TLV and `protocol_details.xw2_rotation_packing` the bit rotation hiding
//! every number. Dart owns GATT; this module owns the bytes.
//!
//! ```text
//! frame:   [size][type][value...]          size = value length + 1
//! wrapped: [07][07][address, reversed][inner size][inner type][inner value...]
//! packed:  [selector s, 4 bits][field, W bits]   field = reading rotated right by s
//! ```
//!
//! XW2 ONLY. The T3 + P3 generation shares the spec but nobody has run it, so
//! nothing here claims it. The bytes this file can produce are the challenge
//! reply and the named reads in [`YummlyRead`]; 0xac, the request that drops a
//! probe into its bootloader, cannot be built.

use crate::error::ProtocolError;

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "yummly_xw2_tlv";

/// The XW2 service, and the two characteristics on it.
pub const SERVICE: &str = "6e40abcd-b5a3-f393-e0a9-e50e4159414d";
pub const REQUEST_CHARACTERISTIC: &str = "6e40aa02-b5a3-f393-e0a9-e50e4159414d";
pub const NOTIFY_CHARACTERISTIC: &str = "6e40aa03-b5a3-f393-e0a9-e50e4159414d";

const BRAND_ID: u32 = 2;
const CORE_WIDTH: u32 = 20;
const BODY_WIDTH: u32 = 12;
const BATTERY_WIDTH: u32 = 4;
const CORE_LIMITS: (u32, u32) = (320, 2120);
const BODY_LIMITS: (u32, u32) = (32, 572);

const TYPE_DOCK_FIRMWARE: u8 = 0x04;
const TYPE_WRAPPED: u8 = 0x07;
const TYPE_DOCK_BATTERY: u8 = 0x15;
const TYPE_PROBE_MAC: u8 = 0x20;
const TYPE_PING: u8 = 0xab;

const INNER_CORE: u8 = 0x01;
const INNER_BODY: u8 = 0x02;
const INNER_BATTERY: u8 = 0x03;
const INNER_FIRMWARE: u8 = 0x12;
const INNER_STATUS: u8 = 0x1e;
const INNER_NAME: u8 = 0x22;

/// What this app asks a dock. Each is a request byte from
/// `xw2_request_reply_types`, named so no caller supplies a raw one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum YummlyRead {
    DockFirmware,
    DockBattery,
    ProbeMac,
    ProbeName,
    ProbeBattery,
}

impl YummlyRead {
    fn request(self) -> u8 {
        match self {
            Self::DockFirmware => 0x09,
            Self::DockBattery => 0x16,
            Self::ProbeMac => 0x21,
            Self::ProbeName => 0x23,
            Self::ProbeBattery => 0x0c,
        }
    }

    fn targets_probe(self) -> bool {
        matches!(self, Self::ProbeName | Self::ProbeBattery)
    }
}

/// What one notification turned out to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum YummlyFrameKind {
    ChallengePing,
    DockFirmware,
    DockBattery,
    ProbeAddress,
    CoreTemperature,
    BodyTemperature,
    ProbeBattery,
    ProbeStatus,
    ProbeFirmware,
    ProbeName,
    /// A well-formed frame of a type this app does not read. The spec says to
    /// drop these, so it is not a fault in the device.
    Other,
}

/// One decoded notification; only the fields its `kind` names are set.
#[derive(Debug, Clone, PartialEq)]
pub struct YummlyFrameDto {
    pub kind: YummlyFrameKind,
    /// Degrees Fahrenheit, after the spec's clamp.
    pub temperature_f: Option<f64>,
    /// The reading sat at or beyond the clamp. The spec warns a reading pinned
    /// at a limit may be hiding a fault, so the screen has to be able to say so.
    pub at_limit: bool,
    pub battery_gauge: Option<u8>,
    pub battery_bars: Option<u8>,
    pub text: Option<String>,
    /// As the dock sent it, least significant byte first. Goes back unchanged
    /// in a probe-targeted request. `None` for the all-zero "no probe" reply.
    pub probe_address_reversed: Option<Vec<u8>>,
    /// Probe status byte: 0x04 connected, anything else a reason code.
    pub status: Option<u8>,
}

impl YummlyFrameDto {
    fn of(kind: YummlyFrameKind) -> Self {
        Self {
            kind,
            temperature_f: None,
            at_limit: false,
            battery_gauge: None,
            battery_bars: None,
            text: None,
            probe_address_reversed: None,
            status: None,
        }
    }
}

fn malformed(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::MalformedReply(reason.into())
}

/// `02 aa <code>`: the brand id rotated right by `selector` (0..=2) within
/// four bits, with the selector in the top nibble. This write answers the
/// dock's ping and changes nothing on it.
pub fn encode_challenge_reply(selector: u8) -> Result<Vec<u8>, ProtocolError> {
    if selector > 2 {
        return Err(ProtocolError::ParameterOutOfRange {
            name: "selector".to_string(),
            value: f64::from(selector),
            min: 0.0,
            max: 2.0,
        });
    }
    let s = u32::from(selector);
    let rotated = ((BRAND_ID >> s) | (BRAND_ID << (BATTERY_WIDTH - s))) & 0x0f;
    Ok(vec![0x02, 0xaa, (rotated | (s << 4)) as u8])
}

/// The request for one read. A probe-targeted read needs the address the dock
/// reported, sent back exactly as it came.
pub fn encode_read(
    read: YummlyRead,
    probe_address_reversed: Option<&[u8]>,
) -> Result<Vec<u8>, ProtocolError> {
    if !read.targets_probe() {
        return Ok(vec![0x01, read.request()]);
    }
    let address = probe_address_reversed
        .ok_or_else(|| ProtocolError::ParameterMissing("probe_address_reversed".to_string()))?;
    if address.len() != 6 {
        return Err(malformed("a probe address is six bytes"));
    }
    let mut out = vec![0x07, 0x07];
    out.extend_from_slice(address);
    out.extend_from_slice(&[0x01, read.request()]);
    Ok(out)
}

/// Undo the rotation on a little-endian packed value of `bytes` bytes.
///
/// `None` when the selector is not meaningful for this field's width, which
/// the spec states for W = 12 and W = 4: a frame carrying one is not a reading.
fn unpack(bytes: &[u8], width: u32) -> Option<u32> {
    let packed = bytes
        .iter()
        .rev()
        .fold(0u32, |acc, byte| (acc << 8) | u32::from(*byte));
    let selector = packed >> width;
    if selector >= width {
        return None;
    }
    let mask = (1u32 << width) - 1;
    let field = packed & mask;
    Some(((field << selector) | (field >> (width - selector))) & mask)
}

/// `payload_formats.Xw2Battery`'s display bars.
fn bars(gauge: u8) -> u8 {
    match gauge {
        1..=3 => 1,
        4..=5 => 2,
        6..=8 => 3,
        9 => 4,
        _ => 0,
    }
}

fn text_of(value: &[u8]) -> String {
    let end = value
        .iter()
        .rposition(|byte| *byte != 0)
        .map_or(0, |last| last + 1);
    String::from_utf8_lossy(&value[..end]).into_owned()
}

fn battery(kind: YummlyFrameKind, value: &[u8]) -> Result<YummlyFrameDto, ProtocolError> {
    let [packed] = value else {
        return Err(malformed("a battery value is one byte"));
    };
    let gauge = unpack(&[*packed], BATTERY_WIDTH)
        .ok_or_else(|| malformed("a battery selector above 3 is not a reading"))?
        as u8;
    Ok(YummlyFrameDto {
        battery_gauge: Some(gauge),
        battery_bars: Some(bars(gauge)),
        ..YummlyFrameDto::of(kind)
    })
}

fn temperature(
    kind: YummlyFrameKind,
    value: &[u8],
    width: u32,
    limits: (u32, u32),
    divisor: f64,
) -> Result<YummlyFrameDto, ProtocolError> {
    let raw = unpack(value, width)
        .ok_or_else(|| malformed("a temperature selector past its field is not a reading"))?;
    Ok(YummlyFrameDto {
        temperature_f: Some(f64::from(raw.clamp(limits.0, limits.1)) / divisor),
        at_limit: raw <= limits.0 || raw >= limits.1,
        ..YummlyFrameDto::of(kind)
    })
}

/// Decode one notification from 6e40aa03. `Err` is a frame that breaks the
/// TLV rule or a field it promises; an unknown type is [`YummlyFrameKind::Other`].
pub fn decode_frame(frame: &[u8]) -> Result<YummlyFrameDto, ProtocolError> {
    let [size, kind, ..] = frame else {
        return Err(ProtocolError::BufferTooShort {
            needed: 2,
            got: frame.len(),
        });
    };
    let size = usize::from(*size);
    if size == 0 || frame.len() < size + 1 {
        return Err(malformed(format!(
            "size byte {size} does not fit a {} byte frame",
            frame.len()
        )));
    }
    let value = &frame[2..=size];
    match *kind {
        TYPE_PING if value.is_empty() => Ok(YummlyFrameDto::of(YummlyFrameKind::ChallengePing)),
        TYPE_DOCK_FIRMWARE => Ok(YummlyFrameDto {
            text: Some(text_of(value)),
            ..YummlyFrameDto::of(YummlyFrameKind::DockFirmware)
        }),
        TYPE_DOCK_BATTERY => battery(YummlyFrameKind::DockBattery, value),
        TYPE_PROBE_MAC => {
            if size != 7 {
                return Err(malformed("a probe address reply has size 7"));
            }
            Ok(YummlyFrameDto {
                probe_address_reversed: value.iter().any(|byte| *byte != 0).then(|| value.to_vec()),
                ..YummlyFrameDto::of(YummlyFrameKind::ProbeAddress)
            })
        }
        TYPE_WRAPPED => decode_wrapped(frame, size),
        _ => Ok(YummlyFrameDto::of(YummlyFrameKind::Other)),
    }
}

fn decode_wrapped(frame: &[u8], size: usize) -> Result<YummlyFrameDto, ProtocolError> {
    if size != 7 {
        return Err(malformed("a probe-wrapped frame has outer size 7"));
    }
    if frame.len() < 10 {
        return Err(ProtocolError::BufferTooShort {
            needed: 10,
            got: frame.len(),
        });
    }
    let inner_size = usize::from(frame[8]);
    let inner_type = frame[9];
    if inner_size == 0 || frame.len() < 9 + inner_size {
        return Err(malformed(format!(
            "inner size {inner_size} does not fit a {} byte frame",
            frame.len()
        )));
    }
    let value = &frame[10..9 + inner_size];
    let sized = |expected: usize| {
        if inner_size == expected {
            Ok(())
        } else {
            Err(malformed(format!(
                "inner type 0x{inner_type:02x} has size {expected}, not {inner_size}"
            )))
        }
    };
    let address = &frame[2..8];
    let reading = match inner_type {
        INNER_CORE => {
            sized(4)?;
            temperature(
                YummlyFrameKind::CoreTemperature,
                value,
                CORE_WIDTH,
                CORE_LIMITS,
                10.0,
            )
        }
        INNER_BODY => {
            sized(3)?;
            temperature(
                YummlyFrameKind::BodyTemperature,
                value,
                BODY_WIDTH,
                BODY_LIMITS,
                1.0,
            )
        }
        INNER_BATTERY => battery(YummlyFrameKind::ProbeBattery, value),
        INNER_STATUS => {
            sized(2)?;
            Ok(YummlyFrameDto {
                status: Some(value[0]),
                ..YummlyFrameDto::of(YummlyFrameKind::ProbeStatus)
            })
        }
        INNER_FIRMWARE => Ok(YummlyFrameDto {
            text: Some(text_of(value)),
            ..YummlyFrameDto::of(YummlyFrameKind::ProbeFirmware)
        }),
        INNER_NAME => Ok(YummlyFrameDto {
            text: Some(text_of(value)),
            ..YummlyFrameDto::of(YummlyFrameKind::ProbeName)
        }),
        _ => Ok(YummlyFrameDto::of(YummlyFrameKind::Other)),
    }?;
    // Any wrapped frame names the probe, which is how a client learns the
    // address when the 0x21 reply reports none (the spec's source saw an
    // all-zero status frame while the probe was streaming).
    Ok(YummlyFrameDto {
        probe_address_reversed: address
            .iter()
            .any(|byte| *byte != 0)
            .then(|| address.to_vec()),
        ..reading
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bytes(text: &str) -> Vec<u8> {
        text.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect()
    }

    fn hex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
            .collect()
    }

    /// The frames below are copied by hand; a spec refresh that changes one
    /// should fail here rather than leave these tests proving an old format.
    #[test]
    fn the_literal_frames_are_the_ones_the_spec_prints() {
        let text = std::fs::read_to_string(format!(
            "{}/../vendor/protocol-specs/device-specs/devices/yummly-smart-thermometer.yaml",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap();
        for vector in [
            "07 07 01 53 00 5e 00 00 04 01 4b 01 20",
            "07 07 01 53 00 5e 00 00 03 02 89 18",
            "05 04 31 2e 35 33",
            "02 15 2d",
            "07 07 01 53 00 5e 00 00 0b 22 59 75 6d 6d 6c 79 20 50 31 00",
            "07 07 01 53 00 5e 00 00 02 03 33",
            "07 07 00 00 00 00 00 00 02 1e 05",
            "07 07 01 53 00 5e 00 00 01 23",
            "07 20 01 53 00 5e 00 00",
            "02 aa 02",
            "4b0120",
            "80a5f0",
            "26b2",
        ] {
            assert!(text.contains(vector), "{vector} is not in the spec");
        }
    }

    /// `xw2_auth_challenge.vectors` and `reply_frame_example`.
    #[test]
    fn the_challenge_reply_matches_the_spec_vectors() {
        assert_eq!(encode_challenge_reply(0).unwrap(), bytes("02 aa 02"));
        assert_eq!(encode_challenge_reply(1).unwrap(), bytes("02 aa 11"));
        assert_eq!(encode_challenge_reply(2).unwrap(), bytes("02 aa 28"));
        assert!(encode_challenge_reply(3).is_err());
    }

    /// `xw2_rotation_packing.vectors`: every battery, core and body row.
    #[test]
    fn the_rotation_decodes_every_spec_vector() {
        for (packed, gauge, bar) in [("2d", 7, 3), ("33", 9, 4), ("07", 7, 3), ("1b", 7, 3)] {
            let unpacked = unpack(&hex(packed), BATTERY_WIDTH).unwrap();
            assert_eq!(unpacked, gauge, "{packed}");
            assert_eq!(bars(unpacked as u8), bar, "{packed}");
        }
        for (packed, decoded) in [
            ("2c0500", 1324),
            ("4b0120", 1324),
            ("a50038", 1324),
            ("80a5f0", 1324),
            ("c70028", 798),
            ("090130", 2120),
        ] {
            assert_eq!(unpack(&hex(packed), CORE_WIDTH), Some(decoded), "{packed}");
        }
        for (packed, decoded) in [
            ("1301", 275),
            ("8918", 275),
            ("2236", 275),
            ("2718", 79),
            ("26b2", 275),
        ] {
            assert_eq!(unpack(&hex(packed), BODY_WIDTH), Some(decoded), "{packed}");
        }
    }

    #[test]
    fn a_selector_past_the_field_is_not_a_reading() {
        assert_eq!(unpack(&[0x40], BATTERY_WIDTH), None);
        assert_eq!(unpack(&hex("00c0"), BODY_WIDTH), None);
        // A 20-bit field takes every selector its nibble can hold.
        assert!(unpack(&hex("0000f0"), CORE_WIDTH).is_some());
    }

    /// The full frames the vector notes print.
    #[test]
    fn the_core_and_body_frames_decode() {
        let core = decode_frame(&bytes("07 07 01 53 00 5e 00 00 04 01 4b 01 20")).unwrap();
        assert_eq!(core.kind, YummlyFrameKind::CoreTemperature);
        assert_eq!(core.temperature_f, Some(132.4));
        assert!(!core.at_limit);
        assert_eq!(
            core.probe_address_reversed,
            Some(bytes("01 53 00 5e 00 00"))
        );

        let body = decode_frame(&bytes("07 07 01 53 00 5e 00 00 03 02 89 18")).unwrap();
        assert_eq!(body.kind, YummlyFrameKind::BodyTemperature);
        assert_eq!(body.temperature_f, Some(275.0));
        assert!(!body.at_limit);
    }

    /// The firmware clamps, and the safety advisory warns about it: a pinned
    /// value reports the limit and says it is one.
    #[test]
    fn a_reading_at_a_clamp_says_so() {
        // The spec's "upper clamp" vector: 2120 tenths exactly.
        let top = decode_frame(&bytes("07 07 01 53 00 5e 00 00 04 01 09 01 30")).unwrap();
        assert_eq!(top.temperature_f, Some(212.0));
        assert!(top.at_limit);

        // Past the clamp: 3000 tenths, unrotated, shows as 212.0 and pinned.
        let past = decode_frame(&bytes("07 07 01 53 00 5e 00 00 04 01 b8 0b 00")).unwrap();
        assert_eq!(past.temperature_f, Some(212.0));
        assert!(past.at_limit);

        // Below it: the source project's 8 F body reading clamps to 32.
        let low = decode_frame(&bytes("07 07 01 53 00 5e 00 00 03 02 08 00")).unwrap();
        assert_eq!(low.temperature_f, Some(32.0));
        assert!(low.at_limit);
    }

    /// `xw2_published_frames`.
    #[test]
    fn the_published_frames_decode() {
        let ping = decode_frame(&bytes("01 ab")).unwrap();
        assert_eq!(ping.kind, YummlyFrameKind::ChallengePing);

        let firmware = decode_frame(&bytes("05 04 31 2e 35 33")).unwrap();
        assert_eq!(firmware.kind, YummlyFrameKind::DockFirmware);
        assert_eq!(firmware.text.as_deref(), Some("1.53"));

        let dock = decode_frame(&bytes("02 15 2d")).unwrap();
        assert_eq!(dock.kind, YummlyFrameKind::DockBattery);
        assert_eq!(dock.battery_gauge, Some(7));
        assert_eq!(dock.battery_bars, Some(3));

        let name = decode_frame(&bytes(
            "07 07 01 53 00 5e 00 00 0b 22 59 75 6d 6d 6c 79 20 50 31 00",
        ))
        .unwrap();
        assert_eq!(name.kind, YummlyFrameKind::ProbeName);
        assert_eq!(name.text.as_deref(), Some("Yummly P1"));

        let probe = decode_frame(&bytes("07 07 01 53 00 5e 00 00 02 03 33")).unwrap();
        assert_eq!(probe.kind, YummlyFrameKind::ProbeBattery);
        assert_eq!(probe.battery_bars, Some(4));

        let status = decode_frame(&bytes("07 07 00 00 00 00 00 00 02 1e 05")).unwrap();
        assert_eq!(status.kind, YummlyFrameKind::ProbeStatus);
        assert_eq!(status.status, Some(0x05));
        assert_eq!(status.probe_address_reversed, None);
    }

    #[test]
    fn the_probe_address_reply_decodes_and_zero_means_no_probe() {
        let address = decode_frame(&bytes("07 20 01 53 00 5e 00 00")).unwrap();
        assert_eq!(address.kind, YummlyFrameKind::ProbeAddress);
        assert_eq!(
            address.probe_address_reversed,
            Some(bytes("01 53 00 5e 00 00"))
        );
        let none = decode_frame(&bytes("07 20 00 00 00 00 00 00")).unwrap();
        assert_eq!(none.kind, YummlyFrameKind::ProbeAddress);
        assert_eq!(none.probe_address_reversed, None);
    }

    /// The requests the spec's `value` and `template` state, `probe_name_request`
    /// among them printed in full.
    #[test]
    fn the_requests_are_the_specs() {
        assert_eq!(
            encode_read(YummlyRead::DockFirmware, None).unwrap(),
            bytes("01 09")
        );
        assert_eq!(
            encode_read(YummlyRead::DockBattery, None).unwrap(),
            bytes("01 16")
        );
        assert_eq!(
            encode_read(YummlyRead::ProbeMac, None).unwrap(),
            bytes("01 21")
        );
        let address = bytes("01 53 00 5e 00 00");
        assert_eq!(
            encode_read(YummlyRead::ProbeName, Some(&address)).unwrap(),
            bytes("07 07 01 53 00 5e 00 00 01 23")
        );
        assert_eq!(
            encode_read(YummlyRead::ProbeBattery, Some(&address)).unwrap(),
            bytes("07 07 01 53 00 5e 00 00 01 0c")
        );
        assert!(encode_read(YummlyRead::ProbeName, None).is_err());
        assert!(encode_read(YummlyRead::ProbeName, Some(&[1, 2])).is_err());
    }

    /// 0xac is the bootloader request. No read's request byte is it.
    #[test]
    fn no_read_can_ask_for_the_bootloader() {
        for read in [
            YummlyRead::DockFirmware,
            YummlyRead::DockBattery,
            YummlyRead::ProbeMac,
            YummlyRead::ProbeName,
            YummlyRead::ProbeBattery,
        ] {
            assert_ne!(read.request(), 0xac);
        }
    }

    #[test]
    fn garbage_is_an_error_and_never_a_reading() {
        for frame in [
            "",
            "01",
            "00 ab",
            "05 04 31",
            "ff ff",
            // A battery with a selector past the nibble.
            "02 15 40",
            "02 15 2d 2d",
            // A wrapped frame with no inner header, a short value, or a bad size.
            "07 07 01 53 00 5e 00 00",
            "07 07 01 53 00 5e 00 00 04 01 4b",
            "07 07 01 53 00 5e 00 00 03 01 4b 01",
            "07 07 01 53 00 5e 00 00 04 02 4b 01 20",
            "06 07 01 53 00 5e 00 00 04 01 4b 01 20",
            // A probe address of the wrong size.
            "06 20 01 53 00 5e 00",
        ] {
            let parsed = decode_frame(&bytes(frame));
            let reading = parsed.as_ref().ok().and_then(|f| f.temperature_f);
            assert_eq!(reading, None, "{frame:?}");
            if frame != "02 15 2d 2d" {
                assert!(parsed.is_err(), "{frame:?} decoded as {parsed:?}");
            }
        }
    }

    #[test]
    fn a_well_formed_frame_of_another_type_is_dropped_quietly() {
        let other = decode_frame(&bytes("02 99 01")).unwrap();
        assert_eq!(other.kind, YummlyFrameKind::Other);
        let inner = decode_frame(&bytes("07 07 01 53 00 5e 00 00 02 77 01")).unwrap();
        assert_eq!(inner.kind, YummlyFrameKind::Other);
    }
}

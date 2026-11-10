// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Settings for a Vevor VT256 / Hti-Xintai HT-W01 thermal camera over its TCP
//! command channel (`vevor-vt256-thermal-imager.yaml`, handler
//! `ht_w01_command`).
//!
//! The phone joins the camera's own access point and talks to 192.168.1.10
//! on TCP 8080. Every frame is the spec's `ht_w01_protocol.framing`:
//! `[0xFB][length u32 LE = total - 3][cmdType][17 zero bytes][data unit]`
//! `[CRC-16/XMODEM over bytes 1..len-3, low byte first]`.
//!
//! What this module can build is a closed list: the heartbeat, the GETs of
//! palette, measuring range, emissivity and version, and the SETs of
//! palette, measuring range and emissivity, plus the shutter refresh. Each
//! takes only a value the spec lists. Everything else the spec declares is
//! listed by [`command_policy`] and refused, with the reason:
//!
//! - `action_reset_config` is unflagged in the spec, yet the spec cannot say
//!   what it resets (whether the access point's name and passphrase too).
//! - `action_restart_device` and `set_wifi_channel` drop the very network the
//!   phone is on.
//! - `set_distance`'s unit was not recovered.
//!
//! The UDP 8888 thermal stream is not decoded at all: the spec says its
//! layout was not recovered. Nor is a reply's value layout known; a reply is
//! checked for its envelope and CRC, and a value is read from it only when
//! its data unit is `[parameter id, value]`, which is an assumption.
//!
//! Nothing here opens a socket.

use crate::error::ProtocolError;
use crate::protocol::readonly::ReadOnlyCommandDto;
use crate::spec::types::DeviceSpec;

/// The spec `protocol_handler` this module answers to.
pub const HANDLER_NAME: &str = "ht_w01_command";

/// The camera's fixed address on its own access point, and its command port.
pub const DEFAULT_HOST: &str = "192.168.1.10";
pub const PORT: u16 = 8080;

const MAGIC: u8 = 0xFB;
const DATA_OFFSET: usize = 23;
/// Magic, length, type, reserved, CRC.
const OVERHEAD: usize = 25;
const MAX_FRAME: usize = 64 * 1024;

const HEART_BEAT: u8 = 0x31;
const GET_PARAM: u8 = 0x33;
const SET_PARAM: u8 = 0x34;
const ACTION: u8 = 0x35;

const ACTION_REFRESH_SHUTTER: u8 = 0x01;

/// `ht_w01_protocol.palette_values`.
pub const PALETTES: &[(u8, &str)] = &[
    (1, "white hot"),
    (3, "sepia"),
    (4, "ironbow"),
    (5, "rainbow"),
    (6, "night"),
    (7, "aurora"),
    (8, "red hot"),
    (9, "jungle"),
    (10, "medical"),
    (11, "black hot"),
];

/// A parameter this app reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HtW01Param {
    Palette,
    MeasuringRange,
    Emissivity,
    VersionInfo,
}

impl HtW01Param {
    pub fn id(self) -> u8 {
        match self {
            Self::Palette => 0x01,
            Self::MeasuringRange => 0x03,
            Self::Emissivity => 0x04,
            Self::VersionInfo => 0x10,
        }
    }
}

/// `parameter_ids` 0x03: 0 Large (120..550 C), 1 Small (-20..120 C).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HtW01Range {
    Large,
    Small,
}

/// CRC-16/XMODEM: poly 0x1021, init 0, no reflection, no final XOR.
pub fn crc16_xmodem(data: &[u8]) -> u16 {
    let mut crc: u16 = 0;
    for &byte in data {
        crc ^= u16::from(byte) << 8;
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

/// One frame. Private: every public builder fixes its type and checks its
/// value.
fn frame(cmd_type: u8, data: &[u8]) -> Vec<u8> {
    let total = OVERHEAD + data.len();
    let mut out = Vec::with_capacity(total);
    out.push(MAGIC);
    out.extend_from_slice(&((total - 3) as u32).to_le_bytes());
    out.push(cmd_type);
    out.extend_from_slice(&[0u8; 17]);
    out.extend_from_slice(data);
    let crc = crc16_xmodem(&out[1..]);
    out.extend_from_slice(&crc.to_le_bytes());
    out
}

/// The keep-alive; `counter` starts at 1 and increments per heartbeat.
pub fn heartbeat(counter: u8) -> Vec<u8> {
    frame(HEART_BEAT, &[counter])
}

pub fn get_param(param: HtW01Param) -> Vec<u8> {
    frame(GET_PARAM, &[param.id()])
}

/// SET palette, to one of [`PALETTES`].
pub fn set_palette(value: u8) -> Result<Vec<u8>, ProtocolError> {
    if !PALETTES.iter().any(|(v, _)| *v == value) {
        return Err(ProtocolError::ParameterValueInvalid {
            name: "palette".to_string(),
            value: value.to_string(),
            reason: "not one of the spec's palette values".to_string(),
        });
    }
    Ok(frame(SET_PARAM, &[HtW01Param::Palette.id(), value]))
}

pub fn set_measuring_range(range: HtW01Range) -> Vec<u8> {
    let value = match range {
        HtW01Range::Large => 0,
        HtW01Range::Small => 1,
    };
    frame(SET_PARAM, &[HtW01Param::MeasuringRange.id(), value])
}

/// SET emissivity, as hundredths (0.95 is 95), 0..=100.
pub fn set_emissivity(hundredths: u8) -> Result<Vec<u8>, ProtocolError> {
    if hundredths > 100 {
        return Err(ProtocolError::ParameterOutOfRange {
            name: "emissivity".to_string(),
            value: f64::from(hundredths),
            min: 0.0,
            max: 100.0,
        });
    }
    Ok(frame(SET_PARAM, &[HtW01Param::Emissivity.id(), hundredths]))
}

/// ACTION RefreshShutter: a flat-field correction.
pub fn refresh_shutter() -> Vec<u8> {
    frame(ACTION, &[ACTION_REFRESH_SHUTTER, 0x00])
}

/// One reply frame, read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HtW01ReplyDto {
    pub cmd_type: u8,
    pub data: Vec<u8>,
}

/// Frames cut from a byte stream, and what is left over.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HtW01SplitDto {
    pub frames: Vec<HtW01ReplyDto>,
    pub rest: Vec<u8>,
    /// Bytes skipped as garbage, or frames dropped for a bad CRC.
    pub discarded: u32,
}

/// Cut whole, CRC-valid frames from `buffer`. Bytes before a magic are
/// skipped, and a frame whose CRC fails is dropped and the search resumes
/// one byte on, so garbage cannot wedge the stream.
pub fn split_stream(buffer: &[u8]) -> HtW01SplitDto {
    let mut frames = Vec::new();
    let mut discarded = 0u32;
    let mut at = 0;
    while at < buffer.len() {
        if buffer[at] != MAGIC {
            at += 1;
            discarded += 1;
            continue;
        }
        let Some(len_bytes) = buffer.get(at + 1..at + 5) else {
            break;
        };
        let length = u32::from_le_bytes(len_bytes.try_into().unwrap_or_default()) as usize;
        let total = length.saturating_add(3);
        if !(OVERHEAD..=MAX_FRAME).contains(&total) {
            at += 1;
            discarded += 1;
            continue;
        }
        let Some(candidate) = buffer.get(at..at + total) else {
            break;
        };
        let crc = u16::from_le_bytes([candidate[total - 2], candidate[total - 1]]);
        if crc16_xmodem(&candidate[1..total - 2]) != crc {
            at += 1;
            discarded += 1;
            continue;
        }
        frames.push(HtW01ReplyDto {
            cmd_type: candidate[5],
            data: candidate[DATA_OFFSET..total - 2].to_vec(),
        });
        at += total;
    }
    HtW01SplitDto {
        frames,
        rest: buffer[at.min(buffer.len())..].to_vec(),
        discarded,
    }
}

/// A one-byte value from a GET reply, when its data unit is
/// `[parameter id, value]`. The reply layout is not recovered, so anything
/// else is `None` rather than a guess.
pub fn reply_value(reply: &HtW01ReplyDto, param: HtW01Param) -> Option<u8> {
    (reply.cmd_type == GET_PARAM && reply.data.len() == 2 && reply.data[0] == param.id())
        .then(|| reply.data[1])
}

/// `ht_w01_protocol.status_codes`.
pub fn status_meaning(code: u8) -> &'static str {
    match code {
        0x00 => "success",
        0x1F => "POST_CMS",
        0x33 => "parameter error",
        0x44 => "CRC error",
        0xFD => "unknown command",
        _ => "a code the spec does not list",
    }
}

/// The commands this app sends, each from the builder above.
const SENT: &[&str] = &[
    "heartbeat",
    "get_version_info",
    "get_palette",
    "set_palette",
    "get_measuring_range",
    "set_measuring_range_small",
    "set_measuring_range_large",
    "get_emissivity",
    "set_emissivity",
    "action_refresh_shutter",
];

/// Why each refused command is refused. A command the spec adds later and
/// this table does not name is refused too.
fn refusal(name: &str) -> &'static str {
    match name {
        "action_reset_config" => {
            "Not sent by this app: the spec cannot say what it resets, whether \
             that includes the camera's own Wi-Fi name and passphrase, and \
             there is no known way back."
        }
        "action_restart_device" => {
            "Not sent by this app: the camera's access point drops, and this \
             phone with it."
        }
        "set_wifi_channel" => {
            "Not sent by this app: it moves the access point this phone is \
             connected through."
        }
        "get_distance" | "set_distance" => {
            "Not sent by this app: the distance unit was not recovered, so a \
             value could not be shown or chosen honestly."
        }
        _ => "Not sent by this app: no encoder for it here.",
    }
}

/// Every command the spec declares, in spec order, and whether this app
/// sends it.
pub fn command_policy(spec: &DeviceSpec) -> Vec<ReadOnlyCommandDto> {
    if spec.protocol_handler.as_deref() != Some(HANDLER_NAME) {
        return Vec::new();
    }
    spec.commands
        .iter()
        .map(|(name, command)| {
            let sent = SENT.contains(&name.as_str());
            ReadOnlyCommandDto {
                name: name.clone(),
                description: command.description.clone(),
                sent,
                refusal: (!sent).then(|| refusal(name).to_string()),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn spec_text() -> String {
        std::fs::read_to_string(format!(
            "{}/../vendor/protocol-specs/device-specs/devices/vevor-vt256-thermal-imager.yaml",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap()
    }

    fn spec() -> DeviceSpec {
        parse_device_spec(&spec_text()).unwrap()
    }

    fn literal(name: &str) -> Vec<u8> {
        let body = spec().commands[name].body.clone().unwrap();
        body.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect()
    }

    #[test]
    fn the_constants_are_the_specs() {
        let doc: serde_yaml::Value = serde_yaml::from_str(&spec_text()).unwrap();
        assert_eq!(doc["protocol_handler"].as_str(), Some(HANDLER_NAME));
        assert_eq!(
            doc["device"]["identification"]["default_port"].as_u64(),
            Some(u64::from(PORT))
        );
        let palettes = doc["protocol_details"]["ht_w01_protocol"]["palette_values"]
            .as_mapping()
            .unwrap();
        assert_eq!(palettes.len(), PALETTES.len());
        for (value, name) in PALETTES {
            assert_eq!(
                palettes
                    .get(serde_yaml::Value::from(u64::from(*value)))
                    .and_then(|v| v.as_str()),
                Some(*name)
            );
        }
    }

    #[test]
    fn crc16_is_xmodem() {
        assert_eq!(crc16_xmodem(b"123456789"), 0x31C3);
        assert_eq!(crc16_xmodem(b""), 0);
    }

    /// Every frame this app sends, byte for byte the spec's literal body.
    #[test]
    fn the_sent_frames_are_the_specs_literal_frames() {
        assert_eq!(heartbeat(1), literal("heartbeat"));
        assert_eq!(
            get_param(HtW01Param::VersionInfo),
            literal("get_version_info")
        );
        assert_eq!(get_param(HtW01Param::Palette), literal("get_palette"));
        assert_eq!(set_palette(1).unwrap(), literal("set_palette"));
        assert_eq!(
            get_param(HtW01Param::MeasuringRange),
            literal("get_measuring_range")
        );
        assert_eq!(
            set_measuring_range(HtW01Range::Small),
            literal("set_measuring_range_small")
        );
        assert_eq!(
            set_measuring_range(HtW01Range::Large),
            literal("set_measuring_range_large")
        );
        assert_eq!(get_param(HtW01Param::Emissivity), literal("get_emissivity"));
        assert_eq!(set_emissivity(95).unwrap(), literal("set_emissivity"));
        assert_eq!(refresh_shutter(), literal("action_refresh_shutter"));
    }

    /// The refused frames follow the same rule, which is how the framing is
    /// known to be right for them too; but no public builder makes them.
    #[test]
    fn the_refused_frames_follow_the_rule_and_have_no_builder() {
        assert_eq!(frame(ACTION, &[0x00, 0x00]), literal("action_reset_config"));
        assert_eq!(
            frame(ACTION, &[0x02, 0x00]),
            literal("action_restart_device")
        );
        assert_eq!(frame(SET_PARAM, &[0x11, 0x00]), literal("set_wifi_channel"));
        assert_eq!(
            frame(SET_PARAM, &[0x08, 0x64, 0x00]),
            literal("set_distance")
        );
        assert_eq!(frame(GET_PARAM, &[0x08]), literal("get_distance"));
    }

    #[test]
    fn values_outside_the_specs_lists_are_refused() {
        for bad in [0u8, 2, 12, 255] {
            assert!(set_palette(bad).is_err(), "{bad}");
        }
        assert!(set_emissivity(101).is_err());
        assert!(set_emissivity(0).is_ok());
        assert!(set_emissivity(100).is_ok());
    }

    /// The pin: exactly these are sent, the reset and the network-dropping
    /// commands are listed and refused with a reason.
    #[test]
    fn the_reset_and_the_network_droppers_are_refused() {
        let policy = command_policy(&spec());
        assert_eq!(policy.len(), spec().commands.len());
        let sent: Vec<&str> = policy
            .iter()
            .filter(|r| r.sent)
            .map(|r| r.name.as_str())
            .collect();
        assert_eq!(sent, SENT);
        for name in [
            "action_reset_config",
            "action_restart_device",
            "set_wifi_channel",
            "set_distance",
        ] {
            let row = policy.iter().find(|r| r.name == name).unwrap();
            assert!(!row.sent, "{name}");
            assert!(row.refusal.as_deref().is_some_and(|r| !r.is_empty()));
        }
        let reset = policy
            .iter()
            .find(|r| r.name == "action_reset_config")
            .unwrap();
        assert!(reset.refusal.as_deref().unwrap().contains("resets"));
    }

    /// No action resolves on the generic network surface either: the spec
    /// binds no entity, and `tcp` is a transport no renderer admits.
    #[test]
    fn the_generic_surface_resolves_nothing() {
        let surface =
            crate::api::device_api::network_entities_for_device(spec_text(), Vec::new()).unwrap();
        assert!(surface
            .entities
            .iter()
            .all(|entity| entity.actions.is_empty()));
    }

    #[test]
    fn the_stream_splitter_finds_frames_through_garbage() {
        let reply = frame(GET_PARAM, &[0x01, 0x04]);
        let mut stream = vec![0x00, 0x13, 0xFB, 0xFF];
        stream.extend_from_slice(&reply);
        stream.extend_from_slice(&reply[..10]);
        let split = split_stream(&stream);
        assert_eq!(split.frames.len(), 1);
        assert_eq!(split.frames[0].cmd_type, GET_PARAM);
        assert_eq!(split.frames[0].data, [0x01, 0x04]);
        assert_eq!(split.rest, &reply[..10]);
        assert!(split.discarded >= 3);
        assert_eq!(reply_value(&split.frames[0], HtW01Param::Palette), Some(4));
        assert_eq!(reply_value(&split.frames[0], HtW01Param::Emissivity), None);

        let mut bad = reply.clone();
        let last = bad.len() - 1;
        bad[last] ^= 0xFF;
        let split = split_stream(&bad);
        assert!(split.frames.is_empty());

        // A huge length is not waited for.
        let mut huge = vec![0xFB, 0xFF, 0xFF, 0xFF, 0x7F];
        huge.extend_from_slice(&reply);
        assert_eq!(split_stream(&huge).frames.len(), 1);
    }

    #[test]
    fn status_codes_read_as_the_spec_lists() {
        assert_eq!(status_meaning(0x44), "CRC error");
        assert_eq!(status_meaning(0xFD), "unknown command");
    }
}

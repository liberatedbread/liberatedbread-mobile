// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! Yummly T3 + P3 (XW3) notifications, decoded read-only.
//!
//! NOT VERIFIED AGAINST HARDWARE, BY ANYONE. The `yummly-smart-thermometer`
//! spec says the XW3 section is its source project's reading of the vendor
//! app, "never run against hardware", and that "no one has reported a value
//! from a T3". It prints no XW3 frame either, so every test below builds its
//! bytes from the spec's stated layout and says so. Passing them shows this
//! file follows the spec, not that a T3 sends what the spec says.
//!
//! ```text
//! f84c3001/3002/3003  [6 bytes, undocumented][int16 LE, tenths of a deg C]...
//! f84c1002            [dock battery %]
//! f84c2000            [6 bytes, undocumented][probe battery %]
//! f84c1001            [command or 30/31/a0][...]   payload_formats.Xw3Reply
//! ```
//!
//! DECODE ONLY. Nothing here builds a byte to send, and the app still does
//! not connect to a T3: the vendor app's sequence writes to a command
//! characteristic on which the single byte 0x01 reboots the dock into its
//! bootloader, and the spec does not say whether the temperatures stream
//! without those writes. Bytes 0-5 of the telemetry frames are left unread
//! (the spec's reading of them is a hypothesis), and so are the alert
//! thresholds' units, which the spec does not establish.

use crate::error::ProtocolError;

/// The XW3 telemetry service and its notify characteristics.
pub const TELEMETRY_SERVICE: &str = "f84cbbbb-b8bb-494e-86c5-01fd7341f217";
pub const REPLY_CHARACTERISTIC: &str = "f84c1001-b8bb-494e-86c5-01fd7341f217";
pub const DOCK_BATTERY_CHARACTERISTIC: &str = "f84c1002-b8bb-494e-86c5-01fd7341f217";
pub const PROBE_BATTERY_CHARACTERISTIC: &str = "f84c2000-b8bb-494e-86c5-01fd7341f217";
pub const CORE_CHARACTERISTIC: &str = "f84c3001-b8bb-494e-86c5-01fd7341f217";
pub const BODY_CHARACTERISTIC: &str = "f84c3002-b8bb-494e-86c5-01fd7341f217";
pub const TIP_CHARACTERISTIC: &str = "f84c3003-b8bb-494e-86c5-01fd7341f217";

/// "int16 little-endian tenths of a degree Celsius at offset 6", in a
/// notification of "at least 8 bytes".
const TEMPERATURE_OFFSET: usize = 6;
const PROBE_BATTERY_OFFSET: usize = 6;
const ADDRESS_LENGTH: usize = 6;

const REPLY_DOCK_MODEL: u8 = 0x11;
const REPLY_DOCK_PRODUCTION_DATE: u8 = 0x13;
const REPLY_DOCK_FIRMWARE: u8 = 0x14;
const REPLY_CONNECTED_PROBES: u8 = 0x50;
const REPLY_PROBE_STATUS: u8 = 0x30;
const REPLY_PROBE_RSSI: u8 = 0x31;
const REPLY_PROBE: u8 = 0xa0;

const PROBE_MODEL: u8 = 0x11;
const PROBE_PRODUCTION_DATE: u8 = 0x13;
const PROBE_FIRMWARE: u8 = 0x14;
const PROBE_ALERT_THRESHOLDS: [u8; 3] = [0x15, 0x16, 0x17];

/// Which layout a reply on f84c1001 carried; byte 0 selects it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Xw3ReplyKind {
    DockModel,
    DockProductionDate,
    DockFirmware,
    ConnectedProbes,
    ProbeStatus,
    ProbeRssi,
    /// An 0xa0 probe sub-reply; `probe_command` says which.
    Probe,
}

/// One decoded f84c1001 notification; only the fields its kind names are set.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Xw3ReplyDto {
    pub kind: Xw3ReplyKind,
    /// The dock's or probe's model, production date or firmware string.
    pub text: Option<String>,
    /// As the dock sent it, least significant byte first. `None` in an 0x50
    /// reply whose byte 1 says no probe.
    pub probe_address_reversed: Option<Vec<u8>>,
    /// 0x30: 1 connected, 0 disconnected; any other byte is not stated.
    pub connected: Option<bool>,
    pub status_raw: Option<u8>,
    pub rssi_dbm: Option<i8>,
    /// 0xa0: the probe command echoed in byte 7.
    pub probe_command: Option<u8>,
    /// 0xa0 to commands 15/16/17: the alert threshold byte, uninterpreted
    /// because the spec does not establish its units or scale.
    pub threshold_raw: Option<u8>,
}

impl Xw3ReplyDto {
    fn of(kind: Xw3ReplyKind) -> Self {
        Self {
            kind,
            text: None,
            probe_address_reversed: None,
            connected: None,
            status_raw: None,
            rssi_dbm: None,
            probe_command: None,
            threshold_raw: None,
        }
    }
}

fn malformed(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::MalformedReply(reason.into())
}

fn at_least(frame: &[u8], needed: usize) -> Result<(), ProtocolError> {
    if frame.len() < needed {
        return Err(ProtocolError::BufferTooShort {
            needed,
            got: frame.len(),
        });
    }
    Ok(())
}

fn utf8(bytes: &[u8]) -> Result<String, ProtocolError> {
    String::from_utf8(bytes.to_vec()).map_err(|_| malformed("the reply's text is not UTF-8"))
}

/// One reading from f84c3001 (core), f84c3002 (probe body) or f84c3003 (tip),
/// in tenths of a degree Celsius as sent. The spec states no "no reading"
/// value, so none is recognised. The vendor app clamped channel 1 to 0-100 C
/// for display; that is the app's choice, not the wire's, and is not applied.
pub fn decode_temperature(frame: &[u8]) -> Result<i16, ProtocolError> {
    at_least(frame, TEMPERATURE_OFFSET + 2)?;
    Ok(i16::from_le_bytes([
        frame[TEMPERATURE_OFFSET],
        frame[TEMPERATURE_OFFSET + 1],
    ]))
}

fn percent(value: u8) -> Result<u8, ProtocolError> {
    if value > 100 {
        return Err(malformed(format!("a battery of {value}% is past 0-100")));
    }
    Ok(value)
}

/// f84c1002: the dock battery, 0-100 %, in byte 0.
pub fn decode_dock_battery(frame: &[u8]) -> Result<u8, ProtocolError> {
    at_least(frame, 1)?;
    percent(frame[0])
}

/// f84c2000: the probe battery, 0-100 %, in byte 6 of at least 7.
pub fn decode_probe_battery(frame: &[u8]) -> Result<u8, ProtocolError> {
    at_least(frame, PROBE_BATTERY_OFFSET + 1)?;
    percent(frame[PROBE_BATTERY_OFFSET])
}

/// A reply on f84c1001, by `payload_formats.Xw3Reply.parse_rules`. A byte 0
/// the rules do not list is refused, not guessed at.
pub fn decode_reply(frame: &[u8]) -> Result<Xw3ReplyDto, ProtocolError> {
    at_least(frame, 1)?;
    let kind = match frame[0] {
        REPLY_DOCK_MODEL => Xw3ReplyKind::DockModel,
        REPLY_DOCK_PRODUCTION_DATE => Xw3ReplyKind::DockProductionDate,
        REPLY_DOCK_FIRMWARE => Xw3ReplyKind::DockFirmware,
        REPLY_CONNECTED_PROBES => return connected_probes(frame),
        REPLY_PROBE_STATUS | REPLY_PROBE_RSSI | REPLY_PROBE => return probe_reply(frame),
        other => {
            return Err(malformed(format!(
                "byte 0 = 0x{other:02x} is not an XW3 reply layout the spec states"
            )));
        }
    };
    // "UTF-8 from byte 1."
    Ok(Xw3ReplyDto {
        text: Some(utf8(&frame[1..])?),
        ..Xw3ReplyDto::of(kind)
    })
}

/// "0x50: byte 1 == 0 means no probe; else bytes 2-7 are the probe address
/// reversed."
fn connected_probes(frame: &[u8]) -> Result<Xw3ReplyDto, ProtocolError> {
    at_least(frame, 2)?;
    let reply = Xw3ReplyDto::of(Xw3ReplyKind::ConnectedProbes);
    if frame[1] == 0 {
        return Ok(reply);
    }
    at_least(frame, 2 + ADDRESS_LENGTH)?;
    Ok(Xw3ReplyDto {
        probe_address_reversed: Some(frame[2..2 + ADDRESS_LENGTH].to_vec()),
        ..reply
    })
}

/// 0x30, 0x31 and 0xa0: bytes 1-6 the probe address reversed, then byte 7.
fn probe_reply(frame: &[u8]) -> Result<Xw3ReplyDto, ProtocolError> {
    at_least(frame, 2 + ADDRESS_LENGTH)?;
    let address = Some(frame[1..1 + ADDRESS_LENGTH].to_vec());
    let seventh = frame[1 + ADDRESS_LENGTH];
    Ok(match frame[0] {
        // "byte 7 status (1 connected, 0 disconnected)".
        REPLY_PROBE_STATUS => Xw3ReplyDto {
            probe_address_reversed: address,
            connected: match seventh {
                1 => Some(true),
                0 => Some(false),
                _ => None,
            },
            status_raw: Some(seventh),
            ..Xw3ReplyDto::of(Xw3ReplyKind::ProbeStatus)
        },
        // "byte 7 RSSI as int8 dBm".
        REPLY_PROBE_RSSI => Xw3ReplyDto {
            probe_address_reversed: address,
            rssi_dbm: Some(seventh as i8),
            ..Xw3ReplyDto::of(Xw3ReplyKind::ProbeRssi)
        },
        // "byte 7 the probe command echoed (11 model / 13 production date / 14
        // firmware: UTF-8 from byte 8; 15/16/17 alert threshold: uint8 at byte
        // 8, units not established)". Another echoed command has no stated
        // payload, so only the echo is reported.
        _ => {
            let payload = &frame[2 + ADDRESS_LENGTH..];
            let mut reply = Xw3ReplyDto {
                probe_address_reversed: address,
                probe_command: Some(seventh),
                ..Xw3ReplyDto::of(Xw3ReplyKind::Probe)
            };
            if matches!(
                seventh,
                PROBE_MODEL | PROBE_PRODUCTION_DATE | PROBE_FIRMWARE
            ) {
                reply.text = Some(utf8(payload)?);
            } else if PROBE_ALERT_THRESHOLDS.contains(&seventh) {
                let [threshold, ..] = payload else {
                    return Err(ProtocolError::BufferTooShort {
                        needed: frame.len() + 1,
                        got: frame.len(),
                    });
                };
                reply.threshold_raw = Some(*threshold);
            }
            reply
        }
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

    /// The statements every test below builds its bytes from. A spec refresh
    /// that changes one should fail here, not leave the tests proving an old
    /// reading.
    #[test]
    fn the_layouts_these_tests_follow_are_still_the_specs() {
        let text = std::fs::read_to_string(format!(
            "{}/../vendor/protocol-specs/device-specs/devices/yummly-smart-thermometer.yaml",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap();
        let folded: String = text.split_whitespace().collect::<Vec<_>>().join(" ");
        for statement in [
            "plain int16 little-endian tenths of a degree CELSIUS at offset 6",
            "0x11 / 0x13 / 0x14: dock model / production date / firmware, UTF-8 from byte 1.",
            "0x50: byte 1 == 0 means no probe; else bytes 2-7 are the probe address reversed.",
            "0x30: bytes 1-6 probe address reversed, byte 7 status (1 connected, 0 disconnected).",
            "0x31: bytes 1-6 probe address reversed, byte 7 RSSI as int8 dBm.",
            "0xa0: bytes 1-6 probe address reversed, byte 7 the probe command echoed \
             (11 model / 13 production date / 14 firmware: UTF-8 from byte 8; 15/16/17 \
             alert threshold: uint8 at byte 8, units not established).",
            "name: \"probe_battery_pct\"",
            "XW3 (T3 + P3) has never been run by anyone known to this project",
        ] {
            assert!(folded.contains(statement), "{statement} is not in the spec");
        }
    }

    /// SYNTHETIC frames (the spec prints none for XW3): six filler bytes where
    /// the spec leaves 0-5 undocumented, then the stated int16 LE tenths of C.
    #[test]
    fn synthetic_temperatures_decode_as_stated() {
        // 22.5 C, -4.0 C, 100.0 C, and a longer frame ("at least 8 bytes").
        let cases = [
            ("01 53 00 5e 00 00 e1 00", 225),
            ("01 53 00 5e 00 00 d8 ff", -40),
            ("01 53 00 5e 00 00 e8 03", 1000),
            ("01 53 00 5e 00 00 e1 00 aa bb", 225),
        ];
        for (frame, tenths) in cases {
            assert_eq!(
                decode_temperature(&bytes(frame)).unwrap(),
                tenths,
                "{frame}"
            );
        }
        // The filler bytes do not matter.
        assert_eq!(
            decode_temperature(&bytes("ff ff ff ff ff ff e1 00")).unwrap(),
            225
        );
        assert!(decode_temperature(&bytes("01 53 00 5e 00 00 e1")).is_err());
        assert!(decode_temperature(&[]).is_err());
    }

    #[test]
    fn synthetic_batteries_decode_as_stated() {
        assert_eq!(decode_dock_battery(&[87]).unwrap(), 87);
        assert_eq!(decode_dock_battery(&[100]).unwrap(), 100);
        assert!(decode_dock_battery(&[101]).is_err());
        assert!(decode_dock_battery(&[]).is_err());

        assert_eq!(
            decode_probe_battery(&bytes("01 53 00 5e 00 00 3c")).unwrap(),
            60
        );
        assert!(decode_probe_battery(&bytes("01 53 00 5e 00 00 c8")).is_err());
        assert!(decode_probe_battery(&bytes("01 53 00 5e 00 00")).is_err());
    }

    #[test]
    fn synthetic_dock_text_replies_decode() {
        let firmware = decode_reply(&bytes("14 31 2e 32 2e 33")).unwrap();
        assert_eq!(firmware.kind, Xw3ReplyKind::DockFirmware);
        assert_eq!(firmware.text.as_deref(), Some("1.2.3"));
        let model = decode_reply(&bytes("11 54 33")).unwrap();
        assert_eq!(model.kind, Xw3ReplyKind::DockModel);
        assert_eq!(model.text.as_deref(), Some("T3"));
        let date = decode_reply(&bytes("13")).unwrap();
        assert_eq!(date.kind, Xw3ReplyKind::DockProductionDate);
        assert_eq!(date.text.as_deref(), Some(""));
        assert!(decode_reply(&bytes("14 ff fe")).is_err(), "not UTF-8");
    }

    #[test]
    fn synthetic_connected_probe_replies_decode() {
        let none = decode_reply(&bytes("50 00")).unwrap();
        assert_eq!(none.kind, Xw3ReplyKind::ConnectedProbes);
        assert_eq!(none.probe_address_reversed, None);

        let one = decode_reply(&bytes("50 01 01 53 00 5e 00 00")).unwrap();
        assert_eq!(one.probe_address_reversed, Some(bytes("01 53 00 5e 00 00")));
        assert!(decode_reply(&bytes("50 01 01 53 00")).is_err());
        assert!(decode_reply(&bytes("50")).is_err());
    }

    #[test]
    fn synthetic_probe_status_and_rssi_decode() {
        let on = decode_reply(&bytes("30 01 53 00 5e 00 00 01")).unwrap();
        assert_eq!(on.kind, Xw3ReplyKind::ProbeStatus);
        assert_eq!(on.connected, Some(true));
        assert_eq!(on.probe_address_reversed, Some(bytes("01 53 00 5e 00 00")));
        let off = decode_reply(&bytes("30 01 53 00 5e 00 00 00")).unwrap();
        assert_eq!(off.connected, Some(false));
        // A status byte the rule does not list is reported raw, not read.
        let odd = decode_reply(&bytes("30 01 53 00 5e 00 00 05")).unwrap();
        assert_eq!(odd.connected, None);
        assert_eq!(odd.status_raw, Some(5));

        let rssi = decode_reply(&bytes("31 01 53 00 5e 00 00 c4")).unwrap();
        assert_eq!(rssi.kind, Xw3ReplyKind::ProbeRssi);
        assert_eq!(rssi.rssi_dbm, Some(-60));
        assert!(decode_reply(&bytes("31 01 53 00 5e 00 00")).is_err());
    }

    #[test]
    fn synthetic_probe_sub_replies_decode() {
        let firmware = decode_reply(&bytes("a0 01 53 00 5e 00 00 14 32 2e 30")).unwrap();
        assert_eq!(firmware.kind, Xw3ReplyKind::Probe);
        assert_eq!(firmware.probe_command, Some(0x14));
        assert_eq!(firmware.text.as_deref(), Some("2.0"));

        let threshold = decode_reply(&bytes("a0 01 53 00 5e 00 00 16 4b")).unwrap();
        assert_eq!(threshold.probe_command, Some(0x16));
        assert_eq!(threshold.threshold_raw, Some(0x4b));
        assert_eq!(threshold.text, None);
        assert!(decode_reply(&bytes("a0 01 53 00 5e 00 00 15")).is_err());

        // An echo with no stated payload reports the echo alone.
        let other = decode_reply(&bytes("a0 01 53 00 5e 00 00 01 99")).unwrap();
        assert_eq!(other.probe_command, Some(0x01));
        assert_eq!(other.text, None);
        assert_eq!(other.threshold_raw, None);
    }

    #[test]
    fn an_unstated_reply_layout_is_refused() {
        for first in [0x00, 0x01, 0x12, 0x51, 0xab] {
            assert!(decode_reply(&[first, 0, 0, 0, 0, 0, 0, 0, 0]).is_err());
        }
        assert!(decode_reply(&[]).is_err());
    }
}

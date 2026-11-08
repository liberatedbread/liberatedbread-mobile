// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Drive a legacy (v1-v5) LimitlessLED / Mi-Light bridge from its spec: 3-byte
//! datagrams to UDP 8899, `<command> <argument> 0x55`, with no reply of any
//! kind.
//!
//! The spec states its zones in prose: a command's byte reads
//! `"0x42 (all) or 0x45/0x47/0x49/0x4B (zone 1-4)"`, and `set_color`'s note
//! says the hue "applies to the most-recently-addressed zone(s)". Those two
//! sentences are the whole addressing model, so this reads the first as a
//! closed grammar — anything else in that field is refused rather than guessed
//! at — and acts on the second by sending the zone's ON ahead of any command
//! whose own byte addresses nothing.
//!
//! That ON is a real power change the protocol never reports, so the light card
//! assumes it too (`_impliedPower`): a change to which commands carry one has to
//! be made there as well.
//!
//! The protocol is write-only and the bridge-to-bulb RF hop drops packets, so
//! the documented reliability strategy is repeating with pacing. That lives
//! here too: what comes out is the complete timed sequence and the Dart client
//! just plays it.
//!
//! Three known limits. The dual-white page is prose under `protocol_details`
//! that no command binds, so it is not reachable. A v6/iBox bridge answers the
//! same discovery probe and ignores all of this, and being write-only nothing
//! can tell. And pairing is timing-sensitive: a zone's ON five times inside the
//! 3 s after a bulb is powered unlinks it, which the three rounds of one press
//! cannot reach and two quick presses in that window could.

use std::collections::BTreeMap;

use crate::error::ProtocolError;
use crate::spec::types::{DeviceSpec, SpecCommand};

/// The transport the spec's commands declare. Bare `udp` is a name Rabbit Air
/// also rides, so [`HANDLER_NAME`] is what admits one of these.
pub const TRANSPORT: &str = "udp";

/// The spec `protocol_handler` this module answers to, and the transport a
/// resolved action carries so the sender can route it.
pub const HANDLER_NAME: &str = "limitlessled_legacy_8899";

/// The bridge's control port (`identification.default_port`).
pub const PORT: u16 = 8899;

/// The `action` every legacy command declares.
const LEGACY_COMMAND: &str = "legacy_command";

/// The third byte of every frame.
const TERMINATOR: u8 = 0x55;

/// The command that addresses a zone. Its byte table is what a colour or
/// brightness frame, which carries no zone of its own, is addressed through.
const ADDRESSING_COMMAND: &str = "turn_on";

/// Rounds of one send: "repeat safe commands ~3 times".
pub const REPEATS: usize = 3;

/// The pause between frames: ">=100 ms".
pub const PACE_MS: u64 = 100;

/// The value naming which zone a send addresses. Absent means all of them.
/// Not a declared parameter — the spec has no slot for it — so it rides beside
/// the declared ones and is read only here.
pub const ZONE_VALUE: &str = "zone";

/// One datagram and how long to wait after it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LegacyFrame {
    pub bytes: [u8; 3],
    pub delay_after_ms: u64,
}

/// Which zones a send addresses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Zone {
    All,
    /// 1-4.
    One(usize),
}

/// What a command's byte field said.
#[derive(Debug)]
enum CommandByte {
    /// `0x4E`: the byte addresses nothing, so the zone must be set first.
    Fixed(u8),
    /// `0x42 (all) or 0x45/0x47/0x49/0x4B (zone 1-4)`.
    Zoned { all: u8, zones: [u8; 4] },
}

impl CommandByte {
    fn parse(spelling: &str) -> Result<Self, ProtocolError> {
        let unreadable = || ProtocolError::UnsupportedCommandEncoding(spelling.to_string());
        let spelling = spelling.trim();
        let Some((all, zones)) = spelling.split_once(" (all) or ") else {
            return Ok(Self::Fixed(hex_byte(spelling).ok_or_else(unreadable)?));
        };
        let zones = zones.strip_suffix(" (zone 1-4)").ok_or_else(unreadable)?;
        let zones = zones
            .split('/')
            .map(hex_byte)
            .collect::<Option<Vec<u8>>>()
            .and_then(|z| <[u8; 4]>::try_from(z).ok())
            .ok_or_else(unreadable)?;
        Ok(Self::Zoned {
            all: hex_byte(all).ok_or_else(unreadable)?,
            zones,
        })
    }

    fn for_zone(&self, zone: Zone) -> u8 {
        match (self, zone) {
            (Self::Fixed(byte), _) => *byte,
            (Self::Zoned { all, .. }, Zone::All) => *all,
            (Self::Zoned { zones, .. }, Zone::One(n)) => zones[n - 1],
        }
    }
}

fn hex_byte(text: &str) -> Option<u8> {
    u8::from_str_radix(text.trim().strip_prefix("0x")?, 16).ok()
}

fn zone_from(values: &BTreeMap<String, String>) -> Result<Zone, ProtocolError> {
    let Some(raw) = values.get(ZONE_VALUE) else {
        return Ok(Zone::All);
    };
    match raw.trim().parse::<usize>() {
        Ok(n @ 1..=4) => Ok(Zone::One(n)),
        _ => Err(ProtocolError::ParameterValueInvalid {
            name: ZONE_VALUE.to_string(),
            value: raw.clone(),
            reason: "a legacy bridge has zones 1 to 4".to_string(),
        }),
    }
}

/// The timed sequence one send puts on the wire.
pub fn render_request(
    spec: &DeviceSpec,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<Vec<LegacyFrame>, ProtocolError> {
    if spec.protocol_handler.as_deref() != Some(HANDLER_NAME) {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            spec.protocol_handler.clone().unwrap_or_default(),
        ));
    }
    let command = super::top_level_command(spec, command_name)?;
    if command.transport.as_deref() != Some(TRANSPORT)
        || command.action.as_deref() != Some(LEGACY_COMMAND)
    {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            command.transport.clone().unwrap_or_default(),
        ));
    }
    let zone = zone_from(values)?;
    // A declared sequence is complete as written and is not repeated: rounds
    // of night_mode would only re-dim a light that has already gone dim.
    if !command.frames.is_empty() {
        return declared_frames(command, command_name, zone, values);
    }

    let mut round = Vec::with_capacity(2);
    let byte = CommandByte::parse(&argument_text(command, "command")?)?;
    if matches!(byte, CommandByte::Fixed(_)) {
        round.push(addressing_frame(spec, zone)?);
    }
    round.push(LegacyFrame {
        bytes: [
            byte.for_zone(zone),
            argument_byte(
                command,
                command_name,
                command.arguments.get("argument"),
                values,
            )?,
            TERMINATOR,
        ],
        delay_after_ms: PACE_MS,
    });

    let mut sequence: Vec<LegacyFrame> = (0..REPEATS).flat_map(|_| round.clone()).collect();
    if let Some(last) = sequence.last_mut() {
        last.delay_after_ms = 0;
    }
    Ok(sequence)
}

/// The zone's ON, spelled by the spec's own `turn_on`.
fn addressing_frame(spec: &DeviceSpec, zone: Zone) -> Result<LegacyFrame, ProtocolError> {
    let on = super::top_level_command(spec, ADDRESSING_COMMAND)?;
    let byte = CommandByte::parse(&argument_text(on, "command")?)?;
    Ok(LegacyFrame {
        bytes: [byte.for_zone(zone), 0x00, TERMINATOR],
        delay_after_ms: PACE_MS,
    })
}

fn declared_frames(
    command: &SpecCommand,
    command_name: &str,
    zone: Zone,
    values: &BTreeMap<String, String>,
) -> Result<Vec<LegacyFrame>, ProtocolError> {
    command
        .frames
        .iter()
        .map(|frame| {
            Ok(LegacyFrame {
                bytes: [
                    CommandByte::parse(&frame.command)?.for_zone(zone),
                    argument_byte(command, command_name, frame.argument.as_ref(), values)?,
                    TERMINATOR,
                ],
                delay_after_ms: frame.delay_after_ms.unwrap_or(0),
            })
        })
        .collect()
}

fn argument_text(command: &SpecCommand, name: &str) -> Result<String, ProtocolError> {
    command
        .arguments
        .get(name)
        .and_then(|v| v.as_str())
        .map(str::to_string)
        .ok_or(ProtocolError::EmptyCommand)
}

/// The frame's middle byte: a literal, or `{param}` read and range-checked as
/// the parameter declares.
fn argument_byte(
    command: &SpecCommand,
    command_name: &str,
    argument: Option<&serde_yaml::Value>,
    values: &BTreeMap<String, String>,
) -> Result<u8, ProtocolError> {
    let unreadable = ProtocolError::UnsupportedCommandEncoding;
    match argument {
        None => Ok(0),
        Some(serde_yaml::Value::Number(n)) => n
            .as_u64()
            .and_then(|n| u8::try_from(n).ok())
            .ok_or_else(|| unreadable(n.to_string())),
        Some(serde_yaml::Value::String(text)) => {
            let Some(name) = text
                .strip_prefix('{')
                .and_then(|rest| rest.strip_suffix('}'))
            else {
                return Err(unreadable(text.clone()));
            };
            let raw = crate::protocol::resolve_parameter(command, command_name, name, values)?;
            let value =
                crate::protocol::http::typed_json(command.parameters.get(name), name, &raw)?;
            value
                .as_u64()
                .and_then(|n| u8::try_from(n).ok())
                .ok_or_else(|| unreadable(raw))
        }
        Some(other) => Err(unreadable(format!("{other:?}"))),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn raw_spec() -> String {
        std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join(
                "../vendor/protocol-specs/device-specs/devices/limitlessled-milight-bridge.yaml",
            ),
        )
        .expect("the bridge spec is vendored")
    }

    fn spec() -> DeviceSpec {
        parse_device_spec(&raw_spec()).expect("the bridge spec parses")
    }

    fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    /// `"45 00 55"` as bytes.
    fn literal(text: &str) -> [u8; 3] {
        let bytes: Vec<u8> = text
            .split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect();
        bytes.try_into().unwrap()
    }

    fn one_round(sequence: &[LegacyFrame]) -> Vec<[u8; 3]> {
        sequence[..sequence.len() / REPEATS]
            .iter()
            .map(|f| f.bytes)
            .collect()
    }

    /// The literal frames as the spec's own table spells them, read from
    /// `protocol_details.limitlessled_protocol.rgbw_commands`, so the prose
    /// grammar in `commands:` is checked against the table it abbreviates.
    fn rgbw_table() -> serde_yaml::Value {
        let doc: serde_yaml::Value = serde_yaml::from_str(&raw_spec()).unwrap();
        doc["protocol_details"]["limitlessled_protocol"]["rgbw_commands"].clone()
    }

    #[test]
    fn power_frames_match_the_specs_literal_table() {
        let spec = spec();
        let table = rgbw_table();
        for (command, all_key, zones_key) in [
            ("turn_on", "all_on", "zone_on"),
            ("turn_off", "all_off", "zone_off"),
        ] {
            let all = render_request(&spec, command, &BTreeMap::new()).unwrap();
            assert_eq!(
                one_round(&all),
                vec![literal(table[all_key].as_str().unwrap())],
                "{command} all"
            );
            for zone in 1..=4 {
                let frames =
                    render_request(&spec, command, &values(&[(ZONE_VALUE, &zone.to_string())]))
                        .unwrap();
                assert_eq!(
                    one_round(&frames),
                    vec![literal(table[zones_key][zone - 1].as_str().unwrap())],
                    "{command} zone {zone}"
                );
            }
        }
    }

    /// The same frames as bare literals, so a refresh that rewrites both the
    /// table and the commands still has to answer to these.
    #[test]
    fn the_wire_bytes_are_the_published_ones() {
        let spec = spec();
        let on = render_request(&spec, "turn_on", &values(&[(ZONE_VALUE, "1")])).unwrap();
        assert_eq!(on[0].bytes, [0x45, 0x00, 0x55]);
        let off = render_request(&spec, "turn_off", &BTreeMap::new()).unwrap();
        assert_eq!(off[0].bytes, [0x41, 0x00, 0x55]);
        let off4 = render_request(&spec, "turn_off", &values(&[(ZONE_VALUE, "4")])).unwrap();
        assert_eq!(off4[0].bytes, [0x4C, 0x00, 0x55]);
    }

    /// "Send a zone ON first; hue applies to the most-recently-addressed
    /// zone(s)." Colour's byte names no zone, so the addressing is this frame.
    #[test]
    fn colour_is_addressed_by_the_zones_on_first() {
        let spec = spec();
        let frames = render_request(
            &spec,
            "set_color",
            &values(&[("hue", "176"), (ZONE_VALUE, "3")]),
        )
        .unwrap();
        assert_eq!(
            one_round(&frames),
            vec![[0x49, 0x00, 0x55], [0x40, 0xB0, 0x55]]
        );
        let all = render_request(&spec, "set_color", &values(&[("hue", "96")])).unwrap();
        assert_eq!(
            one_round(&all),
            vec![[0x42, 0x00, 0x55], [0x40, 0x60, 0x55]],
            "0x60 is the spec's green"
        );
    }

    #[test]
    fn brightness_is_addressed_too_and_stays_in_its_declared_range() {
        let spec = spec();
        let frames = render_request(
            &spec,
            "set_brightness",
            &values(&[("level", "27"), (ZONE_VALUE, "2")]),
        )
        .unwrap();
        assert_eq!(
            one_round(&frames),
            vec![[0x47, 0x00, 0x55], [0x4E, 0x1B, 0x55]]
        );
        for bad in ["1", "28", "300"] {
            let result = render_request(&spec, "set_brightness", &values(&[("level", bad)]));
            assert!(
                matches!(result, Err(ProtocolError::ParameterOutOfRange { .. })),
                "{bad}: {result:?}"
            );
        }
        assert!(matches!(
            render_request(&spec, "set_brightness", &BTreeMap::new()),
            Err(ProtocolError::ParameterMissing(_))
        ));
    }

    /// The spec's worked example: "zone 1: 46 00 55 then C6 00 55", 100 ms
    /// apart.
    #[test]
    fn night_mode_plays_its_declared_frames_once() {
        let spec = spec();
        let frames = render_request(&spec, "night_mode", &values(&[(ZONE_VALUE, "1")])).unwrap();
        assert_eq!(
            frames,
            vec![
                LegacyFrame {
                    bytes: [0x46, 0x00, 0x55],
                    delay_after_ms: 100
                },
                LegacyFrame {
                    bytes: [0xC6, 0x00, 0x55],
                    delay_after_ms: 0
                },
            ]
        );
        let all = render_request(&spec, "night_mode", &BTreeMap::new()).unwrap();
        assert_eq!(all[0].bytes, [0x41, 0x00, 0x55]);
        assert_eq!(all[1].bytes, [0xC1, 0x00, 0x55]);
    }

    /// Lossy RF and no acknowledgement: three rounds, >=100 ms between every
    /// pair of frames, nothing to wait for after the last.
    #[test]
    fn a_send_repeats_with_pacing() {
        let spec = spec();
        let frames = render_request(&spec, "turn_on", &BTreeMap::new()).unwrap();
        assert_eq!(frames.len(), REPEATS);
        assert!(frames[..REPEATS - 1]
            .iter()
            .all(|f| f.delay_after_ms >= 100));
        assert_eq!(frames.last().unwrap().delay_after_ms, 0);

        let colour = render_request(&spec, "set_color", &values(&[("hue", "0")])).unwrap();
        assert_eq!(colour.len(), 2 * REPEATS);
        assert!(colour[..colour.len() - 1]
            .iter()
            .all(|f| f.delay_after_ms >= 100));
    }

    #[test]
    fn a_zone_outside_the_bridges_four_is_refused() {
        let spec = spec();
        for bad in ["0", "5", "all", ""] {
            assert!(
                matches!(
                    render_request(&spec, "turn_on", &values(&[(ZONE_VALUE, bad)])),
                    Err(ProtocolError::ParameterValueInvalid { .. })
                ),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn prose_outside_the_grammar_is_refused_rather_than_guessed_at() {
        for spelling in [
            "0x42 or 0x45",
            "0x42 (all) or 0x45/0x47/0x49 (zone 1-4)",
            "0x42 (all) or 0x45/0x47/0x49/0x4B (zone 1-8)",
            "whatever",
            "42",
        ] {
            assert!(CommandByte::parse(spelling).is_err(), "{spelling}");
        }
    }

    #[test]
    fn another_handlers_spec_is_refused() {
        let mut spec = spec();
        spec.protocol_handler = Some("rabbit_air".to_string());
        assert!(matches!(
            render_request(&spec, "turn_on", &BTreeMap::new()),
            Err(ProtocolError::UnsupportedCommandEncoding(_))
        ));
    }
}

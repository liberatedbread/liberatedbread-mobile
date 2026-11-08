// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! Hörmann BiSecur gateway: door positions over TCP 4000, read-only.
//!
//! The `hormann-bisecur-gateway` spec's `protocol_details.mcp_frame` states the
//! frame. Dart owns the socket. Every byte below crosses as two upper-case hex
//! ASCII characters.
//!
//! ```text
//! frame:  [source 6][destination 6][length u16][packet][transport checksum]
//! packet: [tag][token u32][command][payload][packet checksum]
//! ```
//!
//! The length counts itself: from its own first byte through the packet
//! checksum, so 9 + the payload's length.
//!
//! READ-ONLY BY CONSTRUCTION. An impulse (`SET_STATE`, 0x33) moves a motorised
//! door that can trap or injure, and a reply of PORT_ERROR does not even mean
//! it stayed put. The frame builder is private; its public callers are login,
//! the group list, a door's position and logout, and no argument to any of them
//! is a command id. Nothing in this file can produce 0x33.

use serde::Deserialize;

use crate::error::ProtocolError;

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "bisecur_mcp";

/// The client address on every request. No source shows the gateway rejecting
/// any of the addresses the SDKs use, and this is the one pysecur3 notes the
/// iPhone app sends and the spec's own example frames carry.
const CLIENT_ADDRESS: [u8; 6] = [0, 0, 0, 0, 0, 6];

const COMMAND_ERROR: u8 = 0x01;
const COMMAND_JMCP: u8 = 0x06;
const COMMAND_LOGIN: u8 = 0x10;
const COMMAND_LOGOUT: u8 = 0x11;
const COMMAND_TRANSITION: u8 = 0x70;
const REPLY_FLAG: u8 = 0x80;

/// The gateway sends this, one per stale session, ahead of a LOGIN reply.
const STALE_LOGOUT_TAG: u8 = 0xff;

/// The two addresses, then the length field that a frame's size starts from.
const ADDRESS_CHARS: usize = 24;
const HEADER_CHARS: usize = ADDRESS_CHARS + 4;
const ADDRESS_BYTES: usize = 12;
const MIN_PACKET: usize = 9;
const TRANSITION_BYTES: usize = 16;
const FULL_SCALE: u8 = 200;

/// Largest packet this client will hold. The length field is the DEVICE's
/// claim, and the longest reply here is a household's list of doors.
const MAX_PACKET: usize = 16 * 1024;

/// What a frame turned out to be, for a request with this tag and command.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BiSecurReplyKind {
    /// The answer. Its payload is in [`BiSecurReplyDto::payload`].
    Answer,
    /// The gateway said ERROR; see [`BiSecurReplyDto::error_code`].
    Error,
    /// Not for this request: a stale-session LOGOUT, or another tag.
    Skip,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BiSecurReplyDto {
    pub kind: BiSecurReplyKind,
    pub payload: Vec<u8>,
    pub error_code: Option<u8>,
}

/// What [`split_stream`] found in the bytes so far.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct BiSecurSplitDto {
    pub frames: Vec<Vec<u8>>,
    pub rest: Vec<u8>,
}

/// One door or device the owner set up, from `GET_GROUPS`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BiSecurGroupDto {
    pub id: u32,
    pub name: String,
    pub ports: Vec<BiSecurPortDto>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BiSecurPortDto {
    pub id: u8,
    pub type_code: u32,
    /// `payload_formats.PortType`; `None` for a code the table omits.
    pub type_name: Option<String>,
}

/// `HM_GET_TRANSITION`'s reply.
#[derive(Debug, Clone, PartialEq)]
pub struct BiSecurTransitionDto {
    /// 0 closed to 100 open. `None` for a raw value past the scale.
    pub position_percent: Option<f64>,
    pub target_percent: Option<f64>,
    pub fault: bool,
    pub auto_close: bool,
    pub fully_open: bool,
    pub fully_closed: bool,
    pub light_barrier: bool,
    pub status_error: bool,
    pub driving: bool,
    pub driving_towards_closed: bool,
    pub half_open: bool,
    pub forecast: bool,
    pub learned: bool,
    pub not_referenced: bool,
}

#[derive(Deserialize)]
struct RawGroup {
    id: u32,
    #[serde(default)]
    name: String,
    #[serde(default)]
    ports: Vec<RawPort>,
}

#[derive(Deserialize)]
struct RawPort {
    id: u8,
    #[serde(rename = "type", default)]
    port_type: u32,
}

fn malformed(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::MalformedReply(reason.into())
}

fn sum(bytes: &[u8]) -> u32 {
    bytes.iter().map(|b| u32::from(*b)).sum()
}

/// Build a whole frame. Private on purpose: this would frame an impulse as
/// readily as a read, so it is reachable only through the named encoders.
fn frame(gateway: &[u8; 6], tag: u8, token: u32, command: u8, payload: &[u8]) -> Vec<u8> {
    let length = MIN_PACKET + payload.len();
    let mut bytes = Vec::with_capacity(14 + length);
    bytes.extend_from_slice(&CLIENT_ADDRESS);
    bytes.extend_from_slice(gateway);
    bytes.extend_from_slice(&(length as u16).to_be_bytes());
    let packet_start = bytes.len();
    bytes.push(tag);
    bytes.extend_from_slice(&token.to_be_bytes());
    bytes.push(command);
    bytes.extend_from_slice(payload);
    let checksum = (length as u32 + sum(&bytes[packet_start..])) % 256;
    bytes.push(checksum as u8);

    let mut text = String::with_capacity(bytes.len() * 2 + 2);
    for byte in &bytes {
        text.push_str(&format!("{byte:02X}"));
    }
    let transport = sum(text.as_bytes()) % 256;
    text.push_str(&format!("{transport:02X}"));
    text.into_bytes()
}

/// `54:10:EC:00:00:01`, as the discovery reply's `mac` attribute reads.
fn parse_mac(mac: &str) -> Result<[u8; 6], ProtocolError> {
    let parts: Vec<&str> = mac.trim().split(':').collect();
    let mut out = [0u8; 6];
    if parts.len() != out.len() {
        return Err(malformed(format!("{mac:?} is not a MAC address")));
    }
    for (slot, part) in out.iter_mut().zip(&parts) {
        if part.len() != 2 {
            return Err(malformed(format!("{mac:?} is not a MAC address")));
        }
        *slot = u8::from_str_radix(part, 16)
            .map_err(|_| malformed(format!("{mac:?} is not a MAC address")))?;
    }
    Ok(out)
}

/// `LOGIN`: one byte of user-name length, the name, then the password. Sent in
/// clear, because that is the protocol; nothing here logs or stores it.
pub fn encode_login(
    gateway_mac: &str,
    tag: u8,
    user: &str,
    password: &str,
) -> Result<Vec<u8>, ProtocolError> {
    let gateway = parse_mac(gateway_mac)?;
    let name = user.as_bytes();
    if name.is_empty() || name.len() > 255 {
        return Err(ProtocolError::ParameterOutOfRange {
            name: "user length".to_string(),
            value: name.len() as f64,
            min: 1.0,
            max: 255.0,
        });
    }
    let mut payload = vec![name.len() as u8];
    payload.extend_from_slice(name);
    payload.extend_from_slice(password.as_bytes());
    if payload.len() > MAX_PACKET {
        return Err(ProtocolError::ParameterOutOfRange {
            name: "login length".to_string(),
            value: payload.len() as f64,
            min: 0.0,
            max: MAX_PACKET as f64,
        });
    }
    Ok(frame(&gateway, tag, 0, COMMAND_LOGIN, &payload))
}

/// `JMCP GET_GROUPS`: the doors and their ports.
pub fn encode_get_groups(gateway_mac: &str, tag: u8, token: u32) -> Result<Vec<u8>, ProtocolError> {
    Ok(frame(
        &parse_mac(gateway_mac)?,
        tag,
        token,
        COMMAND_JMCP,
        br#"{"CMD":"GET_GROUPS"}"#,
    ))
}

/// `HM_GET_TRANSITION`: one door's position.
pub fn encode_get_transition(
    gateway_mac: &str,
    tag: u8,
    token: u32,
    port: u8,
) -> Result<Vec<u8>, ProtocolError> {
    Ok(frame(
        &parse_mac(gateway_mac)?,
        tag,
        token,
        COMMAND_TRANSITION,
        &[port],
    ))
}

/// `LOGOUT`. The gateway sends no reply, so nothing should wait for one.
pub fn encode_logout(gateway_mac: &str, tag: u8, token: u32) -> Result<Vec<u8>, ProtocolError> {
    Ok(frame(
        &parse_mac(gateway_mac)?,
        tag,
        token,
        COMMAND_LOGOUT,
        &[],
    ))
}

fn hex_digit(char: u8) -> Option<u8> {
    match char {
        b'0'..=b'9' => Some(char - b'0'),
        b'A'..=b'F' => Some(char - b'A' + 10),
        b'a'..=b'f' => Some(char - b'a' + 10),
        _ => None,
    }
}

fn from_hex(text: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    text.as_chunks::<2>()
        .0
        .iter()
        .map(|pair| {
            let high = hex_digit(pair[0]).ok_or_else(|| malformed("not hex text"))?;
            let low = hex_digit(pair[1]).ok_or_else(|| malformed("not hex text"))?;
            Ok((high << 4) | low)
        })
        .collect()
}

/// Cut the bytes received so far into whole frames by their length fields.
/// Frames arrive coalesced as well as split, and there is no terminator.
pub fn split_stream(buffer: &[u8]) -> Result<BiSecurSplitDto, ProtocolError> {
    let mut frames = Vec::new();
    let mut rest = buffer;
    while rest.len() >= HEADER_CHARS {
        let length = from_hex(&rest[ADDRESS_CHARS..HEADER_CHARS])?;
        let packet = usize::from(u16::from_be_bytes([length[0], length[1]]));
        if !(MIN_PACKET..=MAX_PACKET).contains(&packet) {
            return Err(malformed(format!("a packet length of {packet}")));
        }
        let total = ADDRESS_CHARS + packet * 2 + 2;
        if rest.len() < total {
            break;
        }
        frames.push(rest[..total].to_vec());
        rest = &rest[total..];
    }
    Ok(BiSecurSplitDto {
        frames,
        rest: rest.to_vec(),
    })
}

/// Read one whole frame as an answer to a request with this tag and command.
///
/// `Err` is a frame that fails a checksum or the layout. Both checksums are
/// checked, because this is all that stands between line noise and a door
/// position on screen.
pub fn decode_reply(
    text: &[u8],
    expected_tag: u8,
    expected_command: u8,
) -> Result<BiSecurReplyDto, ProtocolError> {
    if text.len() < ADDRESS_CHARS + MIN_PACKET * 2 + 2 || !text.len().is_multiple_of(2) {
        return Err(ProtocolError::BufferTooShort {
            needed: ADDRESS_CHARS + MIN_PACKET * 2 + 2,
            got: text.len(),
        });
    }
    let bytes = from_hex(text)?;
    let transport = *bytes.last().expect("the length was checked");
    if sum(&text[..text.len() - 2]) % 256 != u32::from(transport) {
        return Err(malformed("the transport checksum does not match"));
    }
    let length = usize::from(u16::from_be_bytes([bytes[12], bytes[13]]));
    if length < MIN_PACKET || bytes.len() != ADDRESS_BYTES + length + 1 {
        return Err(malformed("the packet length does not fit the frame"));
    }
    let packet = &bytes[ADDRESS_BYTES + 2..ADDRESS_BYTES + length];
    let (body, checksum) = packet.split_at(packet.len() - 1);
    // The spec adds the packet length to the sum; none of its frames is long
    // enough to show whether that is the value or its two bytes, and a door
    // list can be. The transport checksum has already covered these bytes.
    let by_value = (length as u32 + sum(body)) % 256;
    let by_bytes = (sum(&bytes[12..14]) + sum(body)) % 256;
    if u32::from(checksum[0]) != by_value && u32::from(checksum[0]) != by_bytes {
        return Err(malformed("the packet checksum does not match"));
    }
    let tag = body[0];
    let command = body[5];
    let payload = &body[6..];
    let skip = BiSecurReplyDto {
        kind: BiSecurReplyKind::Skip,
        payload: Vec::new(),
        error_code: None,
    };
    if command == COMMAND_LOGOUT && tag == STALE_LOGOUT_TAG {
        return Ok(skip);
    }
    if tag != expected_tag {
        return Ok(skip);
    }
    if command == COMMAND_ERROR {
        return match payload {
            [code] => Ok(BiSecurReplyDto {
                kind: BiSecurReplyKind::Error,
                payload: Vec::new(),
                error_code: Some(*code),
            }),
            _ => Err(malformed("an ERROR frame carries one code")),
        };
    }
    if command != expected_command | REPLY_FLAG {
        return Err(malformed(format!(
            "command 0x{command:02x} does not answer 0x{expected_command:02x}"
        )));
    }
    Ok(BiSecurReplyDto {
        kind: BiSecurReplyKind::Answer,
        payload: payload.to_vec(),
        error_code: None,
    })
}

/// The command ids a caller waits on. Named, so a caller cannot ask about any
/// other; `SET_STATE` is not among them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BiSecurExchange {
    Login,
    GetGroups,
    GetTransition,
}

impl BiSecurExchange {
    pub fn command(self) -> u8 {
        match self {
            Self::Login => COMMAND_LOGIN,
            Self::GetGroups => COMMAND_JMCP,
            Self::GetTransition => COMMAND_TRANSITION,
        }
    }
}

/// The session token in a `LOGIN` reply: a sender id, then four bytes.
pub fn decode_login(payload: &[u8]) -> Result<u32, ProtocolError> {
    match payload {
        [_, a, b, c, d] => Ok(u32::from_be_bytes([*a, *b, *c, *d])),
        _ => Err(malformed("a LOGIN reply is five bytes")),
    }
}

/// `payload_formats.PortType`.
fn port_type_name(code: u32) -> Option<&'static str> {
    Some(match code {
        0 => "None",
        1 => "Impulse",
        2 => "Auto-close",
        3 => "On / off",
        4 => "Up",
        5 => "Down",
        6 => "Half open",
        7 => "Pedestrian opening",
        8 => "Light",
        9 => "On",
        10 => "Off",
        11 => "Lock",
        12 => "Unlock",
        13 => "Open door",
        14 => "Lift",
        15 => "Lower",
        _ => return None,
    })
}

/// The JSON array `GET_GROUPS` answers with.
pub fn decode_groups(payload: &[u8]) -> Result<Vec<BiSecurGroupDto>, ProtocolError> {
    let groups: Vec<RawGroup> = serde_json::from_slice(payload)
        .map_err(|e| malformed(format!("the group list is not the promised JSON: {e}")))?;
    Ok(groups
        .into_iter()
        .map(|group| BiSecurGroupDto {
            id: group.id,
            name: group.name,
            ports: group
                .ports
                .into_iter()
                .map(|port| BiSecurPortDto {
                    id: port.id,
                    type_code: port.port_type,
                    type_name: port_type_name(port.port_type).map(str::to_string),
                })
                .collect(),
        })
        .collect())
}

fn percent(raw: u8) -> Option<f64> {
    (raw <= FULL_SCALE).then(|| f64::from(raw) * 0.5)
}

/// `payload_formats.Transition`, 16 bytes.
pub fn decode_transition(payload: &[u8]) -> Result<BiSecurTransitionDto, ProtocolError> {
    if payload.len() != TRANSITION_BYTES {
        return Err(malformed(format!(
            "a transition is {TRANSITION_BYTES} bytes, not {}",
            payload.len()
        )));
    }
    let flags = payload[2];
    let status = u16::from_le_bytes([payload[6], payload[7]]);
    let bit = |n: u16| status & (1 << n) != 0;
    Ok(BiSecurTransitionDto {
        position_percent: percent(payload[0]),
        target_percent: percent(payload[1]),
        fault: flags & 0x80 != 0,
        auto_close: flags & 0x40 != 0,
        fully_open: bit(0),
        fully_closed: bit(1),
        light_barrier: bit(3),
        status_error: bit(4),
        driving_towards_closed: bit(5),
        driving: bit(6),
        half_open: bit(7),
        forecast: bit(8),
        learned: bit(9),
        not_referenced: bit(10),
    })
}

/// `payload_formats.ErrorCode`.
pub fn error_meaning(code: u8) -> &'static str {
    match code {
        0 => "command not found",
        1 => "invalid protocol",
        2 => "login failed",
        3 => "invalid token",
        4 => "user already exists",
        5 => "no empty user slot",
        6 => "invalid password",
        7 => "invalid user name",
        8 => "user not found",
        9 => "port not found",
        10 => "port error",
        11 => "gateway busy",
        12 => "permission denied",
        13 => "no empty group slot",
        14 => "group not found",
        15 => "invalid payload",
        16 => "out of range",
        17 => "add port failed",
        18 => "no empty port slot",
        19 => "radio adapter busy",
        _ => "not named by the spec",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GATEWAY: &str = "54:10:EC:00:00:01";
    const GET_NAME: &str = "0000000000065410EC00000100090200000000263130";
    const LOGIN: &str =
        "0000000000065410EC000001001A03000000001008757365726E616D6570617373776F7264086F";
    const GET_GROUPS: &str =
        "0000000000065410EC000001001D041A2B3C4D067B22434D44223A224745545F47524F555053227DA219";
    const GET_TRANSITION: &str = "0000000000065410EC000001000A051A2B3C4D70004D02";
    const IMPULSE: &str = "0000000000065410EC000001000B061A2B3C4D3300FF1179";
    const LOGOUT: &str = "0000000000065410EC0000010009081A2B3C4D11F096";
    const TRANSITION: &str = "B800001801086C020000000000000000";
    const TOKEN: u32 = 0x1A2B_3C4D;

    fn gateway() -> [u8; 6] {
        parse_mac(GATEWAY).unwrap()
    }

    fn unhex(text: &str) -> Vec<u8> {
        from_hex(text.as_bytes()).unwrap()
    }

    /// A reply as the gateway would build it: the same frame with the
    /// addresses as they are, which the checksums do not care about.
    fn reply(tag: u8, token: u32, command: u8, payload: &[u8]) -> Vec<u8> {
        frame(&gateway(), tag, token, command, payload)
    }

    #[test]
    fn the_literal_frames_are_the_ones_the_spec_prints() {
        let text = std::fs::read_to_string(format!(
            "{}/../vendor/protocol-specs/device-specs/devices/hormann-bisecur-gateway.yaml",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap();
        for vector in [
            GET_NAME,
            LOGIN,
            GET_GROUPS,
            GET_TRANSITION,
            IMPULSE,
            LOGOUT,
            TRANSITION,
        ] {
            assert!(text.contains(vector), "{vector} is not in the spec");
        }
    }

    #[test]
    fn the_public_encoders_build_the_spec_examples() {
        assert_eq!(
            encode_login(GATEWAY, 3, "username", "password").unwrap(),
            LOGIN.as_bytes()
        );
        assert_eq!(
            encode_get_groups(GATEWAY, 4, TOKEN).unwrap(),
            GET_GROUPS.as_bytes()
        );
        assert_eq!(
            encode_get_transition(GATEWAY, 5, TOKEN, 0).unwrap(),
            GET_TRANSITION.as_bytes()
        );
        assert_eq!(encode_logout(GATEWAY, 8, TOKEN).unwrap(), LOGOUT.as_bytes());
    }

    /// The private builder against the two frames no public path builds. The
    /// impulse is here only to prove the checksums against the spec's bytes.
    #[test]
    fn the_private_builder_reproduces_the_other_spec_frames() {
        assert_eq!(frame(&gateway(), 2, 0, 0x26, &[]), GET_NAME.as_bytes());
        assert_eq!(
            frame(&gateway(), 6, TOKEN, 0x33, &[0x00, 0xff]),
            IMPULSE.as_bytes()
        );
    }

    /// The pin. Every public encoder, across its arguments, puts a command id
    /// other than SET_STATE at the command's position.
    #[test]
    fn no_public_encoder_can_produce_an_impulse() {
        let command_of = |text: &[u8]| {
            let bytes = from_hex(text).unwrap();
            bytes[19]
        };
        for tag in [0u8, 1, 0x33, 0xff] {
            for token in [0u32, TOKEN, 0x3333_3333] {
                for port in [0u8, 0x33, 0xff] {
                    assert_eq!(
                        command_of(&encode_get_transition(GATEWAY, tag, token, port).unwrap()),
                        COMMAND_TRANSITION
                    );
                }
                assert_eq!(
                    command_of(&encode_get_groups(GATEWAY, tag, token).unwrap()),
                    COMMAND_JMCP
                );
                assert_eq!(
                    command_of(&encode_logout(GATEWAY, tag, token).unwrap()),
                    COMMAND_LOGOUT
                );
            }
            assert_eq!(
                command_of(&encode_login(GATEWAY, tag, "3", "3").unwrap()),
                COMMAND_LOGIN
            );
        }
        for exchange in [
            BiSecurExchange::Login,
            BiSecurExchange::GetGroups,
            BiSecurExchange::GetTransition,
        ] {
            assert_ne!(exchange.command(), 0x33);
        }
    }

    #[test]
    fn a_bad_mac_or_user_is_refused() {
        assert!(encode_get_groups("", 1, 0).is_err());
        assert!(encode_get_groups("54:10:EC:00:00", 1, 0).is_err());
        assert!(encode_get_groups("54:10:EC:00:00:ZZ", 1, 0).is_err());
        assert!(encode_get_groups("541:0:EC:00:00:01", 1, 0).is_err());
        assert!(encode_login(GATEWAY, 1, "", "x").is_err());
        assert!(encode_login(GATEWAY, 1, &"u".repeat(256), "x").is_err());
    }

    #[test]
    fn the_spec_frames_pass_the_checks_a_reply_has_to() {
        // Requests have the same layout, so the literal frames test the decoder.
        let name = decode_reply(GET_NAME.as_bytes(), 2, 0x26).unwrap_err();
        assert!(name.to_string().contains("does not answer"), "{name}");

        let answer = reply(5, TOKEN, 0xF0, &unhex(TRANSITION));
        let decoded = decode_reply(&answer, 5, COMMAND_TRANSITION).unwrap();
        assert_eq!(decoded.kind, BiSecurReplyKind::Answer);
        assert_eq!(decoded.payload, unhex(TRANSITION));
    }

    /// The example and every state its notes name.
    #[test]
    fn the_transition_example_decodes() {
        let transition = decode_transition(&unhex(TRANSITION)).unwrap();
        assert_eq!(transition.position_percent, Some(92.0));
        assert_eq!(transition.target_percent, Some(0.0));
        assert!(transition.driving);
        assert!(transition.driving_towards_closed);
        assert!(transition.light_barrier);
        assert!(transition.learned);
        assert!(!transition.fully_open);
        assert!(!transition.fully_closed);
        assert!(!transition.fault);
        assert!(!transition.status_error);
        assert!(!transition.not_referenced);
    }

    #[test]
    fn a_position_past_the_scale_is_absent() {
        let mut raw = unhex(TRANSITION);
        raw[0] = 201;
        assert_eq!(
            decode_transition(&raw).unwrap().position_percent,
            None,
            "201 is past 200 = 100 %"
        );
        raw[0] = 200;
        assert_eq!(
            decode_transition(&raw).unwrap().position_percent,
            Some(100.0)
        );
        assert!(decode_transition(&raw[..15]).is_err());
        assert!(decode_transition(&[]).is_err());
    }

    #[test]
    fn the_groups_example_decodes() {
        let groups =
            decode_groups(br#"[{"id":0,"name":"Garage","ports":[{"id":0,"type":1}]}]"#).unwrap();
        assert_eq!(groups.len(), 1);
        assert_eq!(groups[0].name, "Garage");
        assert_eq!(groups[0].ports[0].id, 0);
        assert_eq!(groups[0].ports[0].type_name.as_deref(), Some("Impulse"));
    }

    #[test]
    fn a_group_list_that_is_not_json_is_refused() {
        assert!(decode_groups(b"garbage").is_err());
        assert!(decode_groups(br#"{"id":0}"#).is_err());
        assert!(decode_groups(br#"[{"name":"no id"}]"#).is_err());
        assert_eq!(decode_groups(b"[]").unwrap(), vec![]);
    }

    #[test]
    fn the_login_reply_decodes() {
        assert_eq!(decode_login(&[9, 0x1A, 0x2B, 0x3C, 0x4D]).unwrap(), TOKEN);
        assert!(decode_login(&[]).is_err());
        assert!(decode_login(&[1, 2, 3, 4]).is_err());
    }

    /// `session`: the stale LOGOUT frames come first, coalesced with the reply.
    #[test]
    fn stale_logouts_coalesced_with_a_reply_split_and_are_skipped() {
        let stale = reply(STALE_LOGOUT_TAG, 0, COMMAND_LOGOUT, &[]);
        let answer = reply(3, 0, COMMAND_LOGIN | REPLY_FLAG, &[9, 1, 2, 3, 4]);
        let mut stream = stale.clone();
        stream.extend_from_slice(&stale);
        stream.extend_from_slice(&answer);
        stream.extend_from_slice(b"00000");

        let split = split_stream(&stream).unwrap();
        assert_eq!(split.frames.len(), 3);
        assert_eq!(split.rest, b"00000");

        let first = decode_reply(&split.frames[0], 3, COMMAND_LOGIN).unwrap();
        assert_eq!(first.kind, BiSecurReplyKind::Skip);
        let last = decode_reply(&split.frames[2], 3, COMMAND_LOGIN).unwrap();
        assert_eq!(last.kind, BiSecurReplyKind::Answer);
        assert_eq!(decode_login(&last.payload).unwrap(), 0x0102_0304);
    }

    #[test]
    fn a_frame_split_across_reads_waits_for_the_rest() {
        let answer = reply(3, 0, COMMAND_LOGIN | REPLY_FLAG, &[9, 1, 2, 3, 4]);
        let split = split_stream(&answer[..30]).unwrap();
        assert!(split.frames.is_empty());
        assert_eq!(split.rest, &answer[..30]);
        assert!(split_stream(&answer[..5]).unwrap().frames.is_empty());
    }

    #[test]
    fn a_mad_length_or_non_hex_stream_is_refused() {
        assert!(split_stream(&[b'Z'; 40]).is_err());
        let mut huge = b"000000000006".repeat(2);
        huge.extend_from_slice(b"FFFF");
        assert!(split_stream(&huge).is_err());
        let mut tiny = b"000000000006".repeat(2);
        tiny.extend_from_slice(b"0001");
        assert!(split_stream(&tiny).is_err());
    }

    #[test]
    fn an_error_frame_names_its_code() {
        let port_error = reply(5, TOKEN, COMMAND_ERROR, &[10]);
        let decoded = decode_reply(&port_error, 5, COMMAND_TRANSITION).unwrap();
        assert_eq!(decoded.kind, BiSecurReplyKind::Error);
        assert_eq!(decoded.error_code, Some(10));
        assert_eq!(error_meaning(10), "port error");
        assert_eq!(error_meaning(2), "login failed");
        assert_eq!(error_meaning(200), "not named by the spec");

        let long = reply(5, TOKEN, COMMAND_ERROR, &[1, 2]);
        assert!(decode_reply(&long, 5, COMMAND_TRANSITION).is_err());
    }

    #[test]
    fn another_tag_is_not_this_requests_answer() {
        let answer = reply(
            4,
            TOKEN,
            COMMAND_TRANSITION | REPLY_FLAG,
            &unhex(TRANSITION),
        );
        let decoded = decode_reply(&answer, 5, COMMAND_TRANSITION).unwrap();
        assert_eq!(decoded.kind, BiSecurReplyKind::Skip);
    }

    #[test]
    fn a_damaged_frame_is_refused() {
        let good = reply(
            5,
            TOKEN,
            COMMAND_TRANSITION | REPLY_FLAG,
            &unhex(TRANSITION),
        );
        assert!(decode_reply(&good, 5, COMMAND_TRANSITION).is_ok());
        // Any flipped character, including one inside the payload: a door's
        // position must not survive a bit of noise.
        for index in [0, 25, 30, 40, 60, good.len() - 1] {
            let mut bad = good.clone();
            bad[index] = if bad[index] == b'1' { b'2' } else { b'1' };
            assert!(
                decode_reply(&bad, 5, COMMAND_TRANSITION).is_err(),
                "character {index}"
            );
        }
        assert!(decode_reply(&good[..good.len() - 2], 5, COMMAND_TRANSITION).is_err());
        assert!(decode_reply(b"", 5, COMMAND_TRANSITION).is_err());
        assert!(decode_reply(&[b'G'; 60], 5, COMMAND_TRANSITION).is_err());
    }

    /// A packet past 255 bytes is where the two readings of the checksum part.
    #[test]
    fn a_long_group_list_passes_either_reading_of_the_packet_checksum() {
        let long = vec![b'x'; 300];
        let by_value = reply(4, TOKEN, COMMAND_JMCP | REPLY_FLAG, &long);
        assert!(decode_reply(&by_value, 4, COMMAND_JMCP).is_ok());

        // The same frame with its packet checksum worked over the two length
        // bytes rather than the value, and its transport checksum redone.
        let bytes = from_hex(&by_value).unwrap();
        let packet_end = bytes.len() - 2;
        let mut other = bytes[..packet_end].to_vec();
        let body = &bytes[ADDRESS_BYTES + 2..packet_end];
        other.push(((sum(&bytes[12..14]) + sum(body)) % 256) as u8);
        let mut text = String::new();
        for byte in &other {
            text.push_str(&format!("{byte:02X}"));
        }
        let transport = sum(text.as_bytes()) % 256;
        text.push_str(&format!("{transport:02X}"));
        assert_ne!(text.as_bytes(), by_value.as_slice());
        assert!(decode_reply(text.as_bytes(), 4, COMMAND_JMCP).is_ok());
    }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The CoAP (RFC 7252) message layer: one message to bytes and back.
//!
//! Hand-rolled because no CoAP crate is in this build and the part a client
//! of a purifier needs is small: the 4-byte header, a token, the option
//! delta/length encoding, and the payload marker (RFC 7252 section 3). There
//! is no retransmission, block-wise transfer, DTLS or resource directory
//! here, and no server: callers send non-confirmable requests, match the
//! reply by token, and acknowledge a confirmable reply with [`empty_ack`].
//!
//! Decoding is strict where the RFC says a message is malformed (version
//! not 1, a token longer than 8, a reserved option nibble, a payload marker
//! with nothing after it), because a datagram that fails those rules is
//! not a reply from the device and must not be read as one.
//!
//! Nothing here opens a socket.

use crate::error::ProtocolError;

/// RFC 7252 section 3: the only version defined.
pub const VERSION: u8 = 1;

/// The longest token RFC 7252 allows.
pub const MAX_TOKEN_LEN: usize = 8;

/// Separates the options from the payload.
pub const PAYLOAD_MARKER: u8 = 0xFF;

/// Option numbers this build reads or writes (RFC 7252 section 5.10, RFC 7641).
pub mod option {
    pub const OBSERVE: u16 = 6;
    pub const URI_PATH: u16 = 11;
    pub const CONTENT_FORMAT: u16 = 12;
    pub const MAX_AGE: u16 = 14;
}

/// Method and response codes as `class << 5 | detail`.
pub mod code {
    pub const EMPTY: u8 = 0x00;
    pub const GET: u8 = 0x01;
    pub const POST: u8 = 0x02;
    /// 2.05 Content.
    pub const CONTENT: u8 = 0x45;
    /// 2.04 Changed.
    pub const CHANGED: u8 = 0x44;

    /// The class (the digit before the dot) of a code.
    pub const fn class(code: u8) -> u8 {
        code >> 5
    }

    /// `c.dd`, as RFC 7252 writes codes.
    pub fn dotted(code: u8) -> String {
        format!("{}.{:02}", code >> 5, code & 0x1F)
    }
}

/// The four message types (RFC 7252 section 4.2/4.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageType {
    Confirmable,
    NonConfirmable,
    Acknowledgement,
    Reset,
}

impl MessageType {
    fn bits(self) -> u8 {
        match self {
            Self::Confirmable => 0,
            Self::NonConfirmable => 1,
            Self::Acknowledgement => 2,
            Self::Reset => 3,
        }
    }

    fn from_bits(bits: u8) -> Self {
        match bits & 0x03 {
            0 => Self::Confirmable,
            1 => Self::NonConfirmable,
            2 => Self::Acknowledgement,
            _ => Self::Reset,
        }
    }
}

/// One option: its number and raw value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoapOption {
    pub number: u16,
    pub value: Vec<u8>,
}

/// One CoAP message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Message {
    pub message_type: MessageType,
    pub code: u8,
    pub message_id: u16,
    pub token: Vec<u8>,
    /// In ascending number order once encoded; [`encode`] sorts a copy.
    pub options: Vec<CoapOption>,
    pub payload: Vec<u8>,
}

impl Message {
    /// The first value of option `number`, if present.
    pub fn option(&self, number: u16) -> Option<&[u8]> {
        self.options
            .iter()
            .find(|o| o.number == number)
            .map(|o| o.value.as_slice())
    }

    /// An option read as the RFC's `uint` (big-endian, leading zeros elided).
    pub fn uint_option(&self, number: u16) -> Option<u32> {
        let value = self.option(number)?;
        if value.len() > 4 {
            return None;
        }
        Some(value.iter().fold(0u32, |acc, b| (acc << 8) | u32::from(*b)))
    }
}

/// The RFC's `uint` option value: big-endian with leading zero bytes elided,
/// so zero is the empty string.
pub fn uint_value(value: u32) -> Vec<u8> {
    let bytes = value.to_be_bytes();
    let first = bytes.iter().position(|b| *b != 0).unwrap_or(bytes.len());
    bytes[first..].to_vec()
}

/// One Uri-Path option per segment of `path` (`/sys/dev/sync` is three).
pub fn uri_path_options(path: &str) -> Vec<CoapOption> {
    path.split('/')
        .filter(|segment| !segment.is_empty())
        .map(|segment| CoapOption {
            number: option::URI_PATH,
            value: segment.as_bytes().to_vec(),
        })
        .collect()
}

fn invalid(reason: &str) -> ProtocolError {
    ProtocolError::MalformedReply(format!("CoAP: {reason}"))
}

/// A delta or length as its nibble plus extended bytes (RFC 7252 3.1).
fn nibble(value: usize) -> Result<(u8, Vec<u8>), ProtocolError> {
    match value {
        0..=12 => Ok((value as u8, Vec::new())),
        13..=268 => Ok((13, vec![(value - 13) as u8])),
        269..=65804 => Ok((14, ((value - 269) as u16).to_be_bytes().to_vec())),
        _ => Err(invalid("an option delta or length past 65804")),
    }
}

/// Encode one message.
pub fn encode(message: &Message) -> Result<Vec<u8>, ProtocolError> {
    if message.token.len() > MAX_TOKEN_LEN {
        return Err(invalid("a token longer than 8 bytes"));
    }
    let mut out = vec![
        (VERSION << 6) | (message.message_type.bits() << 4) | message.token.len() as u8,
        message.code,
    ];
    out.extend_from_slice(&message.message_id.to_be_bytes());
    out.extend_from_slice(&message.token);
    // A stable sort keeps repeated options (Uri-Path segments) in order.
    let mut options = message.options.clone();
    options.sort_by_key(|o| o.number);
    let mut previous = 0u16;
    for opt in &options {
        let (delta, delta_ext) = nibble(usize::from(opt.number - previous))?;
        let (length, length_ext) = nibble(opt.value.len())?;
        out.push((delta << 4) | length);
        out.extend_from_slice(&delta_ext);
        out.extend_from_slice(&length_ext);
        out.extend_from_slice(&opt.value);
        previous = opt.number;
    }
    if !message.payload.is_empty() {
        out.push(PAYLOAD_MARKER);
        out.extend_from_slice(&message.payload);
    }
    Ok(out)
}

/// Read a nibble's extended value from `bytes` at `*at`.
fn extended(nibble: u8, bytes: &[u8], at: &mut usize) -> Result<usize, ProtocolError> {
    match nibble {
        0..=12 => Ok(usize::from(nibble)),
        13 => {
            let b = *bytes.get(*at).ok_or_else(|| invalid("truncated option"))?;
            *at += 1;
            Ok(usize::from(b) + 13)
        }
        14 => {
            let pair = bytes
                .get(*at..*at + 2)
                .ok_or_else(|| invalid("truncated option"))?;
            *at += 2;
            Ok(usize::from(u16::from_be_bytes([pair[0], pair[1]])) + 269)
        }
        _ => Err(invalid("reserved option nibble 15")),
    }
}

/// Decode one datagram as a CoAP message, refusing anything malformed.
pub fn decode(bytes: &[u8]) -> Result<Message, ProtocolError> {
    if bytes.len() < 4 {
        return Err(invalid("shorter than the 4-byte header"));
    }
    if bytes[0] >> 6 != VERSION {
        return Err(invalid("not version 1"));
    }
    let message_type = MessageType::from_bits(bytes[0] >> 4);
    let token_len = usize::from(bytes[0] & 0x0F);
    if token_len > MAX_TOKEN_LEN {
        return Err(invalid("a token length over 8"));
    }
    let code = bytes[1];
    let message_id = u16::from_be_bytes([bytes[2], bytes[3]]);
    let token = bytes
        .get(4..4 + token_len)
        .ok_or_else(|| invalid("truncated token"))?
        .to_vec();
    let mut at = 4 + token_len;
    let mut options = Vec::new();
    let mut number = 0usize;
    let mut payload = Vec::new();
    while at < bytes.len() {
        let head = bytes[at];
        at += 1;
        if head == PAYLOAD_MARKER {
            if at == bytes.len() {
                return Err(invalid("a payload marker with no payload"));
            }
            payload = bytes[at..].to_vec();
            break;
        }
        let delta = extended(head >> 4, bytes, &mut at)?;
        let length = extended(head & 0x0F, bytes, &mut at)?;
        number += delta;
        let number16 = u16::try_from(number).map_err(|_| invalid("option number past 65535"))?;
        let value = bytes
            .get(at..at + length)
            .ok_or_else(|| invalid("truncated option value"))?
            .to_vec();
        at += length;
        options.push(CoapOption {
            number: number16,
            value,
        });
    }
    if code == code::EMPTY && (!token.is_empty() || !options.is_empty() || !payload.is_empty()) {
        return Err(invalid("an empty message carrying content"));
    }
    Ok(Message {
        message_type,
        code,
        message_id,
        token,
        options,
        payload,
    })
}

/// The empty ACK a client owes a confirmable reply (RFC 7252 4.2).
pub fn empty_ack(message_id: u16) -> Vec<u8> {
    let mut out = vec![
        (VERSION << 6) | (MessageType::Acknowledgement.bits() << 4),
        0,
    ];
    out.extend_from_slice(&message_id.to_be_bytes());
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn get(path: &str, token: &[u8]) -> Message {
        Message {
            message_type: MessageType::NonConfirmable,
            code: code::GET,
            message_id: 0x1234,
            token: token.to_vec(),
            options: uri_path_options(path),
            payload: Vec::new(),
        }
    }

    /// RFC 7252 figure 1's header fields, worked by hand: NON (01), TKL 2,
    /// GET 0.01, MID 0x1234, then Uri-Path (11) "sys" as delta 11 length 3,
    /// "dev" as delta 0 length 3, "status" as delta 0 length 6.
    #[test]
    fn a_get_encodes_to_the_hand_worked_bytes() {
        let bytes = encode(&get("/sys/dev/status", &[0xAB, 0xCD])).unwrap();
        let mut expected = vec![0x52, 0x01, 0x12, 0x34, 0xAB, 0xCD];
        expected.push(0xB3);
        expected.extend_from_slice(b"sys");
        expected.push(0x03);
        expected.extend_from_slice(b"dev");
        expected.push(0x06);
        expected.extend_from_slice(b"status");
        assert_eq!(bytes, expected);
    }

    /// Observe (6) sorts ahead of Uri-Path (11), and Observe = 0 is an empty
    /// uint: one byte 0x60, then delta 5 to Uri-Path.
    #[test]
    fn observe_zero_is_an_empty_option_ahead_of_the_path() {
        let mut message = get("/sys/dev/status", &[1]);
        message.options.push(CoapOption {
            number: option::OBSERVE,
            value: uint_value(0),
        });
        let bytes = encode(&message).unwrap();
        assert_eq!(&bytes[..6], &[0x51, 0x01, 0x12, 0x34, 0x01, 0x60]);
        assert_eq!(bytes[6], 0x53);
        assert_eq!(
            decode(&bytes).unwrap().uint_option(option::OBSERVE),
            Some(0)
        );
    }

    #[test]
    fn a_post_carries_its_payload_after_the_marker() {
        let message = Message {
            message_type: MessageType::NonConfirmable,
            code: code::POST,
            message_id: 7,
            token: vec![9; 8],
            options: uri_path_options("/sys/dev/sync"),
            payload: b"1A2B3C4D".to_vec(),
        };
        let bytes = encode(&message).unwrap();
        assert_eq!(&bytes[bytes.len() - 9..], b"\xFF1A2B3C4D");
        assert_eq!(decode(&bytes).unwrap(), message);
    }

    /// The extended forms: a 13..268 length takes one extra byte, 269 and up
    /// two, and an option number past 12 takes a delta byte.
    #[test]
    fn extended_deltas_and_lengths_round_trip() {
        for length in [12usize, 13, 268, 269, 1000] {
            let message = Message {
                message_type: MessageType::Confirmable,
                code: code::CONTENT,
                message_id: 0xFFFF,
                token: Vec::new(),
                options: vec![
                    CoapOption {
                        number: option::MAX_AGE,
                        value: uint_value(60),
                    },
                    CoapOption {
                        number: 300,
                        value: vec![0x5A; length],
                    },
                ],
                payload: b"x".to_vec(),
            };
            assert_eq!(decode(&encode(&message).unwrap()).unwrap(), message);
        }
        let one = encode(&Message {
            message_type: MessageType::Confirmable,
            code: code::GET,
            message_id: 0,
            token: Vec::new(),
            options: vec![CoapOption {
                number: 13,
                value: vec![0; 13],
            }],
            payload: Vec::new(),
        })
        .unwrap();
        assert_eq!(&one[4..7], &[0xDD, 0x00, 0x00]);
    }

    #[test]
    fn uint_values_elide_leading_zeros() {
        assert_eq!(uint_value(0), Vec::<u8>::new());
        assert_eq!(uint_value(60), vec![60]);
        assert_eq!(uint_value(0x0102), vec![1, 2]);
        assert_eq!(uint_value(u32::MAX), vec![0xFF; 4]);
    }

    #[test]
    fn malformed_datagrams_are_refused() {
        for bytes in [
            &[][..],
            &[0x50, 0x45, 0x00][..],
            // Version 2.
            &[0x90, 0x45, 0x00, 0x01][..],
            // TKL 9.
            &[0x59, 0x45, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0, 0, 0][..],
            // TKL 2, one byte of token.
            &[0x52, 0x45, 0x00, 0x01, 0xAA][..],
            // Payload marker and nothing after it.
            &[0x50, 0x45, 0x00, 0x01, 0xFF][..],
            // Reserved delta nibble 15 that is not the marker.
            &[0x50, 0x45, 0x00, 0x01, 0xF1, 0x00][..],
            // Option length runs past the end.
            &[0x50, 0x45, 0x00, 0x01, 0xB5, b'a'][..],
            // An empty message with a payload.
            &[0x60, 0x00, 0x00, 0x01, 0xFF, b'x'][..],
        ] {
            assert!(decode(bytes).is_err(), "{bytes:02X?} decoded");
        }
    }

    #[test]
    fn an_empty_ack_is_four_bytes_echoing_the_id() {
        let ack = empty_ack(0xBEEF);
        assert_eq!(ack, vec![0x60, 0x00, 0xBE, 0xEF]);
        let decoded = decode(&ack).unwrap();
        assert_eq!(decoded.message_type, MessageType::Acknowledgement);
        assert_eq!(decoded.code, code::EMPTY);
    }

    #[test]
    fn codes_print_as_the_rfc_writes_them() {
        assert_eq!(code::dotted(code::CONTENT), "2.05");
        assert_eq!(code::dotted(0x84), "4.04");
        assert_eq!(code::class(0xA0), 5);
    }
}

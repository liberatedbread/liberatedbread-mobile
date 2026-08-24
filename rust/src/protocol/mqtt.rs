// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! MQTT 3.1.1, enough of it to talk to a device's own broker.
//!
//! Hand-rolled rather than pulled in: the client half of 3.1.1 that a LAN
//! appliance needs is CONNECT, SUBSCRIBE, PUBLISH at QoS 0 and a keepalive,
//! and every crate that offers it also brings an async runtime this crate
//! deliberately does not have. What crosses the FFI is bytes; the socket is
//! Dart's.
//!
//! Written for the Roomba first and extracted here unchanged in behaviour so
//! the other MQTT devices in the catalogue can use it. Nothing in this module
//! knows about any device: what a client id means, which topics exist, what a
//! payload says are all the caller's, read from the spec.

use crate::protocol::ProtocolError;

// ── MQTT 3.1.1 ───────────────────────────────────────────────────────────────

/// The keepalive to advertise when a caller has no reason to pick another.
///
/// Short on purpose. A device broker often serves one client at a time, so a
/// client that lingers holds the owner's own app out; a minute is long enough
/// not to churn and short enough that a wedged connection is dropped rather
/// than occupying the slot until a TCP timeout.
pub const KEEPALIVE_SECONDS: u16 = 60;

/// What a CONNACK said.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ConnectOutcome {
    Accepted,
    /// The broker refused, with its 3.1.1 return code.
    Refused(u8),
}

/// A packet parsed off the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Incoming {
    ConnAck(ConnectOutcome),
    SubAck {
        packet_id: u16,
    },
    Publish {
        topic: String,
        payload: String,
    },
    PingResp,
    /// A packet type this client does not act on. Kept rather than dropped so
    /// a caller can log what a device sent that we did not expect.
    Other {
        packet_type: u8,
    },
}

/// Who is connecting, and how.
///
/// A struct rather than four positional arguments because three of them are
/// strings and two are optional: `connect(id, None, Some(pw), ...)` is exactly
/// the call site that gets username and password the wrong way round.
#[derive(Debug, Clone)]
pub struct ConnectOptions<'a> {
    /// The client id. Brokers differ on what they accept — a Roomba insists on
    /// its BLID and refuses anything else — so this is always the caller's.
    pub client_id: &'a str,
    /// Username and password, when the broker wants them. Each is sent only
    /// when present: MQTT flags them independently, and a broker that expects
    /// neither refuses a CONNECT carrying empty strings.
    pub username: Option<&'a str>,
    pub password: Option<&'a str>,
    /// Keepalive advertised to the broker. Zero disables the broker's timeout,
    /// which is rarely what anyone wants on a LAN appliance.
    pub keepalive_seconds: u16,
    /// Clean session. False resumes a session the broker held for this client
    /// id, which only makes sense for a client that subscribes at QoS > 0.
    pub clean_session: bool,
}

impl<'a> ConnectOptions<'a> {
    /// The ordinary case: a clean session at the default keepalive, with
    /// credentials.
    pub fn with_credentials(client_id: &'a str, username: &'a str, password: &'a str) -> Self {
        Self {
            client_id,
            username: Some(username),
            password: Some(password),
            keepalive_seconds: KEEPALIVE_SECONDS,
            clean_session: true,
        }
    }
}

/// CONNECT.
pub fn connect_packet(options: &ConnectOptions<'_>) -> Vec<u8> {
    let mut variable = Vec::new();
    encode_string(&mut variable, "MQTT");
    variable.push(0x04); // protocol level 4 = MQTT 3.1.1

    // Flags: username (0x80), password (0x40), clean session (0x02). Built
    // from what is actually present rather than written as one constant, so a
    // broker that wants no credentials gets a CONNECT that says so.
    let mut flags = 0u8;
    if options.username.is_some() {
        flags |= 0x80;
    }
    if options.password.is_some() {
        flags |= 0x40;
    }
    if options.clean_session {
        flags |= 0x02;
    }
    variable.push(flags);
    variable.extend_from_slice(&options.keepalive_seconds.to_be_bytes());

    encode_string(&mut variable, options.client_id);
    // Order is fixed by the spec: client id, then username, then password.
    if let Some(username) = options.username {
        encode_string(&mut variable, username);
    }
    if let Some(password) = options.password {
        encode_string(&mut variable, password);
    }

    packet(0x10, &variable)
}

/// SUBSCRIBE at QoS 0.
///
/// The topic is the caller's, `#` included: which topic shape a given firmware
/// publishes on is a spec question, and for some devices the honest answer is
/// "subscribe to everything and see".
pub fn subscribe_packet(topic: &str, packet_id: u16) -> Vec<u8> {
    let mut variable = Vec::new();
    variable.extend_from_slice(&packet_id.to_be_bytes());
    encode_string(&mut variable, topic);
    variable.push(0x00); // requested QoS
    packet(0x82, &variable)
}

/// PUBLISH at QoS 0 — no packet id, no acknowledgement.
///
/// QoS 0 only, deliberately: a higher QoS needs packet-id bookkeeping and a
/// retransmit timer, which is state this codec does not hold. Every device
/// broker in the catalogue publishes commands this way.
pub fn publish_packet(topic: &str, payload: &str) -> Vec<u8> {
    let mut variable = Vec::new();
    encode_string(&mut variable, topic);
    variable.extend_from_slice(payload.as_bytes());
    packet(0x30, &variable)
}

pub fn pingreq_packet() -> Vec<u8> {
    packet(0xC0, &[])
}

pub fn disconnect_packet() -> Vec<u8> {
    packet(0xE0, &[])
}

/// Parse whole packets out of a receive buffer.
///
/// Returns the packets it could read and how many bytes they consumed; the
/// caller keeps the remainder and calls again when more arrives. A TLS stream
/// splits and coalesces at whatever boundaries it likes, so treating each read
/// as a packet is the bug this exists to prevent.
///
/// A malformed remaining-length is an error rather than a skip: the stream's
/// framing is lost at that point and every later packet would be garbage.
pub fn parse_incoming(buffer: &[u8]) -> Result<(Vec<Incoming>, usize), ProtocolError> {
    let mut packets = Vec::new();
    let mut cursor = 0usize;

    while cursor < buffer.len() {
        let header = buffer[cursor];
        let Some((remaining, length_bytes)) = decode_remaining_length(&buffer[cursor + 1..])?
        else {
            break; // length field not fully arrived
        };
        let start = cursor + 1 + length_bytes;
        let Some(body) = buffer.get(start..start + remaining) else {
            break; // body not fully arrived
        };

        packets.push(decode_packet(header, body)?);
        cursor = start + remaining;
    }

    Ok((packets, cursor))
}

fn decode_packet(header: u8, body: &[u8]) -> Result<Incoming, ProtocolError> {
    match header >> 4 {
        2 => {
            let code = body.get(1).copied().ok_or_else(|| {
                ProtocolError::MalformedReply("CONNACK carries no return code".to_string())
            })?;
            Ok(Incoming::ConnAck(if code == 0 {
                ConnectOutcome::Accepted
            } else {
                ConnectOutcome::Refused(code)
            }))
        }
        9 => {
            let id = body
                .get(..2)
                .map(|b| u16::from_be_bytes([b[0], b[1]]))
                .ok_or_else(|| {
                    ProtocolError::MalformedReply("SUBACK carries no packet id".to_string())
                })?;
            Ok(Incoming::SubAck { packet_id: id })
        }
        3 => {
            let (topic, consumed) = decode_string(body)?;
            // QoS 1 and 2 publishes carry a packet id after the topic. Most
            // device brokers publish at QoS 0, but one that did not would
            // otherwise prepend two bytes of id to every payload and the JSON
            // would fail to parse for reasons nothing explains.
            let qos = (header >> 1) & 0x03;
            let skip = if qos > 0 { 2 } else { 0 };
            let payload = body
                .get(consumed + skip..)
                .ok_or_else(|| {
                    ProtocolError::MalformedReply(
                        "PUBLISH is shorter than its own topic".to_string(),
                    )
                })?
                .to_vec();
            Ok(Incoming::Publish {
                topic,
                payload: String::from_utf8_lossy(&payload).into_owned(),
            })
        }
        13 => Ok(Incoming::PingResp),
        other => Ok(Incoming::Other { packet_type: other }),
    }
}

/// Fixed header + remaining-length varint + body.
fn packet(header: u8, body: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(body.len() + 5);
    out.push(header);
    encode_remaining_length(&mut out, body.len());
    out.extend_from_slice(body);
    out
}

/// MQTT's length-prefixed UTF-8 string: two big-endian bytes, then the bytes.
fn encode_string(out: &mut Vec<u8>, value: &str) {
    let bytes = value.as_bytes();
    out.extend_from_slice(&(bytes.len() as u16).to_be_bytes());
    out.extend_from_slice(bytes);
}

fn decode_string(body: &[u8]) -> Result<(String, usize), ProtocolError> {
    let len = body
        .get(..2)
        .map(|b| u16::from_be_bytes([b[0], b[1]]) as usize)
        .ok_or_else(|| {
            ProtocolError::MalformedReply("string is shorter than its length prefix".to_string())
        })?;
    let bytes = body.get(2..2 + len).ok_or_else(|| {
        ProtocolError::MalformedReply(format!("string declares {len} bytes that do not follow"))
    })?;
    Ok((String::from_utf8_lossy(bytes).into_owned(), 2 + len))
}

/// The remaining-length varint: seven bits per byte, high bit means continue.
fn encode_remaining_length(out: &mut Vec<u8>, mut length: usize) {
    loop {
        let mut byte = (length % 128) as u8;
        length /= 128;
        if length > 0 {
            byte |= 0x80;
        }
        out.push(byte);
        if length == 0 {
            break;
        }
    }
}

/// `Ok(None)` when the varint has not fully arrived yet — the caller waits for
/// more bytes rather than treating a partial read as a protocol error.
fn decode_remaining_length(bytes: &[u8]) -> Result<Option<(usize, usize)>, ProtocolError> {
    let mut value = 0usize;
    let mut multiplier = 1usize;
    for (index, byte) in bytes.iter().enumerate() {
        value += (byte & 0x7F) as usize * multiplier;
        if byte & 0x80 == 0 {
            return Ok(Some((value, index + 1)));
        }
        multiplier *= 128;
        if index == 3 {
            return Err(ProtocolError::MalformedReply(
                "remaining-length field is longer than the 4 bytes MQTT allows".to_string(),
            ));
        }
    }
    Ok(None)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn connect_carries_the_client_id_username_and_password_in_order() {
        let packet = connect_packet(&ConnectOptions::with_credentials(
            "BLID123",
            "BLID123",
            "  :1:secret",
        ));
        assert_eq!(packet[0], 0x10);
        // MQTT 3.1.1 protocol name and level.
        assert_eq!(&packet[2..8], b"\x00\x04MQTT");
        assert_eq!(packet[8], 0x04);
        assert_eq!(packet[9], 0xC2, "username + password + clean session");
        // client id, username, password, in that order.
        let tail = &packet[12..];
        assert_eq!(&tail[..9], b"\x00\x07BLID123");
        assert_eq!(&tail[9..18], b"\x00\x07BLID123");
        // Length-prefixed verbatim: the leading spaces are part of the password.
        // Real Roomba passwords start with ':' and a client that trims either end
        // sends a credential the broker refuses.
        assert_eq!(&tail[18..], b"\x00\x0b  :1:secret");
    }

    #[test]
    fn publish_and_subscribe_round_trip_through_the_parser() {
        let mut stream = Vec::new();
        stream.extend(publish_packet("cmd", r#"{"command":"clean"}"#));
        stream.extend(pingreq_packet());

        let (packets, consumed) = parse_incoming(&stream).unwrap();
        assert_eq!(consumed, stream.len());
        assert_eq!(
            packets[0],
            Incoming::Publish {
                topic: "cmd".to_string(),
                payload: r#"{"command":"clean"}"#.to_string(),
            }
        );
    }

    #[test]
    fn connack_reports_acceptance_and_refusal() {
        let accepted = parse_incoming(&[0x20, 0x02, 0x00, 0x00]).unwrap().0;
        assert_eq!(accepted[0], Incoming::ConnAck(ConnectOutcome::Accepted));

        // 4 = bad username or password: the wrong credential, not a bad network.
        let refused = parse_incoming(&[0x20, 0x02, 0x00, 0x04]).unwrap().0;
        assert_eq!(refused[0], Incoming::ConnAck(ConnectOutcome::Refused(4)));
    }

    /// A TLS stream splits and coalesces wherever it likes. Treating one read
    /// as one packet is the bug `parse_incoming`'s consumed count prevents.
    #[test]
    fn a_partial_packet_is_left_in_the_buffer() {
        let whole = publish_packet("delta", r#"{"state":{}}"#);
        for split in 1..whole.len() {
            let (packets, consumed) = parse_incoming(&whole[..split]).unwrap();
            assert!(packets.is_empty(), "parsed a packet from {split} bytes");
            assert_eq!(consumed, 0, "consumed bytes it could not parse");
        }
        let (packets, consumed) = parse_incoming(&whole).unwrap();
        assert_eq!(packets.len(), 1);
        assert_eq!(consumed, whole.len());
    }

    /// A payload longer than 127 bytes needs a two-byte remaining-length, and a
    /// device's state payloads are routinely far longer than that.
    #[test]
    fn multi_byte_remaining_lengths_round_trip() {
        for size in [0usize, 1, 127, 128, 16_383, 16_384] {
            let payload = "x".repeat(size);
            let whole = publish_packet("delta", &payload);
            let (packets, consumed) = parse_incoming(&whole).unwrap();
            assert_eq!(consumed, whole.len(), "size {size}");
            assert_eq!(
                packets[0],
                Incoming::Publish {
                    topic: "delta".to_string(),
                    payload,
                },
                "size {size}"
            );
        }
    }

    /// A QoS>0 publish carries a packet id between topic and payload. The devices
    /// in the catalogue publish at QoS 0, but firmware that did not would
    /// otherwise prepend two bytes to the JSON and the parse would fail for no
    /// visible reason.
    #[test]
    fn a_qos1_publish_skips_its_packet_id() {
        let mut variable = Vec::new();
        encode_string(&mut variable, "delta");
        variable.extend_from_slice(&7u16.to_be_bytes());
        variable.extend_from_slice(br#"{"ok":1}"#);
        let raw = packet(0x32, &variable); // 0x32 = PUBLISH, QoS 1

        let (packets, _) = parse_incoming(&raw).unwrap();
        assert_eq!(
            packets[0],
            Incoming::Publish {
                topic: "delta".to_string(),
                payload: r#"{"ok":1}"#.to_string(),
            }
        );
    }

    #[test]
    fn several_packets_in_one_read_are_all_returned() {
        let mut stream = Vec::new();
        stream.extend([0x20, 0x02, 0x00, 0x00]);
        stream.extend(publish_packet("delta", "{}"));
        stream.extend([0xD0, 0x00]);

        let (packets, consumed) = parse_incoming(&stream).unwrap();
        assert_eq!(consumed, stream.len());
        assert_eq!(packets.len(), 3);
        assert_eq!(packets[2], Incoming::PingResp);
    }

    #[test]
    fn a_five_byte_remaining_length_is_an_error_not_a_hang() {
        let error = parse_incoming(&[0x30, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]).unwrap_err();
        assert!(matches!(error, ProtocolError::MalformedReply(_)), "{error}");
    }

    /// Credentials are flagged independently, so a broker that wants none gets a
    /// CONNECT that says none — not one carrying two empty strings, which some
    /// brokers refuse and others read as an empty username.
    #[test]
    fn a_connect_without_credentials_sets_neither_flag() {
        let packet = connect_packet(&ConnectOptions {
            client_id: "anon",
            username: None,
            password: None,
            keepalive_seconds: 30,
            clean_session: true,
        });
        assert_eq!(packet[9], 0x02, "clean session only");
        assert_eq!(&packet[10..12], &30u16.to_be_bytes());
        // Client id and nothing after it.
        assert_eq!(&packet[12..], b"\x00\x04anon");
    }

    /// A username with no password is legal in 3.1.1 and is what a token-style
    /// broker takes.
    #[test]
    fn a_username_without_a_password_sets_only_its_own_flag() {
        let packet = connect_packet(&ConnectOptions {
            client_id: "c",
            username: Some("u"),
            password: None,
            keepalive_seconds: KEEPALIVE_SECONDS,
            clean_session: false,
        });
        assert_eq!(packet[9], 0x80, "username flag, no clean session");
    }
}

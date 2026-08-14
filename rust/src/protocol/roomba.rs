// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Drive a Wi-Fi Roomba from its spec: MQTT over TLS to a broker running on
//! the robot itself, TCP 8883, authenticated with the robot's BLID and a
//! per-device password.
//!
//! # Credit
//!
//! None of this protocol is ours. [dorita980](https://github.com/koalazak/dorita980)
//! (koalazak, MIT) worked out the UDP-5678 discovery probe, the
//! password-disclosure handshake, the MQTT session and the command
//! vocabulary; [roombapy](https://github.com/pschmitt/roombapy) carried the
//! same protocol into Python and is what Home Assistant runs. This module is a
//! transcription of the machine-readable spec they made possible
//! (`device-specs/devices/irobot-roomba.yaml`), not independent work.
//!
//! # What lives here, and what does not
//!
//! The same division as [`super::kasa`] and [`super::lifx`]: bytes in, bytes
//! out, no I/O. This module builds the discovery datagram, the password probe,
//! the MQTT packets and the command payloads, and parses what comes back.
//! Dart owns every socket — which for this transport matters more than usual,
//! because the socket is a TLS one and the platform TLS stack is the thing
//! that decides whether a given robot is reachable at all (see
//! [`parse_password_reply`]'s note on ciphers).
//!
//! MQTT 3.1.1 is hand-rolled rather than pulled in as a crate. Five packet
//! types are used — CONNECT, SUBSCRIBE, PUBLISH, PINGREQ, DISCONNECT — plus
//! three parsed on the way back, and a dependency for that would be larger
//! than the code it replaced, in a cdylib that rides inside every app
//! download.

use std::collections::BTreeMap;

use crate::error::ProtocolError;
use crate::spec::types::{DeviceSpec, Entity, SpecCommand};

/// The `protocol_handler` string a spec must declare to be driven from here.
pub const HANDLER_NAME: &str = "roomba_mqtt";

/// The transport a command must declare to be sendable from here, and the
/// token the app's control screen dispatches on.
pub const TRANSPORT: &str = "mqtt";

/// The robot's own MQTT broker. TLS, always.
pub const PORT: u16 = 8883;

/// Where the discovery probe is broadcast.
pub const DISCOVERY_PORT: u16 = 5678;

/// The nine ASCII bytes every iRobot robot on the segment answers.
pub const DISCOVERY_PROBE: &[u8] = b"irobotmcs";

/// Hostname prefixes an announcement must carry to be a robot at all. The
/// probe is a broadcast, so it reaches printers and thermostats too; without
/// this filter a client reports the whole LAN as Roombas.
const HOSTNAME_PREFIXES: [&str; 2] = ["Roomba-", "iRobot-"];

/// The password-disclosure probe: 0xf0 (an MQTT reserved packet type), a
/// payload length of 5, then the payload.
pub const PASSWORD_PROBE: [u8; 7] = [0xf0, 0x05, 0xef, 0xcc, 0x3b, 0x29, 0x00];

/// The reply a model that cannot disclose its password locally sends back.
/// Distinguished from a failed attempt because it is not worth retrying: the
/// user needs the account route instead, and telling them to hold the button
/// again wastes their time.
const PASSWORD_UNSUPPORTED: [u8; 7] = [0xf0, 0x05, 0xef, 0xcc, 0x3b, 0x29, 0x03];

/// Bytes of framing before the disclosure reply's payload.
const PASSWORD_HEADER_LEN: usize = 2;

/// Shorter than this and the robot was never in disclosure mode.
const PASSWORD_MIN_LEN: usize = 8;

/// What one robot said when it answered [`DISCOVERY_PROBE`].
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Announcement {
    /// Announcement format version.
    pub ver: String,
    /// `Roomba-<blid>` or `iRobot-<blid>`.
    pub hostname: String,
    /// The MQTT username, split off `hostname`.
    pub blid: String,
    /// User-assigned name. Display only — it changes.
    pub robotname: String,
    /// A DHCP lease. Never key stored credentials on it.
    pub ip: String,
    pub mac: String,
    /// Firmware version, e.g. `v2.4.16-126`.
    pub sw: String,
    /// Model code, e.g. `R980020`.
    pub sku: String,
    /// `mqtt` on every robot this spec covers.
    pub proto: String,
}

/// Parse one discovery datagram.
///
/// Returns `Ok(None)` — not an error — for a datagram that is simply not from
/// a robot. A broadcast probe collects whatever else is listening on the
/// segment, and a scan must not fail because a printer replied.
pub fn parse_announcement(datagram: &[u8]) -> Result<Option<Announcement>, ProtocolError> {
    let Ok(text) = std::str::from_utf8(datagram) else {
        return Ok(None);
    };
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else {
        return Ok(None);
    };
    let Some(object) = value.as_object() else {
        return Ok(None);
    };

    let string = |key: &str| -> String {
        object
            .get(key)
            .and_then(serde_json::Value::as_str)
            .unwrap_or_default()
            .to_string()
    };

    let hostname = string("hostname");
    let Some(blid) = blid_from_hostname(&hostname) else {
        return Ok(None);
    };

    Ok(Some(Announcement {
        ver: string("ver"),
        blid,
        robotname: string("robotname"),
        ip: string("ip"),
        mac: string("mac"),
        sw: string("sw"),
        sku: string("sku"),
        proto: string("proto"),
        hostname,
    }))
}

/// `Roomba-<blid>` / `iRobot-<blid>` → `<blid>`; `None` for anything else.
///
/// An empty BLID counts as "not a robot": a hostname of exactly `Roomba-` has
/// no identity to key credentials on, and letting it through would produce a
/// device the app could store a password against and never find again.
pub fn blid_from_hostname(hostname: &str) -> Option<String> {
    HOSTNAME_PREFIXES
        .iter()
        .find_map(|prefix| hostname.strip_prefix(prefix))
        .filter(|blid| !blid.is_empty())
        .map(str::to_string)
}

/// Pull the password out of a disclosure reply.
///
/// # Why this is a rule and not an offset
///
/// The three published clients each slice at a different fixed offset into the
/// same reply — roombapy at 7 of the whole reply, dorita980 at 13 when the
/// socket delivered everything in one read and at 9 when the two-byte header
/// arrived separately. The spec records all three as evidence and states the
/// extraction as a rule instead: drop the header, drop remaining leading
/// non-printable bytes, take the rest.
///
/// That rule is the spec's own `hypothesis`-graded synthesis, not something
/// anyone captured, and it rests on the gap before the credential holding no
/// printable byte. If that assumption is ever wrong the caller gets a password
/// with junk on the front and the only symptom is a login the broker refuses —
/// which is why the spec says to report a disagreement upstream rather than
/// work around it locally.
///
/// The whole remaining string is the password. Roomba passwords begin with
/// `:` and contain `:` separators, so nothing may be split off the front.
///
/// # Not handled here
///
/// The failure most users actually hit on old firmware happens before this is
/// ever called: the robot offers only `AES128-SHA256`, which modern TLS stacks
/// have retired, and the handshake fails. That is the socket owner's error to
/// name, not this function's.
pub fn parse_password_reply(reply: &[u8]) -> Result<String, ProtocolError> {
    if reply == PASSWORD_UNSUPPORTED {
        return Err(ProtocolError::MalformedReply(
            "the robot answered that it cannot disclose its password locally; \
             use the iRobot account route instead"
                .to_string(),
        ));
    }
    if reply.len() < PASSWORD_MIN_LEN {
        return Err(ProtocolError::MalformedReply(format!(
            "reply is {} bytes, too short to carry a password — the robot was \
             not in disclosure mode. Hold HOME until it plays the tones, then \
             retry.",
            reply.len()
        )));
    }

    let body = &reply[PASSWORD_HEADER_LEN..];
    let start = body
        .iter()
        .position(|byte| byte.is_ascii_graphic() || *byte == b' ')
        .ok_or_else(|| {
            ProtocolError::MalformedReply(
                "reply carries no printable bytes after its header".to_string(),
            )
        })?;

    let password = std::str::from_utf8(&body[start..])
        .map_err(|_| {
            ProtocolError::MalformedReply("password bytes are not valid UTF-8".to_string())
        })?
        .trim_end_matches('\0')
        .to_string();

    if password.is_empty() {
        return Err(ProtocolError::MalformedReply(
            "reply's printable run is empty".to_string(),
        ));
    }
    Ok(password)
}

// ── Command rendering ────────────────────────────────────────────────────────

/// A rendered command: the topic to publish on and the JSON to publish.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoombaRequest {
    /// The spec command's `path`, which for this transport is the topic.
    pub topic: String,
    /// Compact JSON in the spec's declared argument order.
    pub payload: String,
}

/// Render one of the spec's `commands`.
///
/// `values` must carry `time` — Unix epoch seconds from the caller's clock.
/// It is not defaulted here on purpose: this crate has no clock (a workflow
/// that reads one would be untestable), and a command silently rendered with
/// `time: 0` is exactly the kind of plausible-but-wrong request that is hard
/// to debug against hardware.
pub fn render_request(
    spec: &DeviceSpec,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<RoombaRequest, ProtocolError> {
    let command =
        spec.commands
            .get(command_name)
            .ok_or_else(|| ProtocolError::CommandNotFound {
                uuid: "commands".to_string(),
                command: command_name.to_string(),
            })?;
    render_command(command_name, command, values)
}

/// Render a command already in hand.
pub fn render_command(
    command_name: &str,
    command: &SpecCommand,
    values: &BTreeMap<String, String>,
) -> Result<RoombaRequest, ProtocolError> {
    if command.transport.as_deref() != Some(TRANSPORT) {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            command.transport.clone().unwrap_or_default(),
        ));
    }
    let Some(topic) = command.path.as_deref() else {
        return Err(ProtocolError::EmptyCommand);
    };
    // The argument renderer is the HTTP transport's, unchanged: both build a
    // compact JSON object from `arguments` in declared order, with each value
    // taking the JSON type its parameter declares. `time` renders as the
    // number 1755129600, never the string "1755129600", and a second
    // implementation of that rule is a second place for it to be wrong.
    let payload = super::http::render_body(command, command_name, values)?;
    if payload.is_empty() {
        return Err(ProtocolError::EmptyCommand);
    }
    Ok(RoombaRequest {
        topic: topic.to_string(),
        payload,
    })
}

// ── State ───────────────────────────────────────────────────────────────────

/// Flatten a state payload into the dotted paths the spec's entities bind to.
///
/// The robot publishes `{"state":{"reported":{"batPct":94,...}}}`, and an
/// entity's `state_mapping.value` names a full path from the payload root
/// (`state.reported.batPct`). So every scalar leaf becomes one entry keyed by
/// its path — the Roomba counterpart of `kasaSysinfoFields`, except that the
/// nesting is real and the paths are how the spec addresses it.
///
/// Arrays are skipped rather than indexed: nothing in the spec binds one, and
/// inventing a subscript syntax that no spec uses would be a second addressing
/// scheme for a consumer to get wrong.
pub fn state_fields(payload: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let Ok(value) = serde_json::from_str::<serde_json::Value>(payload) else {
        return out;
    };
    flatten(&value, String::new(), &mut out);
    out
}

fn flatten(value: &serde_json::Value, prefix: String, out: &mut BTreeMap<String, String>) {
    match value {
        serde_json::Value::Object(map) => {
            for (key, child) in map {
                let path = if prefix.is_empty() {
                    key.clone()
                } else {
                    format!("{prefix}.{key}")
                };
                flatten(child, path, out);
            }
        }
        serde_json::Value::String(s) => {
            out.insert(prefix, s.clone());
        }
        serde_json::Value::Number(n) => {
            out.insert(prefix, n.to_string());
        }
        // Rendered as 1/0 so the entity layer's `on_when: nonzero` reads a
        // JSON boolean the same way it reads Kasa's integer relay_state. The
        // spec's bin.full is a boolean and its binary_sensor says nonzero;
        // without this they would never agree.
        serde_json::Value::Bool(b) => {
            out.insert(prefix, if *b { "1" } else { "0" }.to_string());
        }
        serde_json::Value::Null | serde_json::Value::Array(_) => {}
    }
}

// ── The entities a Roomba spec resolves to ───────────────────────────────────

/// One control or reading, resolved from the spec.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoombaEntity {
    pub name: String,
    pub platform: String,
    pub device_class: Option<String>,
    pub icon: Option<String>,
    pub unit: Option<String>,
    /// Topic this entity's reading arrives on, for a stateful entity.
    pub state_topic: Option<String>,
    /// Dotted path into that topic's payload — `state_mapping.value`.
    pub value_path: Option<String>,
    /// True when the entity is on whenever its value is nonzero
    /// (`state_mapping.on_when`). Only meaningful for a binary_sensor.
    pub on_when_nonzero: bool,
    /// Role → command name, for the buttons.
    pub actions: Vec<RoombaAction>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RoombaAction {
    pub role: String,
    pub command_name: String,
}

/// Resolve a Roomba spec's entities.
///
/// A bespoke resolver rather than the generic one for the same reason LIFX has
/// one: the generic path is built around `state_command` — fetch a reading by
/// making a call — and this device pushes. There is no request whose reply is
/// the battery level; there is a topic the robot publishes to. Rather than
/// bend `state_command` to mean "topic" in the shared resolver and leave every
/// other transport to wonder, this reads `state_topic`/`state_mapping`
/// directly.
///
/// An entity binding a command the spec does not declare is dropped, not
/// rendered: a button whose every press fails is worse than a missing button.
pub fn network_entities(spec: &DeviceSpec) -> Vec<RoombaEntity> {
    spec.entities
        .iter()
        .filter_map(|entity| resolve_entity(spec, entity))
        .collect()
}

fn resolve_entity(spec: &DeviceSpec, entity: &Entity) -> Option<RoombaEntity> {
    let actions: Vec<RoombaAction> = entity
        .commands
        .iter()
        .filter_map(|(role, target)| {
            let name = target.as_str()?;
            // Resolve against the spec's own command block, and require the
            // transport to match: a command this module cannot render must not
            // become a button.
            let command = spec.commands.get(name)?;
            if command.transport.as_deref() != Some(TRANSPORT) {
                return None;
            }
            Some(RoombaAction {
                role: role.clone(),
                command_name: name.to_string(),
            })
        })
        .collect();

    let state_topic = entity.state_topic.clone();
    let value_path = entity.value_field().map(str::to_string);

    // Neither a reading nor a working button is nothing at all.
    if actions.is_empty() && (state_topic.is_none() || value_path.is_none()) {
        return None;
    }

    Some(RoombaEntity {
        name: entity.name.clone(),
        platform: entity
            .platform
            .clone()
            .unwrap_or_else(|| "sensor".to_string()),
        device_class: entity.device_class.clone(),
        icon: entity.icon.clone(),
        unit: entity.unit.clone(),
        state_topic,
        value_path,
        on_when_nonzero: entity
            .state_mapping
            .get("on_when")
            .and_then(serde_yaml::Value::as_str)
            == Some("nonzero"),
        actions,
    })
}

// ── MQTT 3.1.1 ───────────────────────────────────────────────────────────────

/// Keepalive advertised in CONNECT, in seconds. The robot serves one client at
/// a time, so a client that lingers is holding the owner's own app out; this
/// is short enough that a wedged connection is noticed and dropped rather than
/// occupying the slot until a TCP timeout.
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
    /// a caller can log what a robot sent that we did not expect.
    Other {
        packet_type: u8,
    },
}

/// CONNECT, with clean session, username and password set.
///
/// The client id is the BLID, which is also the username — that is what the
/// robot expects, and a client id of anything else is refused.
pub fn connect_packet(blid: &str, password: &str) -> Vec<u8> {
    let mut variable = Vec::new();
    encode_string(&mut variable, "MQTT");
    variable.push(0x04); // protocol level 4 = MQTT 3.1.1
    variable.push(0xC2); // username + password + clean session
    variable.extend_from_slice(&KEEPALIVE_SECONDS.to_be_bytes());

    encode_string(&mut variable, blid);
    encode_string(&mut variable, blid);
    encode_string(&mut variable, password);

    packet(0x10, &variable)
}

/// SUBSCRIBE at QoS 0. Callers pass `#`: the spec is explicit that which
/// topic shape a given firmware publishes locally is not settled, so
/// subscribing to everything is the only reading that works on all of them.
pub fn subscribe_packet(topic: &str, packet_id: u16) -> Vec<u8> {
    let mut variable = Vec::new();
    variable.extend_from_slice(&packet_id.to_be_bytes());
    encode_string(&mut variable, topic);
    variable.push(0x00); // requested QoS
    packet(0x82, &variable)
}

/// PUBLISH at QoS 0 — no packet id, no acknowledgement. The robot does not ack
/// commands, and the spec's own transcription of dorita980 publishes this way.
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
            // QoS 1 and 2 publishes carry a packet id after the topic. The
            // robot publishes at QoS 0, but a firmware that did not would
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
    use crate::spec::parser::parse_device_spec;

    /// A miniature Roomba-shaped spec. The real vendored one is driven end to
    /// end in `tests/roomba_control.rs`.
    const SPEC: &str = r#"
device:
  name: "Test Robot"
  manufacturer: "iRobot"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "robot"
protocol_handler: "roomba_mqtt"
mqtt_topics:
  - topic: "cmd"
    name: "Command"
    direction: "publish"
commands:
  clean:
    description: "Start cleaning."
    transport: "mqtt"
    path: "cmd"
    arguments:
      command: "clean"
      time: "{time}"
      initiator: "localApp"
    parameters:
      time:
        type: "integer"
        required: true
    example_body: '{"command":"clean","time":1755129600,"initiator":"localApp"}'
  legacy_http:
    description: "Another transport entirely."
    transport: "http"
    method: "GET"
    path: "/nope"
entities:
  - platform: "button"
    name: "Clean"
    commands:
      press: "clean"
  - platform: "button"
    name: "Broken"
    commands:
      press: "legacy_http"
  - platform: "sensor"
    name: "Battery"
    unit: "%"
    state_topic: "delta"
    state_mapping:
      value: "state.reported.batPct"
  - platform: "binary_sensor"
    name: "Bin Full"
    state_topic: "delta"
    state_mapping:
      value: "state.reported.bin.full"
      on_when: "nonzero"
"#;

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC).expect("test spec parses")
    }

    fn values(time: i64) -> BTreeMap<String, String> {
        BTreeMap::from([("time".to_string(), time.to_string())])
    }

    // ── Discovery ───────────────────────────────────────────────────────────

    #[test]
    fn discovery_probe_is_the_documented_bytes() {
        assert_eq!(DISCOVERY_PROBE, b"irobotmcs");
    }

    #[test]
    fn an_announcement_yields_its_blid() {
        let datagram = br#"{"ver":"3","hostname":"Roomba-3193C60472324700","robotname":"Dorita","ip":"192.168.1.103","mac":"12:12:12:12:12:12","sw":"v2.4.16-126","sku":"R980020","proto":"mqtt"}"#;
        let found = parse_announcement(datagram).unwrap().expect("a robot");
        assert_eq!(found.blid, "3193C60472324700");
        assert_eq!(found.robotname, "Dorita");
        assert_eq!(found.ip, "192.168.1.103");
        assert_eq!(found.proto, "mqtt");
    }

    #[test]
    fn a_braava_announcement_is_also_a_robot() {
        let datagram = br#"{"hostname":"iRobot-ABCD1234","ip":"10.0.0.9"}"#;
        let found = parse_announcement(datagram).unwrap().expect("a robot");
        assert_eq!(found.blid, "ABCD1234");
    }

    /// The probe is a broadcast, so it reaches everything. Anything that is
    /// not a robot must be silently ignored rather than reported or errored.
    #[test]
    fn non_robot_datagrams_are_ignored_not_errors() {
        for datagram in [
            &b"{\"hostname\":\"printer-4f2a\"}"[..],
            &b"{\"hostname\":\"Roomba-\"}"[..], // prefix but no identity
            &b"not json at all"[..],
            &b"[]"[..],
            &b"\xff\xfe\xfd"[..], // not even UTF-8
        ] {
            assert_eq!(parse_announcement(datagram).unwrap(), None);
        }
    }

    // ── Password disclosure ─────────────────────────────────────────────────

    /// Build a reply whose password starts at `offset` of the whole reply,
    /// with non-printable filler in the gap — the assumption the spec's
    /// extraction rule rests on.
    fn reply_at(password: &str, offset: usize) -> Vec<u8> {
        let gap = offset - PASSWORD_HEADER_LEN;
        let mut out = vec![0xf0, (password.len() + gap) as u8];
        out.extend((1..=gap).map(|i| (i % 0x20) as u8));
        out.extend_from_slice(password.as_bytes());
        out
    }

    /// The whole point of the rule: three published clients slice the same
    /// reply at three different offsets, and one extractor has to satisfy all
    /// of them.
    #[test]
    fn the_rule_recovers_the_password_at_every_published_offset() {
        let password = ":1:1486937829:gktkDoYpWaDxCfGh";
        for offset in [7, 9, 13] {
            assert_eq!(
                parse_password_reply(&reply_at(password, offset)).unwrap(),
                password,
                "extraction failed on a reply framed at offset {offset}"
            );
        }
    }

    /// A password split on its first colon is a credential the broker refuses
    /// with no explanation. Pinned because it is an inviting mistake.
    #[test]
    fn the_whole_string_survives_including_leading_and_inner_colons() {
        let password = ":1:1486937829:gktkDoYpWaDxCfGh";
        let recovered = parse_password_reply(&reply_at(password, 13)).unwrap();
        assert!(recovered.starts_with(':'));
        assert_eq!(recovered.matches(':').count(), 3);
    }

    #[test]
    fn trailing_nulls_are_stripped() {
        let password = ":1:1486937829:gktkDoYpWaDxCfGh";
        let mut reply = reply_at(password, 13);
        reply.extend_from_slice(&[0, 0, 0]);
        assert_eq!(parse_password_reply(&reply).unwrap(), password);
    }

    /// The failure a user actually hits: they did not hold HOME long enough.
    /// The message has to say that, because "malformed reply" sends them
    /// looking at their network.
    #[test]
    fn a_short_reply_says_the_robot_was_not_in_disclosure_mode() {
        for length in 0..PASSWORD_MIN_LEN {
            let error = parse_password_reply(&vec![0xf0; length]).unwrap_err();
            assert!(
                error.to_string().contains("disclosure mode"),
                "unhelpful message for a {length}-byte reply: {error}"
            );
        }
    }

    /// Not a retryable failure — holding the button again will never work, and
    /// the message must send the user to the account route instead.
    #[test]
    fn the_unsupported_reply_is_told_apart_from_a_bad_attempt() {
        let error = parse_password_reply(&PASSWORD_UNSUPPORTED).unwrap_err();
        assert!(error.to_string().contains("account"), "{error}");
    }

    // ── Commands ────────────────────────────────────────────────────────────

    #[test]
    fn a_command_renders_its_specs_own_example() {
        let request = render_request(&spec(), "clean", &values(1_755_129_600)).unwrap();
        assert_eq!(request.topic, "cmd");
        assert_eq!(
            request.payload,
            r#"{"command":"clean","time":1755129600,"initiator":"localApp"}"#
        );
    }

    /// A quoted timestamp is the bug this catches: the argument renderer takes
    /// each value's declared type, so `time` must be a JSON number.
    #[test]
    fn time_renders_as_a_number_not_a_string() {
        let request = render_request(&spec(), "clean", &values(1)).unwrap();
        assert!(
            request.payload.contains(r#""time":1"#),
            "{}",
            request.payload
        );
    }

    /// No clock in this crate: a command rendered with a silently defaulted
    /// timestamp is a plausible-but-wrong request that is hard to debug
    /// against hardware, so a missing `time` fails here instead.
    #[test]
    fn a_missing_timestamp_is_a_visible_failure() {
        let error = render_request(&spec(), "clean", &BTreeMap::new()).unwrap_err();
        assert!(
            matches!(error, ProtocolError::ParameterMissing(_)),
            "{error}"
        );
    }

    #[test]
    fn a_command_for_another_transport_is_declined() {
        let error = render_request(&spec(), "legacy_http", &values(1)).unwrap_err();
        assert!(
            matches!(error, ProtocolError::UnsupportedCommandEncoding(_)),
            "{error}"
        );
    }

    // ── State ───────────────────────────────────────────────────────────────

    #[test]
    fn state_flattens_to_the_paths_the_spec_binds() {
        let fields = state_fields(
            r#"{"state":{"reported":{"batPct":94,"bin":{"full":false,"present":true},
                "cleanMissionStatus":{"phase":"charge","cycle":"none"},"name":"Dorita"}}}"#,
        );
        assert_eq!(fields.get("state.reported.batPct").unwrap(), "94");
        assert_eq!(
            fields
                .get("state.reported.cleanMissionStatus.phase")
                .unwrap(),
            "charge"
        );
        assert_eq!(fields.get("state.reported.name").unwrap(), "Dorita");
    }

    /// The spec's bin.full is a JSON boolean and its binary_sensor says
    /// `on_when: nonzero`. Without the 1/0 rendering those two never agree and
    /// the sensor reads as off forever.
    #[test]
    fn booleans_render_as_one_and_zero_for_on_when_nonzero() {
        let fields =
            state_fields(r#"{"state":{"reported":{"bin":{"full":true,"present":false}}}}"#);
        assert_eq!(fields.get("state.reported.bin.full").unwrap(), "1");
        assert_eq!(fields.get("state.reported.bin.present").unwrap(), "0");
    }

    /// A dropped connection can deliver a half payload; a state decode must
    /// not take the screen down with it.
    #[test]
    fn unparseable_state_yields_nothing_rather_than_failing() {
        assert!(state_fields("{\"state\":").is_empty());
        assert!(state_fields("").is_empty());
    }

    // ── Entities ────────────────────────────────────────────────────────────

    #[test]
    fn entities_resolve_buttons_and_readings() {
        let entities = network_entities(&spec());
        let names: Vec<&str> = entities.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["Clean", "Battery", "Bin Full"]);

        let clean = &entities[0];
        assert_eq!(clean.platform, "button");
        assert_eq!(clean.actions.len(), 1);
        assert_eq!(clean.actions[0].command_name, "clean");

        let battery = &entities[1];
        assert_eq!(battery.state_topic.as_deref(), Some("delta"));
        assert_eq!(battery.value_path.as_deref(), Some("state.reported.batPct"));
        assert_eq!(battery.unit.as_deref(), Some("%"));

        assert!(entities[2].on_when_nonzero);
    }

    /// "Broken" binds an http command this module cannot send. Drawing it
    /// would put a button on screen whose every press fails.
    #[test]
    fn an_entity_binding_an_unsendable_command_is_dropped() {
        let entities = network_entities(&spec());
        assert!(!entities.iter().any(|e| e.name == "Broken"));
    }

    // ── MQTT ────────────────────────────────────────────────────────────────

    #[test]
    fn connect_carries_the_blid_as_client_id_and_username() {
        let packet = connect_packet("BLID123", "  :1:secret");
        assert_eq!(packet[0], 0x10);
        // MQTT 3.1.1 protocol name and level.
        assert_eq!(&packet[2..8], b"\x00\x04MQTT");
        assert_eq!(packet[8], 0x04);
        assert_eq!(packet[9], 0xC2, "username + password + clean session");
        // client id, username, password — the BLID twice.
        let tail = &packet[12..];
        assert_eq!(&tail[..9], b"\x00\x07BLID123");
        assert_eq!(&tail[9..18], b"\x00\x07BLID123");
        // Length-prefixed verbatim: the leading spaces are part of the
        // password. Real Roomba passwords start with ':' and a client that
        // trims either end sends a credential the broker refuses.
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

    /// A payload longer than 127 bytes needs a two-byte remaining-length, and
    /// the robot's state payloads are far longer than that.
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

    /// A QoS>0 publish carries a packet id between topic and payload. The
    /// robot publishes at QoS 0, but firmware that did not would otherwise
    /// prepend two bytes to the JSON and the parse would fail for no visible
    /// reason.
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
}

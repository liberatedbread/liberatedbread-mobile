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

/// The probe's magic as the robot echoes it back at the head of the
/// password payload, before a status byte and the credential.
const PASSWORD_ECHOED_MAGIC: &[u8] = &[0xef, 0xcc, 0x3b, 0x29];

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
    // Firmware echoes the probe's magic (`ef cc 3b 29`) plus a status byte
    // ahead of the credential — roombapy's observed offset 7 is exactly
    // header + magic + status. Two of those magic bytes are printable
    // (`;)`), so a printable-run scan that started here returned the
    // password with junk on the front, and the only symptom was CONNACK 4.
    // Skip the echo when it is there; the scan still handles firmware that
    // pads differently (dorita980's offsets 9 and 13).
    let body = match body.strip_prefix(PASSWORD_ECHOED_MAGIC) {
        Some(rest) => rest.get(1..).unwrap_or(&[]),
        None => body,
    };
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

/// The spec's top-level `mqtt_topics:` entries, if it declares any.
///
/// Read out of `extensions` rather than off a typed field: the block is
/// catalogued documentation for a whole family of MQTT devices (three
/// directions, payload formats, QoS) and only this one rule reads it, so
/// promoting it to the shared `DeviceSpec` would model a great deal for one
/// consumer.
fn mqtt_topics(spec: &DeviceSpec) -> &[serde_yaml::Value] {
    spec.extensions
        .get("mqtt_topics")
        .and_then(serde_yaml::Value::as_sequence)
        .map(Vec::as_slice)
        .unwrap_or_default()
}

/// Topics the spec says a client may publish on — `direction: publish` or
/// `both`. A `subscribe` topic is deliberately not among them: the robot's
/// `delta` is a reading, and a command aimed at it is as wrong as one aimed
/// at a topic that does not exist.
fn publishable_topics(spec: &DeviceSpec) -> Vec<&str> {
    mqtt_topics(spec)
        .iter()
        .filter(|entry| {
            matches!(
                entry.get("direction").and_then(serde_yaml::Value::as_str),
                Some("publish") | Some("both")
            )
        })
        .filter_map(|entry| entry.get("topic").and_then(serde_yaml::Value::as_str))
        .collect()
}

/// What the spec's `mqtt_topics` offers, for the error message — so the
/// author sees the vocabulary they missed rather than only that they missed
/// it. Names the empty case explicitly: "declares none" is a different spec
/// bug from "declares three, none of them this one".
fn describe_topics(spec: &DeviceSpec) -> String {
    let publishable = publishable_topics(spec);
    if publishable.is_empty() {
        if mqtt_topics(spec).is_empty() {
            return "the spec declares no mqtt_topics at all".to_string();
        }
        return "the spec declares mqtt_topics, none of them publishable".to_string();
    }
    format!("publishable: {}", publishable.join(", "))
}

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
    let command = super::top_level_command(spec, command_name)?;
    render_command(spec, command_name, command, values)
}

/// Render a command already in hand.
pub fn render_command(
    spec: &DeviceSpec,
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
    // A topic the spec's own catalogue does not offer for publishing is a
    // typo, and MQTT will not say so: a publish to an unsubscribed topic is
    // accepted by the broker and reaches nothing, so the only symptom is a
    // button that does nothing at all. Every other transport's admission
    // gate checks that the address exists (SOAP its service, HTTP its path);
    // this is that check for MQTT.
    if !publishable_topics(spec).contains(&topic) {
        return Err(ProtocolError::TopicNotPublishable {
            command: command_name.to_string(),
            topic: topic.to_string(),
            declared: describe_topics(spec),
        });
    }
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

// ── The robot's MQTT session ────────────────────────────────────────────────
// The codec itself is shared (`protocol::mqtt`). What is Roomba's alone is who
// the client says it is.

/// CONNECT as this robot expects it: the BLID is both the client id and the
/// username, and a client id of anything else is refused.
///
/// Fallible for the reason [`crate::protocol::mqtt::connect_packet`] is: the
/// BLID and the password are length-prefixed strings, and one past 65535 bytes
/// has no encoding.
pub fn connect_packet(blid: &str, password: &str) -> Result<Vec<u8>, ProtocolError> {
    crate::protocol::mqtt::connect_packet(&crate::protocol::mqtt::ConnectOptions::with_credentials(
        blid, blid, password,
    ))
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
    ///
    /// Deliberately the LAST thing this resolver says about a reading. How to
    /// interpret what arrives at that path — `on_when: nonzero`, an `options`
    /// table, a `payload_formats` entry — is not re-derived here: the client
    /// hands the flattened payload back to `read_network_entity`, which
    /// re-resolves the entity from the same spec and reads it through
    /// [`crate::protocol::soap::read_entity`], the decoder every transport
    /// shares. A second copy of those rules on this struct would be a second
    /// place for them to disagree.
    pub value_path: Option<String>,
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
    let publishable = publishable_topics(spec);
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
            // And require the topic to be one the spec offers for publishing,
            // which is the same admission rule the other transports apply to
            // their addresses. `render_command` refuses such a command, so
            // without this the button would be drawn and then fail on press —
            // and on MQTT the failure has no wire symptom to debug from.
            if !publishable.contains(&command.path.as_deref()?) {
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
        actions,
    })
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
    fn an_echoed_probe_magic_is_skipped_not_taken_for_password_bytes() {
        // The gap before the credential is not always non-printable: a
        // firmware that echoes the probe's magic puts `;)` (0x3b 0x29) there,
        // and a scan that started at the first printable byte returned
        // ";)\0<password>"-shaped junk. Header, echoed magic, status byte,
        // then the real credential — roombapy's offset 7 exactly.
        let password = ":1:1700000000:AbCdEfGhIjKlMnOp";
        let mut reply = vec![0xf0, 0x00, 0xef, 0xcc, 0x3b, 0x29, 0x00];
        reply.extend_from_slice(password.as_bytes());
        reply[1] = (reply.len() - 2) as u8;
        assert_eq!(parse_password_reply(&reply).unwrap(), password);

        // A status byte that is itself printable must still be skipped.
        reply[6] = b'!';
        assert_eq!(parse_password_reply(&reply).unwrap(), password);
    }

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

    /// One mistyped character in a `path` used to render a perfectly
    /// well-formed publish onto a topic nothing listens to. MQTT gives that
    /// no wire symptom at all — the broker accepts it — so the bug looks
    /// like a dead button and debugs like a network fault.
    #[test]
    fn a_topic_the_spec_never_declared_is_refused_rather_than_published() {
        let typo = SPEC.replace("    path: \"cmd\"", "    path: \"cnd\"");
        let spec = parse_device_spec(&typo).expect("test spec parses");
        let error = render_request(&spec, "clean", &values(1)).unwrap_err();
        match &error {
            ProtocolError::TopicNotPublishable {
                command,
                topic,
                declared,
            } => {
                assert_eq!(command, "clean");
                assert_eq!(topic, "cnd");
                assert!(declared.contains("cmd"), "the message names the fix");
            }
            other => panic!("expected TopicNotPublishable, got {other:?}"),
        }
        // And the button is not drawn in the first place: a press that can
        // only fail is worse than a control that is honestly absent.
        assert!(!network_entities(&spec).iter().any(|e| e.name == "Clean"));
    }

    /// A reading topic is not a command address. Publishing to the robot's
    /// own `delta` would be as wrong as publishing to a topic that does not
    /// exist, and just as silent.
    #[test]
    fn a_subscribe_only_topic_is_not_a_publish_target() {
        let subscribed = SPEC.replace("direction: \"publish\"", "direction: \"subscribe\"");
        let spec = parse_device_spec(&subscribed).expect("test spec parses");
        let error = render_request(&spec, "clean", &values(1)).unwrap_err();
        assert!(
            matches!(error, ProtocolError::TopicNotPublishable { .. }),
            "{error}"
        );
    }

    /// A spec with no topic catalogue at all gets a message that says so,
    /// because "declares none" and "declares three, none of them this one"
    /// are different spec bugs with different fixes.
    #[test]
    fn a_spec_with_no_topic_catalogue_says_so() {
        let bare = SPEC.replace(
            "mqtt_topics:\n  - topic: \"cmd\"\n    name: \"Command\"\n    direction: \"publish\"\n",
            "",
        );
        let spec = parse_device_spec(&bare).expect("test spec parses");
        let error = render_request(&spec, "clean", &values(1)).unwrap_err();
        assert!(
            error.to_string().contains("no mqtt_topics at all"),
            "{error}"
        );
    }

    /// `direction: both` is the schema's third value and publishes fine.
    #[test]
    fn a_bidirectional_topic_is_publishable() {
        let both = SPEC.replace("direction: \"publish\"", "direction: \"both\"");
        let spec = parse_device_spec(&both).expect("test spec parses");
        assert_eq!(
            render_request(&spec, "clean", &values(1)).unwrap().topic,
            "cmd"
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

        let bin = &entities[2];
        assert_eq!(bin.platform, "binary_sensor");
        assert_eq!(bin.value_path.as_deref(), Some("state.reported.bin.full"));
        // How that path's value becomes on/off is `read_network_entity`'s
        // job, not this resolver's — see `value_path`'s note, and
        // `roomba_control.rs` for the test that drives it.
    }

    /// "Broken" binds an http command this module cannot send. Drawing it
    /// would put a button on screen whose every press fails.
    #[test]
    fn an_entity_binding_an_unsendable_command_is_dropped() {
        let entities = network_entities(&spec());
        assert!(!entities.iter().any(|e| e.name == "Broken"));
    }
}

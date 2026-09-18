// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Drive a TP-Link Kasa device from its spec: JSON over a raw TCP socket on
//! port 9999, obfuscated by a trivial XOR-"autokey" cipher.
//!
//! The same job the SOAP and HTTP modules do, one transport over. A Kasa
//! command's whole instruction is the JSON in its `body` (`set_relay_state`,
//! `get_sysinfo`), so this renders that — substituting `{name}` placeholders
//! exactly as the HTTP path renderer does — and provides the cipher and the
//! TCP length framing a caller wraps it in. The cipher is the one piece of
//! real protocol logic here, so it lives in Rust under test rather than being
//! re-implemented (and mis-implemented) per client.
//!
//! What deliberately does NOT live here is I/O, and — unlike SOAP's XML — not
//! the reply parsing either: a Kasa reply is JSON, which Dart decodes with its
//! own `dart:convert`, flattening `get_sysinfo` into the name→value pairs the
//! generic entity decoder already reads (the same split of labour the SOAP
//! path uses, where Dart turns the XML envelope into those pairs). This module
//! renders requests and moves bytes through the cipher; nothing here opens a
//! socket.

use std::collections::BTreeMap;

use crate::error::ProtocolError;
use crate::spec::types::{DeviceSpec, SpecCommand};

/// The transport a command must declare to be sendable from here.
///
/// Shared, not owned. `tcp-json` describes a shape — JSON down a raw socket —
/// and the catalogue has ten specs using it across four incompatible framings:
/// TP-Link's length prefix and XOR autokey (this module), Yeelight's plaintext
/// CRLF, Tuya's 0x55aa AES envelope, and the iKettle's raw hex. The transport
/// says which shape; [`HANDLER_NAME`] says whose.
pub const TRANSPORT: &str = "tcp-json";

/// The spec `protocol_handler` this module answers to.
///
/// The name is the catalogue's, not one invented here: tplink-kasa-smart-plug
/// has declared `protocol_handler: tplink_smarthome` all along and nothing read
/// it, so admission keyed on the transport string alone and swept up every
/// other `tcp-json` spec. Same shape as [`lifx::HANDLER_NAME`], and the same
/// reason.
///
/// [`lifx::HANDLER_NAME`]: crate::protocol::lifx::HANDLER_NAME
pub const HANDLER_NAME: &str = "tplink_smarthome";

/// The port the Kasa smart-home protocol listens on, for control and for the
/// discovery broadcast alike. The spec's `identification.default_port`,
/// restated as the transport's own constant so a client has it without the
/// parsed spec in hand.
pub const PORT: u16 = 9999;

/// The cipher's initial key. After the first byte the running key is the
/// previous *ciphertext* byte — see [`encrypt`]/[`decrypt`].
const INITIAL_KEY: u8 = 0xAB;

/// A rendered request: the JSON to send, before the cipher and framing.
///
/// Kept as the plaintext JSON rather than the framed bytes so a caller can log
/// it and the tests can diff it; [`encode_frame`] (TCP) or [`encrypt`] (the
/// UDP discovery datagram) turns it into what goes on the wire.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KasaRequest {
    pub json: String,
}

/// Render one of the spec's `commands` into a request.
///
/// Refuses a spec that does not name this handler. The resolver already
/// declines to build a control for one ([`qualify_network`]), so in the app
/// this is unreachable — which is exactly why it is here: the group runner and
/// the FFI both reach the renderers by name without going through the resolver,
/// and a second spec landing on `tcp-json` must not be able to pick up TP-Link's
/// cipher just by asking politely.
///
/// [`qualify_network`]: crate::spec::bindings
pub fn render_request(
    spec: &DeviceSpec,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<KasaRequest, ProtocolError> {
    if spec.protocol_handler.as_deref() != Some(HANDLER_NAME) {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            spec.protocol_handler.clone().unwrap_or_default(),
        ));
    }
    let command = super::top_level_command(spec, command_name)?;
    render_command(command_name, command, values)
}

/// Render a command already in hand — the path a resolved control takes.
pub fn render_command(
    command_name: &str,
    command: &SpecCommand,
    values: &BTreeMap<String, String>,
) -> Result<KasaRequest, ProtocolError> {
    // A command for another transport must not be rendered as though it were
    // tcp-json: absent means the spec's single declared transport, so only an
    // explicit `tcp-json` qualifies — the same rule the HTTP module applies.
    if command.transport.as_deref() != Some(TRANSPORT) {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            command.transport.clone().unwrap_or_default(),
        ));
    }
    let Some(body) = command.body.as_deref() else {
        return Err(ProtocolError::EmptyCommand);
    };
    Ok(KasaRequest {
        json: substitute(body, command, command_name, values)?,
    })
}

/// Render the request that polls a state command's values.
///
/// A Kasa state read is just another command — `get_sysinfo`, which the entity
/// names in `state_command` and the `commands` block declares like any other —
/// so this resolves it by name and renders its body. (SOAP reads state from
/// `http_endpoints`; here the poll is a first-class command with a `body`.)
pub fn render_state_request(
    spec: &DeviceSpec,
    state_command: &str,
) -> Result<KasaRequest, ProtocolError> {
    render_request(spec, state_command, &BTreeMap::new())
}

/// Substitute the command's declared `{parameter}` placeholders in a JSON body.
///
/// Driven by the declared `parameters` rather than by scanning for braces,
/// because the body is JSON and JSON is made of braces: a brace-scanner (what
/// the HTTP path does to a URL) reads `{"system":...}` as a placeholder named
/// `"system":...` and fails on every command. So only the exact token
/// `{param_name}` for a declared parameter is replaced; every other brace is
/// the author's literal JSON and is left alone.
///
/// Resolution order per parameter matches the SOAP and HTTP renderers: the
/// caller's value first, then the parameter's declared `default`, then a
/// visible failure. No Phase-1 command carries a placeholder; the machinery
/// is here for the per-outlet `child_id` a power strip will thread through.
///
/// Values are substituted by their DECLARED type, and that matters because
/// the ones that fill these placeholders are not the author's: a strip's
/// `child_id` is whatever the device's own `get_sysinfo` reply said, and a
/// brightness may be a stored credential or a user-typed string. A string
/// parameter is JSON-escaped — a reply carrying a quote or backslash would
/// otherwise close the string it landed in and turn the rest of the
/// template into syntax. A numeric or boolean parameter is VALIDATED
/// against its declared type (the HTTP renderer's own `typed_json`), which
/// is the half escaping could not cover: `"brightness":{brightness}` filled
/// with `1},"system":{"reboot":{}` contains none of the characters
/// `json_escape` touches and used to render as a perfectly valid document
/// carrying an injected command. It now dies as ParameterInvalid, by name.
///
/// Which parameters are "numeric or boolean" is the HTTP renderer's
/// `declared_type`, not a match on the three JSON names: the catalogue declares
/// its types in the BLE vocabulary as readily (WLED's `bri` is a `uint8`),
/// and a `uint8` that fell through to the string arm was the injection case
/// above with the guard switched off.
///
/// `pub(crate)` because Rabbit Air's envelope bodies and the HTTP transport's
/// literal JSON bodies carry the same `{name}` placeholders with the same
/// semantics — one substitution rule, one home.
/// The scan is ONE left-to-right pass over the template
/// ([`crate::protocol::walk_placeholders`]), not a `String::replace` per
/// parameter. The loop it replaced re-scanned its own output: a value
/// substituted early that happened to contain another declared parameter's
/// `{name}` had THAT parameter's value spliced into it on a later turn, so a
/// strip's `child_id` — whatever the device's `get_sysinfo` reply said — could
/// pull a credential into a place the spec never put one. Walking once cannot:
/// what `fill` returns is never looked at again. The MQTT and WebSocket
/// renderers were rewritten for exactly this; this one was the copy left
/// behind, and Rabbit Air's envelope bodies and the HTTP transport's literal
/// JSON bodies both run through it.
pub(crate) fn substitute(
    template: &str,
    command: &SpecCommand,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    crate::protocol::walk_placeholders(template, |name| {
        // A brace pair naming nothing the command declares is the author's
        // JSON syntax, not a placeholder — which is the whole reason this
        // scanner and not the path renderer's.
        let Some(parameter) = command.parameters.get(name) else {
            return Ok(None);
        };
        let value = resolve_param(command, command_name, name, values)?;
        let rendered = match crate::protocol::http::declared_type(parameter.value_type.as_deref()) {
            crate::protocol::http::DeclaredType::String => json_escape(&value),
            _ => crate::protocol::http::typed_json(Some(parameter), name, &value)?.to_string(),
        };
        Ok(Some(rendered))
    })
}

/// One value as it may appear INSIDE a JSON string — the escaping serde_json
/// would apply, minus the surrounding quotes, which the template already
/// wrote. Serializing and trimming rather than hand-rolling the escape table:
/// the corner cases are the control characters (a raw newline or NUL in a
/// device reply), and a hand-rolled table that forgets one is exactly how
/// this bug comes back.
fn json_escape(value: &str) -> String {
    let quoted = serde_json::Value::String(value.to_string()).to_string();
    // `to_string` on a JSON string always yields at least the two quotes.
    quoted[1..quoted.len() - 1].to_string()
}

fn resolve_param(
    command: &SpecCommand,
    command_name: &str,
    param: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    crate::protocol::resolve_parameter(command, command_name, param, values)
}

// ── The cipher and framing ───────────────────────────────────────────────────

/// XOR-autokey encrypt. Start `key = 0xAB`; for each plaintext byte emit
/// `key XOR byte`, then set `key` to that output. So after the first byte the
/// key is the previous ciphertext byte. Obfuscation, not security.
pub fn encrypt(plaintext: &[u8]) -> Vec<u8> {
    let mut key = INITIAL_KEY;
    plaintext
        .iter()
        .map(|&byte| {
            key ^= byte;
            key
        })
        .collect()
}

/// The inverse of [`encrypt`]: `plain = key XOR cipher`, then `key = cipher`.
pub fn decrypt(ciphertext: &[u8]) -> Vec<u8> {
    let mut key = INITIAL_KEY;
    ciphertext
        .iter()
        .map(|&cipher| {
            let plain = key ^ cipher;
            key = cipher;
            plain
        })
        .collect()
}

/// Frame a message for the TCP control stream: a 4-byte big-endian length
/// prefix (the encrypted-payload length, prefix excluded) followed by the
/// encrypted payload.
pub fn encode_frame(plaintext: &[u8]) -> Vec<u8> {
    let body = encrypt(plaintext);
    let mut out = Vec::with_capacity(4 + body.len());
    out.extend_from_slice(&(body.len() as u32).to_be_bytes());
    out.extend_from_slice(&body);
    out
}

/// Decode a TCP frame back to plaintext: read the 4-byte length, decrypt that
/// many following bytes. Errors rather than truncating on a short read, so a
/// half-arrived reply fails visibly instead of decoding to garbage.
pub fn decode_frame(frame: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    let Some(header) = frame.get(..4) else {
        return Err(ProtocolError::MalformedReply(format!(
            "TCP frame is {} bytes, shorter than its 4-byte length prefix",
            frame.len()
        )));
    };
    let len = u32::from_be_bytes(header.try_into().expect("4 bytes")) as usize;
    // Bounds-check against what actually arrived BEFORE forming `4 + len`:
    // the length is device-controlled, and on a 32-bit target (armv7
    // Android) a huge u32 makes `4 + len` overflow usize — a debug panic
    // where a malformed-reply error belongs.
    let available = frame.len() - 4;
    if len > available {
        return Err(ProtocolError::MalformedReply(format!(
            "TCP frame declares {len} payload bytes but only {available} follow the prefix"
        )));
    }
    Ok(decrypt(&frame[4..4 + len]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A miniature Kasa-shaped device, so these tests exercise the rules. The
    /// real vendored spec is driven end to end in `tests/kasa_control.rs`.
    const SPEC: &str = r#"
device:
  name: "Test Plug"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "switch"
# As the real spec does. `tcp-json` alone no longer buys the TP-Link framing:
# four other vendors declare that transport and none of them frame alike.
protocol_handler: "tplink_smarthome"
commands:
  relay_on:
    description: "On."
    transport: "tcp-json"
    body: '{"system":{"set_relay_state":{"state":1}}}'
  get_sysinfo:
    description: "State poll."
    transport: "tcp-json"
    body: '{"system":{"get_sysinfo":null}}'
  set_child:
    description: "A body with a runtime-filled placeholder."
    transport: "tcp-json"
    body: '{"context":{"child_ids":["{child_id}"]},"system":{"set_relay_state":{"state":1}}}'
    parameters:
      child_id:
        type: "string"
        required: true
  set_child_and_brightness:
    description: "Two placeholders in one body, string then numeric."
    transport: "tcp-json"
    body: '{"context":{"child_ids":["{child_id}"]},"system":{"set_brightness":{brightness}}}'
    parameters:
      child_id:
        type: "string"
        required: true
      brightness:
        type: "integer"
        required: true
  set_brightness:
    description: "A placeholder in NUMERIC position, not inside a string."
    transport: "tcp-json"
    body: '{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"brightness":{brightness}}}}'
    parameters:
      brightness:
        type: "integer"
        required: true
  set_brightness_u8:
    description: "The same numeric slot, typed in the BLE vocabulary."
    transport: "tcp-json"
    body: '{"smartlife.iot.smartbulb.lightingservice":{"transition_light_state":{"brightness":{brightness}}}}'
    parameters:
      brightness:
        type: "uint8"
        required: true
  over_soap:
    description: "A transport this module does not speak."
    transport: "soap"
    service: "urn:Test:service:basicevent:1"
    action: "SetBinaryState"
entities:
  - platform: "switch"
    name: "Outlet"
    state_command: "get_sysinfo"
    state_mapping:
      value: "relay_state"
      on_when: "nonzero"
    commands:
      turn_on: "relay_on"
"#;

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC).expect("fixture spec parses")
    }

    fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect()
    }

    #[test]
    fn renders_a_fixed_command_body() {
        let request = render_request(&spec(), "relay_on", &values(&[])).unwrap();
        assert_eq!(
            request.json,
            r#"{"system":{"set_relay_state":{"state":1}}}"#
        );
    }

    #[test]
    fn state_request_renders_the_poll_body() {
        let request = render_state_request(&spec(), "get_sysinfo").unwrap();
        assert_eq!(request.json, r#"{"system":{"get_sysinfo":null}}"#);
    }

    #[test]
    fn substitutes_a_supplied_placeholder() {
        let request =
            render_request(&spec(), "set_child", &values(&[("child_id", "8006ABC00")])).unwrap();
        assert_eq!(
            request.json,
            r#"{"context":{"child_ids":["8006ABC00"]},"system":{"set_relay_state":{"state":1}}}"#
        );
    }

    /// A resolved value is data, never template. `child_id` is whatever the
    /// device's own `get_sysinfo` reply said, so one that happens to contain
    /// `{brightness}` must land on the wire as those thirteen characters. The
    /// old `String::replace`-per-parameter loop re-scanned its own output and
    /// substituted `brightness` INTO the child id on the next turn — a way to
    /// pull one parameter's value somewhere the spec never put it, and the
    /// same bug the MQTT and WebSocket renderers were rewritten to end.
    #[test]
    fn a_resolved_value_is_never_rescanned_for_another_placeholder() {
        let request = render_request(
            &spec(),
            "set_child_and_brightness",
            &values(&[("child_id", "{brightness}"), ("brightness", "42")]),
        )
        .expect("renders");
        assert_eq!(
            request.json,
            r#"{"context":{"child_ids":["{brightness}"]},"system":{"set_brightness":42}}"#
        );
    }

    /// The value filling `{child_id}` comes from the device's own reply, not
    /// from the spec. One carrying a quote — a corrupt read, a truncated
    /// string, something else answering on 9999 — must not close the string
    /// it lands in and turn the rest of the template into syntax.
    #[test]
    fn a_device_value_carrying_json_syntax_is_escaped_not_pasted() {
        let hostile = r#"a","system":{"reboot":{"delay":1}},"x":"b"#;
        let request =
            render_request(&spec(), "set_child", &values(&[("child_id", hostile)])).unwrap();

        // The document still parses, and it still says exactly what the
        // template said: one system member, still set_relay_state.
        let parsed: serde_json::Value =
            serde_json::from_str(&request.json).expect("the rendered body is still valid JSON");
        let system = parsed["system"].as_object().expect("one system member");
        assert_eq!(system.len(), 1);
        assert!(system.contains_key("set_relay_state"));
        assert!(!system.contains_key("reboot"), "{}", request.json);

        // And the id round-trips intact: escaping preserves the value, it
        // does not mangle it.
        assert_eq!(parsed["context"]["child_ids"][0], hostile);
    }

    /// A backslash is the other half of the escape problem, and a raw control
    /// character is the half a hand-rolled escape table forgets.
    #[test]
    fn backslashes_and_control_characters_survive_as_escapes() {
        for raw in ["back\\slash", "line\nbreak", "nul\0byte"] {
            let request =
                render_request(&spec(), "set_child", &values(&[("child_id", raw)])).unwrap();
            let parsed: serde_json::Value =
                serde_json::from_str(&request.json).unwrap_or_else(|e| panic!("{raw:?}: {e}"));
            assert_eq!(parsed["context"]["child_ids"][0], raw);
        }
    }

    /// A placeholder in numeric position must stay a number: escaping touches
    /// only characters no number contains, so the brightness body renders as
    /// it always did.
    #[test]
    fn a_numeric_placeholder_renders_as_its_declared_type() {
        let request = render_request(&spec(), "set_brightness", &values(&[("brightness", "50")]))
            .expect("renders");
        assert!(
            request.json.contains(r#""brightness":50"#),
            "{}",
            request.json
        );
    }

    #[test]
    fn a_numeric_placeholder_refuses_a_value_that_is_not_a_number() {
        // `json_escape` touches none of `{ } , :` — this value used to render
        // as a perfectly valid document with an injected `system.reboot`
        // beside the brightness. The declared type is the guard: not an
        // integer, not sent, named in the error.
        let err = render_request(
            &spec(),
            "set_brightness",
            &values(&[("brightness", r#"1},"system":{"reboot":{}"#)]),
        )
        .unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterInvalid { name, .. } if name == "brightness"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn a_ble_vocabulary_numeric_placeholder_is_validated_not_escaped() {
        // `uint8` used to miss the numeric match and fall through to
        // `json_escape`, which leaves `{ } , :` alone — the injection above
        // with the guard switched off. The declared type must still guard.
        let request = render_request(
            &spec(),
            "set_brightness_u8",
            &values(&[("brightness", "50")]),
        )
        .expect("renders");
        assert!(
            request.json.contains(r#""brightness":50"#),
            "{}",
            request.json
        );
        let err = render_request(
            &spec(),
            "set_brightness_u8",
            &values(&[("brightness", r#"1},"system":{"reboot":{}"#)]),
        )
        .unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterInvalid { name, .. } if name == "brightness"),
            "unexpected error: {err}"
        );
        // And the width is the type's own meaning: 256 is not a uint8.
        let err = render_request(
            &spec(),
            "set_brightness_u8",
            &values(&[("brightness", "256")]),
        )
        .unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterOutOfRange { name, .. } if name == "brightness"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn a_missing_placeholder_is_an_error_not_a_blank() {
        let err = render_request(&spec(), "set_child", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterMissing(name) if name == "set_child.child_id"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn a_command_for_another_transport_is_declined() {
        let err = render_request(&spec(), "over_soap", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::UnsupportedCommandEncoding(t) if t == "soap"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn an_unknown_command_names_itself_in_the_error() {
        let err = render_request(&spec(), "no_such_command", &values(&[])).unwrap_err();
        assert!(err.to_string().contains("no_such_command"));
    }

    // ── The cipher, against hand-verifiable and canonical vectors ────────────

    #[test]
    fn cipher_matches_the_published_vectors() {
        // Hand-computable: key starts 0xAB; XORing zeros re-emits the key.
        assert_eq!(encrypt(&[0x00, 0x00, 0x00]), [0xAB, 0xAB, 0xAB]);
        assert_eq!(encrypt(&[0x01, 0x02, 0x03]), [0xAA, 0xA8, 0xAB]);
        // The canonical get_sysinfo discovery datagram softScheck and
        // python-kasa both publish, and the spec's own test vector.
        let got = encrypt(br#"{"system":{"get_sysinfo":null}}"#);
        assert_eq!(
            hex(&got),
            "d0f281f88bff9af7d5ef94b6d1b4c09fec95e68fe187e8caf09eeb87eb96eb"
        );
    }

    #[test]
    fn cipher_round_trips() {
        for sample in [
            b"".as_slice(),
            b"\x00",
            br#"{"system":{"get_sysinfo":null}}"#,
            &(0u16..=255).map(|b| b as u8).collect::<Vec<_>>(),
        ] {
            assert_eq!(decrypt(&encrypt(sample)), sample);
        }
    }

    #[test]
    fn tcp_framing_round_trips_and_prefixes_the_length() {
        let plaintext = br#"{"system":{"set_relay_state":{"state":0}}}"#;
        let frame = encode_frame(plaintext);
        let declared = u32::from_be_bytes(frame[..4].try_into().unwrap()) as usize;
        assert_eq!(declared, frame.len() - 4, "the prefix counts the payload");
        assert_eq!(decode_frame(&frame).unwrap(), plaintext);
    }

    #[test]
    fn a_short_frame_is_a_malformed_reply_not_a_panic() {
        assert!(matches!(
            decode_frame(&[0x00, 0x00]),
            Err(ProtocolError::MalformedReply(_))
        ));
        // Length prefix promises more bytes than arrived.
        assert!(matches!(
            decode_frame(&[0x00, 0x00, 0x00, 0x10, 0xAB]),
            Err(ProtocolError::MalformedReply(_))
        ));
    }

    fn hex(bytes: &[u8]) -> String {
        bytes.iter().map(|b| format!("{b:02x}")).collect()
    }
    #[test]
    fn a_huge_declared_length_is_a_malformed_reply_not_a_panic() {
        // The length prefix is device-controlled; u32::MAX as usize + 4
        // overflows on a 32-bit target. Must bounds-check, not arithmetic.
        let mut frame = 0xFFFF_FFFFu32.to_be_bytes().to_vec();
        frame.extend_from_slice(&[1, 2, 3]);
        let err = decode_frame(&frame).unwrap_err();
        assert!(
            err.to_string().contains("4294967295"),
            "names the declared length: {err}"
        );
    }
}

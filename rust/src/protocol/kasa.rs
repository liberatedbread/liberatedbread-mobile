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
use crate::spec::types::{scalar_to_string, DeviceSpec, SpecCommand};

/// The transport a command must declare to be sendable from here.
pub const TRANSPORT: &str = "tcp-json";

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
pub fn render_request(
    spec: &DeviceSpec,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<KasaRequest, ProtocolError> {
    let command =
        spec.commands
            .get(command_name)
            .ok_or_else(|| ProtocolError::CommandNotFound {
                uuid: "commands".to_string(),
                command: command_name.to_string(),
            })?;
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
/// visible failure. Not percent-encoded — the value lands inside a JSON
/// document, not a URL — so a spec interpolating a device-supplied value must
/// keep it JSON-safe. No Phase-1 command carries a placeholder; the machinery
/// is here for the per-outlet `child_id` a power strip will thread through.
fn substitute(
    template: &str,
    command: &SpecCommand,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    let mut out = template.to_string();
    for name in command.parameters.keys() {
        let placeholder = format!("{{{name}}}");
        if out.contains(&placeholder) {
            let value = resolve_param(command, command_name, name, values)?;
            out = out.replace(&placeholder, &value);
        }
    }
    Ok(out)
}

fn resolve_param(
    command: &SpecCommand,
    command_name: &str,
    param: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    if let Some(value) = values.get(param) {
        return Ok(value.clone());
    }
    command
        .parameters
        .get(param)
        .and_then(|p| p.default.as_ref())
        .and_then(scalar_to_string)
        .ok_or_else(|| ProtocolError::ParameterMissing(format!("{command_name}.{param}")))
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
    let payload = frame.get(4..4 + len).ok_or_else(|| {
        ProtocolError::MalformedReply(format!(
            "TCP frame declares {len} payload bytes but only {} follow the prefix",
            frame.len().saturating_sub(4)
        ))
    })?;
    Ok(decrypt(payload))
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
        assert_eq!(request.json, r#"{"system":{"set_relay_state":{"state":1}}}"#);
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
}

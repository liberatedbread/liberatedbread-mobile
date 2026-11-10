// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Drive a Philips air purifier of the encrypted-CoAP generation from its
//! spec (`philips-air-coap.yaml`, handler `philips_air_coap`).
//!
//! Three CoAP resources on UDP 5683 carry everything
//! (`protocol_details.session`): POST `/sys/dev/sync` trades eight hex digits
//! for the device's counter, GET `/sys/dev/status` (Observe 0) answers the
//! state, and POST `/sys/dev/control` takes a JSON write. Status and control
//! bodies ride the envelope in `protocol_details.envelope`: the counter as
//! eight uppercase hex digits, AES-128-CBC ciphertext as uppercase hex under
//! a key and IV that are the ASCII halves of `MD5(secret + counter)` in
//! uppercase hex, and a plain SHA-256 of `counter + ciphertext hex`.
//!
//! What the spec leaves open is handled conservatively
//! (`remaining_unknowns`):
//!
//! - Whether the device rejects a reused, skipped or stale counter is not
//!   known, so every write starts from a fresh sync and uses that counter
//!   plus one. A counter is never reused, and one that would wrap past
//!   FFFFFFFF is refused rather than wrapped: the clients disagree there and
//!   no device has been seen doing either.
//! - A write that is not answered `{"status":"success"}` is reported as
//!   failed and NOT retried. The open-source clients re-sync and retry up to
//!   five times; whether a refused write was applied anyway is unknown.
//! - Some models never answer CoAP at all and some firmware removed local
//!   access; the transport client says so when the sync goes unanswered.
//!
//! The shared secret is a published constant of every open-source client
//! and authenticates nothing. Nothing here opens a socket.

use std::collections::BTreeMap;

use aes::Aes128;
use cbc::cipher::block_padding::Pkcs7;
use cbc::cipher::{BlockModeDecrypt, BlockModeEncrypt, KeyIvInit};
use md5::{Digest as _, Md5};
use sha2::Sha256;

use super::coap::{self, CoapOption, Message, MessageType};
use crate::error::ProtocolError;
use crate::spec::types::{DeviceSpec, SpecCommand};

/// The spec `protocol_handler` this module answers to, and the transport a
/// resolved action reports so the sender can route it.
pub const HANDLER_NAME: &str = "philips_air_coap";

/// What the spec's commands declare. The IKEA gateway declares it too, over
/// DTLS, so the handler is what admits a command.
pub const TRANSPORT: &str = "coap";

/// `identification.default_port`.
pub const PORT: u16 = 5683;

/// `protocol_details.envelope.shared_secret`, the same for every unit.
pub const SHARED_SECRET: &str = "JiangPan";

pub const SYNC_PATH: &str = "/sys/dev/sync";
pub const STATUS_PATH: &str = "/sys/dev/status";
pub const CONTROL_PATH: &str = "/sys/dev/control";

/// The state command every entity of the spec reads.
pub const STATUS_COMMAND: &str = "get_status";

/// Characters in the counter and in the SHA-256 trailer.
const COUNTER_LEN: usize = 8;
const DIGEST_LEN: usize = 64;

/// Largest envelope this will try to read. A full classic status is about
/// 1.4 KB of hex; a datagram is at most 64 KB anyway.
const MAX_ENVELOPE_LEN: usize = 64 * 1024;

fn malformed(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::MalformedReply(reason.into())
}

// ── Counter ─────────────────────────────────────────────────────────────────

/// Read a counter: exactly eight hex digits. Lowercase is accepted on the way
/// in; everything this module writes is uppercase.
pub fn parse_counter(text: &str) -> Result<u32, ProtocolError> {
    let text = text.trim();
    if text.len() != COUNTER_LEN || !text.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(malformed(format!(
            "expected eight hex digits for a counter, got {:?}",
            truncate(text)
        )));
    }
    u32::from_str_radix(text, 16).map_err(|_| malformed("counter is not hex"))
}

/// A counter as the wire writes it: eight uppercase hex digits, zero-padded.
pub fn format_counter(counter: u32) -> String {
    format!("{counter:08X}")
}

/// The counter the next client envelope uses after `current`.
///
/// Refuses at FFFFFFFF instead of wrapping: aioairctrl 0.3.1 wraps to
/// 00000000, the original raised, and what a device accepts is untested.
pub fn next_counter(current: u32) -> Result<u32, ProtocolError> {
    current.checked_add(1).ok_or_else(|| {
        ProtocolError::UnsupportedCommandEncoding(
            "the purifier's counter is at FFFFFFFF; what it accepts after a wrap \
             is unknown, so nothing is sent (power-cycling it resets the session)"
                .to_string(),
        )
    })
}

// ── Envelope ────────────────────────────────────────────────────────────────

fn upper_hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02X}")).collect()
}

/// `H = uppercase hex of MD5(secret + counter)`; the key is the ASCII of
/// `H[0..16]` and the IV the ASCII of `H[16..32]`, NOT hex-decoded.
pub fn key_and_iv(counter_hex: &str) -> ([u8; 16], [u8; 16]) {
    let mut hasher = Md5::new();
    hasher.update(SHARED_SECRET.as_bytes());
    hasher.update(counter_hex.as_bytes());
    let h = upper_hex(&hasher.finalize());
    let mut key = [0u8; 16];
    let mut iv = [0u8; 16];
    key.copy_from_slice(&h.as_bytes()[..16]);
    iv.copy_from_slice(&h.as_bytes()[16..32]);
    (key, iv)
}

/// `D = uppercase hex of SHA-256(counter + C)`: corruption detection, keyed
/// by nothing.
pub fn digest(counter_hex: &str, cipher_hex: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(counter_hex.as_bytes());
    hasher.update(cipher_hex.as_bytes());
    upper_hex(&hasher.finalize())
}

/// Wrap `plaintext` under `counter`: `counter || C || D`.
pub fn encode_envelope(counter: u32, plaintext: &str) -> String {
    let counter_hex = format_counter(counter);
    let (key, iv) = key_and_iv(&counter_hex);
    let ciphertext = cbc::Encryptor::<Aes128>::new(&key.into(), &iv.into())
        .encrypt_padded_vec::<Pkcs7>(plaintext.as_bytes());
    let cipher_hex = upper_hex(&ciphertext);
    let trailer = digest(&counter_hex, &cipher_hex);
    format!("{counter_hex}{cipher_hex}{trailer}")
}

fn unhex(text: &str) -> Option<Vec<u8>> {
    if !text.len().is_multiple_of(2) {
        return None;
    }
    text.as_bytes()
        .as_chunks::<2>()
        .0
        .iter()
        .map(|pair| {
            let s = std::str::from_utf8(pair).ok()?;
            u8::from_str_radix(s, 16).ok()
        })
        .collect()
}

/// Unwrap a device envelope to its JSON text: check the trailer, derive the
/// key from the envelope's own counter, decrypt, strip PKCS#7.
pub fn decode_envelope(envelope: &str) -> Result<String, ProtocolError> {
    let envelope = envelope.trim();
    if envelope.len() > MAX_ENVELOPE_LEN {
        return Err(malformed("envelope too long to be a status"));
    }
    if !envelope.is_ascii() || envelope.len() < COUNTER_LEN + 32 + DIGEST_LEN {
        return Err(malformed(format!(
            "not an envelope: {:?}",
            truncate(envelope)
        )));
    }
    let (counter_hex, rest) = envelope.split_at(COUNTER_LEN);
    let (cipher_hex, trailer) = rest.split_at(rest.len() - DIGEST_LEN);
    parse_counter(counter_hex)?;
    if !cipher_hex.len().is_multiple_of(32) {
        return Err(malformed("ciphertext is not whole AES blocks"));
    }
    if !digest(counter_hex, cipher_hex).eq_ignore_ascii_case(trailer) {
        return Err(malformed(
            "the envelope's SHA-256 trailer does not match its contents",
        ));
    }
    let ciphertext = unhex(cipher_hex).ok_or_else(|| malformed("ciphertext is not hex"))?;
    let (key, iv) = key_and_iv(&counter_hex.to_ascii_uppercase());
    let plaintext = cbc::Decryptor::<Aes128>::new(&key.into(), &iv.into())
        .decrypt_padded_vec::<Pkcs7>(&ciphertext)
        .map_err(|_| malformed("the envelope does not decrypt under its counter"))?;
    String::from_utf8(plaintext).map_err(|_| malformed("decrypted status is not UTF-8"))
}

fn truncate(text: &str) -> String {
    text.chars().take(40).collect()
}

// ── Control documents ───────────────────────────────────────────────────────

/// Whether `command_name` is one of the spec's control writes: POST to
/// `/sys/dev/control` with a body. `sync` and `get_status` are session
/// plumbing this module builds itself, not something a caller renders.
pub fn is_control_command(command: &SpecCommand) -> bool {
    command.transport.as_deref() == Some(TRANSPORT)
        && command.method.as_deref() == Some("POST")
        && command.path.as_deref() == Some(CONTROL_PATH)
        && command.body.is_some()
}

/// Render one of the spec's control writes to its JSON plaintext.
///
/// Every value is checked against what its parameter declares — its `enum`
/// when it has one, its type and range otherwise — because a value outside
/// the spec's list is exactly the write whose effect no source describes.
pub fn render_control(
    spec: &DeviceSpec,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    if spec.protocol_handler.as_deref() != Some(HANDLER_NAME) {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            spec.protocol_handler.clone().unwrap_or_default(),
        ));
    }
    let command = super::top_level_command(spec, command_name)?;
    if !is_control_command(command) {
        return Err(ProtocolError::UnsupportedCommandEncoding(format!(
            "{command_name} is not a control write"
        )));
    }
    let body = command.body.as_deref().unwrap_or_default();
    let rendered = crate::protocol::walk_placeholders(body, |name| {
        let Some(parameter) = command.parameters.get(name) else {
            return Ok(None);
        };
        let value = crate::protocol::resolve_parameter(command, command_name, name, values)?;
        let allowed = parameter.code_table();
        if !allowed.is_empty() && !allowed.iter().any(|(raw, _)| *raw == value) {
            return Err(ProtocolError::ParameterValueInvalid {
                name: name.to_string(),
                value,
                reason: format!(
                    "not one of the values the spec lists ({})",
                    allowed
                        .iter()
                        .map(|(raw, _)| raw.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                ),
            });
        }
        Ok(Some(
            match crate::protocol::http::declared_type(parameter.value_type.as_deref()) {
                crate::protocol::http::DeclaredType::String => {
                    crate::protocol::kasa::json_escape(&value)
                }
                _ => crate::protocol::http::typed_json(Some(parameter), name, &value)?.to_string(),
            },
        ))
    })?;
    // The template is the spec's; a body that no longer parses, or that is
    // not a desired-state write, is not sent.
    let parsed: serde_json::Value = serde_json::from_str(&rendered)
        .map_err(|e| ProtocolError::InvalidStateReply(format!("{command_name}: {e}")))?;
    if !parsed["state"]["desired"].is_object() {
        return Err(ProtocolError::InvalidStateReply(format!(
            "{command_name} does not render a state.desired write"
        )));
    }
    Ok(rendered)
}

// ── CoAP exchanges ──────────────────────────────────────────────────────────

fn request(
    code: u8,
    message_id: u16,
    token: &[u8],
    path: &str,
    observe: Option<u32>,
    payload: &[u8],
) -> Result<Vec<u8>, ProtocolError> {
    if token.is_empty() {
        // An empty token cannot tell this request's reply from another's.
        return Err(ProtocolError::ParameterMissing("token".to_string()));
    }
    let mut options = coap::uri_path_options(path);
    if let Some(observe) = observe {
        options.push(CoapOption {
            number: coap::option::OBSERVE,
            value: coap::uint_value(observe),
        });
    }
    coap::encode(&Message {
        message_type: MessageType::NonConfirmable,
        code,
        message_id,
        token: token.to_vec(),
        options,
        payload: payload.to_vec(),
    })
}

/// POST `/sys/dev/sync` with an eight-hex-digit nonce (uppercase, fresh per
/// sync), NON as every client sends it.
pub fn sync_request(message_id: u16, token: &[u8], nonce: &str) -> Result<Vec<u8>, ProtocolError> {
    if nonce.len() != COUNTER_LEN
        || !nonce
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b))
    {
        return Err(ProtocolError::ParameterValueInvalid {
            name: "nonce".to_string(),
            value: nonce.to_string(),
            reason: "eight uppercase hex digits".to_string(),
        });
    }
    request(
        coap::code::POST,
        message_id,
        token,
        SYNC_PATH,
        None,
        nonce.as_bytes(),
    )
}

/// GET `/sys/dev/status` with Observe = 0, as the clients ask for it.
pub fn status_request(message_id: u16, token: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    request(
        coap::code::GET,
        message_id,
        token,
        STATUS_PATH,
        Some(0),
        &[],
    )
}

/// GET `/sys/dev/status` with Observe = 1 on the same token: RFC 7641's
/// deregistration, so a one-shot read does not leave an observation behind
/// on a socket that is about to close. The spec's clients do not send this
/// (they keep observing or just stop); it is plain RFC 7641.
pub fn status_deregister(message_id: u16, token: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    request(
        coap::code::GET,
        message_id,
        token,
        STATUS_PATH,
        Some(1),
        &[],
    )
}

/// POST `/sys/dev/control` carrying an envelope.
pub fn control_request(
    message_id: u16,
    token: &[u8],
    envelope: &str,
) -> Result<Vec<u8>, ProtocolError> {
    request(
        coap::code::POST,
        message_id,
        token,
        CONTROL_PATH,
        None,
        envelope.as_bytes(),
    )
}

/// What one datagram means for the request in flight.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CoapReply {
    /// True when this is the reply to the token asked about.
    pub answers_request: bool,
    /// Bytes the client owes the sender: an empty ACK for a confirmable
    /// reply, a Reset for a confirmable message on a token it never asked.
    pub owe: Option<Vec<u8>>,
    pub code: u8,
    pub payload: Vec<u8>,
    pub max_age: Option<u32>,
}

/// Read a datagram against `token`. Never an error: garbage, another
/// token's message, or an empty ACK promising a separate reply are all "not
/// the answer", and the caller's timeout reports a device that never gives
/// one.
pub fn read_reply(datagram: &[u8], token: &[u8]) -> CoapReply {
    let not_ours = |owe| CoapReply {
        answers_request: false,
        owe,
        code: 0,
        payload: Vec::new(),
        max_age: None,
    };
    let Ok(message) = coap::decode(datagram) else {
        return not_ours(None);
    };
    let confirmable = message.message_type == MessageType::Confirmable;
    if message.code == coap::code::EMPTY || coap::code::class(message.code) == 0 {
        // An empty ACK (separate response to follow), a ping, or a request:
        // none of them is the answer.
        return not_ours(None);
    }
    if message.token != token {
        let reset = confirmable.then(|| {
            let mut out = coap::empty_ack(message.message_id);
            out[0] = (coap::VERSION << 6) | (3 << 4);
            out
        });
        return not_ours(reset);
    }
    CoapReply {
        answers_request: true,
        owe: confirmable.then(|| coap::empty_ack(message.message_id)),
        code: message.code,
        max_age: message.uint_option(coap::option::MAX_AGE),
        payload: message.payload,
    }
}

/// The counter a sync reply carries.
pub fn parse_sync_reply(payload: &[u8]) -> Result<u32, ProtocolError> {
    let text = std::str::from_utf8(payload).map_err(|_| malformed("sync reply is not text"))?;
    parse_counter(text)
}

/// Whether a control reply says the write was taken: the plain JSON
/// `{"status":"success"}`, and nothing else counts.
pub fn control_succeeded(payload: &[u8]) -> bool {
    serde_json::from_slice::<serde_json::Value>(payload)
        .ok()
        .and_then(|v| {
            let object = v.as_object()?;
            (object.len() == 1).then(|| object.get("status")?.as_str().map(str::to_string))?
        })
        .is_some_and(|status| status == "success")
}

/// A status payload to its JSON text, checked to be the documented wrapper.
pub fn decode_status(payload: &[u8]) -> Result<String, ProtocolError> {
    let text = std::str::from_utf8(payload).map_err(|_| malformed("status is not text"))?;
    let json = decode_envelope(text)?;
    let parsed: serde_json::Value = serde_json::from_str(&json)
        .map_err(|e| ProtocolError::InvalidStateReply(format!("status: {e}")))?;
    if !parsed["state"]["reported"].is_object() {
        return Err(ProtocolError::InvalidStateReply(
            "status carries no state.reported object".to_string(),
        ));
    }
    Ok(json)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn spec_text() -> String {
        std::fs::read_to_string(format!(
            "{}/../vendor/protocol-specs/device-specs/devices/philips-air-coap.yaml",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap()
    }

    fn spec() -> DeviceSpec {
        parse_device_spec(&spec_text()).unwrap()
    }

    fn doc() -> serde_yaml::Value {
        serde_yaml::from_str(&spec_text()).unwrap()
    }

    fn vectors() -> Vec<serde_yaml::Value> {
        doc()["protocol_details"]["envelope"]["test_vectors"]
            .as_sequence()
            .unwrap()
            .clone()
    }

    fn s(v: &serde_yaml::Value) -> &str {
        v.as_str().unwrap()
    }

    #[test]
    fn the_constants_are_the_specs() {
        let doc = doc();
        assert_eq!(s(&doc["protocol_handler"]), HANDLER_NAME);
        assert_eq!(
            s(&doc["protocol_details"]["envelope"]["shared_secret"]),
            SHARED_SECRET
        );
        assert_eq!(
            doc["device"]["identification"]["default_port"].as_u64(),
            Some(u64::from(PORT))
        );
        let spec = spec();
        assert_eq!(spec.commands["sync"].path.as_deref(), Some(SYNC_PATH));
        assert_eq!(
            spec.commands[STATUS_COMMAND].path.as_deref(),
            Some(STATUS_PATH)
        );
        assert_eq!(
            spec.commands["power_on"].path.as_deref(),
            Some(CONTROL_PATH)
        );
    }

    /// Every test vector in the spec, both ways: key and IV where it states
    /// them, the envelope built byte for byte from counter and plaintext, and
    /// the envelope read back to the plaintext.
    #[test]
    fn the_specs_envelope_vectors_reproduce() {
        let vectors = vectors();
        assert_eq!(vectors.len(), 3);
        for v in &vectors {
            let counter = s(&v["counter"]);
            let plaintext = s(&v["plaintext"]);
            let envelope = s(&v["envelope"]);
            let (key, iv) = key_and_iv(counter);
            if let Some(expected) = v["key_ascii"].as_str() {
                assert_eq!(std::str::from_utf8(&key).unwrap(), expected);
                assert_eq!(std::str::from_utf8(&iv).unwrap(), s(&v["iv_ascii"]));
            }
            assert_eq!(
                encode_envelope(parse_counter(counter).unwrap(), plaintext),
                envelope,
                "{}",
                s(&v["name"])
            );
            assert_eq!(decode_envelope(envelope).unwrap(), plaintext);
        }
    }

    /// The vector's own story: a sync answered 6D2C0F41, and the first write
    /// goes under 6D2C0F42; FFFFFFFE gives FFFFFFFF.
    #[test]
    fn the_next_envelope_uses_the_synced_counter_plus_one() {
        assert_eq!(
            format_counter(next_counter(parse_sync_reply(b"6D2C0F41").unwrap()).unwrap()),
            "6D2C0F42"
        );
        assert_eq!(
            format_counter(next_counter(parse_counter("FFFFFFFE").unwrap()).unwrap()),
            "FFFFFFFF"
        );
        assert_eq!(format_counter(0x0000A0B1), "0000A0B1");
    }

    /// The edge the clients disagree on and no device has been seen at: this
    /// refuses rather than picks a side.
    #[test]
    fn a_counter_at_its_end_is_not_wrapped() {
        let error = next_counter(u32::MAX).unwrap_err().to_string();
        assert!(error.contains("FFFFFFFF"), "{error}");
    }

    #[test]
    fn counters_are_exactly_eight_hex_digits() {
        assert_eq!(parse_counter("6d2c0f41").unwrap(), 0x6D2C0F41);
        for bad in ["", "6D2C0F4", "6D2C0F411", "6D2C0F4G", "  ", "{\"x\":1}"] {
            assert!(parse_counter(bad).is_err(), "{bad:?}");
        }
    }

    #[test]
    fn a_tampered_or_truncated_envelope_is_refused() {
        let envelope = s(&vectors()[2]["envelope"]).to_string();
        // One ciphertext character changed: the trailer no longer matches.
        let mut tampered = envelope.clone().into_bytes();
        tampered[10] = if tampered[10] == b'0' { b'1' } else { b'0' };
        let error = decode_envelope(std::str::from_utf8(&tampered).unwrap())
            .unwrap_err()
            .to_string();
        assert!(error.contains("SHA-256"), "{error}");
        assert!(decode_envelope(&envelope[..envelope.len() - 2]).is_err());
        assert!(decode_envelope("").is_err());
        assert!(decode_envelope("not an envelope at all, just some words here").is_err());
        // A trailer recomputed over a re-countered envelope: the digest is
        // right but the key is not, so it fails to decrypt instead.
        let counter = "0000A0B2";
        let cipher = &envelope[8..envelope.len() - 64];
        let forged = format!("{counter}{cipher}{}", digest(counter, cipher));
        assert!(decode_envelope(&forged).is_err());
    }

    #[test]
    fn controls_render_to_the_specs_example_bodies() {
        let spec = spec();
        let values = |pairs: &[(&str, &str)]| -> BTreeMap<String, String> {
            pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        };
        assert_eq!(
            render_control(&spec, "power_on", &BTreeMap::new()).unwrap(),
            s(&vectors()[0]["plaintext"])
        );
        for (name, given) in [
            ("set_mode", values(&[("mode", "P")])),
            ("set_fan_speed", values(&[("speed", "2")])),
            ("set_light_brightness", values(&[("brightness", "50")])),
            ("set_button_light", values(&[("state", "0")])),
            ("set_timer", values(&[("hours", "2")])),
            ("set_target_humidity", values(&[("humidity", "50")])),
            ("set_function", values(&[("function", "PH")])),
            ("set_preferred_index", values(&[("index", "1")])),
            ("dashed_set_mode", values(&[("mode", "Sleep")])),
            ("compact_set_mode", values(&[("mode", "18")])),
            (
                "compact_set_mode_pair",
                values(&[("mode", "19"), ("companion", "2")]),
            ),
            ("compact_set_target_humidity", values(&[("humidity", "50")])),
            ("compact_set_timer", values(&[("code", "3")])),
        ] {
            let expected = spec.commands[name].example_body.as_deref().unwrap();
            assert_eq!(
                render_control(&spec, name, &given).unwrap(),
                expected,
                "{name}"
            );
        }
        // The compact vector's write is compact_set_mode with turbo.
        assert_eq!(
            render_control(&spec, "compact_set_mode", &values(&[("mode", "18")])).unwrap(),
            s(&vectors()[1]["plaintext"])
        );
    }

    #[test]
    fn values_outside_the_specs_lists_are_refused() {
        let spec = spec();
        for (name, param, value) in [
            ("set_mode", "mode", "X"),
            ("set_mode", "mode", "P\", \"pwr\": \"0"),
            ("set_fan_speed", "speed", "s"),
            ("set_light_brightness", "brightness", "60"),
            (
                "set_light_brightness",
                "brightness",
                "1}, \"pwr\": \"0\"}}}",
            ),
            ("set_timer", "hours", "13"),
            ("compact_set_mode", "mode", "7"),
            ("compact_set_target_humidity", "humidity", "80"),
        ] {
            let given = [(param.to_string(), value.to_string())]
                .into_iter()
                .collect();
            assert!(
                render_control(&spec, name, &given).is_err(),
                "{name} {param}={value} rendered"
            );
        }
    }

    #[test]
    fn session_plumbing_is_not_a_renderable_control() {
        let spec = spec();
        for name in ["sync", STATUS_COMMAND] {
            assert!(render_control(&spec, name, &BTreeMap::new()).is_err());
        }
        let other = parse_device_spec(
            &std::fs::read_to_string(format!(
                "{}/../vendor/protocol-specs/device-specs/devices/ikea-tradfri-gateway.yaml",
                env!("CARGO_MANIFEST_DIR")
            ))
            .unwrap(),
        )
        .unwrap();
        let name = other.commands.keys().next().unwrap().clone();
        assert!(render_control(&other, &name, &BTreeMap::new()).is_err());
    }

    #[test]
    fn the_session_requests_are_the_documented_coap_messages() {
        let token = [0xA1, 0xB2, 0xC3, 0xD4];
        let sync = coap::decode(&sync_request(0x0102, &token, "1A2B3C4D").unwrap()).unwrap();
        assert_eq!(sync.message_type, MessageType::NonConfirmable);
        assert_eq!(sync.code, coap::code::POST);
        assert_eq!(sync.message_id, 0x0102);
        assert_eq!(sync.token, token);
        let path: Vec<&[u8]> = sync
            .options
            .iter()
            .filter(|o| o.number == coap::option::URI_PATH)
            .map(|o| o.value.as_slice())
            .collect();
        assert_eq!(path, [&b"sys"[..], b"dev", b"sync"]);
        assert_eq!(sync.payload, b"1A2B3C4D");
        assert!(sync_request(1, &token, "1a2b3c4d").is_err());
        assert!(sync_request(1, &token, "1A2B3C").is_err());
        assert!(sync_request(1, &[], "1A2B3C4D").is_err());

        let status = coap::decode(&status_request(3, &token).unwrap()).unwrap();
        assert_eq!(status.code, coap::code::GET);
        assert_eq!(status.uint_option(coap::option::OBSERVE), Some(0));
        assert!(status.payload.is_empty());
        let stop = coap::decode(&status_deregister(4, &token).unwrap()).unwrap();
        assert_eq!(stop.uint_option(coap::option::OBSERVE), Some(1));

        let vectors = vectors();
        let envelope = s(&vectors[0]["envelope"]);
        let control = coap::decode(&control_request(5, &token, envelope).unwrap()).unwrap();
        assert_eq!(control.code, coap::code::POST);
        assert_eq!(control.payload, envelope.as_bytes());
    }

    fn reply(kind: MessageType, code: u8, token: &[u8], payload: &[u8]) -> Vec<u8> {
        coap::encode(&Message {
            message_type: kind,
            code,
            message_id: 0x0A0B,
            token: token.to_vec(),
            options: vec![CoapOption {
                number: coap::option::MAX_AGE,
                value: coap::uint_value(60),
            }],
            payload: payload.to_vec(),
        })
        .unwrap()
    }

    #[test]
    fn replies_are_matched_by_token_and_confirmables_are_acknowledged() {
        let token = [1, 2, 3, 4];
        let non = read_reply(
            &reply(
                MessageType::NonConfirmable,
                coap::code::CONTENT,
                &token,
                b"6D2C0F41",
            ),
            &token,
        );
        assert!(non.answers_request);
        assert_eq!(non.owe, None);
        assert_eq!(non.max_age, Some(60));
        assert_eq!(parse_sync_reply(&non.payload).unwrap(), 0x6D2C0F41);

        let con = read_reply(
            &reply(MessageType::Confirmable, coap::code::CONTENT, &token, b"x"),
            &token,
        );
        assert!(con.answers_request);
        assert_eq!(con.owe, Some(vec![0x60, 0x00, 0x0A, 0x0B]));

        let stranger = read_reply(
            &reply(MessageType::Confirmable, coap::code::CONTENT, &[9], b"x"),
            &token,
        );
        assert!(!stranger.answers_request);
        assert_eq!(stranger.owe, Some(vec![0x70, 0x00, 0x0A, 0x0B]));

        let piggybacked = read_reply(
            &reply(
                MessageType::Acknowledgement,
                coap::code::CHANGED,
                &token,
                b"y",
            ),
            &token,
        );
        assert!(piggybacked.answers_request);
        assert_eq!(piggybacked.owe, None);

        // Garbage, an empty ACK, and a request are not the answer.
        for datagram in [
            b"garbage".to_vec(),
            Vec::new(),
            coap::empty_ack(1),
            sync_request(2, &token, "00000000").unwrap(),
        ] {
            assert!(!read_reply(&datagram, &token).answers_request);
        }
    }

    #[test]
    fn only_the_exact_success_document_is_success() {
        assert!(control_succeeded(br#"{"status":"success"}"#));
        assert!(control_succeeded(br#"{ "status" : "success" }"#));
        for bad in [
            &br#"{"status":"failed"}"#[..],
            br#"{"status":"success","err":1}"#,
            br#"{"Status":"success"}"#,
            b"success",
            b"",
            b"\xFF\xFE",
        ] {
            assert!(!control_succeeded(bad), "{bad:?}");
        }
    }

    #[test]
    fn a_status_payload_decodes_to_the_reported_document() {
        let vectors = vectors();
        let v = &vectors[2];
        let json = decode_status(s(&v["envelope"]).as_bytes()).unwrap();
        assert_eq!(json, s(&v["plaintext"]));
        // An enveloped control document is not a status.
        assert!(decode_status(s(&vectors[0]["envelope"]).as_bytes()).is_err());
        assert!(decode_status(b"{\"status\":\"success\"}").is_err());
    }
}

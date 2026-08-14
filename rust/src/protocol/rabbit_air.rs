// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Drive a Rabbit Air purifier from its spec: an encrypted JSON envelope over
//! UDP datagrams on port 9009.
//!
//! The fourth network transport's sibling of [`crate::protocol::kasa`]: a
//! command's `body` carries only the STATIC envelope fields (`cmd`, plus
//! `data` when the command writes state), with `{name}` placeholders
//! substituted from the command's declared `parameters` exactly as the Kasa
//! renderer does — the substitution is literally shared. What this module adds
//! on top is the envelope and the wire crypto: the renderer wraps the body
//! into the full `{id, cmd, ts, data}` document — `id` a fresh client nonce
//! the caller owns (it must match replies against it), `ts` the device-clock
//! timestamp the caller extrapolates from the learned offset — serialized
//! minified in that field order with `data` last and omitted when absent.
//! On the wire every message is AES-128-CBC with PKCS7 padding under the
//! per-device 16-byte user key, with a random 16-byte IV APPENDED as the last
//! 16 bytes (ciphertext || IV).
//!
//! What deliberately does NOT live here is I/O — Dart owns the UDP socket, the
//! retry loop and the request-id matching — and reply *parsing* beyond the
//! crypto: a reply is JSON, which Dart flattens into the name→value pairs the
//! generic entity decoder reads (the Kasa split of labour, one transport
//! over). The TCP 9009 variant (2-byte little-endian length prefix) is
//! documented in the spec and deliberately not implemented.

use std::collections::BTreeMap;

use aes::Aes128;
use cbc::cipher::block_padding::Pkcs7;
use cbc::cipher::{BlockDecryptMut, BlockEncryptMut, KeyIvInit};

use crate::error::ProtocolError;
use crate::spec::types::{DeviceSpec, SpecCommand};

/// The `protocol_handler` name a spec declares to be driven from here. The
/// bindings resolver admits `transport: udp` commands only under this handler,
/// so no other spec can claim the bare transport.
pub const HANDLER_NAME: &str = "rabbit_air_lan";

/// The transport a command must declare to be sendable from here.
pub const TRANSPORT: &str = "udp";

/// The port the Rabbit Air LAN protocol listens on. The spec's
/// `identification.default_port`, restated as the transport's own constant.
pub const PORT: u16 = 9009;

/// The user key is 16 raw bytes, entered as its 32-hex-character spelling.
pub const USER_KEY_LEN: usize = 16;

/// The IV is one AES block, appended after the ciphertext.
const IV_LEN: usize = 16;

type Aes128CbcEncryptor = cbc::Encryptor<Aes128>;
type Aes128CbcDecryptor = cbc::Decryptor<Aes128>;

/// A rendered request: the plaintext envelope JSON and the nonce it carries.
///
/// `id` is handed back because the caller matches replies on it — the
/// wire-matching contract is `response.id == request.id`, so the renderer must
/// not hide the value it stamped. The JSON stays plaintext so a caller can log
/// it and the tests can diff it; [`encrypt`] turns it into the datagram.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RabbitAirRequest {
    pub json: String,
    pub id: u32,
}

/// Render one of the spec's `commands` into a request envelope.
///
/// `id` is the caller's fresh client nonce; `ts` the device-clock timestamp —
/// the local clock plus the offset learned from the `time_sync` reply (zero
/// offset for the time-sync request itself, before any offset is known).
pub fn render_request(
    spec: &DeviceSpec,
    command_name: &str,
    values: &BTreeMap<String, String>,
    id: u32,
    ts: u32,
) -> Result<RabbitAirRequest, ProtocolError> {
    let command =
        spec.commands
            .get(command_name)
            .ok_or_else(|| ProtocolError::CommandNotFound {
                uuid: "commands".to_string(),
                command: command_name.to_string(),
            })?;
    render_command(command_name, command, values, id, ts)
}

/// Render a command already in hand — the path a resolved control takes.
pub fn render_command(
    command_name: &str,
    command: &SpecCommand,
    values: &BTreeMap<String, String>,
    id: u32,
    ts: u32,
) -> Result<RabbitAirRequest, ProtocolError> {
    // The same rule the Kasa module applies: absent means the spec's single
    // declared transport, so only an explicit `udp` qualifies — a command for
    // another transport must not be rendered as though it were this one.
    if command.transport.as_deref() != Some(TRANSPORT) {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            command.transport.clone().unwrap_or_default(),
        ));
    }
    let Some(body) = command.body.as_deref() else {
        return Err(ProtocolError::EmptyCommand);
    };
    let body = crate::protocol::kasa::substitute(body, command, command_name, values)?;
    Ok(RabbitAirRequest {
        json: envelope(&body, id, ts)?,
        id,
    })
}

/// Render the request that polls a state command's values — `get_state`,
/// which every entity names in `state_command`. A state read is just another
/// command here (the Kasa poll's exact shape), so this resolves it by name.
pub fn render_state_request(
    spec: &DeviceSpec,
    state_command: &str,
    id: u32,
    ts: u32,
) -> Result<RabbitAirRequest, ProtocolError> {
    render_request(spec, state_command, &BTreeMap::new(), id, ts)
}

/// Wrap a command body into the wire envelope `{id, cmd, ts, data}`: minified
/// JSON in that field order, `data` last and omitted when the body carries
/// none. The body supplies only the STATIC fields (`cmd`, `data`); `id` and
/// `ts` are per-send values the renderer stamps, and a body that froze them
/// would replay one nonce and one stale timestamp forever — which is why they
/// are parameters here, not body content.
fn envelope(body: &str, id: u32, ts: u32) -> Result<String, ProtocolError> {
    let mut fields = match serde_json::from_str::<serde_json::Value>(body) {
        Ok(serde_json::Value::Object(map)) => map,
        _ => {
            return Err(ProtocolError::InvalidStateReply(format!(
                "a Rabbit Air command body must be a JSON object, got: {body}"
            )))
        }
    };
    // `preserve_order` is on, so the body's declared order survives the parse;
    // `data` is lifted out first so it can be re-appended LAST regardless of
    // where a body spelled it — the vendor client reads by key, but the spec's
    // example exchange pins this order and the renderer honours it.
    let data = fields.shift_remove("data");
    let mut out = serde_json::Map::new();
    out.insert("id".to_string(), serde_json::Value::from(id));
    for (key, value) in fields {
        out.insert(key, value);
    }
    out.insert("ts".to_string(), serde_json::Value::from(ts));
    if let Some(data) = data {
        out.insert("data".to_string(), data);
    }
    // serde_json::to_string is minified — the spec's `json.dumps`
    // separators=(',',':') spelling.
    serde_json::to_string(&serde_json::Value::Object(out))
        .map_err(|e| ProtocolError::InvalidStateReply(format!("envelope did not serialize: {e}")))
}

/// Hex-decode the 32-character user-key string the vendor app reveals into
/// the 16-byte AES key. Anything else — wrong length, non-hex — is rejected
/// here, at the edge, rather than producing a key that fails mysteriously
/// against the device.
pub fn parse_user_key(hex: &str) -> Result<[u8; USER_KEY_LEN], ProtocolError> {
    let hex = hex.trim();
    if hex.len() != USER_KEY_LEN * 2 {
        return Err(ProtocolError::ParameterInvalid {
            name: "user_key".to_string(),
            value: hex.len() as f64,
            reason: format!("the user key is 32 hex characters, got {}", hex.len()),
        });
    }
    let mut key = [0u8; USER_KEY_LEN];
    for (i, byte) in key.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).map_err(|_| {
            ProtocolError::ParameterInvalid {
                name: "user_key".to_string(),
                value: 0.0,
                reason: "the user key is hexadecimal (0-9, a-f)".to_string(),
            }
        })?;
    }
    Ok(key)
}

/// Encrypt one envelope for the wire: AES-128-CBC with PKCS7 padding under the
/// user key, a fresh random 16-byte IV APPENDED as the last 16 bytes of the
/// datagram (ciphertext || IV) — the spec's framing, one message per datagram.
pub fn encrypt(key: &[u8; USER_KEY_LEN], plaintext: &[u8]) -> Vec<u8> {
    let mut iv = [0u8; IV_LEN];
    getrandom::getrandom(&mut iv).expect("the OS has a CSPRNG");
    let ciphertext =
        Aes128CbcEncryptor::new(key.into(), &iv.into()).encrypt_padded_vec_mut::<Pkcs7>(plaintext);
    let mut out = Vec::with_capacity(ciphertext.len() + IV_LEN);
    out.extend_from_slice(&ciphertext);
    out.extend_from_slice(&iv);
    out
}

/// The inverse of [`encrypt`]: the IV is the last 16 bytes, the ciphertext
/// everything before it. Rejects short or mis-sized datagrams, and a payload
/// whose padding does not check out — which is what a WRONG KEY looks like
/// from here (a one-in-256 chance per message of a fluke valid pad, the
/// standard CBC caveat), so an undecryptable datagram is a malformed reply,
/// never garbage JSON handed upstream.
pub fn decrypt(key: &[u8; USER_KEY_LEN], datagram: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    let (ciphertext, iv) = datagram
        .split_at_checked(datagram.len().saturating_sub(IV_LEN))
        .filter(|(c, _)| !c.is_empty() && c.len() % IV_LEN == 0)
        .ok_or_else(|| {
            ProtocolError::MalformedReply(format!(
                "datagram is {} bytes; need a nonzero AES block multiple plus a 16-byte IV",
                datagram.len()
            ))
        })?;
    Aes128CbcDecryptor::new(key.into(), iv.into())
        .decrypt_padded_vec_mut::<Pkcs7>(ciphertext)
        .map_err(|_| {
            ProtocolError::MalformedReply(
                "datagram does not decrypt under this user key (bad padding)".to_string(),
            )
        })
}

/// The clock offset a `time_sync` (cmd 9) reply teaches: `data.ts` minus the
/// local clock at the moment the reply arrived. Every later request stamps
/// `ts = local_now + offset`, extrapolating the device clock — the spec's
/// handshake, with a re-sync whenever the socket is re-created.
///
/// A reply carrying a truthy `error`, no `data.ts`, or a non-numeric `ts` is
/// rejected: stamping requests from a guessed clock produces anti-replay
/// rejections that read as a dead device.
pub fn time_sync_offset(reply_json: &str, local_now_secs: u32) -> Result<i64, ProtocolError> {
    let reply = serde_json::from_str::<serde_json::Value>(reply_json)
        .map_err(|e| ProtocolError::MalformedReply(format!("time-sync reply is not JSON: {e}")))?;
    if reply
        .get("error")
        .is_some_and(|e| !e.is_null() && *e != false)
    {
        return Err(ProtocolError::MalformedReply(format!(
            "time-sync reply carries an error: {reply_json}"
        )));
    }
    let device_ts = reply
        .get("data")
        .and_then(|data| data.get("ts"))
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| {
            ProtocolError::MalformedReply(format!(
                "time-sync reply carries no data.ts: {reply_json}"
            ))
        })?;
    Ok(device_ts - i64::from(local_now_secs))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A miniature Rabbit-Air-shaped device, so these tests exercise the
    /// rules. The real spec is driven end to end in `tests/rabbit_air_control.rs`.
    const SPEC: &str = r#"
device:
  name: "Test Purifier"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "climate"
protocol_handler: "rabbit_air_lan"
commands:
  get_state:
    description: "State poll."
    transport: "udp"
    body: '{"cmd":4}'
  turn_on:
    description: "On."
    transport: "udp"
    body: '{"cmd":4,"data":{"power":true}}'
  set_speed:
    description: "Speed, with a runtime-filled placeholder."
    transport: "udp"
    body: '{"cmd":4,"data":{"mode":2,"speed":{speed}}}'
    parameters:
      speed:
        type: "integer"
        required: true
        min: 1
        max: 5
  over_soap:
    description: "A transport this module does not speak."
    transport: "soap"
    service: "urn:Test:service:basicevent:1"
    action: "SetBinaryState"
entities:
  - platform: "switch"
    name: "Power"
    state_command: "get_state"
    state_mapping:
      value: "power"
    commands:
      turn_on: "turn_on"
"#;

    /// The example key from the spec's own exchange documentation (a
    /// documentation value, not a real device).
    const KEY_HEX: &str = "0123456789abcdeffedcba9876543210";

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC).expect("fixture spec parses")
    }

    fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect()
    }

    fn key() -> [u8; USER_KEY_LEN] {
        parse_user_key(KEY_HEX).unwrap()
    }

    #[test]
    fn a_read_envelope_omits_data_and_pins_field_order() {
        let request =
            render_request(&spec(), "get_state", &values(&[]), 1234568, 1700000123).unwrap();
        assert_eq!(request.json, r#"{"id":1234568,"cmd":4,"ts":1700000123}"#);
        assert_eq!(request.id, 1234568);
    }

    #[test]
    fn a_write_envelope_carries_data_last() {
        let request =
            render_request(&spec(), "turn_on", &values(&[]), 1234569, 1700000124).unwrap();
        assert_eq!(
            request.json,
            r#"{"id":1234569,"cmd":4,"ts":1700000124,"data":{"power":true}}"#
        );
    }

    #[test]
    fn a_placeholder_substitutes_into_the_body_not_the_envelope() {
        let request =
            render_request(&spec(), "set_speed", &values(&[("speed", "3")]), 42, 99).unwrap();
        assert_eq!(
            request.json,
            r#"{"id":42,"cmd":4,"ts":99,"data":{"mode":2,"speed":3}}"#
        );
    }

    #[test]
    fn a_missing_placeholder_is_an_error_not_a_blank() {
        let err = render_request(&spec(), "set_speed", &values(&[]), 1, 1).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterMissing(name) if name == "set_speed.speed"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn a_command_for_another_transport_is_declined() {
        let err = render_request(&spec(), "over_soap", &values(&[]), 1, 1).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::UnsupportedCommandEncoding(t) if t == "soap"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn the_state_poll_renders_the_get_state_body() {
        let request = render_state_request(&spec(), "get_state", 7, 70).unwrap();
        assert_eq!(request.json, r#"{"id":7,"cmd":4,"ts":70}"#);
    }

    #[test]
    fn user_key_parsing_accepts_the_documented_shape_only() {
        assert_eq!(parse_user_key(KEY_HEX).unwrap()[0], 0x01);
        assert_eq!(parse_user_key(KEY_HEX).unwrap()[15], 0x10);
        // Uppercase hex is hex too.
        assert_eq!(
            parse_user_key(&KEY_HEX.to_uppercase()).unwrap(),
            parse_user_key(KEY_HEX).unwrap()
        );
        assert!(parse_user_key("0123").is_err(), "too short");
        assert!(parse_user_key(&format!("{KEY_HEX}00")).is_err(), "too long");
        assert!(
            parse_user_key(&KEY_HEX.replace('0', "g")).is_err(),
            "not hex"
        );
    }

    #[test]
    fn crypto_round_trips_with_the_iv_appended() {
        let plaintext = br#"{"id":1234568,"cmd":4,"ts":1700000123}"#;
        let datagram = encrypt(&key(), plaintext);
        assert_eq!(
            datagram.len() % 16,
            0,
            "ciphertext blocks plus one IV block"
        );
        assert!(datagram.len() > plaintext.len(), "padding grew the payload");
        // Two encryptions of the same plaintext differ — a fresh IV each time.
        assert_ne!(encrypt(&key(), plaintext), datagram);
        assert_eq!(decrypt(&key(), &datagram).unwrap(), plaintext);
    }

    #[test]
    fn a_wrong_key_or_garbage_datagram_is_rejected() {
        let datagram = encrypt(&key(), br#"{"id":1,"cmd":9,"ts":1}"#);
        let wrong_key = [0xFFu8; USER_KEY_LEN];
        assert!(matches!(
            decrypt(&wrong_key, &datagram),
            Err(ProtocolError::MalformedReply(_))
        ));
        for garbage in [&b""[..], &[0u8; 8][..], &[0u8; 16][..], &[0u8; 24][..]] {
            assert!(
                matches!(
                    decrypt(&key(), garbage),
                    Err(ProtocolError::MalformedReply(_))
                ),
                "{garbage:?} must not decrypt"
            );
        }
    }

    #[test]
    fn time_sync_offset_is_device_clock_minus_local_clock() {
        // The spec's example reply, answered 123 s ahead of the local clock.
        let reply = r#"{"id":1234567,"data":{"ts":1700000123}}"#;
        assert_eq!(time_sync_offset(reply, 1700000000).unwrap(), 123);
    }

    #[test]
    fn time_sync_rejects_errors_and_shapeless_replies() {
        assert!(time_sync_offset(r#"{"id":1,"error":1}"#, 0).is_err());
        assert!(time_sync_offset(r#"{"id":1,"data":{}}"#, 0).is_err());
        assert!(time_sync_offset(r#"{"id":1,"data":{"ts":"soon"}}"#, 0).is_err());
        assert!(time_sync_offset("not json", 0).is_err());
        // `error: false` / null is not an error.
        assert!(time_sync_offset(r#"{"id":1,"error":false,"data":{"ts":10}}"#, 4).is_ok());
    }
}

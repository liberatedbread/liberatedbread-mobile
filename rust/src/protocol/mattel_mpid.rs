// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Mattel's MPID session — `protocol_handler: "mattel_mpid"`
//! (`fisher-price-lumalou.yaml`, `protocol_details.mpid`, which states every
//! byte; the vectors in the tests are that block's `test_vectors`).
//!
//! ```text
//! token   = read 4cea0004: 192 bytes, device key at 25..58, salt at 188..192
//! shared  = ECDH(app ephemeral P-256, device key).x
//! key     = 100 rounds of AES-128-CTR over shared, keyed by its own front half
//! session = write 4cea0005: app compressed key (33) || app nonce (4)
//! frame   = 7e | seq u32be | len u16be | crc8(those 7) | CTR(body || crc8(body))
//!   tx iv = seq | app nonce   | device salt | 00000000
//!   rx iv = seq | device salt | app nonce   | 00000000
//! ```
//!
//! # Where the line is
//!
//! A spec's command templates are the decrypted BODY of a frame, and
//! [`bind_commands`] states [`SCHEME`] on the command characteristic when the
//! spec is parsed, so the generic encoder, the entity cards and group ops
//! render those bodies unchanged. What turns a body into a frame needs the
//! session — a key agreed on this connection, a nonce, the device's salt and
//! a counter — and a stateless encoder has none of it, so the session lives
//! with the connection: Dart's `MattelMpidBleService` runs the handshake
//! below and calls [`seal`] / [`open`] (through `api::mpid_api`) on every
//! write and notification that crosses the MPID service. A body that reached
//! the radio without that layer is not a frame at all (no `7e` header), and
//! the unit ignores it.
//!
//! # What [`seal`] refuses
//!
//! Only the bodies the spec declares go out: `ENABLE_RX`, and FE-framed
//! commands whose opcode is in [`SENDABLE_OPCODES`] with a correct XOR. The
//! spec's `do_not_write` list stays unsendable by construction —
//! `SEND_PAIRING_COMPLETE` (0x34) is not in the list, and no OTA opcode is
//! published to put in it. The Nordic DFU service is refused by the Dart
//! layer, which sees the service a write names. `set_time_prescaler` is
//! sendable because the spec declares it, behind its `advanced` flag; the
//! command surface asks before sending it, and no entity or group op binds it.
//!
//! Replies are not parsed here. GLOBAL_STATE is decoded by the spec's own
//! `format` (under its `format_match`), and the single-value replies have no
//! established layout, so nothing guesses at them. Nothing here has been run
//! against hardware.

use crate::error::ProtocolError;
use crate::spec::types::DeviceSpec;
use aes::cipher::{BlockCipherEncrypt, KeyInit};

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "mattel_mpid";

/// The `framing.scheme` [`bind_commands`] states on the command
/// characteristic. Not a name any spec writes.
pub const SCHEME: &str = crate::codec::types::MATTEL_MPID_SCHEME;

/// The MPID control service and its four characteristics.
pub const SERVICE_UUID: &str = "4cea0001-c678-4202-b5d3-712dbb5e5b14";
pub const TX_UUID: &str = "4cea0002-c678-4202-b5d3-712dbb5e5b14";
pub const RX_UUID: &str = "4cea0003-c678-4202-b5d3-712dbb5e5b14";
pub const TOKEN_UUID: &str = "4cea0004-c678-4202-b5d3-712dbb5e5b14";
pub const SESSION_UUID: &str = "4cea0005-c678-4202-b5d3-712dbb5e5b14";

/// Nordic legacy DFU, on the same unit. Never written: the spec reports a
/// wrong write bricks it.
pub const DFU_SERVICE_UUID: &str = "00001530-1212-efde-1523-785feabcd123";

/// The spec's `setup.methods[0].timing`.
pub const AFTER_SESSION_WRITE_MS: u32 = 400;
pub const AFTER_ENABLE_RX_MS: u32 = 300;
pub const BETWEEN_COMMANDS_MS: u32 = 150;

/// `ENABLE_RX`, the transport command sent once as frame 1.
pub const ENABLE_RX: [u8; 3] = [0x01, 0x50, 0x01];

/// REQUEST_GLOBAL_STATE's body, sent once after ENABLE_RX so a screen that
/// just connected has a state to show (the spec's setup step "optionally send
/// request_global_state").
pub const REQUEST_GLOBAL_STATE: [u8; 6] = [0x01, 0x10, 0xFE, 0x01, 0x53, 0x52];

const TOKEN_LEN: usize = 192;
const DEVICE_KEY: std::ops::Range<usize> = 25..58;
const DEVICE_SALT: std::ops::Range<usize> = 188..192;
const HEADER_LEN: usize = 8;
const MAGIC: u8 = 0x7E;
const STRETCH_ROUNDS: u32 = 100;
/// `max_plaintext`, as kvdb/gld09-control states it.
const MAX_PLAINTEXT: usize = 0x1FF;

/// Every application opcode the spec declares a command for, and nothing
/// else. `set_day_routine` / `request_day_routine` are one command each over
/// seven opcodes. A test holds this to the vendored spec.
pub const SENDABLE_OPCODES: &[u8] = &[
    0x03, 0x30, 0x31, 0x35, 0x37, 0x38, 0x3A, 0x3C, 0x3E, 0x3F, 0x40, 0x41, 0x42, 0x44, 0x46, 0x47,
    0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x52, 0x53, 0x58, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x60,
    0x61, 0x62, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6B, 0x6C, 0x77, 0x79, 0x7A, 0x7B,
];

fn invalid(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::InvalidFraming {
        reason: reason.into(),
    }
}

/// Give a Lumalou spec's command characteristic the MPID body scheme in place
/// of its `encryption` block, which nothing stateless can execute, and leave
/// the connect-time handshake to the session layer. Runs at parse time; a
/// spec naming any other handler is untouched.
pub fn bind_commands(spec: &mut DeviceSpec) {
    if spec.protocol_handler.as_deref() != Some(HANDLER_NAME) {
        return;
    }
    for service in &mut spec.services {
        if !service.uuid.eq_ignore_ascii_case(SERVICE_UUID) {
            continue;
        }
        for characteristic in &mut service.characteristics {
            if !characteristic.uuid.eq_ignore_ascii_case(TX_UUID) {
                continue;
            }
            let handshake_ctr = characteristic.encryption.as_ref().is_some_and(|block| {
                block.get("algorithm").and_then(|v| v.as_str()) == Some("aes-128-ctr")
                    && block.get("key_derivation").and_then(|v| v.as_str()) == Some("handshake")
            });
            if !handshake_ctr || characteristic.framing.is_some() {
                continue;
            }
            characteristic.encryption = None;
            let mut framing = serde_yaml::Mapping::new();
            framing.insert("scheme".into(), SCHEME.into());
            characteristic.framing = Some(serde_yaml::Value::Mapping(framing));
        }
    }
    // The token read, the session write and ENABLE_RX are the session
    // layer's, and two of them are prose a generic executor can only warn
    // about. The subscribe stays: it is what opens the session on connect.
    spec.initialization
        .retain(|step| step.subscribe && step.write.is_none() && !step.read);
}

/// [`SCHEME`] as a [`super::image_upload::FragmentScheme`]: the body as the
/// command rendered it, which is what the session layer seals. The framing
/// path runs [`check_body`] first, so a body [`seal`] would refuse is refused
/// when it is encoded.
pub fn fragment_packet(request: super::image_upload::FragmentRequest<'_>) -> Vec<Vec<u8>> {
    vec![request.packet.to_vec()]
}

/// CRC-8, polynomial 0x07, initial value 0xFF, no reflection, no final XOR.
pub fn crc8(data: &[u8]) -> u8 {
    data.iter().fold(0xFF, |mut crc, byte| {
        crc ^= byte;
        for _ in 0..8 {
            crc = if crc & 0x80 != 0 {
                (crc << 1) ^ 0x07
            } else {
                crc << 1
            };
        }
        crc
    })
}

/// AES-128-CTR over `data` in place, the whole 16-byte block counting as one
/// big-endian integer.
fn ctr(key: &[u8; 16], iv: [u8; 16], data: &mut [u8]) {
    let cipher = aes::Aes128::new(key.into());
    let mut counter = u128::from_be_bytes(iv);
    let mut pad = [0u8; 16];
    // Byte by byte rather than in 16-byte chunks: the last block is usually
    // partial, and this keeps one path for both.
    for (i, byte) in data.iter_mut().enumerate() {
        if i % 16 == 0 {
            pad = counter.to_be_bytes();
            cipher.encrypt_block((&mut pad).into());
            counter = counter.wrapping_add(1);
        }
        *byte ^= pad[i % 16];
    }
}

/// The 100-round stretch of an ECDH X coordinate into the session key.
pub fn stretch(shared_x: &[u8; 32]) -> [u8; 16] {
    let mut state = *shared_x;
    for round in 0..STRETCH_ROUNDS {
        let mut key = [0u8; 16];
        key.copy_from_slice(&state[..16]);
        let mut iv = [0u8; 16];
        iv[4..8].copy_from_slice(&round.to_be_bytes());
        iv[8..16].copy_from_slice(b"\0mattel\0");
        ctr(&key, iv, &mut state);
    }
    let mut out = [0u8; 16];
    out.copy_from_slice(&state[..16]);
    out
}

/// One connection's agreed session: everything [`seal`] and [`open`] need.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Session {
    pub key: [u8; 16],
    pub app_nonce: [u8; 4],
    pub device_salt: [u8; 4],
}

/// The device key and salt out of a factory token. The token's signature is
/// not checked: the manufacturing key that would check it is not in the
/// spec, so the session authenticates nothing about the unit.
pub fn parse_token(token: &[u8]) -> Result<(p256::PublicKey, [u8; 4]), ProtocolError> {
    if token.len() != TOKEN_LEN {
        return Err(invalid(format!(
            "an MPID factory token is {TOKEN_LEN} bytes, and this one is {}",
            token.len()
        )));
    }
    let key = p256::PublicKey::from_sec1_bytes(&token[DEVICE_KEY])
        .map_err(|_| invalid("the factory token's device key is not a P-256 point"))?;
    let mut salt = [0u8; 4];
    salt.copy_from_slice(&token[DEVICE_SALT]);
    Ok((key, salt))
}

/// Agree a session with the unit whose token was read, from the app's
/// ephemeral `secret` and `app_nonce`. Returns the session and the 37 bytes to
/// write to the session characteristic.
pub fn agree(
    token: &[u8],
    secret: &p256::SecretKey,
    app_nonce: [u8; 4],
) -> Result<(Session, Vec<u8>), ProtocolError> {
    let (device_key, device_salt) = parse_token(token)?;
    let shared = secret.diffie_hellman(&device_key);
    let mut shared_x = [0u8; 32];
    shared_x.copy_from_slice(shared.raw_secret_bytes());
    let session = Session {
        key: stretch(&shared_x),
        app_nonce,
        device_salt,
    };
    let compressed = p256::CompressedPoint::from(&secret.public_key());
    let mut write = compressed.to_vec();
    write.extend_from_slice(&app_nonce);
    Ok((session, write))
}

/// [`agree`] with a fresh ephemeral key and nonce from the OS.
pub fn start_session(token: &[u8]) -> Result<(Session, Vec<u8>), ProtocolError> {
    let random = |len: usize| -> Result<Vec<u8>, ProtocolError> {
        let mut bytes = vec![0u8; len];
        getrandom::fill(&mut bytes).map_err(|e| invalid(format!("no OS randomness: {e}")))?;
        Ok(bytes)
    };
    // A uniformly random 32 bytes is a valid scalar except with negligible
    // odds; the loop is for those odds.
    let secret = loop {
        if let Ok(secret) = p256::SecretKey::from_slice(&random(32)?) {
            break secret;
        }
    };
    let mut nonce = [0u8; 4];
    nonce.copy_from_slice(&random(4)?);
    agree(token, &secret, nonce)
}

fn iv(seq: u32, first: [u8; 4], second: [u8; 4]) -> [u8; 16] {
    let mut iv = [0u8; 16];
    iv[..4].copy_from_slice(&seq.to_be_bytes());
    iv[4..8].copy_from_slice(&first);
    iv[8..12].copy_from_slice(&second);
    iv
}

/// Whether `body` is one the spec declares, as [`seal`] decides it.
pub fn check_body(body: &[u8]) -> Result<(), ProtocolError> {
    if body == ENABLE_RX {
        return Ok(());
    }
    let [0x01, 0x10, 0xFE, n, opcode, rest @ ..] = body else {
        return Err(invalid(
            "an MPID command body is 01 10 + an FE frame, or ENABLE_RX",
        ));
    };
    let Some((checksum, args)) = rest.split_last() else {
        return Err(invalid("an MPID FE frame ends in its XOR byte"));
    };
    if usize::from(*n) != args.len() + 1 {
        return Err(invalid(format!(
            "an FE frame's length byte says {n}, and it carries {}",
            args.len() + 1
        )));
    }
    let xor = args.iter().fold(n ^ opcode, |acc, b| acc ^ b);
    if xor != *checksum {
        return Err(invalid("an FE frame's XOR byte does not match"));
    }
    if !SENDABLE_OPCODES.contains(opcode) {
        return Err(invalid(format!(
            "opcode {opcode:#04x} is not a command the spec declares"
        )));
    }
    Ok(())
}

/// One complete app-to-device frame around `body`, as frame number `seq`.
pub fn seal(session: &Session, seq: u32, body: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    check_body(body)?;
    let mut out = Vec::with_capacity(HEADER_LEN + body.len() + 1);
    out.push(MAGIC);
    out.extend_from_slice(&seq.to_be_bytes());
    out.extend_from_slice(&((body.len() + 1) as u16).to_be_bytes());
    out.push(crc8(&out));
    let start = out.len();
    out.extend_from_slice(body);
    out.push(crc8(body));
    ctr(
        &session.key,
        iv(seq, session.app_nonce, session.device_salt),
        &mut out[start..],
    );
    Ok(out)
}

/// A device-to-app frame opened: its sequence number and decrypted body,
/// without the body CRC.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Opened {
    pub seq: u32,
    pub body: Vec<u8>,
}

/// Decrypt one notification. Anything that is not a whole frame whose two
/// CRCs check is refused rather than half-read.
pub fn open(session: &Session, frame: &[u8]) -> Result<Opened, ProtocolError> {
    if frame.len() < HEADER_LEN + 1 || frame[0] != MAGIC {
        return Err(invalid("not an MPID frame"));
    }
    if crc8(&frame[..7]) != frame[7] {
        return Err(invalid("the MPID header CRC does not match"));
    }
    let seq = u32::from_be_bytes([frame[1], frame[2], frame[3], frame[4]]);
    let len = usize::from(u16::from_be_bytes([frame[5], frame[6]]));
    if len != frame.len() - HEADER_LEN || len > MAX_PLAINTEXT + 1 {
        return Err(invalid(format!(
            "the MPID header announces {len} body bytes, and {} arrived",
            frame.len() - HEADER_LEN
        )));
    }
    let mut body = frame[HEADER_LEN..].to_vec();
    ctr(
        &session.key,
        iv(seq, session.device_salt, session.app_nonce),
        &mut body,
    );
    let crc = body.pop().unwrap_or_default();
    if crc8(&body) != crc {
        return Err(invalid("the MPID body CRC does not match"));
    }
    Ok(Opened { seq, body })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn hex(text: &str) -> Vec<u8> {
        let text: String = text.split_whitespace().collect();
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
            .collect()
    }

    fn arr<const N: usize>(text: &str) -> [u8; N] {
        hex(text).try_into().unwrap()
    }

    fn vectors_session() -> Session {
        Session {
            key: arr("000102030405060708090a0b0c0d0e0f"),
            app_nonce: arr("a1a2a3a4"),
            device_salt: arr("b1b2b3b4"),
        }
    }

    /// A token carrying `device_key` and `salt`, the rest zero.
    fn token_with(device_key: &[u8], salt: [u8; 4]) -> Vec<u8> {
        let mut token = vec![0u8; TOKEN_LEN];
        token[DEVICE_KEY].copy_from_slice(device_key);
        token[DEVICE_SALT].copy_from_slice(&salt);
        token
    }

    #[test]
    fn crc8_check_value() {
        assert_eq!(crc8(b"123456789"), 0xFB);
    }

    #[test]
    fn stretch_only_vector() {
        let shared: [u8; 32] =
            arr("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f");
        assert_eq!(stretch(&shared), arr("f579f3d6caee3e91f5f9c606e3b4ddcd"));
    }

    /// `test_vectors.key_agreement`, both sides: the session write the app
    /// sends, and the key both ends derive.
    #[test]
    fn key_agreement_vector() {
        let app = p256::SecretKey::from_slice(&[0x11; 32]).unwrap();
        let device = p256::SecretKey::from_slice(&[0x22; 32]).unwrap();
        let device_public = p256::CompressedPoint::from(&device.public_key());
        assert_eq!(
            device_public.to_vec(),
            hex("03d65a93977caa3d1b081852ff57a79e465f1660577304baead505dd3a48589cf3")
        );
        let shared = app.diffie_hellman(&device.public_key());
        assert_eq!(
            shared.raw_secret_bytes().to_vec(),
            hex("ccfc261f58193c98ca4ad4a53bbac6f0ee29bc4d48438090446908622ca79af6")
        );

        let token = token_with(&device_public, arr("b1b2b3b4"));
        let (session, write) = agree(&token, &app, arr("a1a2a3a4")).unwrap();
        assert_eq!(
            write,
            hex("020217e617f0b6443928278f96999e69a23a4f2c152bdf6d6cdf66e5b80282d4eda1a2a3a4")
        );
        assert_eq!(session.key, arr("ac0ee25389a81249cae457666d29215a"));
        assert_eq!(session.device_salt, arr("b1b2b3b4"));
    }

    #[test]
    fn transmit_frame_vectors() {
        let session = vectors_session();
        assert_eq!(
            seal(&session, 1, &ENABLE_RX).unwrap(),
            hex("7e00000001000422f9b2b8ef")
        );
        assert_eq!(
            seal(&session, 2, &hex("0110fe023c043a")).unwrap(),
            hex("7e000000020008bbaeb6896dfb1ccf32")
        );
        assert_eq!(
            seal(&session, 3, &REQUEST_GLOBAL_STATE).unwrap(),
            hex("7e000000030007fde608ee08e41b7e")
        );
    }

    #[test]
    fn receive_frame_vector() {
        let opened = open(
            &vectors_session(),
            &hex("7e00000009001403bf980718dc58e7163ac5d6be2ce1b042be802fed"),
        )
        .unwrap();
        assert_eq!(opened.seq, 9);
        assert_eq!(opened.body, hex("0150fe0e020110345164001002131010451048"));
    }

    /// The receive IV is the mirror of the transmit one: a frame sealed for
    /// the device does not open as one from it. (This one happens to pass
    /// the one-byte CRC under the wrong IV, a 1-in-256 chance, so the test
    /// asks about the body rather than the CRC.)
    #[test]
    fn the_two_directions_use_different_ivs() {
        let session = vectors_session();
        let body = hex("0110fe023c043a");
        let sealed = seal(&session, 2, &body).unwrap();
        if let Ok(opened) = open(&session, &sealed) {
            assert_ne!(opened.body, body);
        }
    }

    #[test]
    fn a_damaged_or_short_frame_does_not_open() {
        let session = vectors_session();
        let good = hex("7e00000009001403bf980718dc58e7163ac5d6be2ce1b042be802fed");
        for i in 0..good.len() {
            let mut bad = good.clone();
            bad[i] ^= 0x01;
            assert!(open(&session, &bad).is_err(), "flipped byte {i}");
        }
        assert!(open(&session, &good[..good.len() - 1]).is_err());
        assert!(open(&session, &[]).is_err());
        assert!(open(&session, &[0x7E; 8]).is_err());
        let mut wrong_key = session.clone();
        wrong_key.key[0] ^= 1;
        assert!(open(&wrong_key, &good).is_err());
    }

    #[test]
    fn a_token_must_be_whole_and_carry_a_point() {
        assert!(parse_token(&[0u8; 191]).is_err());
        assert!(parse_token(&[0u8; 193]).is_err());
        // Zeros where the key should be are no point at all.
        assert!(parse_token(&[0u8; TOKEN_LEN]).is_err());
        let device = p256::SecretKey::from_slice(&[0x22; 32]).unwrap();
        let point = p256::CompressedPoint::from(&device.public_key());
        let (_, salt) = parse_token(&token_with(&point, [1, 2, 3, 4])).unwrap();
        assert_eq!(salt, [1, 2, 3, 4]);
    }

    #[test]
    fn a_fresh_session_writes_a_compressed_key_and_a_nonce() {
        let device = p256::SecretKey::from_slice(&[0x22; 32]).unwrap();
        let point = p256::CompressedPoint::from(&device.public_key());
        let token = token_with(&point, [9, 9, 9, 9]);
        let (first, write) = start_session(&token).unwrap();
        assert_eq!(write.len(), 37);
        assert!(write[0] == 0x02 || write[0] == 0x03);
        // The device, holding its own secret, derives the same key.
        let app_public = p256::PublicKey::from_sec1_bytes(&write[..33]).unwrap();
        let mut shared_x = [0u8; 32];
        shared_x.copy_from_slice(device.diffie_hellman(&app_public).raw_secret_bytes());
        assert_eq!(stretch(&shared_x), first.key);
        assert_eq!(first.app_nonce[..], write[33..]);
        let (second, _) = start_session(&token).unwrap();
        assert_ne!(first.key, second.key, "a session key must be ephemeral");
    }

    /// Only declared bodies are sealed: the pairing-complete message, an
    /// unpublished opcode and a body with a bad XOR or length are refused.
    #[test]
    fn seal_refuses_what_the_spec_does_not_declare() {
        let session = vectors_session();
        let fe = |opcode: u8, args: &[u8]| {
            let n = args.len() as u8 + 1;
            let mut body = vec![0x01, 0x10, 0xFE, n, opcode];
            body.extend_from_slice(args);
            body.push(args.iter().fold(n ^ opcode, |a, b| a ^ b));
            body
        };
        // SEND_PAIRING_COMPLETE, SET_GLOBAL_STATE, SET_NAP_TIME_ALARM, and an
        // opcode nobody has named.
        for opcode in [0x34, 0x01, 0x4F, 0xA0] {
            assert!(seal(&session, 1, &fe(opcode, &[0])).is_err(), "{opcode:#x}");
        }
        assert!(seal(&session, 1, &fe(0x3C, &[4])).is_ok());
        let mut bad_xor = fe(0x3C, &[4]);
        *bad_xor.last_mut().unwrap() ^= 1;
        assert!(seal(&session, 1, &bad_xor).is_err());
        let mut bad_len = fe(0x3C, &[4]);
        bad_len[3] = 5;
        assert!(seal(&session, 1, &bad_len).is_err());
        assert!(seal(&session, 1, &[0x01, 0x50, 0x02]).is_err());
        assert!(seal(&session, 1, &[]).is_err());
    }

    fn vendored() -> DeviceSpec {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../vendor/protocol-specs/device-specs/devices/fisher-price-lumalou.yaml"
        );
        parse_device_spec(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    /// [`SENDABLE_OPCODES`] is exactly the opcodes of the spec's commands:
    /// fixed bodies, templates with a literal opcode, and the day-routine
    /// commands' `allowed` opcodes.
    #[test]
    fn sendable_opcodes_are_the_specs_commands() {
        use crate::spec::types::TemplateElement;
        let spec = vendored();
        let tx = spec
            .services
            .iter()
            .flat_map(|s| &s.characteristics)
            .find(|c| c.uuid == TX_UUID)
            .unwrap();
        let mut declared = Vec::new();
        for (name, command) in tx.commands.as_ref().unwrap() {
            if let Some(value) = &command.value {
                if value[..] != ENABLE_RX {
                    declared.push(value[4]);
                }
                continue;
            }
            match &command.template.as_ref().unwrap()[4] {
                TemplateElement::Byte(op) => declared.push(*op),
                TemplateElement::Param(param) => {
                    let def = &command.parameters.as_ref().unwrap().params[param.as_str()];
                    let allowed = def.allowed.as_ref().unwrap_or_else(|| panic!("{name}"));
                    declared.extend(allowed.iter().map(|v| *v as u8));
                }
            }
        }
        declared.sort_unstable();
        declared.dedup();
        assert_eq!(declared, SENDABLE_OPCODES);
        assert!(!declared.contains(&0x34));
    }

    #[test]
    fn binding_states_the_scheme_and_leaves_the_subscribe() {
        let spec = vendored();
        let tx = spec.services[0]
            .characteristics
            .iter()
            .find(|c| c.uuid == TX_UUID)
            .unwrap();
        assert!(tx.encryption.is_none());
        assert_eq!(
            crate::codec::types::framing_scheme_name(tx).as_deref(),
            Some(SCHEME)
        );
        assert_eq!(spec.initialization.len(), 1);
        assert!(spec.initialization[0].subscribe);
        assert_eq!(spec.initialization[0].characteristic, RX_UUID);
    }
}

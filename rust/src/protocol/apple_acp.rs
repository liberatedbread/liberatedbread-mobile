// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Read an Apple AirPort base station's status over ACP (TCP 5009), from its
//! spec (`apple-airport-acp.yaml`, handler `apple_acp`). READ-ONLY.
//!
//! The spec's `protocol_details.acp` states the wire: a 128-byte header
//! (magic `acpp`, version, Adler-32 of header and body, flags, command,
//! error code, a 32-byte key field), a body of property elements or a CFB0
//! plist, SRP-6a (SHA-1, RFC 5054's 1536-bit group) as user `admin`, and
//! then AES-128-CTR over everything both ways, with keys from PBKDF2.
//!
//! What this module can put on the wire is fixed: the AUTHENTICATE stage-1
//! and stage-3 messages and one GET_PROPERTY of five status properties. The
//! message builder is private and takes no command or property from a
//! caller; SET_PROPERTY (which is also how a base station is rebooted or
//! reset) is not a command this module knows outside its tests.
//!
//! Legacy mode, which puts a reversible form of the admin password in every
//! header (the spec's security advisory), is not implemented for sending.
//! The legacy key exists only in the tests, to reproduce the spec's example
//! frames.
//!
//! What the spec could not vector: SRP, M1/M2 and the session keystream are
//! transcribed from node-acp's client and checked here against RFC 5054's
//! group arithmetic, RFC 6070's PBKDF2 and the spec's invented PBKDF2
//! example; the M1/M2 composition and the exact counter handling have no
//! vector and have not met a real base station.
//!
//! Nothing here opens a socket.

use aes::cipher::{BlockCipherEncrypt, KeyInit};
use aes::Aes128;
use num_bigint::BigUint;
use sha1::{Digest, Sha1};

use crate::error::ProtocolError;

/// The spec `protocol_handler` this module answers to.
pub const HANDLER_NAME: &str = "apple_acp";

/// `identification.default_port`.
pub const PORT: u16 = 5009;

pub const HEADER_LEN: usize = 128;
const MAGIC: &[u8; 4] = b"acpp";
const VERSION: u32 = 0x0003_0001;
/// Accepted on replies by both community parsers.
const VERSION_OLD: u32 = 0x0000_0001;

const GET_PROPERTY: u32 = 0x14;
const AUTHENTICATE: u32 = 0x1A;

/// Flags the clients put on GET_PROPERTY and AUTHENTICATE requests.
const FLAGS_READ: u32 = 4;

/// `key_field.keystream`'s static key.
const STATIC_KEY: [u8; 16] = [
    0x5b, 0x6f, 0xaf, 0x5d, 0x9d, 0x5b, 0x0e, 0x13, 0x51, 0xf2, 0xda, 0x1d, 0xe7, 0xe8, 0xd6, 0x73,
];

/// The properties [`status_request`] reads: name, firmware version, product
/// id, uptime and Wi-Fi network name (`commands.get_status`).
pub const STATUS_PROPERTIES: [&[u8; 4]; 5] = [b"syNm", b"syVs", b"syAP", b"syUT", b"raNm"];

/// `error_codes`: incorrect password.
pub const ERROR_WRONG_PASSWORD: i32 = -6754;

/// The SRP user name ACP uses.
const SRP_USER: &str = "admin";

/// RFC 5054 appendix A, the 1536-bit group; generator 2.
const N_1536_HEX: &str = concat!(
    "9DEF3CAFB939277AB1F12A8617A47BBBDBA51DF499AC4C80BEEEA961",
    "4B19CC4D5F4F5F556E27CBDE51C6A94BE4607A291558903BA0D0F843",
    "80B655BB9A22E8DCDF028A7CEC67F0D08134B1C8B97989149B609E0B",
    "E3BAB63D47548381DBC5B1FC764E3F4B53DD9DA1158BFD3E2B9C8CF5",
    "6EDF019539349627DB2FD53D24B7C48665772E437D6C7F8CE442734A",
    "F7CCB7AE837C264AE3A9BEB87F8A2FE9B8B5292E5A021FFF5E91479E",
    "8CE7A28C2442C6F315180F93499A234DCF76E3FED135F9BB"
);
const N_LEN: usize = 192;

/// `session_encryption`'s PBKDF2 salts and iteration counts.
const CLIENT_KEY_SALT: [u8; 16] = [
    0xF0, 0x72, 0xFA, 0x3F, 0x66, 0xB4, 0x10, 0xA1, 0x35, 0xFA, 0xE8, 0xE6, 0xD1, 0xD4, 0x3D, 0x5F,
];
const SERVER_KEY_SALT: [u8; 16] = [
    0xBD, 0x06, 0x82, 0xC9, 0xFE, 0x79, 0x32, 0x5B, 0xC7, 0x36, 0x55, 0xF4, 0x17, 0x4B, 0x99, 0x6C,
];
const CLIENT_KEY_ITERATIONS: u32 = 5;
const SERVER_KEY_ITERATIONS: u32 = 7;

/// Bounds on what a reply may make this buffer.
const MAX_ELEMENT_LEN: usize = 64 * 1024;
const MAX_REPLY_LEN: usize = 1024 * 1024;
const MAX_PLIST_DEPTH: usize = 16;

fn malformed(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::MalformedReply(format!("ACP: {}", reason.into()))
}

// ── Header ──────────────────────────────────────────────────────────────────

/// zlib's Adler-32.
pub fn adler32(data: &[u8]) -> u32 {
    const MOD: u32 = 65521;
    let (mut a, mut b) = (1u32, 0u32);
    for chunk in data.chunks(5552) {
        for byte in chunk {
            a += u32::from(*byte);
            b += a;
        }
        a %= MOD;
        b %= MOD;
    }
    (b << 16) | a
}

/// Byte `i` of the fixed header keystream.
fn keystream_byte(i: usize) -> u8 {
    ((i + 0x55) & 0xFF) as u8 ^ STATIC_KEY[i % 16]
}

/// The key AUTHENTICATE always carries: the empty password's, which is the
/// first 32 keystream bytes themselves.
fn unauthenticated_key() -> [u8; 32] {
    std::array::from_fn(keystream_byte)
}

/// One message. Private: every caller below fixes its command.
fn message(command: u32, flags: u32, body: Option<&[u8]>, key: &[u8; 32]) -> Vec<u8> {
    let mut h = [0u8; HEADER_LEN];
    h[0..4].copy_from_slice(MAGIC);
    h[4..8].copy_from_slice(&VERSION.to_be_bytes());
    let (checksum, size) = match body {
        Some(body) => (adler32(body), body.len() as i32),
        None => (1, -1),
    };
    h[12..16].copy_from_slice(&checksum.to_be_bytes());
    h[16..20].copy_from_slice(&size.to_be_bytes());
    h[20..24].copy_from_slice(&flags.to_be_bytes());
    h[28..32].copy_from_slice(&command.to_be_bytes());
    h[48..80].copy_from_slice(key);
    let header_checksum = adler32(&h);
    h[8..12].copy_from_slice(&header_checksum.to_be_bytes());
    let mut out = h.to_vec();
    out.extend_from_slice(body.unwrap_or_default());
    out
}

/// A received header.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AcpHeader {
    pub version: u32,
    pub body_checksum: u32,
    /// -1 when no body follows.
    pub body_size: i32,
    pub flags: u32,
    pub command: u32,
    pub error_code: i32,
}

fn be32(bytes: &[u8], at: usize) -> u32 {
    u32::from_be_bytes([bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3]])
}

/// Read and check a header: magic, a version either parser accepts, and the
/// header's own Adler-32.
pub fn decode_header(bytes: &[u8]) -> Result<AcpHeader, ProtocolError> {
    if bytes.len() < HEADER_LEN {
        return Err(ProtocolError::BufferTooShort {
            needed: HEADER_LEN,
            got: bytes.len(),
        });
    }
    let h = &bytes[..HEADER_LEN];
    if &h[0..4] != MAGIC {
        return Err(malformed("not an ACP header (no acpp magic)"));
    }
    let version = be32(h, 4);
    if version != VERSION && version != VERSION_OLD {
        return Err(malformed(format!("unknown version {version:#010x}")));
    }
    let mut zeroed = [0u8; HEADER_LEN];
    zeroed.copy_from_slice(h);
    zeroed[8..12].fill(0);
    if adler32(&zeroed) != be32(h, 8) {
        return Err(malformed("header checksum does not match"));
    }
    Ok(AcpHeader {
        version,
        body_checksum: be32(h, 12),
        body_size: be32(h, 16) as i32,
        flags: be32(h, 20),
        command: be32(h, 28),
        error_code: be32(h, 32) as i32,
    })
}

/// What an error code means (`error_codes`).
pub fn error_meaning(code: i32) -> &'static str {
    match code {
        0 => "success",
        -10 => "property not available on this unit",
        -16 => "invalid key",
        ERROR_WRONG_PASSWORD => "incorrect password",
        _ => "an error code the spec does not explain",
    }
}

// ── CFB0 plists ─────────────────────────────────────────────────────────────

/// A CFB0 object, as far as the spec's markers go.
#[derive(Debug, Clone, PartialEq)]
pub enum Cfb {
    Bool(bool),
    Int(u64),
    Real(f64),
    Data(Vec<u8>),
    Str(String),
    Array(Vec<Cfb>),
    /// Key, value pairs in wire order.
    Dict(Vec<(Cfb, Cfb)>),
}

impl Cfb {
    /// A dict member by string key.
    pub fn get(&self, key: &str) -> Option<&Cfb> {
        match self {
            Cfb::Dict(members) => members
                .iter()
                .find(|(k, _)| matches!(k, Cfb::Str(s) if s == key))
                .map(|(_, v)| v),
            _ => None,
        }
    }

    fn data(&self) -> Option<&[u8]> {
        match self {
            Cfb::Data(d) => Some(d),
            _ => None,
        }
    }
}

fn encode_int(value: u64, out: &mut Vec<u8>) {
    let (n, width) = match value {
        0..=0xFF => (0, 1),
        0x100..=0xFFFF => (1, 2),
        0x1_0000..=0xFFFF_FFFF => (2, 4),
        _ => (3, 8),
    };
    out.push(0x10 | n);
    out.extend_from_slice(&value.to_be_bytes()[8 - width..]);
}

fn encode_object(object: &Cfb, out: &mut Vec<u8>) {
    match object {
        Cfb::Bool(b) => out.push(if *b { 0x09 } else { 0x08 }),
        Cfb::Int(i) => encode_int(*i, out),
        Cfb::Real(r) => {
            out.push(0x23);
            out.extend_from_slice(&r.to_be_bytes());
        }
        Cfb::Data(d) => {
            if d.len() < 15 {
                out.push(0x40 | d.len() as u8);
            } else {
                out.push(0x4F);
                encode_int(d.len() as u64, out);
            }
            out.extend_from_slice(d);
        }
        Cfb::Str(s) => {
            out.push(0x70);
            out.extend_from_slice(s.as_bytes());
            out.push(0);
        }
        Cfb::Array(items) => {
            out.push(0xA0);
            for item in items {
                encode_object(item, out);
            }
            out.push(0);
        }
        Cfb::Dict(members) => {
            out.push(0xD0);
            for (k, v) in members {
                encode_object(k, out);
                encode_object(v, out);
            }
            out.push(0);
        }
    }
}

/// `CFB0`, one root object, `END!`.
pub fn encode_plist(root: &Cfb) -> Vec<u8> {
    let mut out = b"CFB0".to_vec();
    encode_object(root, &mut out);
    out.extend_from_slice(b"END!");
    out
}

struct PlistReader<'a> {
    bytes: &'a [u8],
    at: usize,
}

impl PlistReader<'_> {
    fn byte(&mut self) -> Result<u8, ProtocolError> {
        let b = *self
            .bytes
            .get(self.at)
            .ok_or_else(|| malformed("plist truncated"))?;
        self.at += 1;
        Ok(b)
    }

    fn take(&mut self, n: usize) -> Result<&[u8], ProtocolError> {
        let end = self
            .at
            .checked_add(n)
            .filter(|end| *end <= self.bytes.len())
            .ok_or_else(|| malformed("plist truncated"))?;
        let slice = &self.bytes[self.at..end];
        self.at = end;
        Ok(slice)
    }

    /// One object; `None` for the 0x00 terminator.
    fn object(&mut self, depth: usize) -> Result<Option<Cfb>, ProtocolError> {
        if depth > MAX_PLIST_DEPTH {
            return Err(malformed("plist nested too deep"));
        }
        let marker = self.byte()?;
        let (kind, info) = (marker >> 4, marker & 0x0F);
        Ok(Some(match (kind, info) {
            (0, 0) => return Ok(None),
            (0, 8) => Cfb::Bool(false),
            (0, 9) => Cfb::Bool(true),
            (1, n @ 0..=3) => {
                let width = 1usize << n;
                let raw = self.take(width)?;
                Cfb::Int(raw.iter().fold(0u64, |acc, b| (acc << 8) | u64::from(*b)))
            }
            (2, 2) => {
                let raw = self.take(4)?;
                Cfb::Real(f64::from(f32::from_be_bytes([
                    raw[0], raw[1], raw[2], raw[3],
                ])))
            }
            (2, 3) => {
                let raw = self.take(8)?;
                Cfb::Real(f64::from_be_bytes(raw.try_into().unwrap_or_default()))
            }
            (4, n) => {
                let length = if n == 0x0F {
                    match self.object(depth + 1)? {
                        Some(Cfb::Int(len)) if (len as usize) <= MAX_REPLY_LEN => len as usize,
                        _ => return Err(malformed("bad data length")),
                    }
                } else {
                    usize::from(n)
                };
                Cfb::Data(self.take(length)?.to_vec())
            }
            (7, 0) => {
                let rest = &self.bytes[self.at..];
                let end = rest
                    .iter()
                    .position(|b| *b == 0)
                    .ok_or_else(|| malformed("unterminated string"))?;
                let text = std::str::from_utf8(&rest[..end])
                    .map_err(|_| malformed("string is not UTF-8"))?
                    .to_string();
                self.at += end + 1;
                Cfb::Str(text)
            }
            (0xA, 0) => {
                let mut items = Vec::new();
                while let Some(item) = self.object(depth + 1)? {
                    items.push(item);
                }
                Cfb::Array(items)
            }
            (0xD, 0) => {
                let mut members = Vec::new();
                while let Some(key) = self.object(depth + 1)? {
                    let value = self
                        .object(depth + 1)?
                        .ok_or_else(|| malformed("dict key without a value"))?;
                    members.push((key, value));
                }
                Cfb::Dict(members)
            }
            _ => {
                return Err(malformed(format!(
                    "plist marker {marker:#04x} not supported"
                )))
            }
        }))
    }
}

/// Read a CFB0 plist.
pub fn decode_plist(bytes: &[u8]) -> Result<Cfb, ProtocolError> {
    let inner = bytes
        .strip_prefix(b"CFB0")
        .and_then(|b| b.strip_suffix(b"END!"))
        .ok_or_else(|| malformed("not a CFB0 plist"))?;
    let mut reader = PlistReader {
        bytes: inner,
        at: 0,
    };
    let root = reader.object(0)?.ok_or_else(|| malformed("empty plist"))?;
    if reader.at != inner.len() {
        return Err(malformed("trailing bytes after the plist's root"));
    }
    Ok(root)
}

fn str_key(key: &str) -> Cfb {
    Cfb::Str(key.to_string())
}

// ── The three messages this module sends ────────────────────────────────────

/// SRP stage 1 (`commands.authenticate_start`).
pub fn auth_start_message() -> Vec<u8> {
    let body = encode_plist(&Cfb::Dict(vec![
        (str_key("state"), Cfb::Int(1)),
        (str_key("username"), Cfb::Str(SRP_USER.to_string())),
    ]));
    message(
        AUTHENTICATE,
        FLAGS_READ,
        Some(&body),
        &unauthenticated_key(),
    )
}

fn property_request_element(name: &[u8; 4]) -> [u8; 16] {
    let mut e = [0u8; 16];
    e[..4].copy_from_slice(name);
    e[8..12].copy_from_slice(&4u32.to_be_bytes());
    e
}

/// GET_PROPERTY of [`STATUS_PROPERTIES`] (`commands.get_status`), with the
/// all-zero key field a session after SRP carries. Plaintext: the caller
/// encrypts it with the client keystream.
pub fn status_request() -> Vec<u8> {
    let body: Vec<u8> = STATUS_PROPERTIES
        .iter()
        .flat_map(|name| property_request_element(name))
        .collect();
    message(GET_PROPERTY, FLAGS_READ, Some(&body), &[0u8; 32])
}

// ── SRP-6a ──────────────────────────────────────────────────────────────────

fn sha1(parts: &[&[u8]]) -> [u8; 20] {
    let mut h = Sha1::new();
    for part in parts {
        h.update(part);
    }
    h.finalize().into()
}

fn n_1536() -> BigUint {
    BigUint::parse_bytes(N_1536_HEX.as_bytes(), 16).expect("the RFC 5054 group parses")
}

fn pad(value: &BigUint, len: usize) -> Vec<u8> {
    let bytes = value.to_bytes_be();
    let mut out = vec![0; len.saturating_sub(bytes.len())];
    out.extend_from_slice(&bytes);
    out
}

/// The SRP-6a client values, generic over the group so RFC 5054's 1024-bit
/// vectors can check the arithmetic: `(A, S)` for private `a`.
fn srp_premaster(
    n: &BigUint,
    n_len: usize,
    salt: &[u8],
    user: &str,
    password: &[u8],
    a: &BigUint,
    b_pub: &BigUint,
) -> Result<(BigUint, BigUint), ProtocolError> {
    let g = BigUint::from(2u8);
    if (b_pub % n) == BigUint::ZERO {
        return Err(malformed("the base station's public value is zero mod N"));
    }
    let k = BigUint::from_bytes_be(&sha1(&[&pad(n, n_len), &pad(&g, n_len)]));
    let inner = sha1(&[user.as_bytes(), b":", password]);
    let x = BigUint::from_bytes_be(&sha1(&[salt, &inner]));
    let a_pub = g.modpow(a, n);
    let u = BigUint::from_bytes_be(&sha1(&[&pad(&a_pub, n_len), &pad(b_pub, n_len)]));
    if u == BigUint::ZERO {
        return Err(malformed("SRP scrambler is zero"));
    }
    let gx = g.modpow(&x, n);
    let kgx = (k * gx) % n;
    let base = ((b_pub % n) + n - kgx) % n;
    let s = base.modpow(&(a + u * x), n);
    Ok((a_pub, s))
}

/// The base station's stage-1 answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SrpChallenge {
    pub salt: Vec<u8>,
    pub b_pub: Vec<u8>,
}

/// Read the stage-1 reply body. Refuses a group other than RFC 5054's 1536-bit
/// one with generator 2: the spec names that group, and a base station
/// offering a weaker one is not one this app will authenticate to.
pub fn parse_challenge(body: &[u8]) -> Result<SrpChallenge, ProtocolError> {
    let plist = decode_plist(body)?;
    let field = |key: &str| {
        plist
            .get(key)
            .and_then(Cfb::data)
            .ok_or_else(|| malformed(format!("stage-1 reply has no {key}")))
    };
    let salt = field("salt")?;
    let generator = field("generator")?;
    let b_pub = field("publicKey")?;
    let modulus = field("modulus")?;
    if BigUint::from_bytes_be(modulus) != n_1536()
        || BigUint::from_bytes_be(generator) != 2u8.into()
    {
        return Err(malformed(
            "the base station offered an SRP group other than the spec's 1536-bit one",
        ));
    }
    if salt.len() != 16 || b_pub.len() != N_LEN {
        return Err(malformed(
            "stage-1 salt or public value has the wrong length",
        ));
    }
    Ok(SrpChallenge {
        salt: salt.to_vec(),
        b_pub: b_pub.to_vec(),
    })
}

/// Stage 3, built: the message to send, and what the base station must
/// answer.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SrpStage3 {
    pub message: Vec<u8>,
    pub expected_m2: [u8; 20],
    pub session_key: [u8; 20],
}

/// Compute A, M1 and K for `password` and build the stage-3 message.
/// `a_private` is the caller's random 24 bytes (node-acp's size);
/// `client_iv` its random 16.
pub fn srp_stage3(
    challenge: &SrpChallenge,
    password: &str,
    a_private: &[u8],
    client_iv: &[u8; 16],
) -> Result<SrpStage3, ProtocolError> {
    if a_private.len() != 24 || a_private.iter().all(|b| *b == 0) {
        return Err(malformed("the SRP private value must be 24 random bytes"));
    }
    let n = n_1536();
    let b_pub = BigUint::from_bytes_be(&challenge.b_pub);
    let a = BigUint::from_bytes_be(a_private);
    let (a_pub, s) = srp_premaster(
        &n,
        N_LEN,
        &challenge.salt,
        SRP_USER,
        password.as_bytes(),
        &a,
        &b_pub,
    )?;
    let a_bytes = pad(&a_pub, N_LEN);
    let b_bytes = pad(&b_pub, N_LEN);
    let k = sha1(&[&pad(&s, N_LEN)]);
    let hn = sha1(&[&pad(&n, N_LEN)]);
    let hg = sha1(&[&[2u8]]);
    let xor: Vec<u8> = hn.iter().zip(hg.iter()).map(|(a, b)| a ^ b).collect();
    let m1 = sha1(&[
        &xor,
        &sha1(&[SRP_USER.as_bytes()]),
        &challenge.salt,
        &a_bytes,
        &b_bytes,
        &k,
    ]);
    let m2 = sha1(&[&a_bytes, &m1, &k]);
    let body = encode_plist(&Cfb::Dict(vec![
        (str_key("iv"), Cfb::Data(client_iv.to_vec())),
        (str_key("publicKey"), Cfb::Data(a_bytes)),
        (str_key("state"), Cfb::Int(3)),
        (str_key("response"), Cfb::Data(m1.to_vec())),
    ]));
    Ok(SrpStage3 {
        message: message(
            AUTHENTICATE,
            FLAGS_READ,
            Some(&body),
            &unauthenticated_key(),
        ),
        expected_m2: m2,
        session_key: k,
    })
}

/// Why an AUTHENTICATE reply was not success.
fn auth_refusal(header: &AcpHeader) -> ProtocolError {
    if header.error_code == ERROR_WRONG_PASSWORD {
        ProtocolError::MalformedReply("the base station password is incorrect".to_string())
    } else {
        malformed(format!(
            "the base station refused authentication ({}: {})",
            header.error_code,
            error_meaning(header.error_code)
        ))
    }
}

/// Check an AUTHENTICATE reply's header and body: right command, success,
/// body checksum.
pub fn check_auth_reply(header: &AcpHeader, body: &[u8]) -> Result<(), ProtocolError> {
    if header.command != AUTHENTICATE {
        return Err(malformed("the reply is not to AUTHENTICATE"));
    }
    if header.error_code != 0 {
        return Err(auth_refusal(header));
    }
    if adler32(body) != header.body_checksum {
        return Err(malformed("body checksum does not match"));
    }
    Ok(())
}

/// The session's two keystreams.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SessionKeys {
    pub client_key: [u8; 16],
    pub client_iv: [u8; 16],
    pub server_key: [u8; 16],
    pub server_iv: [u8; 16],
}

/// Verify the stage-3 reply's M2 and derive the session keys.
pub fn finish_auth(
    stage3_body: &[u8],
    stage3: &SrpStage3,
    client_iv: &[u8; 16],
) -> Result<SessionKeys, ProtocolError> {
    let plist = decode_plist(stage3_body)?;
    let m2 = plist
        .get("response")
        .and_then(Cfb::data)
        .ok_or_else(|| malformed("stage-3 reply has no response"))?;
    if m2 != stage3.expected_m2 {
        return Err(malformed(
            "the base station's proof does not match: it does not know this password, \
             or it is not the base station",
        ));
    }
    let server_iv: [u8; 16] = plist
        .get("iv")
        .and_then(Cfb::data)
        .and_then(|iv| iv.try_into().ok())
        .ok_or_else(|| malformed("stage-3 reply has no 16-byte iv"))?;
    let (client_key, server_key) = session_keys(&stage3.session_key);
    Ok(SessionKeys {
        client_key,
        client_iv: *client_iv,
        server_key,
        server_iv,
    })
}

// ── Session encryption ──────────────────────────────────────────────────────

fn hmac_sha1(key: &[u8], message: &[&[u8]]) -> [u8; 20] {
    let mut block = [0u8; 64];
    if key.len() > 64 {
        block[..20].copy_from_slice(&sha1(&[key]));
    } else {
        block[..key.len()].copy_from_slice(key);
    }
    let ipad: Vec<u8> = block.iter().map(|b| b ^ 0x36).collect();
    let opad: Vec<u8> = block.iter().map(|b| b ^ 0x5c).collect();
    let mut inner = Sha1::new();
    inner.update(&ipad);
    for part in message {
        inner.update(part);
    }
    let inner: [u8; 20] = inner.finalize().into();
    sha1(&[&opad, &inner])
}

/// PBKDF2-HMAC-SHA1 (RFC 8018), `len` bytes.
pub fn pbkdf2_sha1(password: &[u8], salt: &[u8], iterations: u32, len: usize) -> Vec<u8> {
    let mut out = Vec::with_capacity(len);
    let mut block_index = 1u32;
    while out.len() < len {
        let mut u = hmac_sha1(password, &[salt, &block_index.to_be_bytes()]);
        let mut t = u;
        for _ in 1..iterations {
            u = hmac_sha1(password, &[&u]);
            t.iter_mut().zip(u.iter()).for_each(|(t, u)| *t ^= u);
        }
        out.extend_from_slice(&t);
        block_index += 1;
    }
    out.truncate(len);
    out
}

/// `(client key, server key)` from the SRP session key.
pub fn session_keys(k: &[u8]) -> ([u8; 16], [u8; 16]) {
    let derive = |salt: &[u8], iterations| {
        let mut key = [0u8; 16];
        key.copy_from_slice(&pbkdf2_sha1(k, salt, iterations, 16));
        key
    };
    (
        derive(&CLIENT_KEY_SALT, CLIENT_KEY_ITERATIONS),
        derive(&SERVER_KEY_SALT, SERVER_KEY_ITERATIONS),
    )
}

/// AES-128-CTR over `data`, which starts `offset` bytes into the stream that
/// began at `iv`. The counter is the whole 16-byte block as a big-endian
/// integer, as Node's `aes-128-ctr` steps it. Stateless, so the caller keeps
/// one offset per direction for the life of the connection.
pub fn ctr_apply(key: &[u8; 16], iv: &[u8; 16], offset: u64, data: &[u8]) -> Vec<u8> {
    let cipher = Aes128::new(key.into());
    let start = u128::from_be_bytes(*iv);
    let mut out = Vec::with_capacity(data.len());
    for (position, byte) in (offset..).zip(data) {
        let block_index = position / 16;
        let mut block = start
            .wrapping_add(u128::from(block_index))
            .to_be_bytes()
            .into();
        cipher.encrypt_block(&mut block);
        out.push(byte ^ block[(position % 16) as usize]);
    }
    out
}

// ── Property replies ────────────────────────────────────────────────────────

/// One property element of a reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PropertyElement {
    pub name: [u8; 4],
    /// The 4-byte signed error code, when flags bit 0 is set.
    pub error: Option<i32>,
    pub value: Vec<u8>,
}

/// Read elements from the body bytes so far. `Ok(None)` means more are
/// needed; `Ok(Some(elements))` that the end marker was reached.
pub fn feed_property_list(body: &[u8]) -> Result<Option<Vec<PropertyElement>>, ProtocolError> {
    if body.len() > MAX_REPLY_LEN {
        return Err(malformed("the property reply is too long"));
    }
    let mut elements = Vec::new();
    let mut at = 0;
    loop {
        let Some(head) = body.get(at..at + 12) else {
            return Ok(None);
        };
        let name: [u8; 4] = head[..4].try_into().unwrap_or_default();
        let flags = be32(head, 4);
        let size = be32(head, 8) as usize;
        if size > MAX_ELEMENT_LEN {
            return Err(malformed("a property element is too long"));
        }
        let Some(value) = body.get(at + 12..at + 12 + size) else {
            return Ok(None);
        };
        at += 12 + size;
        if name == [0; 4] && size == 4 && value == [0; 4] {
            return Ok(Some(elements));
        }
        let error = if flags & 1 == 1 {
            if size != 4 {
                return Err(malformed("an error element without a 4-byte code"));
            }
            Some(be32(value, 0) as i32)
        } else {
            None
        };
        elements.push(PropertyElement {
            name,
            error,
            value: value.to_vec(),
        });
    }
}

/// What a status read says.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct AcpStatusDto {
    pub name: Option<String>,
    pub firmware: Option<String>,
    pub product_id: Option<u32>,
    /// The model, for the two product ids the spec names.
    pub product_name: Option<String>,
    pub uptime_seconds: Option<u32>,
    pub wifi_name: Option<String>,
    /// Properties the unit answered with an error element, as `name: meaning`.
    pub unavailable: Vec<String>,
}

fn text(value: &[u8]) -> Option<String> {
    Some(
        String::from_utf8_lossy(value)
            .trim_end_matches('\0')
            .to_string(),
    )
}

fn u32_value(value: &[u8]) -> Option<u32> {
    (value.len() == 4).then(|| be32(value, 0))
}

/// The model the spec names for a product id.
pub fn product_name(product_id: u32) -> Option<&'static str> {
    match product_id {
        115 => Some("AirPort Express 802.11n (2nd generation)"),
        120 => Some("AirPort Extreme 802.11ac"),
        _ => None,
    }
}

/// Check a GET_PROPERTY reply header and read the status elements.
pub fn decode_status(
    header: &AcpHeader,
    elements: &[PropertyElement],
) -> Result<AcpStatusDto, ProtocolError> {
    if header.command != GET_PROPERTY {
        return Err(malformed("the reply is not to GET_PROPERTY"));
    }
    if header.error_code != 0 {
        return Err(malformed(format!(
            "the base station refused the read ({}: {})",
            header.error_code,
            error_meaning(header.error_code)
        )));
    }
    let mut status = AcpStatusDto::default();
    for element in elements {
        let name = String::from_utf8_lossy(&element.name).to_string();
        if let Some(code) = element.error {
            status
                .unavailable
                .push(format!("{name}: {}", error_meaning(code)));
            continue;
        }
        match &element.name {
            b"syNm" => status.name = text(&element.value),
            b"syVs" => status.firmware = text(&element.value),
            b"syAP" => {
                status.product_id = u32_value(&element.value);
                status.product_name = status.product_id.and_then(product_name).map(str::to_string);
            }
            b"syUT" => status.uptime_seconds = u32_value(&element.value),
            b"raNm" => status.wifi_name = text(&element.value),
            // Not asked for; nothing this read wanted.
            _ => {}
        }
    }
    Ok(status)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn spec_doc() -> serde_yaml::Value {
        serde_yaml::from_str(
            &std::fs::read_to_string(format!(
                "{}/../vendor/protocol-specs/device-specs/devices/apple-airport-acp.yaml",
                env!("CARGO_MANIFEST_DIR")
            ))
            .unwrap(),
        )
        .unwrap()
    }

    fn hex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
            .collect()
    }

    fn s(v: &serde_yaml::Value) -> &str {
        v.as_str().unwrap()
    }

    /// Legacy mode's header key. Here only to reproduce the spec's example
    /// frames: nothing outside the tests can build a legacy request.
    fn legacy_key(password: &str) -> [u8; 32] {
        let mut key = [0u8; 32];
        for (i, b) in password.bytes().take(32).enumerate() {
            key[i] = b;
        }
        std::array::from_fn(|i| key[i] ^ keystream_byte(i))
    }

    const SET_PROPERTY: u32 = 0x15;
    const GET_FEATURES: u32 = 0x1B;

    #[test]
    fn the_keystream_and_legacy_key_are_the_specs() {
        let doc = spec_doc();
        let key_field = &doc["protocol_details"]["acp"]["key_field"];
        assert_eq!(
            unauthenticated_key().to_vec(),
            hex("0e39f805c401554f0cac857d868ab5173e09c835f431657f3c9cb56d969aa507")
        );
        assert_eq!(
            legacy_key(s(&key_field["example_password"])).to_vec(),
            hex(s(&key_field["example_key"]))
        );
        assert_eq!(s(&doc["protocol_handler"]), HANDLER_NAME);
        assert_eq!(
            doc["device"]["identification"]["default_port"].as_u64(),
            Some(u64::from(PORT))
        );
    }

    #[test]
    fn adler32_is_zlibs() {
        assert_eq!(adler32(b""), 1);
        assert_eq!(adler32(b"Wikipedia"), 0x11E6_0398);
        assert_eq!(adler32(&vec![0xFF; 100_000]), {
            // Computed the slow way, mod at every step.
            let (mut a, mut b) = (1u64, 0u64);
            for _ in 0..100_000 {
                a = (a + 0xFF) % 65521;
                b = (b + a) % 65521;
            }
            ((b << 16) | a) as u32
        });
    }

    /// Every example frame in the spec, rebuilt from the rule. The legacy
    /// ones go through the test-only key; the two this app sends
    /// (authenticate_start) and get_features use the unauthenticated key.
    #[test]
    fn the_specs_example_frames_reproduce() {
        let doc = spec_doc();
        let commands = &doc["commands"];
        let legacy = legacy_key("example-owner-pw");
        let elements = |names: &[&[u8; 4]]| -> Vec<u8> {
            names
                .iter()
                .flat_map(|n| property_request_element(n))
                .collect()
        };
        assert_eq!(
            auth_start_message(),
            hex(s(&commands["authenticate_start"]["example_body"]))
        );
        assert_eq!(
            message(GET_FEATURES, 0, None, &unauthenticated_key()),
            hex(s(&commands["get_features"]["example_body"]))
        );
        for (name, props) in [
            ("get_name", vec![b"syNm"]),
            ("get_status", STATUS_PROPERTIES.to_vec()),
            ("get_wan_ip", vec![b"waIP"]),
            ("get_log", vec![b"logm"]),
        ] {
            assert_eq!(
                message(GET_PROPERTY, FLAGS_READ, Some(&elements(&props)), &legacy),
                hex(s(&commands[name]["example_body"])),
                "{name}"
            );
        }
        let mut set_name = b"syNm".to_vec();
        set_name.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 12]);
        set_name.extend_from_slice(b"Example Base");
        assert_eq!(
            message(SET_PROPERTY, 0, Some(&set_name), &legacy),
            hex(s(&commands["set_name"]["example_body"]))
        );
        assert_eq!(
            hex(s(&doc["payload_formats"]["PropertyElement"]["example"])),
            set_name
        );
        let header = hex(s(&doc["protocol_details"]["acp"]["header"]["example_hex"]));
        assert_eq!(
            header,
            message(
                GET_PROPERTY,
                FLAGS_READ,
                Some(&elements(&[b"syNm"])),
                &legacy
            )[..128]
        );
        let decoded = decode_header(&header).unwrap();
        assert_eq!(decoded.command, GET_PROPERTY);
        assert_eq!(decoded.body_size, 16);
        assert_eq!(decoded.body_checksum, 0x1838_01AC);
    }

    /// The status read this app sends is get_status's elements under the
    /// all-zero key a session after SRP carries (`key_field.after_srp`).
    #[test]
    fn the_status_request_is_get_status_with_a_zero_key() {
        let doc = spec_doc();
        let example = hex(s(&doc["commands"]["get_status"]["example_body"]));
        let ours = status_request();
        assert_eq!(ours[128..], example[128..], "same five elements");
        assert_eq!(&ours[48..80], &[0u8; 32]);
        assert_eq!(&ours[..8], &example[..8]);
        assert_eq!(&ours[12..48], &example[12..48]);
        assert!(decode_header(&ours).is_ok());
    }

    #[test]
    fn a_damaged_header_is_refused() {
        let mut frame = auth_start_message();
        assert!(decode_header(&frame[..100]).is_err());
        frame[30] ^= 1;
        assert!(decode_header(&frame).is_err());
        let mut wrong = auth_start_message();
        wrong[0] = b'x';
        assert!(decode_header(&wrong).is_err());
    }

    #[test]
    fn the_specs_plist_example_round_trips() {
        let doc = spec_doc();
        let example = hex(s(
            &doc["protocol_details"]["acp"]["cfb0_plist"]["example_hex"]
        ));
        let decoded = decode_plist(&example).unwrap();
        assert_eq!(decoded.get("state"), Some(&Cfb::Int(1)));
        assert_eq!(decoded.get("username"), Some(&Cfb::Str("admin".into())));
        assert_eq!(encode_plist(&decoded), example);
        // Long data takes the 0x4F form with an integer length.
        let long = Cfb::Dict(vec![(str_key("k"), Cfb::Data(vec![7; 192]))]);
        let bytes = encode_plist(&long);
        assert_eq!(&bytes[8..11], &[0x4F, 0x10, 0xC0]);
        assert_eq!(decode_plist(&bytes).unwrap(), long);
        for bad in [
            &b"CFB0"[..],
            b"CFB0\xD0END!",
            b"CFB0\x70abcEND!",
            b"CFB0\x4F\x13\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFFEND!",
            b"CFB0\x30END!",
            b"XXXX\x09END!",
            b"CFB0\x09\x09END!",
        ] {
            assert!(decode_plist(bad).is_err(), "{bad:02x?}");
        }
        let deep: Vec<u8> = [
            b"CFB0".to_vec(),
            vec![0xA0; 40],
            vec![0; 40],
            b"END!".to_vec(),
        ]
        .concat();
        assert!(decode_plist(&deep).is_err());
    }

    /// RFC 5054 appendix B: the 1024-bit group, SHA-1, alice / password123.
    /// Checks k, x, u and the premaster secret through the same arithmetic
    /// the 1536-bit session uses.
    #[test]
    fn srp_arithmetic_matches_rfc_5054s_vectors() {
        let n = BigUint::parse_bytes(
            concat!(
                "EEAF0AB9ADB38DD69C33F80AFA8FC5E86072618775FF3C0B9EA2314C",
                "9C256576D674DF7496EA81D3383B4813D692C6E0E0D5D8E250B98BE4",
                "8E495C1D6089DAD15DC7D7B46154D6B6CE8EF4AD69B15D4982559B29",
                "7BCF1885C529F566660E57EC68EDBC3C05726CC02FD4CBF4976EAA9A",
                "FD5138FE8376435B9FC61D2FC0EB06E3"
            )
            .as_bytes(),
            16,
        )
        .unwrap();
        let salt = hex("BEB25379D1A8581EB5A727673A2441EE");
        let a = BigUint::from_bytes_be(&hex(
            "60975527035CF2AD1989806F0407210BC81EDC04E2762A56AFD529DDDA2D4393",
        ));
        let b_pub = BigUint::from_bytes_be(&hex(concat!(
            "BD0C61512C692C0CB6D041FA01BB152D4916A1E77AF46AE105393011BAF38964",
            "DC46A0670DD125B95A981652236F99D9B681CBF87837EC996C6DA04453728610",
            "D0C6DDB58B318885D7D82C7F8DEB75CE7BD4FBAA37089E6F9C6059F388838E7A",
            "00030B331EB76840910440B1B27AAEAEEB4012B7D7665238A8E3FB004B117B58"
        )));
        let (a_pub, s) =
            srp_premaster(&n, 128, &salt, "alice", b"password123", &a, &b_pub).unwrap();
        assert_eq!(
            pad(&a_pub, 128),
            hex(concat!(
                "61D5E490F6F1B79547B0704C436F523DD0E560F0C64115BB72557EC44352E890",
                "3211C04692272D8B2D1A5358A2CF1B6E0BFCF99F921530EC8E39356179EAE45E",
                "42BA92AEACED825171E1E8B9AF6D9C03E1327F44BE087EF06530E69F66615261",
                "EEF54073CA11CF5858F0EDFDFE15EFEAB349EF5D76988A3672FAC47B0769447B"
            ))
        );
        assert_eq!(
            pad(&s, 128),
            hex(concat!(
                "B0DC82BABCF30674AE450C0287745E7990A3381F63B387AAF271A10D233861E3",
                "59B48220F7C4693C9AE12B0A6F67809F0876E2D013800D6C41BB59B6D5979B5C",
                "00A172B4A2A5903A0BDCAF8A709585EB2AFAFA8F3499B200210DCC1F10EB3394",
                "3CD67FC88A2F39A4BE5BEC4EC0A3212DC346D7E474B29EDE8A469FFECA686E5A"
            ))
        );
    }

    #[test]
    fn the_1536_bit_group_is_the_specs_and_a_prime() {
        let n = n_1536();
        assert_eq!(n.bits(), 1536);
        let one = BigUint::from(1u8);
        for base in [2u8, 3, 5, 7] {
            assert_eq!(BigUint::from(base).modpow(&(&n - &one), &n), one);
        }
    }

    /// RFC 6070's PBKDF2-HMAC-SHA1 vectors, then the spec's invented-K
    /// session keys.
    #[test]
    fn pbkdf2_matches_rfc_6070_and_the_specs_example() {
        assert_eq!(
            pbkdf2_sha1(b"password", b"salt", 1, 20),
            hex("0c60c80f961f0e71f3a9b524af6012062fe037a6")
        );
        assert_eq!(
            pbkdf2_sha1(b"password", b"salt", 2, 20),
            hex("ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
        );
        assert_eq!(
            pbkdf2_sha1(b"password", b"salt", 4096, 20),
            hex("4b007901b765489abead49d926f721d065a429c1")
        );
        assert_eq!(
            pbkdf2_sha1(
                b"passwordPASSWORDpassword",
                b"saltSALTsaltSALTsaltSALTsaltSALTsalt",
                4096,
                25
            ),
            hex("3d2eec4fe41c849b80c8d83662c0e44a8b291a964cf2f07038")
        );
        let example = &spec_doc()["protocol_details"]["acp"]["session_encryption"]["example"];
        let (client, server) = session_keys(&hex(s(&example["K"])));
        assert_eq!(client.to_vec(), hex(s(&example["client_key"])));
        assert_eq!(server.to_vec(), hex(s(&example["server_key"])));
    }

    /// NIST SP 800-38A F.5.1 (CTR-AES128), whole and from every offset.
    #[test]
    fn ctr_matches_nist_and_resumes_at_any_offset() {
        let key: [u8; 16] = hex("2b7e151628aed2a6abf7158809cf4f3c").try_into().unwrap();
        let iv: [u8; 16] = hex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff").try_into().unwrap();
        let plain = hex(concat!(
            "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51",
            "30c81c46a35ce411e5fbc1191a0a52eff69f2445df4f9b17ad2b417be66c3710"
        ));
        let cipher = hex(concat!(
            "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff",
            "5ae4df3edbd5d35e5b4f09020db03eab1e031dda2fbe03d1792170a0f3009cee"
        ));
        assert_eq!(ctr_apply(&key, &iv, 0, &plain), cipher);
        for split in [1usize, 15, 16, 17, 40] {
            let mut joined = ctr_apply(&key, &iv, 0, &plain[..split]);
            joined.extend(ctr_apply(&key, &iv, split as u64, &plain[split..]));
            assert_eq!(joined, cipher, "split at {split}");
        }
        // The counter carries across the whole 128 bits.
        let edge = [0xFFu8; 16];
        let two = ctr_apply(&key, &edge, 0, &[0u8; 32]);
        assert_eq!(&two[16..], &ctr_apply(&key, &[0u8; 16], 0, &[0u8; 16])[..]);
    }

    /// A whole authentication against an emulated base station that does
    /// the server side of SRP-6a independently, then a status read through
    /// the session keystreams.
    #[test]
    fn a_session_authenticates_and_reads_against_an_emulated_base_station() {
        let password = "example-owner-pw";
        let n = n_1536();
        let g = BigUint::from(2u8);
        let salt = [0x11u8; 16];
        let x = BigUint::from_bytes_be(&sha1(&[
            &salt,
            &sha1(&[format!("admin:{password}").as_bytes()]),
        ]));
        let v = g.modpow(&x, &n);
        let k = BigUint::from_bytes_be(&sha1(&[&pad(&n, N_LEN), &pad(&g, N_LEN)]));
        let b = BigUint::from_bytes_be(&[0x42; 32]);
        let b_pub = (&k * &v + g.modpow(&b, &n)) % &n;
        let challenge_body = encode_plist(&Cfb::Dict(vec![
            (str_key("salt"), Cfb::Data(salt.to_vec())),
            (str_key("generator"), Cfb::Data(vec![2])),
            (str_key("publicKey"), Cfb::Data(pad(&b_pub, N_LEN))),
            (str_key("modulus"), Cfb::Data(pad(&n, N_LEN))),
        ]));
        let challenge = parse_challenge(&challenge_body).unwrap();
        let client_iv = [0x22u8; 16];
        let stage3 = srp_stage3(&challenge, password, &[0x33; 24], &client_iv).unwrap();

        // The server reads stage 3 and computes S its own way.
        let header = decode_header(&stage3.message).unwrap();
        assert_eq!(header.command, AUTHENTICATE);
        let sent = decode_plist(&stage3.message[HEADER_LEN..]).unwrap();
        assert_eq!(sent.get("state"), Some(&Cfb::Int(3)));
        let a_pub = BigUint::from_bytes_be(sent.get("publicKey").unwrap().data().unwrap());
        let u = BigUint::from_bytes_be(&sha1(&[&pad(&a_pub, N_LEN), &pad(&b_pub, N_LEN)]));
        let server_s = (&a_pub * v.modpow(&u, &n)).modpow(&b, &n);
        let server_k = sha1(&[&pad(&server_s, N_LEN)]);
        assert_eq!(server_k, stage3.session_key, "both sides agree on K");

        let server_iv = [0x44u8; 16];
        let reply = encode_plist(&Cfb::Dict(vec![
            (str_key("response"), Cfb::Data(stage3.expected_m2.to_vec())),
            (str_key("iv"), Cfb::Data(server_iv.to_vec())),
        ]));
        let keys = finish_auth(&reply, &stage3, &client_iv).unwrap();
        assert_eq!(keys.server_iv, server_iv);

        // A forged proof is refused.
        let forged = encode_plist(&Cfb::Dict(vec![
            (str_key("response"), Cfb::Data(vec![0; 20])),
            (str_key("iv"), Cfb::Data(server_iv.to_vec())),
        ]));
        assert!(finish_auth(&forged, &stage3, &client_iv).is_err());

        // The status request, through the client keystream and back.
        let request = status_request();
        let on_wire = ctr_apply(&keys.client_key, &keys.client_iv, 0, &request);
        assert_ne!(on_wire, request);
        assert_eq!(
            ctr_apply(&keys.client_key, &client_iv, 0, &on_wire),
            request
        );
    }

    #[test]
    fn a_weaker_group_or_a_zero_public_value_is_refused() {
        let n = n_1536();
        let good = |modulus: Vec<u8>, generator: Vec<u8>, b: Vec<u8>| {
            encode_plist(&Cfb::Dict(vec![
                (str_key("salt"), Cfb::Data(vec![1; 16])),
                (str_key("generator"), Cfb::Data(generator)),
                (str_key("publicKey"), Cfb::Data(b)),
                (str_key("modulus"), Cfb::Data(modulus)),
            ]))
        };
        assert!(parse_challenge(&good(pad(&n, N_LEN), vec![2], vec![9; N_LEN])).is_ok());
        assert!(parse_challenge(&good(vec![0xFF; 128], vec![2], vec![9; N_LEN])).is_err());
        assert!(parse_challenge(&good(pad(&n, N_LEN), vec![5], vec![9; N_LEN])).is_err());
        let challenge = parse_challenge(&good(pad(&n, N_LEN), vec![2], pad(&n, N_LEN))).unwrap();
        assert!(srp_stage3(&challenge, "pw", &[1; 24], &[0; 16]).is_err());
        let fine = parse_challenge(&good(pad(&n, N_LEN), vec![2], vec![9; N_LEN])).unwrap();
        assert!(srp_stage3(&fine, "pw", &[0; 24], &[0; 16]).is_err());
        assert!(srp_stage3(&fine, "pw", &[1; 16], &[0; 16]).is_err());
    }

    #[test]
    fn a_wrong_password_reply_says_so() {
        let mut reply = message(AUTHENTICATE, 5, None, &[0; 32]);
        reply[32..36].copy_from_slice(&ERROR_WRONG_PASSWORD.to_be_bytes());
        // Re-checksum after editing the error field.
        reply[8..12].fill(0);
        let sum = adler32(&reply[..128]);
        reply[8..12].copy_from_slice(&sum.to_be_bytes());
        let header = decode_header(&reply).unwrap();
        let error = check_auth_reply(&header, &[]).unwrap_err().to_string();
        assert!(error.contains("password is incorrect"), "{error}");
    }

    fn element(name: &[u8; 4], flags: u32, value: &[u8]) -> Vec<u8> {
        let mut e = name.to_vec();
        e.extend_from_slice(&flags.to_be_bytes());
        e.extend_from_slice(&(value.len() as u32).to_be_bytes());
        e.extend_from_slice(value);
        e
    }

    #[test]
    fn a_status_reply_reads_up_to_its_end_marker() {
        let end = hex(s(&spec_doc()["payload_formats"]["EndMarker"]["example"]));
        let body = [
            element(b"syNm", 0, b"Example Base"),
            element(b"syVs", 0, b"7.9.1"),
            element(b"syAP", 0, &120u32.to_be_bytes()),
            element(b"syUT", 0, &86_400u32.to_be_bytes()),
            element(b"raNm", 1, &(-10i32).to_be_bytes()),
            end,
        ]
        .concat();
        for cut in [0, 5, 12, 30, body.len() - 1] {
            assert_eq!(feed_property_list(&body[..cut]).unwrap(), None, "{cut}");
        }
        let elements = feed_property_list(&body).unwrap().unwrap();
        let header = AcpHeader {
            version: VERSION,
            body_checksum: 0,
            body_size: -1,
            flags: 5,
            command: GET_PROPERTY,
            error_code: 0,
        };
        let status = decode_status(&header, &elements).unwrap();
        assert_eq!(status.name.as_deref(), Some("Example Base"));
        assert_eq!(status.firmware.as_deref(), Some("7.9.1"));
        assert_eq!(status.product_id, Some(120));
        assert_eq!(
            status.product_name.as_deref(),
            Some("AirPort Extreme 802.11ac")
        );
        assert_eq!(status.uptime_seconds, Some(86_400));
        assert_eq!(status.wifi_name, None);
        assert_eq!(
            status.unavailable,
            ["raNm: property not available on this unit"]
        );

        let refused = AcpHeader {
            error_code: -16,
            ..header.clone()
        };
        assert!(decode_status(&refused, &elements).is_err());
        let wrong = AcpHeader {
            command: SET_PROPERTY,
            ..header
        };
        assert!(decode_status(&wrong, &elements).is_err());
        assert!(feed_property_list(&element(b"syNm", 0, &vec![0; MAX_ELEMENT_LEN + 1])).is_err());
        assert!(feed_property_list(&element(b"syNm", 1, &[0; 2])).is_err());
    }

    /// The spec declares writes; none of them is a message this module can
    /// produce. Its public builders are three, and they are these.
    #[test]
    fn only_authentication_and_the_status_read_can_be_built() {
        let spec = parse_device_spec(
            &std::fs::read_to_string(format!(
                "{}/../vendor/protocol-specs/device-specs/devices/apple-airport-acp.yaml",
                env!("CARGO_MANIFEST_DIR")
            ))
            .unwrap(),
        )
        .unwrap();
        assert!(spec.commands.contains_key("reboot"));
        assert!(spec.commands.contains_key("set_name"));
        for frame in [auth_start_message(), status_request()] {
            let header = decode_header(&frame).unwrap();
            assert!(matches!(header.command, GET_PROPERTY | AUTHENTICATE));
            assert_ne!(header.command, SET_PROPERTY);
        }
    }
}

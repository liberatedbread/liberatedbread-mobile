// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Identify a Tuya-based device from the discovery datagram it broadcasts on
//! the LAN — the same identify-only job the Ubiquiti and MikroTik transports
//! do, one ecosystem over.
//!
//! Tuya powers a large fraction of white-label smart plugs, bulbs and sensors.
//! Every such device beacons a small UDP datagram roughly every ten seconds to
//! the broadcast address on port 6666 (protocol 3.1, plaintext) or 6667
//! (protocol 3.2+, AES-128-ECB). The datagram is a self-description — device
//! id, IP, protocol version, product key — NOT a control channel: driving a
//! Tuya device needs its per-device local key, a secret issued by the Tuya
//! cloud to the vendor's app, which this project does not have and does not
//! ask for. So this module does exactly one thing: turn a broadcast into the
//! facts that identify the device, for a pictogram and a "set up in the vendor
//! app" note.
//!
//! The 6667 cipher is AES-128-ECB under a FIXED key that is the same on every
//! Tuya device on earth — `md5("yGAdlopoPVldABfn")` — and is published in
//! every open Tuya library (tinytuya, localtuya, python-tuya). It is a
//! discovery key, not a device secret: it only unwraps the broadcast a device
//! is already shouting to the whole segment. The per-device local key that
//! actually protects control is never derived here. The cipher lives in Rust,
//! under test, for the same reason Kasa's does — one tested place rather than
//! re-implemented per client.
//!
//! Frame (little of it matters to us): prefix `00 00 55 aa`, 4-byte sequence,
//! 4-byte command (`0x00` on 6666, `0x13` on 6667), 4-byte payload length,
//! then the payload — an optional 4-byte return code, the data (plaintext or
//! ciphertext), a 4-byte CRC32 and the suffix `00 00 aa 55`. We locate the
//! data between the 16-byte header and the trailing CRC+suffix, drop a leading
//! return code when present (detected by which slice is a whole number of AES
//! blocks), and read the JSON out — trying plaintext first, then the fixed-key
//! decrypt.

use aes::cipher::{generic_array::GenericArray, BlockDecrypt, KeyInit};
use aes::Aes128;
use md5::{Digest, Md5};
use serde::Deserialize;

/// The string every open Tuya library hashes for the broadcast key. MD5 of it
/// is the AES-128-ECB key for the 6667 datagram — fixed across all devices.
const UDP_KEY_SEED: &[u8] = b"yGAdlopoPVldABfn";

const PREFIX: [u8; 4] = [0x00, 0x00, 0x55, 0xaa];
const SUFFIX: [u8; 4] = [0x00, 0x00, 0xaa, 0x55];
/// header (prefix+seq+cmd+len) + trailing (crc + suffix): the fixed overhead
/// around the data region.
const HEADER_LEN: usize = 16;
const TRAILER_LEN: usize = 8;

/// What a Tuya broadcast tells us about the device that sent it. Every field is
/// optional because a malformed or partial datagram should still identify the
/// device by whatever it did carry (in the worst case, nothing — the caller
/// still has the source IP).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TuyaBroadcast {
    /// The stable device id (`gwId`) — Tuya's per-device identifier, the good
    /// identity key (survives a DHCP move, unlike the IP).
    pub gw_id: Option<String>,
    /// The IP the device put in its own broadcast. Usually equals the datagram
    /// source; kept because the device is authoritative about it.
    pub ip: Option<String>,
    /// Protocol version string, e.g. "3.3" — useful context, not identity.
    pub version: Option<String>,
    /// The product key: identifies the firmware product, shared across every
    /// unit of that model. Not an identity on its own.
    pub product_key: Option<String>,
    /// Whether the 6667 (encrypted) framing was used, i.e. whether the JSON
    /// had to be decrypted. Purely informational.
    pub encrypted: bool,
}

/// The subset of the broadcast JSON we read. Tuya spells the id `gwId`; the
/// rest are lower-case. Unknown keys are ignored.
#[derive(Deserialize)]
struct BroadcastJson {
    #[serde(rename = "gwId")]
    gw_id: Option<String>,
    ip: Option<String>,
    version: Option<String>,
    #[serde(rename = "productKey")]
    product_key: Option<String>,
}

/// The fixed AES-128-ECB broadcast key: `md5("yGAdlopoPVldABfn")`.
fn udp_key() -> [u8; 16] {
    let mut hasher = Md5::new();
    hasher.update(UDP_KEY_SEED);
    hasher.finalize().into()
}

/// Decrypt one or more AES-128-ECB blocks under [`udp_key`], returning the
/// PKCS#7-unpadded plaintext. `None` when the input is not a whole number of
/// 16-byte blocks or the padding is invalid — either means this was not the
/// ciphertext (e.g. a plaintext 6666 datagram), so the caller falls back.
fn ecb_decrypt(ciphertext: &[u8]) -> Option<Vec<u8>> {
    if ciphertext.is_empty() || ciphertext.len() % 16 != 0 {
        return None;
    }
    let cipher = Aes128::new(GenericArray::from_slice(&udp_key()));
    let mut out = Vec::with_capacity(ciphertext.len());
    for chunk in ciphertext.chunks_exact(16) {
        let mut block = GenericArray::clone_from_slice(chunk);
        cipher.decrypt_block(&mut block);
        out.extend_from_slice(&block);
    }
    // Strip PKCS#7: the last byte is the pad length, 1..=16, and every padding
    // byte must equal it. A bad tail means this was not our ciphertext.
    let pad = *out.last()? as usize;
    if pad == 0 || pad > 16 || pad > out.len() {
        return None;
    }
    if out[out.len() - pad..].iter().any(|&b| b as usize != pad) {
        return None;
    }
    out.truncate(out.len() - pad);
    Some(out)
}

/// Parse a Tuya discovery datagram into the facts that identify its sender, or
/// `None` when the bytes are not a Tuya broadcast we can read.
pub fn parse_broadcast(datagram: &[u8]) -> Option<TuyaBroadcast> {
    if datagram.len() < HEADER_LEN + TRAILER_LEN
        || datagram[0..4] != PREFIX
        || datagram[datagram.len() - 4..] != SUFFIX
    {
        return None;
    }
    // The data region sits between the 16-byte header and the 8-byte CRC+suffix
    // trailer. It may lead with a 4-byte return code; we detect that by which
    // slice is a whole number of AES blocks (the ciphertext must be), and try
    // both when reading plaintext.
    let data = &datagram[HEADER_LEN..datagram.len() - TRAILER_LEN];
    if data.is_empty() {
        return None;
    }
    let without_retcode = if data.len() >= 4 {
        Some(&data[4..])
    } else {
        None
    };

    // Plaintext (6666): the data is JSON directly. Try both framings.
    for candidate in [Some(data), without_retcode].into_iter().flatten() {
        if let Ok(json) = serde_json::from_slice::<BroadcastJson>(candidate) {
            return Some(build(json, false));
        }
    }

    // Ciphertext (6667): whichever framing is a whole number of blocks.
    for candidate in [Some(data), without_retcode].into_iter().flatten() {
        if candidate.len() % 16 == 0 {
            if let Some(plain) = ecb_decrypt(candidate) {
                if let Ok(json) = serde_json::from_slice::<BroadcastJson>(&plain) {
                    return Some(build(json, true));
                }
            }
        }
    }
    None
}

fn build(json: BroadcastJson, encrypted: bool) -> TuyaBroadcast {
    let norm = |s: Option<String>| s.map(|v| v.trim().to_string()).filter(|v| !v.is_empty());
    TuyaBroadcast {
        gw_id: norm(json.gw_id),
        ip: norm(json.ip),
        version: norm(json.version),
        product_key: norm(json.product_key),
        encrypted,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use aes::cipher::{BlockEncrypt, KeyInit};

    /// Wrap a JSON body in a Tuya 6667 frame: header + return code + AES-ECB
    /// ciphertext + CRC placeholder + suffix. Mirrors what a device sends, so
    /// the round-trip test uses no captured packet (clean-room).
    fn frame_encrypted(json: &str) -> Vec<u8> {
        // PKCS#7 pad to a block boundary, then AES-128-ECB encrypt.
        let mut plain = json.as_bytes().to_vec();
        let pad = 16 - (plain.len() % 16);
        plain.extend(std::iter::repeat_n(pad as u8, pad));
        let cipher = Aes128::new(GenericArray::from_slice(&udp_key()));
        let mut ct = Vec::new();
        for chunk in plain.chunks_exact(16) {
            let mut block = GenericArray::clone_from_slice(chunk);
            cipher.encrypt_block(&mut block);
            ct.extend_from_slice(&block);
        }
        let mut payload = vec![0u8, 0, 0, 0]; // return code 0
        payload.extend_from_slice(&ct);
        payload.extend_from_slice(&[0, 0, 0, 0]); // CRC (unchecked here)
        payload.extend_from_slice(&SUFFIX);
        let mut frame = Vec::new();
        frame.extend_from_slice(&PREFIX);
        frame.extend_from_slice(&[0, 0, 0, 0]); // sequence
        frame.extend_from_slice(&[0, 0, 0, 0x13]); // command 0x13 (UDP_NEW)
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(&payload);
        frame
    }

    fn frame_plaintext(json: &str) -> Vec<u8> {
        let mut payload = json.as_bytes().to_vec();
        payload.extend_from_slice(&[0, 0, 0, 0]); // CRC
        payload.extend_from_slice(&SUFFIX);
        let mut frame = Vec::new();
        frame.extend_from_slice(&PREFIX);
        frame.extend_from_slice(&[0, 0, 0, 0]);
        frame.extend_from_slice(&[0, 0, 0, 0x00]); // command 0x00 (UDP)
        frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        frame.extend_from_slice(&payload);
        frame
    }

    #[test]
    fn decrypts_encrypted_broadcast() {
        let json = r#"{"ip":"10.0.0.9","gwId":"03712560f4cfa2072048","active":2,"encrypt":true,"productKey":"key9xu7q8ntqw7jx","version":"3.3"}"#;
        let got = parse_broadcast(&frame_encrypted(json)).expect("parses");
        assert_eq!(got.gw_id.as_deref(), Some("03712560f4cfa2072048"));
        assert_eq!(got.ip.as_deref(), Some("10.0.0.9"));
        assert_eq!(got.version.as_deref(), Some("3.3"));
        assert_eq!(got.product_key.as_deref(), Some("key9xu7q8ntqw7jx"));
        assert!(got.encrypted);
    }

    #[test]
    fn reads_plaintext_broadcast() {
        let json = r#"{"ip":"10.0.0.5","gwId":"abc123","version":"3.1"}"#;
        let got = parse_broadcast(&frame_plaintext(json)).expect("parses");
        assert_eq!(got.gw_id.as_deref(), Some("abc123"));
        assert_eq!(got.version.as_deref(), Some("3.1"));
        assert!(!got.encrypted);
    }

    #[test]
    fn rejects_non_tuya() {
        assert!(parse_broadcast(b"not a tuya frame at all").is_none());
        assert!(parse_broadcast(&[0u8; 8]).is_none());
    }
}

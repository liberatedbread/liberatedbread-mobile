// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! PAX 3 and PAX Era temperature and battery over BLE, read-only —
//! `protocol_handler: "pax_ofb"` (`pax-vape.yaml`).
//!
//! ```text
//! key    = AES-128-ECB(master key, serial || serial)   serial: 8 ASCII, from DIS 2a25
//! packet = AES-128-OFB(key, iv, plaintext) || iv        iv: 16 random bytes, last on the wire
//! plain  = [attribute id] [payload...]
//!   0x01 ACTUAL_TEMP  uint16 LE, tenths of a degree C
//!   0x03 BATTERY      uint8, percent
//!   0xFE status update request: 8-byte LE bitmask of attribute ids
//! ```
//!
//! # What this reads, and what it cannot send
//!
//! This is a heating device. The only frame this module can build is the
//! status-update request for ACTUAL_TEMP and BATTERY ([`encode_status_request`]
//! takes no attribute and no mask), so the heater set point (0x02) and the
//! lock (0x06) have no way out of it, and `protocol::readonly` refuses every
//! command of the spec to the generic encoders.
//!
//! The Era Pro speaks something else — "nonces, AES-CTR mode and a connection
//! handshake" (the spec's device notes) — whose nonces and handshake the spec
//! does not state. A unit carrying the Era Pro enrollment service is refused
//! ([`refuses_model`]) rather than read with the wrong cipher.
//!
//! The spec carries no captured frame, so the tests pin the master key to the
//! spec's own text and the derivation and cipher to values computed
//! independently (OpenSSL / Python `cryptography`). Nothing here has been run
//! against hardware.

use crate::error::ProtocolError;
use aes::cipher::{BlockCipherEncrypt, KeyInit};

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "pax_ofb";

pub const SERVICE: &str = "8e320200-64d2-11e6-bdf4-0800200c9a66";
pub const READ_CHARACTERISTIC: &str = "8e320201-64d2-11e6-bdf4-0800200c9a66";
pub const WRITE_CHARACTERISTIC: &str = "8e320202-64d2-11e6-bdf4-0800200c9a66";
pub const NOTIFY_CHARACTERISTIC: &str = "8e320203-64d2-11e6-bdf4-0800200c9a66";
/// The Era Pro's enrollment service. Its presence is how [`refuses_model`]
/// tells an Era Pro.
pub const ENROLLMENT_SERVICE: &str = "8e320210-64d2-11e6-bdf4-0800200c9a66";
/// Device Information, and the serial number the key is derived from.
pub const DIS_SERVICE: &str = "0000180a-0000-1000-8000-00805f9b34fb";
pub const SERIAL_CHARACTERISTIC: &str = "00002a25-0000-1000-8000-00805f9b34fb";

/// The key-derivation key, as the spec states it (`static_key`).
const MASTER_KEY: [u8; 16] = [
    0xF7, 0xC8, 0x66, 0xC3, 0x8F, 0x78, 0x75, 0x30, 0x86, 0x29, 0x3B, 0xD5, 0x7D, 0xD3, 0x25, 0x40,
];

const IV_LEN: usize = 16;
const SERIAL_LEN: usize = 8;

const ATTR_ACTUAL_TEMP: u8 = 0x01;
const ATTR_BATTERY: u8 = 0x03;
const STATUS_UPDATE: u8 = 0xFE;

/// What one decrypted read turned out to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaxReadingKind {
    Temperature,
    Battery,
    /// An attribute this app does not read.
    Other,
}

/// One decrypted read; only the field its `kind` names is set.
#[derive(Debug, Clone, PartialEq)]
pub struct PaxReadingDto {
    pub kind: PaxReadingKind,
    /// The attribute id the packet carried.
    pub attribute: u8,
    pub temperature_c: Option<f64>,
    pub battery_percent: Option<u8>,
}

fn malformed(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::MalformedReply(reason.into())
}

fn aes_block(key: &[u8; 16], block: &mut [u8; 16]) {
    aes::Aes128::new(key.into()).encrypt_block(block.into());
}

/// The per-device key: the 8-character serial twice, under the master key.
pub fn derive_key(serial: &str) -> Result<[u8; 16], ProtocolError> {
    let serial = serial.trim_end_matches('\0').trim();
    if serial.len() != SERIAL_LEN || !serial.is_ascii() {
        return Err(ProtocolError::ParameterValueInvalid {
            name: "serial".to_string(),
            value: serial.to_string(),
            reason: format!("a PAX key comes from an {SERIAL_LEN}-character ASCII serial"),
        });
    }
    let mut block = [0u8; 16];
    block[..SERIAL_LEN].copy_from_slice(serial.as_bytes());
    block[SERIAL_LEN..].copy_from_slice(serial.as_bytes());
    aes_block(&MASTER_KEY, &mut block);
    Ok(block)
}

/// AES-128-OFB over `data` in place (encrypt and decrypt are the same).
fn ofb(key: &[u8; 16], iv: [u8; 16], data: &mut [u8]) {
    let mut stream = iv;
    for (i, byte) in data.iter_mut().enumerate() {
        if i % 16 == 0 {
            aes_block(key, &mut stream);
        }
        *byte ^= stream[i % 16];
    }
}

/// The status-update request for temperature and battery, encrypted under
/// `serial`'s key with `iv`, as `ciphertext || iv`. The ONLY frame this module
/// builds.
pub fn encode_status_request(serial: &str, iv: [u8; 16]) -> Result<Vec<u8>, ProtocolError> {
    let key = derive_key(serial)?;
    let mask = (1u64 << ATTR_ACTUAL_TEMP) | (1u64 << ATTR_BATTERY);
    let mut packet = vec![STATUS_UPDATE];
    packet.extend_from_slice(&mask.to_le_bytes());
    ofb(&key, iv, &mut packet);
    packet.extend_from_slice(&iv);
    Ok(packet)
}

/// [`encode_status_request`] with a fresh IV from the OS.
pub fn encode_status_request_random(serial: &str) -> Result<Vec<u8>, ProtocolError> {
    let mut iv = [0u8; IV_LEN];
    getrandom::fill(&mut iv).map_err(|e| malformed(format!("no OS randomness: {e}")))?;
    encode_status_request(serial, iv)
}

/// Decrypt and read one value of the read characteristic.
pub fn decode_read(serial: &str, packet: &[u8]) -> Result<PaxReadingDto, ProtocolError> {
    let key = derive_key(serial)?;
    if packet.len() <= IV_LEN {
        return Err(malformed(format!(
            "a PAX read is ciphertext then a {IV_LEN}-byte IV, and this one is {} bytes",
            packet.len()
        )));
    }
    let (ciphertext, iv) = packet.split_at(packet.len() - IV_LEN);
    let mut iv_block = [0u8; IV_LEN];
    iv_block.copy_from_slice(iv);
    let mut plain = ciphertext.to_vec();
    ofb(&key, iv_block, &mut plain);
    let attribute = plain[0];
    let mut reading = PaxReadingDto {
        kind: PaxReadingKind::Other,
        attribute,
        temperature_c: None,
        battery_percent: None,
    };
    match attribute {
        ATTR_ACTUAL_TEMP => {
            let [_, low, high, ..] = plain[..] else {
                return Err(malformed("a temperature read carries two bytes"));
            };
            reading.kind = PaxReadingKind::Temperature;
            reading.temperature_c = Some(f64::from(u16::from_le_bytes([low, high])) / 10.0);
        }
        ATTR_BATTERY => {
            let Some(&percent) = plain.get(1) else {
                return Err(malformed("a battery read carries one byte"));
            };
            // The spec states 0-100. Anything else is a wrong key or a
            // different layout, and is not shown as a charge.
            if percent > 100 {
                return Err(malformed(format!("battery {percent} % is not a charge")));
            }
            reading.kind = PaxReadingKind::Battery;
            reading.battery_percent = Some(percent);
        }
        _ => {}
    }
    Ok(reading)
}

/// Why this unit is not read, from the services it carries, or `None`.
pub fn refuses_model(service_uuids: &[String]) -> Option<String> {
    service_uuids
        .iter()
        .any(|uuid| uuid.eq_ignore_ascii_case(ENROLLMENT_SERVICE))
        .then(|| {
            "This looks like a PAX Era Pro, which carries the enrollment service. \
             The Era Pro encrypts with nonces and a handshake the spec does not \
             state, so this app does not connect to it."
                .to_string()
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn hex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
            .collect()
    }

    fn vendored() -> crate::spec::types::DeviceSpec {
        let path = concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../vendor/protocol-specs/device-specs/devices/pax-vape.yaml"
        );
        parse_device_spec(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    /// The key is the spec's: both encrypted characteristics state it, and so
    /// do the device notes.
    #[test]
    fn the_master_key_is_the_one_the_spec_states() {
        let spec = vendored();
        for uuid in [READ_CHARACTERISTIC, WRITE_CHARACTERISTIC] {
            let characteristic = spec.services[0]
                .characteristics
                .iter()
                .find(|c| c.uuid == uuid)
                .unwrap();
            let stated = characteristic.encryption.as_ref().unwrap()["static_key"]
                .as_str()
                .unwrap();
            assert_eq!(hex(&stated.to_lowercase()), MASTER_KEY);
        }
        assert!(spec
            .device
            .notes
            .as_deref()
            .unwrap()
            .contains("f7c866c38f78753086293bd57dd32540"));
    }

    /// AES-128-ECB of "ABCD1234ABCD1234" under the master key, computed with
    /// `openssl enc -aes-128-ecb -nopad`.
    #[test]
    fn the_key_derivation_matches_an_independent_computation() {
        assert_eq!(
            derive_key("ABCD1234").unwrap().to_vec(),
            hex("e4a604f5ac59a51fd6efc67712d3a689")
        );
        // DIS strings can arrive NUL-padded.
        assert_eq!(
            derive_key("ABCD1234\0").unwrap(),
            derive_key("ABCD1234").unwrap()
        );
        for bad in ["", "ABCD123", "ABCD12345", "ABCD123é"] {
            assert!(derive_key(bad).is_err(), "{bad:?}");
        }
    }

    /// The request for ACTUAL_TEMP (bit 1) and BATTERY (bit 3), under the key
    /// above and an IV of 00..0f; the ciphertext computed with Python
    /// `cryptography`'s AES-OFB.
    #[test]
    fn the_status_request_matches_an_independent_computation() {
        let iv: [u8; 16] = hex("000102030405060708090a0b0c0d0e0f").try_into().unwrap();
        let packet = encode_status_request("ABCD1234", iv).unwrap();
        assert_eq!(packet.len(), 9 + 16);
        assert_eq!(packet[9..], iv);
        assert_eq!(packet[..9], hex("72cc323411af0f60cd")[..]);
        // And it decrypts back to FE 0A 00..00.
        let mut plain = packet[..9].to_vec();
        ofb(&derive_key("ABCD1234").unwrap(), iv, &mut plain);
        assert_eq!(plain, [0xFE, 0x0A, 0, 0, 0, 0, 0, 0, 0]);
    }

    fn sealed(serial: &str, plain: &[u8]) -> Vec<u8> {
        let iv = [0x5Au8; 16];
        let mut packet = plain.to_vec();
        ofb(&derive_key(serial).unwrap(), iv, &mut packet);
        packet.extend_from_slice(&iv);
        packet
    }

    #[test]
    fn reads_decode_temperature_and_battery() {
        // 0x073F = 1855 tenths of a degree.
        let reading = decode_read("ABCD1234", &sealed("ABCD1234", &[0x01, 0x3F, 0x07])).unwrap();
        assert_eq!(reading.kind, PaxReadingKind::Temperature);
        assert_eq!(reading.temperature_c, Some(185.5));

        let reading = decode_read("ABCD1234", &sealed("ABCD1234", &[0x03, 87])).unwrap();
        assert_eq!(reading.kind, PaxReadingKind::Battery);
        assert_eq!(reading.battery_percent, Some(87));

        // The heater set point is an attribute this app does not read.
        let reading = decode_read("ABCD1234", &sealed("ABCD1234", &[0x02, 0x3F, 0x07])).unwrap();
        assert_eq!(reading.kind, PaxReadingKind::Other);
        assert_eq!(reading.attribute, 0x02);
    }

    #[test]
    fn short_or_impossible_reads_are_refused() {
        assert!(decode_read("ABCD1234", &[0u8; 16]).is_err());
        assert!(decode_read("ABCD1234", &sealed("ABCD1234", &[0x01, 0x3F])).is_err());
        assert!(decode_read("ABCD1234", &sealed("ABCD1234", &[0x03])).is_err());
        assert!(decode_read("ABCD1234", &sealed("ABCD1234", &[0x03, 101])).is_err());
    }

    #[test]
    fn the_era_pro_is_refused_by_its_enrollment_service() {
        let pax3 = vec![SERVICE.to_string(), DIS_SERVICE.to_string()];
        assert!(refuses_model(&pax3).is_none());
        let era_pro = vec![SERVICE.to_string(), ENROLLMENT_SERVICE.to_uppercase()];
        assert!(refuses_model(&era_pro).is_some());
    }
}

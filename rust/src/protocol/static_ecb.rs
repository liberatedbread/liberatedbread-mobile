// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Static-key AES-128-ECB for spec-declared commands: the Heaton/cdbwsoft
//! family's `[length][ASCII opcode][args][padding]` block, written as one
//! cipher block per command.
//!
//! The key is the spec's (`encryption.static_key`). A key derived per device
//! or by a handshake (pax-vape, niu) is refused. A static key in a public
//! catalogue is obfuscation rather than security, which is why ECB costs
//! nothing here.
//!
//! # Padding
//!
//! The specs' `encryption` block has no field for how the block is filled, so
//! the handler a spec names says, and [`bind_padding`] states it on the block
//! when the spec is parsed. A characteristic whose padding nobody stated stays
//! refused rather than guessed at.
//!
//! - `cdbwsoft_ecb` (ideal-led, magic-display, shining-glasses): zeros.
//!   ideal-led and magic-display say so outright. The glasses state no padding
//!   of their own: they name this handler and describe its framing as "shared
//!   with Magic Display", though their notes also call the protocol identical
//!   to the mask's. See `SPECS_TO_FIX.md`.
//! - `shiningmask_ecb`: filler. "Unused tail bytes are random padding (the app
//!   fills them from its RNG), not zeros — a receiver must not require zero
//!   padding."
//!
//! The vendor's RNG protects nothing, since the key is public and the first
//! byte says how much of the block counts, so [`Padding::Filler`] derives its
//! bytes from the plaintext. The tail is never zero, as on the mask's own
//! link, and one command always encrypts to one ciphertext, so the encoder
//! stays a pure function that tests can pin. Nothing here has been run against
//! hardware.

use super::cdbwsoft_ecb::{encrypt_block, HANDLER_NAME as CDBWSOFT_HANDLER};
use super::image_upload::declared_static_key;
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, DeviceSpec};

/// The cipher this module runs, as a spec's `encryption.algorithm` spells it.
const ALGORITHM: &str = "aes-128-ecb";

/// `protocol_handler` of `shining-mask.yaml`.
const SHINING_MASK_HANDLER: &str = "shiningmask_ecb";

/// One command is one cipher block.
const BLOCK: usize = 16;

/// The key [`bind_padding`] adds to an `encryption` block. Not a name the
/// catalogue's schema has yet.
const PADDING_KEY: &str = "padding";

/// How the bytes after a command's last meaningful byte are filled.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Padding {
    Zero,
    Filler,
}

impl Padding {
    fn name(self) -> &'static str {
        match self {
            Padding::Zero => "zero",
            Padding::Filler => "filler",
        }
    }

    fn parse(name: &str) -> Option<Self> {
        [Padding::Zero, Padding::Filler]
            .into_iter()
            .find(|p| p.name() == name)
    }
}

/// The padding each handler's family states in prose. See the module docs.
const HANDLER_PADDING: &[(&str, Padding)] = &[
    (CDBWSOFT_HANDLER, Padding::Zero),
    (SHINING_MASK_HANDLER, Padding::Filler),
];

/// State the padding of a named handler's `encryption` blocks on the blocks
/// themselves, because the encodability gates are handed a characteristic and
/// cannot see the spec's handler. Runs at parse time, like
/// `popled::bind_commands`. A spec naming any other handler is untouched, and
/// a padding the block already states is left alone.
pub fn bind_padding(spec: &mut DeviceSpec) {
    let Some(padding) = spec.protocol_handler.as_deref().and_then(|handler| {
        HANDLER_PADDING
            .iter()
            .find(|(name, _)| *name == handler)
            .map(|(_, padding)| *padding)
    }) else {
        return;
    };
    for service in &mut spec.services {
        for characteristic in &mut service.characteristics {
            if let Some(serde_yaml::Value::Mapping(block)) = characteristic.encryption.as_mut() {
                if !block.contains_key(PADDING_KEY) {
                    block.insert(PADDING_KEY.into(), padding.name().into());
                }
            }
        }
    }
}

/// The key and padding of a block this module can execute, or why it cannot.
fn cipher_of(characteristic: &Characteristic) -> Result<([u8; BLOCK], Padding), ProtocolError> {
    let invalid = |reason: String| ProtocolError::InvalidFraming { reason };
    // Which of the two would come first is stated nowhere.
    if characteristic.framing.is_some() {
        return Err(invalid(format!(
            "characteristic {} declares both encryption and framing",
            characteristic.uuid
        )));
    }
    let key = declared_static_key(characteristic, ALGORITHM).map_err(|e| invalid(e.to_string()))?;
    let padding = characteristic
        .encryption
        .as_ref()
        .and_then(|block| block.get(PADDING_KEY))
        .and_then(serde_yaml::Value::as_str)
        .and_then(Padding::parse)
        .ok_or_else(|| {
            invalid(format!(
                "nothing states how characteristic {} pads a block",
                characteristic.uuid
            ))
        })?;
    Ok((key, padding))
}

/// Whether [`encrypt_command`] can serve a characteristic that declares
/// encryption. The gates ask this, so a malformed key is refused on load
/// rather than when a control is pressed.
pub fn can_encrypt(characteristic: &Characteristic) -> bool {
    cipher_of(characteristic).is_ok()
}

/// One command's plaintext as the single encrypted block that goes on the
/// wire. A command longer than a block is refused, never truncated.
pub fn encrypt_command(
    characteristic: &Characteristic,
    plaintext: &[u8],
) -> Result<Vec<u8>, ProtocolError> {
    let (key, padding) = cipher_of(characteristic)?;
    encrypt_block(&key, pad(plaintext, padding)?)
}

fn pad(plaintext: &[u8], padding: Padding) -> Result<Vec<u8>, ProtocolError> {
    if plaintext.len() > BLOCK {
        return Err(ProtocolError::InvalidFraming {
            reason: format!(
                "a command is one {BLOCK}-byte cipher block, and this one renders {} bytes",
                plaintext.len()
            ),
        });
    }
    let mut block = plaintext.to_vec();
    match padding {
        Padding::Zero => block.resize(BLOCK, 0),
        Padding::Filler => {
            // FNV-1a of the plaintext, stepped once per byte of tail. `| 1`
            // keeps every byte nonzero.
            let mut state = plaintext.iter().fold(0x811C_9DC5u32, |hash, byte| {
                (hash ^ u32::from(*byte)).wrapping_mul(0x0100_0193)
            });
            while block.len() < BLOCK {
                state = state.wrapping_mul(0x0100_0193) ^ (state >> 15);
                block.push((state >> 24) as u8 | 1);
            }
        }
    }
    Ok(block)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;
    use aes::cipher::{BlockCipherDecrypt, KeyInit};

    const MASK_KEY: &str = "32672f7974ad43451d9c6c894a0e8764";
    const IDEAL_KEY: &str = "34522a5b7a6e492c08090a9d8d2a23f8";

    fn hex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
            .collect()
    }

    fn decrypt(key: &str, ciphertext: &[u8]) -> Vec<u8> {
        let key: [u8; 16] = hex(key).try_into().unwrap();
        let mut block: [u8; 16] = ciphertext.try_into().unwrap();
        aes::Aes128::new(&key.into()).decrypt_block((&mut block).into());
        block.to_vec()
    }

    fn spec_with(handler: &str, encryption: &str) -> DeviceSpec {
        parse_device_spec(&format!(
            r#"
device:
  name: "Test"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
protocol_handler: "{handler}"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "d44bc439-abfd-45a2-b575-925416129600"
        name: "Command"
        properties: ["write"]
        encryption: {encryption}
"#
        ))
        .unwrap()
    }

    fn only_characteristic(spec: &DeviceSpec) -> &Characteristic {
        &spec.services[0].characteristics[0]
    }

    fn complete(key: &str) -> String {
        format!(r#"{{ algorithm: "aes-128-ecb", key_derivation: "static", static_key: "{key}" }}"#)
    }

    /// FIPS-197 appendix C.1, so the primitive under the padding is checked
    /// against the standard rather than against itself.
    #[test]
    fn the_cipher_is_aes_128() {
        let key: [u8; 16] = hex("000102030405060708090a0b0c0d0e0f").try_into().unwrap();
        let out = encrypt_block(&key, hex("00112233445566778899aabbccddeeff")).unwrap();
        assert_eq!(out, hex("69c4e0d86a7b0430d8cdb78070b4c55a"));
    }

    /// ideal-led's `power_on` (`05 'TURN' 01`, zero-padded per its notes)
    /// under its key. The ciphertext was computed separately with
    /// `openssl enc -aes-128-ecb -nopad`.
    #[test]
    fn a_zero_padded_command_matches_an_independent_ciphertext() {
        let spec = spec_with("cdbwsoft_ecb", &complete(IDEAL_KEY));
        let out = encrypt_command(only_characteristic(&spec), &hex("055455524e01")).unwrap();
        assert_eq!(out, hex("84dd5042374150897ac82f39110968a8"));
        assert_eq!(decrypt(IDEAL_KEY, &out)[6..], [0u8; 10]);
    }

    /// The mask's fill: the tail is nonzero as the spec says, the plaintext
    /// survives in front of it, and the same command encrypts the same way
    /// every time.
    #[test]
    fn a_filler_padded_command_is_deterministic_and_never_zero_filled() {
        let spec = spec_with("shiningmask_ecb", &complete(MASK_KEY));
        let characteristic = only_characteristic(&spec);
        // shining-mask set_brightness 0x80: [0x06, "LIGHT", 0x80].
        let plaintext = hex("064c4947485480");
        let first = encrypt_command(characteristic, &plaintext).unwrap();
        assert_eq!(first, encrypt_command(characteristic, &plaintext).unwrap());
        assert_eq!(first.len(), BLOCK);

        let block = decrypt(MASK_KEY, &first);
        assert_eq!(block[..plaintext.len()], plaintext);
        assert!(block[plaintext.len()..].iter().all(|b| *b != 0));

        // Pinned, so that a change of fill is a deliberate one. The fill and
        // the ciphertext were worked out separately, in Python and with
        // `openssl enc -aes-128-ecb -nopad`.
        assert_eq!(block, hex("064c4947485480f58d1d91d1738fb9a9"));
        assert_eq!(first, hex("2504606a6fa236e2b5f17ce231b65c50"));

        // A different command gets a different tail.
        let other = decrypt(
            MASK_KEY,
            &encrypt_command(characteristic, &hex("064c4947485481")).unwrap(),
        );
        assert_ne!(block[7..], other[7..]);
    }

    #[test]
    fn a_full_block_takes_no_padding_and_a_longer_one_is_refused() {
        let spec = spec_with("cdbwsoft_ecb", &complete(IDEAL_KEY));
        let characteristic = only_characteristic(&spec);
        let full: Vec<u8> = (0..16).collect();
        let out = encrypt_command(characteristic, &full).unwrap();
        assert_eq!(decrypt(IDEAL_KEY, &out), full);
        assert!(encrypt_command(characteristic, &[0u8; 17]).is_err());
    }

    /// Everything [`can_encrypt`] must say no to. The last is a complete key
    /// on a handler that states no padding, which is the "don't guess" case.
    #[test]
    fn only_a_complete_static_block_with_a_stated_padding_can_encrypt() {
        for (handler, encryption) in [
            (
                "cdbwsoft_ecb",
                r#"{ algorithm: "aes-128-ecb", key_derivation: "device-specific" }"#.to_string(),
            ),
            (
                "cdbwsoft_ecb",
                r#"{ algorithm: "aes-128-ofb", key_derivation: "static", static_key: "00" }"#
                    .to_string(),
            ),
            (
                "cdbwsoft_ecb",
                r#"{ algorithm: "aes-128-ecb", key_derivation: "static", static_key: "abcd" }"#
                    .to_string(),
            ),
            (
                "cdbwsoft_ecb",
                r#"{ algorithm: "aes-128-ecb" }"#.to_string(),
            ),
            ("somebody_elses", complete(IDEAL_KEY)),
        ] {
            let spec = spec_with(handler, &encryption);
            assert!(
                !can_encrypt(only_characteristic(&spec)),
                "{handler} {encryption}"
            );
        }
        let spec = spec_with("cdbwsoft_ecb", &complete(IDEAL_KEY));
        assert!(can_encrypt(only_characteristic(&spec)));
    }

    /// A block that states its own padding needs no handler, and one that
    /// states a padding this build does not know stays refused.
    #[test]
    fn a_padding_the_block_states_itself_wins() {
        let stated = |padding: &str| {
            format!(
                r#"{{ algorithm: "aes-128-ecb", key_derivation: "static", static_key: "{IDEAL_KEY}", padding: "{padding}" }}"#
            )
        };
        let spec = spec_with("somebody_elses", &stated("zero"));
        assert!(can_encrypt(only_characteristic(&spec)));

        let spec = spec_with("cdbwsoft_ecb", &stated("filler"));
        let out = encrypt_command(only_characteristic(&spec), &[1, 2]).unwrap();
        assert!(decrypt(IDEAL_KEY, &out)[2..].iter().all(|b| *b != 0));

        let spec = spec_with("cdbwsoft_ecb", &stated("pkcs7"));
        assert!(!can_encrypt(only_characteristic(&spec)));
    }

    #[test]
    fn encryption_beside_framing_is_refused() {
        let mut spec = spec_with("cdbwsoft_ecb", &complete(IDEAL_KEY));
        spec.services[0].characteristics[0].framing =
            Some(serde_yaml::from_str("{ length_prefix: true }").unwrap());
        assert!(!can_encrypt(only_characteristic(&spec)));
    }
}

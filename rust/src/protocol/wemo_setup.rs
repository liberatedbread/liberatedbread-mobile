// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The algorithmic half of adopting a reset Wemo device: turning a WiFi
//! passphrase into the encrypted `password` argument of
//! `ConnectHomeNetwork`, and turning the device's `GetApList` reply into a
//! list a person can pick a network from.
//!
//! Everything here transcribes `device.setup` in the Wemo spec
//! (`softap.credential_encryption` and `payload_formats.ApList`), the same
//! way `soap` transcribes the rendering rules. The conversation itself —
//! probe the AP, ask, encrypt, send twice, poll — is I/O and lives with the
//! caller; this module is pure functions so the spec's own test vectors can
//! pin every byte without a device in the room.

use aes::cipher::{block_padding::Pkcs7, BlockEncryptMut, KeyIvInit};
use base64::engine::general_purpose::STANDARD as BASE64;
use base64::Engine;
use md5::{Digest, Md5};

use crate::error::ProtocolError;

type Aes128CbcEnc = cbc::Encryptor<aes::Aes128>;

/// One key-derivation layout. The spec numbers them 1-3; which one a device
/// wants follows from `rtos`/`iot` in its setup.xml, unreliably — see
/// [`password_candidates`] for the sweep that copes with that.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KeydataMethod {
    /// `mac[0:6] + serial + mac[6:12]` — the default.
    Method1,
    /// Method 1's layout plus a constant suffix; selected by `rtos=1` without
    /// `iot=1`.
    Method2,
    /// Shuffled MAC around a different constant; associated with
    /// `binaryOption=1` but reported to match hardware less often than the
    /// rtos/iot rule.
    Method3,
}

impl KeydataMethod {
    pub fn number(self) -> u8 {
        match self {
            KeydataMethod::Method1 => 1,
            KeydataMethod::Method2 => 2,
            KeydataMethod::Method3 => 3,
        }
    }
}

/// Spec constants, verbatim: the method 2 and method 3 keydata suffixes.
const METHOD2_SUFFIX: &str = "b3{8t;80dIN{ra83eC1s?M70?683@2Yf";
const METHOD3_INFIX: &str = "b2Ujb3Rtb24mY3ZEbmlhaXBBZGFiT25v";

/// The spec's passphrase floor: the device rejects anything shorter with
/// network status 2, so refusing here turns a silent terminal failure into a
/// message before any network I/O.
pub const MIN_PASSPHRASE: usize = 8;
/// The spec's ceiling, from the two-hex-digit length suffix.
pub const MAX_PASSPHRASE: usize = 255;

/// One encrypted passphrase attempt: what to send, and which variant built it
/// so a caller can say which one finally worked.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PasswordCandidate {
    pub method: u8,
    pub add_lengths: bool,
    /// The `password` argument of `ConnectHomeNetwork`, exactly.
    pub password: String,
}

/// The MAC and serial out of a `GetMetaInfo` reply.
///
/// The spec's warning transcribed: field order matters, and swapping them
/// yields a valid-looking blob the device rejects without explanation — so
/// the MAC's shape is checked rather than trusted.
pub fn parse_meta_info(meta_info: &str) -> Result<(String, String), ProtocolError> {
    let mut fields = meta_info.split('|');
    let mac = fields.next().unwrap_or_default().trim();
    let serial = fields.next().unwrap_or_default().trim();
    if mac.len() != 12 || !mac.chars().all(|c| c.is_ascii_hexdigit()) {
        return Err(ProtocolError::ParameterInvalid {
            name: "MetaInfo".to_string(),
            value: 0.0,
            reason: format!(
                "field 0 should be a 12-hex-character MAC, got {:?} — the device's reply is not in the documented layout",
                mac
            ),
        });
    }
    if serial.is_empty() {
        return Err(ProtocolError::ParameterInvalid {
            name: "MetaInfo".to_string(),
            value: 0.0,
            reason: "field 1 (serial number) is empty".to_string(),
        });
    }
    Ok((mac.to_string(), serial.to_string()))
}

/// The key material for one method, exactly as the spec lays it out.
fn keydata(method: KeydataMethod, mac: &str, serial: &str) -> String {
    match method {
        KeydataMethod::Method1 => format!("{}{}{}", &mac[0..6], serial, &mac[6..12]),
        KeydataMethod::Method2 => {
            format!("{}{}{}{}", &mac[0..6], serial, &mac[6..12], METHOD2_SUFFIX)
        }
        KeydataMethod::Method3 => format!(
            "{}{}{}{}{}{}",
            &mac[0..3],
            &mac[9..12],
            serial,
            METHOD3_INFIX,
            &mac[6..9],
            &mac[3..6]
        ),
    }
}

/// Encrypt one passphrase with one variant — the spec's `algorithm_steps`,
/// one step per line.
///
/// The `mac` must be the 12-hex-character field 0 of MetaInfo and `serial`
/// field 1; [`parse_meta_info`] produces both. Fails rather than truncates
/// when the passphrase is outside the device's documented bounds.
pub fn encrypt_password(
    mac: &str,
    serial: &str,
    passphrase: &str,
    method: KeydataMethod,
    add_lengths: bool,
) -> Result<String, ProtocolError> {
    if passphrase.len() < MIN_PASSPHRASE {
        return Err(ProtocolError::ParameterInvalid {
            name: "passphrase".to_string(),
            value: passphrase.len() as f64,
            reason: format!(
                "shorter than {MIN_PASSPHRASE} characters — the device rejects it (network status 2)"
            ),
        });
    }
    if passphrase.len() > MAX_PASSPHRASE {
        return Err(ProtocolError::ParameterInvalid {
            name: "passphrase".to_string(),
            value: passphrase.len() as f64,
            reason: format!("longer than {MAX_PASSPHRASE} characters"),
        });
    }
    // Steps 2-3: salt and iv are CHARACTERS of keydata as UTF-8 bytes, not
    // hex-decoded. Keydata opens with 6 hex digits + serial, all ASCII, so
    // byte slicing equals character slicing; the MAC shape was validated.
    let keydata = keydata(method, mac, serial);
    let key_bytes = keydata.as_bytes();
    if key_bytes.len() < 16 {
        return Err(ProtocolError::ParameterInvalid {
            name: "MetaInfo".to_string(),
            value: key_bytes.len() as f64,
            reason: "keydata shorter than 16 characters — serial number too short".to_string(),
        });
    }
    let salt = &key_bytes[0..8];
    let iv: [u8; 16] = key_bytes[0..16].try_into().expect("sliced to 16");

    // Step 4: one MD5 round over keydata || salt, truncated to 16 bytes —
    // OpenSSL's legacy EVP_BytesToKey with the IV supplied explicitly.
    let mut hasher = Md5::new();
    hasher.update(key_bytes);
    hasher.update(salt);
    let digest = hasher.finalize();
    let aes_key: [u8; 16] = digest[0..16].try_into().expect("md5 is 16 bytes");

    // Steps 5-6: PKCS#7 pad, AES-128-CBC.
    let ciphertext = Aes128CbcEnc::new(&aes_key.into(), &iv.into())
        .encrypt_padded_vec_mut::<Pkcs7>(passphrase.as_bytes());

    // Step 7: standard base64, '=' padding kept.
    let encoded = BASE64.encode(&ciphertext);

    // Step 8: two lengths as lowercase hex, EACH zero-padded to exactly two
    // digits — '08', not '8'. Both must fit two digits, which is where the
    // spec's 255 ceiling comes from.
    if !add_lengths {
        return Ok(encoded);
    }
    if encoded.len() > 0xFF {
        return Err(ProtocolError::ParameterInvalid {
            name: "passphrase".to_string(),
            value: passphrase.len() as f64,
            reason: "encrypts to a base64 string longer than 255 characters, which the length suffix cannot express".to_string(),
        });
    }
    Ok(format!(
        "{}{:02x}{:02x}",
        encoded,
        encoded.len(),
        passphrase.len()
    ))
}

/// Every encryption variant worth sending, in the order to try them.
///
/// The spec's troubleshooting order verbatim — (1,true), (2,false), (3,true),
/// then the three unlikely-but-cheap pairings — with one adjustment it also
/// states: when setup.xml said `rtos=1` and not `iot=1`, method 2 is the
/// documented selection, so its documented pairing moves to the front.
pub fn password_candidates(
    meta_info: &str,
    passphrase: &str,
    rtos: Option<i64>,
    iot: Option<i64>,
) -> Result<Vec<PasswordCandidate>, ProtocolError> {
    let (mac, serial) = parse_meta_info(meta_info)?;
    let sweep: &[(KeydataMethod, bool)] = &[
        (KeydataMethod::Method1, true),
        (KeydataMethod::Method2, false),
        (KeydataMethod::Method3, true),
        (KeydataMethod::Method1, false),
        (KeydataMethod::Method2, true),
        (KeydataMethod::Method3, false),
    ];
    let prefers_method2 = rtos == Some(1) && iot != Some(1);

    let mut ordered: Vec<(KeydataMethod, bool)> = Vec::with_capacity(sweep.len());
    if prefers_method2 {
        ordered.push((KeydataMethod::Method2, false));
    }
    for pair in sweep {
        if !ordered.contains(pair) {
            ordered.push(*pair);
        }
    }

    ordered
        .into_iter()
        .map(|(method, add_lengths)| {
            encrypt_password(&mac, &serial, passphrase, method, add_lengths).map(|password| {
                PasswordCandidate {
                    method: method.number(),
                    add_lengths,
                    password,
                }
            })
        })
        .collect()
}

/// One network out of a `GetApList` reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WemoAccessPoint {
    pub ssid: String,
    /// Verbatim, because it goes back verbatim as the `channel` argument.
    pub channel: String,
    /// The AUTHMODE half of the last column, e.g. `WPA2PSK`, `OPEN` — or
    /// `Unknown`, the device saying it cannot express that network's
    /// security (WPA3 appears this way).
    pub auth: String,
    /// The CIPHER half, e.g. `AES`, `NONE`. Absent when the last column had
    /// no '/', which is how `Unknown` arrives.
    pub encrypt: Option<String>,
    /// Whether the device can join this network at all. False for the
    /// `Unknown` marker — the remedy is a WPA2 SSID, not a retry.
    pub joinable: bool,
}

impl WemoAccessPoint {
    /// An open network takes `auth=OPEN, encrypt=NONE` and an empty
    /// password, skipping the encryption entirely — the spec's
    /// `open_network_handling` rule.
    pub fn is_open(&self) -> bool {
        self.encrypt.as_deref() == Some("NONE")
    }
}

/// Parse a `GetApList` reply — `payload_formats.ApList`'s rules, one per
/// line of this function.
pub fn parse_ap_list(ap_list: &str) -> Vec<WemoAccessPoint> {
    ap_list
        .lines()
        // Rule 1: the first line is a header/count, not an access point.
        .skip(1)
        .filter_map(|line| {
            // Rule 2: strip whitespace and the common trailing comma.
            let line = line.trim().trim_end_matches(',');
            // Rule 3: no '|' means a blank or partial trailing line.
            if !line.contains('|') {
                return None;
            }
            let columns: Vec<&str> = line.split('|').collect();
            let ssid = columns[0].to_string();
            if ssid.is_empty() {
                return None;
            }
            let channel = columns.get(1).copied().unwrap_or_default().to_string();
            // Rule 5: the LAST column is AUTHMODE/CIPHER — never a fixed
            // index, the column count varies.
            let last = columns.last().copied().unwrap_or_default();
            let (auth, encrypt) = match last.split_once('/') {
                Some((auth, cipher)) => (auth.to_string(), Some(cipher.to_string())),
                None => (last.to_string(), None),
            };
            let joinable = encrypt.is_some() && !auth.eq_ignore_ascii_case("unknown");
            Some(WemoAccessPoint {
                ssid,
                channel,
                auth,
                encrypt,
                joinable,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The spec's own test vectors (`credential_encryption.test_vectors`),
    /// transcribed. The integration test in `tests/wifi_setup.rs` reads the
    /// same values out of the catalogue YAML so the two cannot drift apart
    /// silently.
    const MAC: &str = "00005E00530A";
    const SERIAL: &str = "229999K9999999";
    const META_INFO: &str =
        "00005E00530A|229999K9999999|Wemo_WW|WeMo_US_2.00.11408|Wemo.Mini.4A2|Socket";
    const PASSPHRASE: &str = "correct horse battery staple";

    #[test]
    fn method_1_reproduces_the_spec_vector() {
        let got = encrypt_password(MAC, SERIAL, PASSPHRASE, KeydataMethod::Method1, true).unwrap();
        assert_eq!(got, "mKUXMHrq3r71VIBnALtgaQH/iTpWEZSSMVizvzMXrVM=2c1c");
    }

    #[test]
    fn method_2_reproduces_the_spec_vector_and_appends_no_lengths() {
        let got = encrypt_password(MAC, SERIAL, PASSPHRASE, KeydataMethod::Method2, false).unwrap();
        assert_eq!(got, "9ibm3ouYHODjuzVQ0hEHGkEdj4Pf/uCQ0vr8s8Ghuyk=");
    }

    #[test]
    fn method_3_reproduces_the_spec_vector() {
        let got = encrypt_password(MAC, SERIAL, PASSPHRASE, KeydataMethod::Method3, true).unwrap();
        assert_eq!(got, "JHw2xNnoahVM1rEfW1N2HDn4UT/v60Up80M4Nd3xAQo=2c1c");
    }

    #[test]
    fn the_length_suffix_is_zero_padded() {
        // 8 characters is the shortest legal passphrase and its length must
        // arrive as '08' — the spec calls this digit out.
        let got = encrypt_password(MAC, SERIAL, "12345678", KeydataMethod::Method1, true).unwrap();
        assert!(got.ends_with("08"), "suffix of {got:?} is not zero-padded");
        let b64_len = got.len() - 4;
        assert_eq!(&got[b64_len..b64_len + 2], format!("{b64_len:02x}"));
    }

    #[test]
    fn a_short_passphrase_is_refused_before_any_io() {
        let err =
            encrypt_password(MAC, SERIAL, "seven77", KeydataMethod::Method1, true).unwrap_err();
        assert!(err.to_string().contains("network status 2"), "{err}");
    }

    #[test]
    fn meta_info_parses_and_validates_the_mac_shape() {
        assert_eq!(
            parse_meta_info(META_INFO).unwrap(),
            (MAC.to_string(), SERIAL.to_string())
        );
        // Swapped fields — the exact trap the spec warns about — fail loudly
        // because a serial is not 12 hex characters.
        let swapped = format!("{SERIAL}|{MAC}");
        assert!(parse_meta_info(&swapped).is_err());
        assert!(parse_meta_info("").is_err());
    }

    #[test]
    fn candidates_follow_the_spec_sweep_order() {
        let got = password_candidates(META_INFO, PASSPHRASE, None, None).unwrap();
        let order: Vec<(u8, bool)> = got.iter().map(|c| (c.method, c.add_lengths)).collect();
        assert_eq!(
            order,
            [
                (1, true),
                (2, false),
                (3, true),
                (1, false),
                (2, true),
                (3, false)
            ]
        );
        assert_eq!(
            got[0].password,
            "mKUXMHrq3r71VIBnALtgaQH/iTpWEZSSMVizvzMXrVM=2c1c"
        );
    }

    #[test]
    fn rtos_without_iot_moves_method_2_to_the_front() {
        let got = password_candidates(META_INFO, PASSPHRASE, Some(1), Some(0)).unwrap();
        assert_eq!((got[0].method, got[0].add_lengths), (2, false));
        // Still six distinct attempts, nothing sent twice.
        assert_eq!(got.len(), 6);
        // An iot=1 device is NOT the method 2 selection.
        let got = password_candidates(META_INFO, PASSPHRASE, Some(1), Some(1)).unwrap();
        assert_eq!((got[0].method, got[0].add_lengths), (1, true));
    }

    #[test]
    fn the_spec_example_ap_list_parses_by_its_own_rules() {
        // Verbatim from `payload_formats.ApList.example`.
        let example = "3\nHomeNet|6|WPA2PSK|blah|WPA2PSK/AES,\nOpenGuest|1|OPEN|blah|OPEN/NONE,\nNewFangled|1|SAE|blah|Unknown,\n";
        let got = parse_ap_list(example);
        assert_eq!(got.len(), 3);
        assert_eq!(got[0].ssid, "HomeNet");
        assert_eq!(got[0].channel, "6");
        assert_eq!(got[0].auth, "WPA2PSK");
        assert_eq!(got[0].encrypt.as_deref(), Some("AES"));
        assert!(got[0].joinable);
        assert!(!got[0].is_open());

        assert!(got[1].is_open(), "OPEN/NONE is the open-network shape");
        assert!(got[1].joinable);

        // The WPA3 network: the device cannot join it and the entry says so.
        assert_eq!(got[2].auth, "Unknown");
        assert_eq!(got[2].encrypt, None);
        assert!(!got[2].joinable);
    }

    #[test]
    fn ap_list_tolerates_blank_and_partial_trailing_lines() {
        let got = parse_ap_list("1\nHomeNet|6|WPA2PSK/AES,\n\n   \ngarbage-no-pipes\n");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].auth, "WPA2PSK");
    }

    #[test]
    fn the_first_line_is_skipped_even_when_it_looks_like_an_ap() {
        // The header is positional, not recognised by shape.
        let got = parse_ap_list("Header|0|X/Y\nRealNet|11|WPA2PSK/AES");
        assert_eq!(got.len(), 1);
        assert_eq!(got[0].ssid, "RealNet");
    }
}

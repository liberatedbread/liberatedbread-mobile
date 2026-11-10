// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Read an Enel X JuiceBox's JuiceNet status lines (`enel-x-juicebox.yaml`,
//! handler `juicenet_udp`). READ-ONLY, plaintext only.
//!
//! The charger is the UDP client: once one of the spec's setup routes points
//! its stream at this phone, it sends one ASCII status line every 9-30 s
//! (`protocol_details.juicenet_udp`). This module reads those lines: the
//! base-35 hash (`protocol_details.crc`), the `<letter><integer>` fields by
//! letter, the legacy and debug forms, and the encrypted `v09e` / `v08`
//! frames, which it recognises and refuses because their cipher is unknown.
//!
//! It builds no reply. The CMD line a server answers with is how the
//! charging current is set (`set_online_current`, `set_offline_current`),
//! and the spec's own advisory says a value above the circuit's rating can
//! overheat the wiring and the offline value is written to EEPROM. There is
//! no CMD encoder here outside the tests that check the hash against the
//! spec's CMD vectors.
//!
//! Not listening to a charger changes nothing about it: with no reply it
//! falls back to its offline limit after about five minutes, which is what
//! it has done since the vendor's servers went away.

/// The spec `protocol_handler` this module answers to.
pub const HANDLER_NAME: &str = "juicenet_udp";

/// The port the charger falls back to with no directory answer
/// (`ports_seen`: jbv1.emotorwerks.com:8042). Any port works; this is only
/// the listener's default.
pub const DEFAULT_LISTEN_PORT: u16 = 8042;

/// `protocol_details.crc`'s digit alphabet: 0-9, A-N, Z for 24, P-Y.
const ALPHABET: &[u8; 35] = b"0123456789ABCDEFGHIJKLMNZPQRSTUVWXY";

const ID_LEN: usize = 28;

/// Longest datagram worth reading as a line. Real ones are under 200 bytes.
const MAX_LINE: usize = 1024;

/// The 16-bit JuiceNet hash of `payload` (everything before `!`).
pub fn hash(payload: &[u8]) -> u16 {
    let mut h: u32 = 0;
    for &c in payload {
        h = (h ^ ((h << 5) + (h >> 2) + u32::from(c))) & 0xFFFF;
    }
    h as u16
}

/// The hash as the wire writes it: modulo 35^3, three base-35 digits, least
/// significant first.
pub fn hash_text(payload: &[u8]) -> String {
    let mut value = u32::from(hash(payload)) % (35 * 35 * 35);
    let mut out = String::with_capacity(3);
    for _ in 0..3 {
        out.push(char::from(ALPHABET[(value % 35) as usize]));
        value /= 35;
    }
    out
}

/// What a datagram turned out to be.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JuiceNetFrameKind {
    /// A `v07` / `v09u` status line whose hash checks.
    Status,
    /// A pre-v07 status line: no version tag, no hash.
    Legacy,
    /// `<id>:DBG,<LVL>:<text>:`.
    Debug,
    /// `v09e` / `v08`: recognised, and not decodable by anyone.
    Encrypted,
    /// Anything else, including a status line whose hash does not match.
    Invalid,
}

/// One datagram, read.
#[derive(Debug, Clone, PartialEq)]
pub struct JuiceNetFrameDto {
    pub kind: JuiceNetFrameKind,
    pub unit_id: Option<String>,
    pub version: Option<String>,
    pub status_code: Option<i64>,
    pub status_text: Option<String>,
    /// Field A × 0.1; 0 when absent on a status line (nothing plugged in).
    pub current_amps: Option<f64>,
    pub voltage: Option<f64>,
    /// V × A, which is not on the wire.
    pub power_watts: Option<f64>,
    pub session_wh: Option<i64>,
    pub lifetime_wh: Option<i64>,
    pub temperature_c: Option<i64>,
    pub frequency_hz: Option<f64>,
    pub rated_amps: Option<i64>,
    /// Field M: the online limit in force.
    pub online_limit_amps: Option<i64>,
    /// Field C: the offline limit (generation 2 only).
    pub offline_limit_amps: Option<i64>,
    pub debug_text: Option<String>,
    /// Why a frame was refused or what it means, in words.
    pub note: Option<String>,
}

impl JuiceNetFrameDto {
    fn bare(kind: JuiceNetFrameKind) -> Self {
        Self {
            kind,
            unit_id: None,
            version: None,
            status_code: None,
            status_text: None,
            current_amps: None,
            voltage: None,
            power_watts: None,
            session_wh: None,
            lifetime_wh: None,
            temperature_c: None,
            frequency_hz: None,
            rated_amps: None,
            online_limit_amps: None,
            offline_limit_amps: None,
            debug_text: None,
            note: None,
        }
    }

    fn invalid(note: &str) -> Self {
        Self {
            note: Some(note.to_string()),
            ..Self::bare(JuiceNetFrameKind::Invalid)
        }
    }
}

/// `payload_formats.StatusCode`.
pub fn status_text(code: i64) -> &'static str {
    match code {
        0 => "Unplugged",
        1 => "Plugged in, not charging",
        2 => "Charging",
        5 => "Error",
        _ => "A status code the spec does not explain",
    }
}

/// One `<letter><integer>` token; the integer may be negative.
fn field(token: &str) -> Option<(char, &str, i64)> {
    let mut chars = token.chars();
    let letter = chars.next().filter(char::is_ascii_alphabetic)?;
    let digits = chars.as_str();
    let unsigned = digits.strip_prefix('-').unwrap_or(digits);
    if unsigned.is_empty() || !unsigned.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some((letter, unsigned, digits.parse().ok()?))
}

/// Read the comma-separated fields by letter, first occurrence winning.
fn read_fields(frame: &mut JuiceNetFrameDto, tokens: &[&str], legacy: bool) -> Result<(), ()> {
    let mut seen = std::collections::HashSet::new();
    for token in tokens {
        let (letter, digits, value) = field(token).ok_or(())?;
        if !seen.insert(letter) {
            continue;
        }
        match letter {
            'S' => {
                frame.status_code = Some(value);
                frame.status_text = Some(status_text(value).to_string());
            }
            'A' => frame.current_amps = Some(value as f64 / 10.0),
            'V' => {
                frame.voltage = Some(if digits.len() < 4 {
                    value as f64
                } else {
                    value as f64 / 10.0
                });
            }
            'E' => frame.session_wh = Some(value),
            'L' => frame.lifetime_wh = Some(value),
            'T' => frame.temperature_c = Some(value),
            'f' => frame.frequency_hz = Some(value as f64 / 100.0),
            'm' => frame.rated_amps = Some(value),
            'M' => frame.online_limit_amps = Some(value),
            'C' => frame.offline_limit_amps = Some(value),
            _ => {}
        }
    }
    if frame.current_amps.is_none() && !legacy {
        frame.current_amps = Some(0.0);
    }
    if let (Some(v), Some(a)) = (frame.voltage, frame.current_amps) {
        frame.power_watts = Some((v * a * 10.0).round() / 10.0);
    }
    if legacy && frame.status_code.is_none() {
        // The legacy format has no S; A > 0 means charging.
        if let Some(a) = frame.current_amps {
            let code = if a > 0.0 { 2 } else { 0 };
            frame.status_code = Some(code);
            frame.status_text = Some(status_text(code).to_string());
        }
    }
    Ok(())
}

fn valid_id(id: &str) -> bool {
    id.len() == ID_LEN && id.bytes().all(|b| b.is_ascii_digit())
}

/// Read one datagram from the charger. Never an error: what cannot be read
/// comes back as [`JuiceNetFrameKind::Invalid`] with a note.
pub fn parse_datagram(datagram: &[u8]) -> JuiceNetFrameDto {
    if datagram.len() > MAX_LINE {
        return JuiceNetFrameDto::invalid("too long to be a JuiceNet line");
    }
    // The ID and tag are readable even on an encrypted frame, which carries
    // binary after them, so look at those bytes before asking for text.
    let Some(colon) = datagram.iter().position(|b| *b == b':') else {
        return JuiceNetFrameDto::invalid("not a JuiceNet line");
    };
    let Ok(id) = std::str::from_utf8(&datagram[..colon]) else {
        return JuiceNetFrameDto::invalid("not a JuiceNet line");
    };
    let rest = &datagram[colon + 1..];
    if valid_id(id) && (rest.starts_with(b"v09e") || rest.starts_with(b"v08")) {
        let tag_end = rest
            .iter()
            .position(|b| !b.is_ascii_alphanumeric())
            .unwrap_or(rest.len());
        return JuiceNetFrameDto {
            unit_id: Some(id.to_string()),
            version: std::str::from_utf8(&rest[..tag_end])
                .ok()
                .map(str::to_string),
            note: Some(
                "This charger is sending the encrypted protocol, which cannot be \
                 decoded: its cipher is not known. Units kept off the internet \
                 and power-cycled have come back on the plaintext protocol."
                    .to_string(),
            ),
            ..JuiceNetFrameDto::bare(JuiceNetFrameKind::Encrypted)
        };
    }
    let Ok(text) = std::str::from_utf8(datagram) else {
        return JuiceNetFrameDto::invalid("not text");
    };
    let text = text.trim_end_matches(['\r', '\n']);
    if !text.is_ascii() || !valid_id(id) {
        return JuiceNetFrameDto::invalid("not a JuiceNet line");
    }
    let body = &text[colon + 1..];

    if let Some(debug) = body.strip_prefix("DBG,") {
        return JuiceNetFrameDto {
            unit_id: Some(id.to_string()),
            debug_text: Some(debug.trim_end_matches(':').to_string()),
            ..JuiceNetFrameDto::bare(JuiceNetFrameKind::Debug)
        };
    }

    match text.split_once('!') {
        Some((payload, tail)) => {
            let Some(given) = tail.strip_suffix(':') else {
                return JuiceNetFrameDto::invalid("a status line must end in ':'");
            };
            if given.len() != 3 || given != hash_text(payload.as_bytes()) {
                return JuiceNetFrameDto::invalid(
                    "the line's hash does not match its contents; dropped",
                );
            }
            let body = &payload[colon + 1..];
            let mut tokens = body.split(',');
            let tag = tokens.next().unwrap_or_default();
            let Some(version) = tag.strip_prefix('v') else {
                return JuiceNetFrameDto::invalid("no version tag");
            };
            if !matches!(version, "07" | "09u") {
                return JuiceNetFrameDto {
                    unit_id: Some(id.to_string()),
                    version: Some(tag.to_string()),
                    note: Some(format!(
                        "protocol version {tag} is not one the spec describes"
                    )),
                    ..JuiceNetFrameDto::bare(JuiceNetFrameKind::Invalid)
                };
            }
            let mut frame = JuiceNetFrameDto {
                unit_id: Some(id.to_string()),
                version: Some(tag.to_string()),
                ..JuiceNetFrameDto::bare(JuiceNetFrameKind::Status)
            };
            let tokens: Vec<&str> = tokens.collect();
            if read_fields(&mut frame, &tokens, false).is_err() {
                return JuiceNetFrameDto::invalid("a field is not a letter and an integer");
            }
            frame
        }
        None => {
            let Some(body) = body.strip_suffix(':') else {
                return JuiceNetFrameDto::invalid("a status line must end in ':'");
            };
            let tokens: Vec<&str> = body.split(',').collect();
            let mut frame = JuiceNetFrameDto {
                unit_id: Some(id.to_string()),
                note: Some("Legacy (pre-v07) format, which carries no hash.".to_string()),
                ..JuiceNetFrameDto::bare(JuiceNetFrameKind::Legacy)
            };
            if read_fields(&mut frame, &tokens, true).is_err() {
                return JuiceNetFrameDto::invalid("not a JuiceNet line");
            }
            frame
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn spec_doc() -> serde_yaml::Value {
        serde_yaml::from_str(
            &std::fs::read_to_string(format!(
                "{}/../vendor/protocol-specs/device-specs/devices/enel-x-juicebox.yaml",
                env!("CARGO_MANIFEST_DIR")
            ))
            .unwrap(),
        )
        .unwrap()
    }

    fn s(v: &serde_yaml::Value) -> &str {
        v.as_str().unwrap()
    }

    #[test]
    fn the_handler_name_is_the_specs() {
        assert_eq!(s(&spec_doc()["protocol_handler"]), HANDLER_NAME);
    }

    /// `protocol_details.crc.worked_example`, and both CMD example bodies.
    /// The hash is checked on CMD lines here only: this module builds none.
    #[test]
    fn the_hash_reproduces_the_specs_vectors() {
        assert_eq!(hash(b"CMD31830A0016M040C006S001"), 34677);
        assert_eq!(hash_text(b"CMD31830A0016M040C006S001"), "RAS");
        let doc = spec_doc();
        for name in ["set_online_current", "set_offline_current"] {
            let example = s(&doc["commands"][name]["example_body"]);
            let (payload, tail) = example.split_once('!').unwrap();
            assert_eq!(
                format!("{}$", hash_text(payload.as_bytes())),
                tail,
                "{name}"
            );
        }
        assert_eq!(hash(b"CMD31830A0032M032C006S003"), 15120);
        let cmd = s(&doc["payload_formats"]["CommandMessage"]["example"]);
        let (payload, tail) = cmd.split_once('!').unwrap();
        assert_eq!(format!("{}$", hash_text(payload.as_bytes())), tail);
    }

    #[test]
    fn the_alphabet_skips_o_and_puts_z_at_24() {
        assert_eq!(ALPHABET.len(), 35);
        assert!(!ALPHABET.contains(&b'O'));
        assert_eq!(ALPHABET[24], b'Z');
        assert_eq!(ALPHABET[25], b'P');
        assert_eq!(ALPHABET[23], b'N');
    }

    #[test]
    fn the_specs_status_example_decodes() {
        let example = s(&spec_doc()["payload_formats"]["StatusMessage"]["example"]).to_string();
        let frame = parse_datagram(example.as_bytes());
        assert_eq!(frame.kind, JuiceNetFrameKind::Status, "{:?}", frame.note);
        assert_eq!(
            frame.unit_id.as_deref(),
            Some("0910000000000000000000004242")
        );
        assert_eq!(frame.version.as_deref(), Some("v09u"));
        assert_eq!(frame.status_code, Some(2));
        assert_eq!(frame.status_text.as_deref(), Some("Charging"));
        assert_eq!(frame.current_amps, Some(16.1));
        assert_eq!(frame.voltage, Some(240.0));
        assert_eq!(frame.power_watts, Some(3864.0));
        assert_eq!(frame.session_wh, Some(4501));
        assert_eq!(frame.lifetime_wh, Some(4_262_804));
        assert_eq!(frame.temperature_c, Some(28));
        assert_eq!(frame.frequency_hz, Some(59.9));
        assert_eq!(frame.rated_amps, Some(40));
        assert_eq!(frame.online_limit_amps, Some(24));
        assert_eq!(frame.offline_limit_amps, Some(40));
        // A trailing newline is tolerated.
        let with_newline = format!("{example}\r\n");
        assert_eq!(
            parse_datagram(with_newline.as_bytes()).kind,
            JuiceNetFrameKind::Status
        );
    }

    #[test]
    fn a_wrong_hash_is_dropped() {
        let example = s(&spec_doc()["payload_formats"]["StatusMessage"]["example"])
            .replace("A00161", "A00162");
        let frame = parse_datagram(example.as_bytes());
        assert_eq!(frame.kind, JuiceNetFrameKind::Invalid);
        assert!(frame.note.unwrap().contains("hash"));
        assert_eq!(frame.current_amps, None);
    }

    /// The legacy example in `legacy_grammar`, behind a unit ID: whole volts,
    /// a repeated E (first kept), no S, and A absent meaning not charging.
    #[test]
    fn a_legacy_line_reads_without_a_hash() {
        let frame =
            parse_datagram(b"0910000000000000000000004242:V247,L11097,S0,T34,E14,i84,e1,t30:");
        assert_eq!(frame.kind, JuiceNetFrameKind::Legacy);
        assert_eq!(frame.voltage, Some(247.0));
        assert_eq!(frame.lifetime_wh, Some(11097));
        assert_eq!(frame.session_wh, Some(14));
        assert_eq!(frame.status_code, Some(0));
        let repeated = parse_datagram(b"0910000000000000000000004242:V247,E14,E99,A100:");
        assert_eq!(repeated.session_wh, Some(14));
        assert_eq!(repeated.status_code, Some(2), "A > 0 means charging");
        assert_eq!(repeated.current_amps, Some(10.0));
    }

    #[test]
    fn a_debug_line_is_read_as_text() {
        let example = s(&spec_doc()["payload_formats"]["DebugMessage"]["example"]).to_string();
        let frame = parse_datagram(example.as_bytes());
        assert_eq!(frame.kind, JuiceNetFrameKind::Debug);
        assert!(frame
            .debug_text
            .unwrap()
            .starts_with("NFO:BOT:EMWERK-JB201-1.0.46"));
    }

    #[test]
    fn encrypted_frames_are_recognised_and_refused() {
        for tag in [&b"v09e"[..], b"v08", b"v08L"] {
            let mut datagram = b"0910000000000000000000004242:".to_vec();
            datagram.extend_from_slice(tag);
            datagram.extend_from_slice(&[0x00, 0xFF, 0x13, 0x88, 0xC3, 0x28]);
            let frame = parse_datagram(&datagram);
            assert_eq!(frame.kind, JuiceNetFrameKind::Encrypted);
            assert_eq!(frame.version.as_deref(), std::str::from_utf8(tag).ok());
            assert!(frame.note.unwrap().contains("cannot be decoded"));
            assert_eq!(frame.current_amps, None, "nothing is read from it");
        }
    }

    #[test]
    fn garbage_is_invalid() {
        for datagram in [
            &b""[..],
            b"hello",
            b"\xFF\xFE\xFD:v09u",
            b"123:v09u,s001!ABC:",
            b"0910000000000000000000004242:v09u,s001",
            b"0910000000000000000000004242:v09u,sXYZ!000:",
            b"CMD31830A0016M040C006S001!RAS$",
        ] {
            assert_eq!(
                parse_datagram(datagram).kind,
                JuiceNetFrameKind::Invalid,
                "{datagram:02x?}"
            );
        }
        assert_eq!(
            parse_datagram(&vec![b'1'; 5000]).kind,
            JuiceNetFrameKind::Invalid
        );
    }

    /// The spec's two writes are the CMD lines; both exist in the spec and
    /// this module has no public way to produce either.
    #[test]
    fn the_current_writes_exist_and_nothing_here_builds_them() {
        let spec = parse_device_spec(
            &std::fs::read_to_string(format!(
                "{}/../vendor/protocol-specs/device-specs/devices/enel-x-juicebox.yaml",
                env!("CARGO_MANIFEST_DIR")
            ))
            .unwrap(),
        )
        .unwrap();
        for name in ["set_online_current", "set_offline_current"] {
            assert!(spec.commands.contains_key(name), "{name}");
        }
        assert!(crate::protocol::readonly::is_read_only(&spec));
    }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The Rabbit Air purifier's BLE transport: how the byte payload a UDP
//! datagram would carry is framed and chunked for the GATT command
//! characteristic, and how the cleartext setup-phase envelopes are rendered.
//!
//! This module is the BLE sibling of [`crate::protocol::rabbit_air`]: the
//! PAYLOAD is identical (cleartext JSON during provisioning, AES-128-CBC
//! encrypted JSON once a user key has been pushed), what changes is the
//! framing. On BLE every message is prefixed with a 2-byte LITTLE-ENDIAN
//! uint16 length — of the payload only, the prefix itself not counted — and
//! then split into consecutive chunks of `chunk_size` bytes, written with
//! response; the device answers on ATT indications (hardware-verified
//! 2026-08-15: characteristic properties 0x28 = write + indicate) framed
//! the same way, so the first chunk of a reply announces the total payload
//! length the accumulator waits for.
//!
//! The setup phase — reading network settings, joining Wi-Fi, pushing the
//! user key — speaks CLEARTEXT minified JSON `{"id":..,"cmd":..}` envelopes
//! with NO `ts` field and no encryption; `id` is a per-client counter the
//! caller owns. The user key itself is generated client-side as 32 uppercase
//! hex characters (the 16 raw AES bytes [`crate::protocol::rabbit_air`] then
//! encrypts under).
//!
//! As in the LAN module, no I/O lives here: Dart owns the GATT connection,
//! the MTU negotiation, the notification accumulation, and the 7-second
//! response timeout.

use crate::error::ProtocolError;

/// The GATT service the purifier's provisioning/control protocol lives on.
pub const SERVICE_UUID: &str = "366048ae-9f36-43cf-8004-010c0c9fa52e";

/// The single command characteristic: write-with-response for requests,
/// ATT indications for responses (hardware properties 0x28 — indicate, not
/// notify).
pub const COMMAND_CHARACTERISTIC_UUID: &str = "53ef7d7d-c244-42bd-9064-a1569a521ca9";

/// The ATT MTU the vendor app negotiates. The client requests it before
/// sending; the device is not known to accept more.
pub const NEGOTIATED_MTU: u16 = 515;

/// The per-chunk overhead the MTU-5 rule prices in (the 3-byte ATT header
/// plus the 2-byte attribute handle of a write request), so a chunk's body
/// is at most `MTU - CHUNK_OVERHEAD` bytes.
pub const CHUNK_OVERHEAD: usize = 5;

/// The chunk size once [`NEGOTIATED_MTU`] is in effect: 510 bytes.
pub const NEGOTIATED_CHUNK_SIZE: usize = NEGOTIATED_MTU as usize - CHUNK_OVERHEAD;

/// The chunk size the vendor app uses before MTU negotiation completes.
pub const DEFAULT_CHUNK_SIZE: usize = 512;

/// The length prefix announcing each message's payload: a little-endian
/// uint16 counting the PAYLOAD bytes only.
const LEN_PREFIX_LEN: usize = 2;

/// Frame one payload for the wire: prepend the 2-byte little-endian payload
/// length, then split the result into consecutive chunks of `chunk_size`
/// bytes. The prefix rides INSIDE the chunked stream (the first chunk is the
/// 2 prefix bytes plus up to `chunk_size - 2` payload bytes), which is why
/// reassembly skips the prefix of the first chunk only.
///
/// `chunk_size` must be at least 3 — a chunk that cannot carry the prefix
/// plus one payload byte would frame nothing — and the payload must fit the
/// uint16 the prefix spells.
pub fn frame_payload(payload: &[u8], chunk_size: usize) -> Result<Vec<Vec<u8>>, ProtocolError> {
    if chunk_size < LEN_PREFIX_LEN + 1 {
        return Err(ProtocolError::ParameterInvalid {
            name: "chunk_size".to_string(),
            value: chunk_size as f64,
            reason: format!(
                "a chunk must carry the {LEN_PREFIX_LEN}-byte length prefix plus at least 1 payload byte"
            ),
        });
    }
    if payload.len() > u16::MAX as usize {
        return Err(ProtocolError::ParameterInvalid {
            name: "payload".to_string(),
            value: payload.len() as f64,
            reason: "the 2-byte length prefix counts at most 65535 payload bytes".to_string(),
        });
    }
    let mut framed = Vec::with_capacity(LEN_PREFIX_LEN + payload.len());
    framed.extend_from_slice(&(payload.len() as u16).to_le_bytes());
    framed.extend_from_slice(payload);
    Ok(framed.chunks(chunk_size).map(|c| c.to_vec()).collect())
}

/// The total payload length the first notification of a reply announces —
/// the 2-byte little-endian prefix, counting payload bytes only. `None` when
/// the chunk is shorter than the prefix, which the vendor app ignores when a
/// new message is expected.
pub fn expected_payload_len(first_chunk: &[u8]) -> Option<usize> {
    let prefix: [u8; LEN_PREFIX_LEN] = first_chunk.get(..LEN_PREFIX_LEN)?.try_into().ok()?;
    Some(u16::from_le_bytes(prefix) as usize)
}

/// Render a setup-phase envelope: minified JSON `{"id":id,"cmd":cmd}` with
/// `,"data":<object>` appended when `data_json` is supplied — the LAN
/// envelope minus `ts`, sent cleartext because encryption starts only once a
/// user key has been pushed (cmd 5, type 4). `id` is the caller's per-client
/// counter, starting at 0.
///
/// `data_json` must parse as a JSON OBJECT — the setup commands all take an
/// object of named fields, so a scalar here is a caller bug worth rejecting
/// at the edge rather than a surprise to the device.
pub fn render_setup_envelope(
    id: u32,
    cmd: u32,
    data_json: Option<&str>,
) -> Result<String, ProtocolError> {
    let mut out = serde_json::Map::new();
    out.insert("id".to_string(), serde_json::Value::from(id));
    out.insert("cmd".to_string(), serde_json::Value::from(cmd));
    if let Some(data_json) = data_json {
        match serde_json::from_str::<serde_json::Value>(data_json) {
            Ok(serde_json::Value::Object(data)) => {
                out.insert("data".to_string(), serde_json::Value::Object(data));
            }
            _ => {
                return Err(ProtocolError::InvalidStateReply(format!(
                    "a Rabbit Air setup envelope's data must be a JSON object, got: {data_json}"
                )))
            }
        }
    }
    serde_json::to_string(&serde_json::Value::Object(out))
        .map_err(|e| ProtocolError::InvalidStateReply(format!("envelope did not serialize: {e}")))
}

/// Generate a user key the way the vendor app does: 32 random uppercase hex
/// characters — the 16 raw AES bytes [`crate::protocol::rabbit_air::encrypt`]
/// consumes, spelled as the client must push them (cmd 5, type 4) and as
/// [`crate::protocol::rabbit_air::parse_user_key`] reads them back.
pub fn generate_user_key() -> String {
    const HEX: &[u8; 16] = b"0123456789ABCDEF";
    let mut bytes = [0u8; crate::protocol::rabbit_air::USER_KEY_LEN];
    getrandom::getrandom(&mut bytes).expect("the OS has a CSPRNG");
    let mut key = String::with_capacity(crate::protocol::rabbit_air::USER_KEY_LEN * 2);
    for byte in bytes {
        key.push(HEX[(byte >> 4) as usize] as char);
        key.push(HEX[(byte & 0x0F) as usize] as char);
    }
    key
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_short_message_is_one_chunk_with_the_prefix() {
        let payload = br#"{"id":0,"cmd":0}"#;
        let chunks = frame_payload(payload, NEGOTIATED_CHUNK_SIZE).unwrap();
        assert_eq!(chunks.len(), 1);
        assert_eq!(chunks[0].len(), LEN_PREFIX_LEN + payload.len());
        assert_eq!(chunks[0][0], payload.len() as u8, "little-endian LSB");
        assert_eq!(chunks[0][1], 0, "little-endian MSB");
        assert_eq!(&chunks[0][LEN_PREFIX_LEN..], payload);
    }

    #[test]
    fn the_prefix_counts_the_payload_only() {
        let payload = [0xABu8; 300];
        let chunks = frame_payload(&payload, NEGOTIATED_CHUNK_SIZE).unwrap();
        assert_eq!(chunks.len(), 1);
        assert_eq!(expected_payload_len(&chunks[0]), Some(300));
    }

    #[test]
    fn a_message_crossing_a_chunk_boundary_round_trips() {
        // 600 payload bytes at 510-byte chunks: the first chunk is full, the
        // second carries the remainder, and reassembly skipping only the
        // first chunk's prefix recovers exactly the payload.
        let payload: Vec<u8> = (0..600u32).map(|i| (i % 251) as u8).collect();
        let chunks = frame_payload(&payload, NEGOTIATED_CHUNK_SIZE).unwrap();
        assert_eq!(chunks.len(), 2);
        assert_eq!(chunks[0].len(), NEGOTIATED_CHUNK_SIZE);
        assert_eq!(
            chunks[1].len(),
            LEN_PREFIX_LEN + 600 - NEGOTIATED_CHUNK_SIZE
        );

        // Reassemble as the Dart accumulator will: length from the first
        // chunk, then bodies with only the first chunk's prefix skipped.
        let expected = expected_payload_len(&chunks[0]).unwrap();
        assert_eq!(expected, 600);
        let mut buffered = Vec::new();
        for (i, chunk) in chunks.iter().enumerate() {
            buffered.extend_from_slice(if i == 0 {
                &chunk[LEN_PREFIX_LEN..]
            } else {
                chunk
            });
        }
        assert_eq!(buffered, payload);
    }

    #[test]
    fn a_payload_exactly_filling_chunks_needs_no_partial_tail() {
        // Prefix + payload exactly two full chunks: no empty third chunk.
        let payload = vec![0x55u8; 2 * NEGOTIATED_CHUNK_SIZE - LEN_PREFIX_LEN];
        let chunks = frame_payload(&payload, NEGOTIATED_CHUNK_SIZE).unwrap();
        assert_eq!(chunks.len(), 2);
        assert!(chunks.iter().all(|c| c.len() == NEGOTIATED_CHUNK_SIZE));
    }

    #[test]
    fn an_empty_payload_frames_to_a_bare_prefix() {
        let chunks = frame_payload(&[], 512).unwrap();
        assert_eq!(chunks, vec![vec![0, 0]]);
    }

    #[test]
    fn chunking_rejects_a_size_that_cannot_hold_the_prefix() {
        for size in [0, 1, 2] {
            assert!(
                matches!(
                    frame_payload(b"ab", size),
                    Err(ProtocolError::ParameterInvalid { .. })
                ),
                "chunk_size {size}"
            );
        }
    }

    #[test]
    fn the_payload_must_fit_the_u16_prefix() {
        let payload = vec![0u8; u16::MAX as usize + 1];
        assert!(matches!(
            frame_payload(&payload, NEGOTIATED_CHUNK_SIZE),
            Err(ProtocolError::ParameterInvalid { .. })
        ));
        assert!(frame_payload(&payload[..u16::MAX as usize], NEGOTIATED_CHUNK_SIZE).is_ok());
    }

    #[test]
    fn the_expected_length_is_little_endian_and_needs_two_bytes() {
        assert_eq!(expected_payload_len(&[]), None);
        assert_eq!(expected_payload_len(&[0x2C]), None);
        assert_eq!(expected_payload_len(&[0x2C, 0x01]), Some(300));
        assert_eq!(expected_payload_len(&[0x2C, 0x01, 0x99, 0x88]), Some(300));
        assert_eq!(expected_payload_len(&[0x00, 0x00]), Some(0));
    }

    #[test]
    fn a_setup_envelope_without_data_is_id_and_cmd_only() {
        assert_eq!(
            render_setup_envelope(0, 0, None).unwrap(),
            r#"{"id":0,"cmd":0}"#
        );
    }

    #[test]
    fn a_setup_envelope_carries_data_last() {
        let envelope = render_setup_envelope(
            3,
            1,
            Some(r#"{"ssid":"Cottage","passphrase":"hunter2","security":3}"#),
        )
        .unwrap();
        assert_eq!(
            envelope,
            r#"{"id":3,"cmd":1,"data":{"ssid":"Cottage","passphrase":"hunter2","security":3}}"#
        );
    }

    #[test]
    fn a_setup_envelope_never_grows_a_ts_field() {
        let envelope = render_setup_envelope(1, 7, None).unwrap();
        assert!(
            !envelope.contains("ts"),
            "setup envelopes are cleartext {{id, cmd}}"
        );
    }

    #[test]
    fn setup_data_must_be_a_json_object() {
        for bad in ["not json", "[1,2]", "\"text\"", "42"] {
            assert!(
                matches!(
                    render_setup_envelope(0, 5, Some(bad)),
                    Err(ProtocolError::InvalidStateReply(_))
                ),
                "{bad}"
            );
        }
        assert!(render_setup_envelope(0, 5, Some("{}")).is_ok());
    }

    #[test]
    fn a_generated_user_key_is_32_uppercase_hex_chars() {
        let key = generate_user_key();
        assert_eq!(key.len(), 32);
        assert!(
            key.chars()
                .all(|c| c.is_ascii_digit() || ('A'..='F').contains(&c)),
            "uppercase hex only: {key}"
        );
        // And the LAN codec accepts its own spelling back.
        crate::protocol::rabbit_air::parse_user_key(&key).expect("the key parses");
        // Two generations differ — this is randomness, not a constant.
        assert_ne!(generate_user_key(), key);
    }
}

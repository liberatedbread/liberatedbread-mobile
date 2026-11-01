// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

use crate::error::ProtocolError;
use crate::spec::types::Characteristic;

pub const SCHEME: &str = "orba_sysex_ble_midi";

#[derive(serde::Deserialize)]
struct OrbaFraming {
    scheme: Option<String>,
    max_chunk_size: Option<usize>,
}

pub fn encode_command(
    characteristic: &Characteristic,
    payload: &[u8],
    message_id: u8,
) -> Result<Vec<Vec<u8>>, ProtocolError> {
    let raw = characteristic
        .framing
        .as_ref()
        .ok_or_else(|| ProtocolError::InvalidFraming {
            reason: format!("{SCHEME} requires a framing block"),
        })?;
    let framing: OrbaFraming =
        serde_yaml::from_value(raw.clone()).map_err(|e| ProtocolError::InvalidFraming {
            reason: e.to_string(),
        })?;
    if framing.scheme.as_deref() != Some(SCHEME) {
        return Err(ProtocolError::InvalidFraming {
            reason: format!("expected {SCHEME}, got {:?}", framing.scheme),
        });
    }
    let write_size = framing.max_chunk_size.unwrap_or(20);
    if !(3..=512).contains(&write_size) {
        return Err(ProtocolError::InvalidFraming {
            reason: format!("BLE-MIDI write size {write_size} is outside 3..512"),
        });
    }
    let payload_len = u16::try_from(payload.len()).map_err(|_| ProtocolError::InvalidFraming {
        reason: format!(
            "Orba payload is {} bytes; the u16 length cannot hold it",
            payload.len()
        ),
    })?;

    let mut packet = Vec::with_capacity(payload.len() + 7);
    packet.extend_from_slice(&[0x82, 0x01, message_id]);
    packet.extend_from_slice(&payload_len.to_be_bytes());
    packet.extend_from_slice(payload);
    let crc = crc16_orba(&packet);
    packet.extend_from_slice(&crc.to_be_bytes());

    let mut midi = Vec::with_capacity((packet.len() * 8).div_ceil(7) + 3);
    midi.extend_from_slice(&[0xF0, 0x00]);
    midi.extend_from_slice(&encode7(&packet));
    midi.push(0xF7);

    let body = &midi[..midi.len() - 1];
    let mut writes = Vec::new();
    let mut offset = 0;
    let first_len = (write_size - 2).min(body.len());
    let mut write = Vec::with_capacity(first_len + 2);
    write.extend_from_slice(&[0x80, 0x80]);
    write.extend_from_slice(&body[..first_len]);
    writes.push(write);
    offset += first_len;
    while offset < body.len() {
        let len = (write_size - 1).min(body.len() - offset);
        let mut write = Vec::with_capacity(len + 1);
        write.push(0x80);
        write.extend_from_slice(&body[offset..offset + len]);
        writes.push(write);
        offset += len;
    }
    writes.push(vec![0x80, 0x80, 0xF7]);
    Ok(writes)
}

fn encode7(packet: &[u8]) -> Vec<u8> {
    let mut output = Vec::with_capacity((packet.len() * 8).div_ceil(7));
    let mut bits = packet
        .iter()
        .flat_map(|byte| (0..8).map(move |bit| (byte >> bit) & 1));
    while let Some(first) = bits.next() {
        let mut value = first;
        for bit in 1..7 {
            if let Some(next) = bits.next() {
                value |= next << bit;
            } else {
                break;
            }
        }
        output.push(value);
    }
    output
}

fn crc16_orba(data: &[u8]) -> u16 {
    let mut crc = 0u16;
    for byte in data {
        crc ^= u16::from(*byte);
        for _ in 0..8 {
            crc = if crc & 1 != 0 {
                (crc >> 1) ^ 0xA001
            } else {
                crc >> 1
            };
        }
    }
    crc
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::types::Characteristic;

    fn characteristic(write_size: usize) -> Characteristic {
        serde_yaml::from_str(&format!(
            "uuid: 7772e5db-3868-4112-a1a9-f2669d106bf3\nname: MIDI\nproperties: [write]\nframing:\n  scheme: {SCHEME}\n  max_chunk_size: {write_size}\n"
        ))
        .unwrap()
    }

    fn hex(text: &str) -> Vec<u8> {
        text.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect()
    }

    #[test]
    fn play_matches_the_capture_verified_reference() {
        let writes =
            encode_command(&characteristic(20), &[0x03, 0x07, 0x00, 0x02, 0x05], 0).unwrap();
        assert_eq!(
            writes,
            vec![
                hex("80 80 f0 00 02 03 00 00 50 60 40 03 00 04 14 00 7f 05"),
                hex("80 80 f7"),
            ]
        );
    }

    #[test]
    fn fx_write_preserves_its_trailer_and_fragments() {
        let writes = encode_command(
            &characteristic(20),
            &[0x03, 0x02, 0x50, 0x10, 0x80, 0x00, 0x01, 0x04],
            0,
        )
        .unwrap();
        assert_eq!(
            writes,
            vec![
                hex("80 80 f0 00 02 03 00 00 00 61 00 01 50 20 00 04 10 00 41 2a"),
                hex("80 65 01"),
                hex("80 80 f7"),
            ]
        );
    }

    #[test]
    fn every_fragment_respects_the_write_budget() {
        let writes = encode_command(&characteristic(20), &(0..64).collect::<Vec<u8>>(), 0).unwrap();
        assert!(writes.iter().all(|write| write.len() <= 20));
        assert_eq!(&writes[0][..3], &[0x80, 0x80, 0xF0]);
        assert_eq!(writes.last().unwrap(), &[0x80, 0x80, 0xF7]);
    }

    #[test]
    fn an_impossibly_small_write_budget_is_rejected() {
        assert!(encode_command(&characteristic(2), &[0x03], 0).is_err());
    }
}

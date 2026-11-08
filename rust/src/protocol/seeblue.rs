// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The SEEBlue transport envelope — `framing.scheme: "seeblue_envelope"`
//! (`seeblue-motorcycle-led.yaml`, and the scheme's text in the catalogue's
//! `schema.json`, which between them state every byte):
//!
//! ```text
//! 95 | message_length | message_index | protocol_id | packet… | checksum
//!   message_length = message_index through the last packet byte
//!   checksum       = 8-bit two's complement of the sum of message_length
//!                    through the last packet byte
//! ```
//!
//! The spec gives no captured frame, so the vectors in the tests below are
//! worked by hand from that text.
//!
//! `protocol_id` is the command's own. `message_index` is "a per-connection
//! sequence number the client owns"; its first value is not stated, and a send
//! path here does not know which connection it serves, so
//! [`next_message_index`] counts for the whole process. Each connection still
//! sees increasing numbers, possibly with gaps.
//!
//! What this does NOT do: the vendor app's post-connect handshake on protocol
//! 0x00 (`[0x00] + 6 bytes of ANDROID_ID`). The spec declares no command for
//! it and says whether firmware requires it is unknown. Nothing here has been
//! run against hardware.

use super::image_upload::FragmentRequest;
use crate::error::ProtocolError;
use std::sync::atomic::{AtomicU8, Ordering};

/// The `framing.scheme` this module implements.
pub const SCHEME: &str = crate::codec::types::SEEBLUE_ENVELOPE_SCHEME;

const START: u8 = 0x95;

/// Start, length, index and protocol ahead of the packet, and the checksum
/// after it, all out of one write.
pub const ENVELOPE_LEN: usize = 5;

/// `message_length` is one byte and also counts the index and the protocol.
const MAX_PACKET: usize = u8::MAX as usize - 2;

static NEXT_INDEX: AtomicU8 = AtomicU8::new(0);

/// The next `message_index`, for a send whose caller names none.
pub fn next_message_index() -> u8 {
    NEXT_INDEX.fetch_add(1, Ordering::Relaxed)
}

/// One complete write around `packet`.
pub fn frame(message_index: u8, protocol_id: u8, packet: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(packet.len() + ENVELOPE_LEN);
    out.push(START);
    out.push((packet.len() + 2) as u8);
    out.push(message_index);
    out.push(protocol_id);
    out.extend_from_slice(packet);
    let sum = out[1..].iter().fold(0u8, |acc, b| acc.wrapping_add(*b));
    out.push(sum.wrapping_neg());
    out
}

/// What [`fragment_packet`] needs and cannot report the lack of, checked by
/// the framing path before it gets there.
pub fn check_packet(packet: &[u8], protocol_id: Option<u8>) -> Result<(), ProtocolError> {
    if protocol_id.is_none() {
        return Err(ProtocolError::InvalidFraming {
            reason: "seeblue_envelope needs the command's protocol_id".to_string(),
        });
    }
    if packet.len() > MAX_PACKET {
        return Err(ProtocolError::InvalidFraming {
            reason: format!(
                "a {} byte packet does not fit seeblue_envelope's one-byte length",
                packet.len()
            ),
        });
    }
    Ok(())
}

/// [`SCHEME`] as a [`super::image_upload::FragmentScheme`]: one packet, one
/// write.
pub fn fragment_packet(request: FragmentRequest<'_>) -> Vec<Vec<u8>> {
    vec![frame(
        request.serial as u8,
        request.protocol_id,
        request.packet,
    )]
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `direct_set_color_1` for (0x10, 0x20, 0x30), message 7. The sum of
    /// 06 07 01 01 10 20 30 is 0x6F, whose two's complement is 0x91.
    #[test]
    fn a_colour_write_matches_the_hand_worked_frame() {
        assert_eq!(
            frame(7, 0x01, &[0x01, 0x10, 0x20, 0x30]),
            [0x95, 0x06, 0x07, 0x01, 0x01, 0x10, 0x20, 0x30, 0x91]
        );
    }

    /// `ledglow_v2_power_off`, `[05 00 00]` on protocol 0x10, message 0. The
    /// sum of 05 00 10 05 00 00 is 0x1A, whose two's complement is 0xE6.
    #[test]
    fn a_v2_write_matches_the_hand_worked_frame() {
        assert_eq!(
            frame(0, 0x10, &[0x05, 0x00, 0x00]),
            [0x95, 0x05, 0x00, 0x10, 0x05, 0x00, 0x00, 0xE6]
        );
    }

    /// The start byte is outside the sum, so a frame checks to zero from
    /// `message_length` on, whatever carries past eight bits.
    #[test]
    fn a_frame_sums_to_zero_from_its_length_byte_on() {
        let out = frame(0xFF, 0x10, &[0xFF; 12]);
        assert_eq!(out[0], START);
        assert_eq!(out[1], 14);
        assert_eq!(out[1..].iter().fold(0u8, |acc, b| acc.wrapping_add(*b)), 0);
    }

    /// 02 + FE carries to exactly zero, and the complement of zero is zero.
    #[test]
    fn a_sum_of_zero_has_a_zero_checksum() {
        assert_eq!(frame(0xFE, 0, &[]), [0x95, 0x02, 0xFE, 0x00, 0x00]);
    }

    #[test]
    fn successive_indexes_differ() {
        assert_ne!(next_message_index(), next_message_index());
    }

    #[test]
    fn a_packet_needs_a_protocol_and_must_fit_the_length_byte() {
        assert!(check_packet(&[0; MAX_PACKET], Some(1)).is_ok());
        assert!(check_packet(&[0; MAX_PACKET + 1], Some(1)).is_err());
        assert!(check_packet(&[], None).is_err());
    }
}

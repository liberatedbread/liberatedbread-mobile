// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The UV-17Pro programming protocol: handshake, framing, byte substitution.
//!
//! Every function here is pure. Rust decides what bytes to send and what a
//! reply means; Dart owns the serial line or the GATT tunnel. That split is
//! the house rule, and it is also what lets the whole protocol be tested
//! without a radio.

use crate::error::ProtocolError;

/// The acknowledgement byte the radio answers a good command with.
pub const ACK: u8 = 0x06;

/// Read a block.
pub const CMD_READ: u8 = 0x52;

/// Write a block.
pub const CMD_WRITE: u8 = 0x57;

/// Blocks are 0x40 bytes over a serial cable.
pub const BLOCK_SIZE: u16 = 0x40;

/// Over the radio's own Bluetooth the writes are re-blocked to 0x80.
///
/// Reads stay at 0x40 either way; only the upload changes. This is a property
/// of the tunnel rather than of the protocol, which is why the block size is
/// a parameter everywhere below instead of a constant.
pub const BLE_WRITE_BLOCK_SIZE: u16 = 0x80;

/// A read reply is a four-byte echo of the request header, then the payload.
pub const REPLY_HEADER_LEN: usize = 4;

/// The handshake, after the model magic has been acknowledged.
///
/// Three exchanges: `F`, then `M`, then a fixed 25-byte sequence beginning
/// `SEND!`. Each expects a reply of a known length, which is what makes the
/// step machine drivable from Dart without guessing when to stop reading.
pub struct HandshakeStep {
    pub request: &'static [u8],
    pub expected_reply_len: usize,
}

/// `F` -- expects 16 bytes.
pub const HANDSHAKE_F: HandshakeStep = HandshakeStep {
    request: &[0x46],
    expected_reply_len: 16,
};

/// `M` -- expects 15 bytes.
pub const HANDSHAKE_M: HandshakeStep = HandshakeStep {
    request: &[0x4D],
    expected_reply_len: 15,
};

/// The fixed `SEND!` sequence -- expects a single byte.
pub const HANDSHAKE_SEND: HandshakeStep = HandshakeStep {
    request: &[
        0x53, 0x45, 0x4E, 0x44, 0x21, 0x05, 0x0D, 0x01, 0x01, 0x01, 0x04, 0x11, 0x08, 0x05, 0x0D,
        0x0D, 0x01, 0x11, 0x0F, 0x09, 0x12, 0x09, 0x10, 0x04, 0x00,
    ],
    expected_reply_len: 1,
};

/// The handshake in order.
pub fn handshake_steps() -> [&'static HandshakeStep; 3] {
    [&HANDSHAKE_F, &HANDSHAKE_M, &HANDSHAKE_SEND]
}

/// The byte-substitution table the family calls its "encryption".
///
/// Twenty four-byte symbols; every model in this family uses index 1. It is a
/// rotating XOR with four exemptions, and those exemptions are what make it
/// its own inverse -- see [`crypt`].
const SYMBOL_TABLE: [&[u8; 4]; 20] = [
    b"BHT ", b"CO 7", b"A ES", b" EIY", b"M PQ", b"XN Y", b"RVB ", b" HQP", b"W RC", b"MS N",
    b" SAT", b"K DH", b"ZO R", b"C SL", b"6RB ", b" JCG", b"PN V", b"J PK", b"EK L", b"I LZ",
];

/// Apply the byte substitution. Applying it twice returns the original.
///
/// A byte is XORed with the rotating key byte unless any of four things is
/// true: the key byte is a space, the data byte is 0x00 or 0xFF, or the data
/// byte already equals the key byte or its complement. Those exemptions are
/// symmetric -- an XORed byte can never land on one of the excluded values --
/// which is why one routine both encodes and decodes.
pub fn crypt(symbol_index: usize, buffer: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    let symbol = SYMBOL_TABLE.get(symbol_index).ok_or_else(|| {
        ProtocolError::MalformedReply(format!("no substitution symbol at index {symbol_index}"))
    })?;

    Ok(buffer
        .iter()
        .enumerate()
        .map(|(i, &byte)| {
            let key = symbol[i % 4];
            let exempt =
                key == b' ' || byte == 0x00 || byte == 0xFF || byte == key || byte == key ^ 0xFF;
            if exempt {
                byte
            } else {
                byte ^ key
            }
        })
        .collect())
}

/// The substitution symbol every radio in this family uses.
pub const DEFAULT_SYMBOL_INDEX: usize = 1;

/// Build a command frame: opcode, a big-endian 16-bit address, a length, then
/// the payload for a write.
pub fn make_frame(cmd: u8, addr: u16, len: u8, data: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(4 + data.len());
    frame.push(cmd);
    frame.extend_from_slice(&addr.to_be_bytes());
    frame.push(len);
    frame.extend_from_slice(data);
    frame
}

/// The request that reads `len` bytes from `addr`.
pub fn read_command(addr: u16, len: u8) -> Vec<u8> {
    make_frame(CMD_READ, addr, len, &[])
}

/// The request that writes `data` to `addr`, substitution applied.
pub fn write_command(
    addr: u16,
    data: &[u8],
    symbol_index: usize,
) -> Result<Vec<u8>, ProtocolError> {
    let len = u8::try_from(data.len()).map_err(|_| ProtocolError::InvalidFraming {
        reason: format!(
            "block of {} bytes does not fit a one-byte length",
            data.len()
        ),
    })?;
    let scrambled = crypt(symbol_index, data)?;
    Ok(make_frame(CMD_WRITE, addr, len, &scrambled))
}

/// How many bytes a read of `len` will answer with, header included.
///
/// Dart needs this before the first notification arrives: over BLE a reply
/// comes back in ~20-byte pieces, and knowing the total is the only way to
/// tell "still arriving" from "done".
pub fn expected_read_reply_len(len: u8) -> usize {
    REPLY_HEADER_LEN + len as usize
}

/// Take the payload out of a read reply, substitution undone.
///
/// The four-byte header is checked rather than skipped: a reply for the wrong
/// address means the conversation has slipped a step, and carrying on would
/// write the next block's data over the wrong part of the radio.
pub fn parse_read_reply(
    reply: &[u8],
    addr: u16,
    len: u8,
    symbol_index: usize,
) -> Result<Vec<u8>, ProtocolError> {
    let expected = expected_read_reply_len(len);
    if reply.len() != expected {
        return Err(ProtocolError::MalformedReply(format!(
            "read of 0x{addr:04X} wanted {expected} bytes, got {}",
            reply.len()
        )));
    }
    let echoed_addr = u16::from_be_bytes([reply[1], reply[2]]);
    if reply[0] != CMD_READ || echoed_addr != addr || reply[3] != len {
        return Err(ProtocolError::MalformedReply(format!(
            "read reply header {:02X?} does not match a request for 0x{addr:04X} len {len}",
            &reply[..REPLY_HEADER_LEN]
        )));
    }
    crypt(symbol_index, &reply[REPLY_HEADER_LEN..])
}

/// Whether a one-byte reply is the radio's acknowledgement.
pub fn is_ack(reply: &[u8]) -> bool {
    reply.first() == Some(&ACK)
}

/// One block to read: where it lives on the radio, and where it belongs in
/// the flat image.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BlockPlan {
    /// Address on the radio.
    pub addr: u16,
    /// Offset into the flat memory image.
    pub image_offset: u32,
    pub len: u8,
}

/// Every block that makes up a full read, in order.
///
/// The radio's memory is not contiguous: it is a handful of regions at
/// separate addresses that the driver concatenates into one flat image. The
/// image offset is therefore not the address, and conflating the two is how a
/// codeplug ends up shifted by 0x1000 bytes.
pub fn read_plan(regions: &[(u16, u16)], block_size: u16) -> Vec<BlockPlan> {
    let mut plan = Vec::new();
    let mut image_offset: u32 = 0;
    for &(start, size) in regions {
        let mut offset = 0u16;
        while offset < size {
            let len = block_size.min(size - offset);
            plan.push(BlockPlan {
                addr: start + offset,
                image_offset,
                len: len as u8,
            });
            image_offset += u32::from(len);
            offset += len;
        }
    }
    plan
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_carry_a_big_endian_address_and_a_byte_length() {
        assert_eq!(read_command(0x1234, 0x40), vec![0x52, 0x12, 0x34, 0x40]);
        assert_eq!(read_command(0x0000, 0x40), vec![0x52, 0x00, 0x00, 0x40]);
        assert_eq!(read_command(0xA000, 0x40), vec![0x52, 0xA0, 0x00, 0x40]);
    }

    #[test]
    fn a_write_frame_carries_the_scrambled_payload() {
        let plain = [0x11u8, 0x22, 0x33, 0x44];
        let frame = write_command(0x9000, &plain, DEFAULT_SYMBOL_INDEX).unwrap();
        assert_eq!(&frame[..4], &[0x57, 0x90, 0x00, 0x04]);
        assert_eq!(
            &frame[4..],
            &crypt(DEFAULT_SYMBOL_INDEX, &plain).unwrap()[..]
        );
    }

    #[test]
    fn a_block_too_long_for_the_length_byte_is_refused() {
        let huge = vec![0u8; 256];
        assert!(write_command(0, &huge, DEFAULT_SYMBOL_INDEX).is_err());
    }

    #[test]
    fn the_substitution_is_its_own_inverse() {
        // The exemptions are what make this true, and they are the part that
        // would be easy to get subtly wrong.
        for symbol in 0..20 {
            let data: Vec<u8> = (0..=255u8).collect();
            let once = crypt(symbol, &data).unwrap();
            let twice = crypt(symbol, &once).unwrap();
            assert_eq!(twice, data, "symbol {symbol} does not round-trip");
        }
    }

    #[test]
    fn the_substitution_leaves_the_reserved_bytes_alone() {
        // 0x00 and 0xFF are exempt everywhere, which is why an unwritten
        // block of 0xFF survives a read unchanged.
        let data = vec![0x00u8, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF];
        assert_eq!(crypt(DEFAULT_SYMBOL_INDEX, &data).unwrap(), data);
    }

    #[test]
    fn a_space_in_the_symbol_exempts_its_column() {
        // "CO 7" has a space third, so every fourth byte from index 2 passes
        // through untouched.
        let data = vec![0x41u8; 8];
        let out = crypt(1, &data).unwrap();
        assert_eq!(out[2], 0x41);
        assert_eq!(out[6], 0x41);
        assert_ne!(out[0], 0x41);
    }

    #[test]
    fn an_unknown_symbol_index_is_an_error_not_a_panic() {
        assert!(crypt(99, &[1, 2, 3]).is_err());
    }

    #[test]
    fn a_read_reply_round_trips_through_the_parser() {
        let payload: Vec<u8> = (0..0x40u8).collect();
        let scrambled = crypt(DEFAULT_SYMBOL_INDEX, &payload).unwrap();
        let mut reply = vec![CMD_READ, 0x12, 0x34, 0x40];
        reply.extend_from_slice(&scrambled);

        let parsed = parse_read_reply(&reply, 0x1234, 0x40, DEFAULT_SYMBOL_INDEX).unwrap();
        assert_eq!(parsed, payload);
    }

    #[test]
    fn a_reply_for_another_address_is_refused() {
        // A slipped conversation must not be mistaken for data: writing the
        // next block over the wrong part of the radio is how one gets bricked.
        let mut reply = vec![CMD_READ, 0x12, 0x34, 0x40];
        reply.extend_from_slice(&[0u8; 0x40]);
        assert!(parse_read_reply(&reply, 0x9000, 0x40, DEFAULT_SYMBOL_INDEX).is_err());
    }

    #[test]
    fn a_short_or_long_reply_is_refused() {
        let mut short = vec![CMD_READ, 0x12, 0x34, 0x40];
        short.extend_from_slice(&[0u8; 0x20]);
        assert!(parse_read_reply(&short, 0x1234, 0x40, DEFAULT_SYMBOL_INDEX).is_err());

        let mut long = vec![CMD_READ, 0x12, 0x34, 0x40];
        long.extend_from_slice(&[0u8; 0x80]);
        assert!(parse_read_reply(&long, 0x1234, 0x40, DEFAULT_SYMBOL_INDEX).is_err());
    }

    #[test]
    fn a_reply_with_the_wrong_opcode_is_refused() {
        let mut reply = vec![CMD_WRITE, 0x12, 0x34, 0x40];
        reply.extend_from_slice(&[0u8; 0x40]);
        assert!(parse_read_reply(&reply, 0x1234, 0x40, DEFAULT_SYMBOL_INDEX).is_err());
    }

    #[test]
    fn the_expected_reply_length_includes_the_header() {
        assert_eq!(expected_read_reply_len(0x40), 0x44);
        assert_eq!(expected_read_reply_len(0x80), 0x84);
    }

    #[test]
    fn acks_are_recognised_and_nothing_else_is() {
        assert!(is_ack(&[ACK]));
        assert!(!is_ack(&[0x15]));
        assert!(!is_ack(&[]));
    }

    #[test]
    fn the_handshake_is_three_steps_with_known_reply_lengths() {
        let steps = handshake_steps();
        assert_eq!(steps.len(), 3);
        assert_eq!(steps[0].request, &[0x46]);
        assert_eq!(steps[0].expected_reply_len, 16);
        assert_eq!(steps[1].request, &[0x4D]);
        assert_eq!(steps[1].expected_reply_len, 15);
        assert_eq!(steps[2].request.len(), 25);
        assert_eq!(&steps[2].request[..5], b"SEND!");
        assert_eq!(steps[2].expected_reply_len, 1);
    }

    #[test]
    fn a_read_plan_walks_every_region_in_order() {
        let plan = read_plan(&[(0x0000, 0x0100), (0x9000, 0x0040)], 0x40);
        assert_eq!(plan.len(), 5);
        assert_eq!(plan[0].addr, 0x0000);
        assert_eq!(plan[0].image_offset, 0);
        assert_eq!(plan[3].addr, 0x00C0);
        assert_eq!(plan[3].image_offset, 0xC0);
        // The second region jumps in address but not in the flat image, which
        // is the distinction a codeplug shifted by 0x1000 bytes got wrong.
        assert_eq!(plan[4].addr, 0x9000);
        assert_eq!(plan[4].image_offset, 0x100);
    }

    #[test]
    fn a_read_plan_covers_exactly_the_image() {
        let regions = [(0x0000u16, 0x8040u16), (0x9000, 0x0040), (0xA000, 0x01C0)];
        let plan = read_plan(&regions, 0x40);
        let total: u32 = plan.iter().map(|b| u32::from(b.len)).sum();
        assert_eq!(total, 0x8240);
        assert_eq!(plan.last().unwrap().image_offset + 0x40, 0x8240);
    }

    #[test]
    fn a_trailing_partial_block_is_not_over_read() {
        let plan = read_plan(&[(0x0000, 0x0050)], 0x40);
        assert_eq!(plan.len(), 2);
        assert_eq!(plan[1].len, 0x10);
    }

    #[test]
    fn the_ble_write_block_is_twice_the_serial_one() {
        assert_eq!(BLE_WRITE_BLOCK_SIZE, BLOCK_SIZE * 2);
        let plan = read_plan(&[(0x0000, 0x0100)], BLE_WRITE_BLOCK_SIZE);
        assert_eq!(plan.len(), 2);
        assert_eq!(plan[0].len, 0x80);
    }
}

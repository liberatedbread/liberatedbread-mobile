// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Pixel-frame encoder for Hangzhou Daniao's "DDP" BLE platform — the stack
//! behind SmartDawn / SuperPix / SmartPixel addressable-RGB lights.
//!
//! Byte layouts come from the SmartDawn device spec
//! (`smartdawn-smart-lights.yaml`), which maps them from two independent
//! encoders inside the vendor app (decompiled Java and the bundled H5
//! JavaScript):
//!
//! - **Standard DDP packet** (pixel data): 10-byte header
//!   `[flag][sn u8][datatype][target][offset u32 BE][psize u16 BE]` followed
//!   by `psize` payload bytes. `datatype` 0x01 = DISPLAY, `target` 0x01 (what
//!   the app writes), flag bit 0x01 = PUSH. Payload bytes are raster pixel
//!   data at `offset` into the device's display buffer.
//! - **BLE fragment framing**: every logical packet is split into writes of
//!   at most the payload MTU, each prefixed with
//!   `[message serial u8][total fragments u8][fragments remaining u8][0x00]`;
//!   reassembly keys on the first three bytes.
//!
//! Following the DDP convention (the header shape matches WLED/xLights DDP,
//! which this platform derives from), PUSH is set only on the *final* packet
//! of a frame, telling the controller to latch the assembled buffer onto the
//! LEDs. Not yet verified by live capture — flagged in the spec's confidence
//! notes.
//!
//! The encoder is stateless: callers pass a `frame_index` and sequence
//! numbers derive from it, so streaming N frames produces distinct serials
//! without shared state across the FFI boundary.

use super::EncodedFrame;
use crate::error::ProtocolError;

/// `protocol_handler` name this module implements (see the device spec's
/// top-level `protocol_handler` key).
pub const HANDLER_NAME: &str = "daniao_ddp";

/// The platform's single custom GATT service.
pub const SERVICE_UUID: &str = "00000074-1972-1925-3022-077119514e44";

/// DDP Write characteristic — command/pixel channel, fragmented writes.
pub const DDP_WRITE_UUID: &str = "01020074-1972-1925-3022-077119514e44";

const DDP_HEADER_LEN: usize = 10;
const FRAG_HEADER_LEN: usize = 4;
const FLAG_PUSH: u8 = 0x01;
const DATATYPE_DISPLAY: u8 = 0x01;
const TARGET_APP: u8 = 0x01;
const MAX_PSIZE: usize = u16::MAX as usize;
const MAX_FRAGMENTS: usize = u8::MAX as usize;

/// The BLE 4.0 minimum ATT payload (MTU 23 - 3). The vendor app requests MTU
/// 512 and falls back to this; anything smaller is not a plausible link and
/// almost certainly a caller bug.
const MIN_PAYLOAD_PER_WRITE: usize = 20;

/// Encode one RGB frame into the ordered BLE writes that push it to the
/// display, targeting [`DDP_WRITE_UUID`].
///
/// `rgb` is row-major RGB888, so its length must be `width * height * 3`
/// (color-order quirks like GRB strips are the controller's concern — the
/// wire format is the app's canvas order). `max_payload_per_write` is the
/// usable bytes per BLE write (negotiated ATT MTU minus 3; 20 when unknown).
///
/// Frames larger than one DDP packet can carry (`u16` psize, and at most 255
/// fragments per packet) are split into multiple packets at increasing
/// buffer offsets; only the last packet carries PUSH. The returned
/// [`EncodedFrame::packets`] is how many sequence numbers were consumed —
/// callers MUST advance `frame_index` by it (not by 1) so the next frame's
/// serials don't collide with this one's.
pub fn encode_display_frame(
    rgb: &[u8],
    width: u32,
    height: u32,
    frame_index: u32,
    max_payload_per_write: usize,
) -> Result<EncodedFrame, ProtocolError> {
    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|px| px.checked_mul(3))
        .ok_or(ProtocolError::ImageDimensionsInvalid {
            reason: format!("{width}x{height} overflows the pixel buffer size"),
        })?;
    if expected == 0 {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!("{width}x{height} has no pixels"),
        });
    }
    if rgb.len() != expected {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "pixel buffer is {} bytes but {width}x{height} RGB888 needs {expected}",
                rgb.len()
            ),
        });
    }
    if max_payload_per_write < MIN_PAYLOAD_PER_WRITE {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "max_payload_per_write {max_payload_per_write} is below the BLE minimum of \
                 {MIN_PAYLOAD_PER_WRITE}"
            ),
        });
    }

    // A DDP packet must reassemble from at most 255 fragments of
    // (payload - 4) bytes, and psize is u16 — whichever is tighter bounds the
    // pixel bytes one packet may carry.
    let frag_capacity = max_payload_per_write - FRAG_HEADER_LEN;
    let max_packet_pixels = MAX_PSIZE.min(frag_capacity * MAX_FRAGMENTS - DDP_HEADER_LEN);

    let packets: Vec<&[u8]> = rgb.chunks(max_packet_pixels).collect();
    let mut writes = Vec::new();
    for (i, chunk) in packets.iter().enumerate() {
        let offset = i * max_packet_pixels;
        let last = i == packets.len() - 1;
        // One sequence number per DDP packet. Derived from the frame index,
        // which the caller advances by the returned packet count — that
        // contract is what keeps serials distinct across frames when one
        // frame spans several packets.
        let sn = (frame_index as usize + i) as u8;

        let mut packet = Vec::with_capacity(DDP_HEADER_LEN + chunk.len());
        packet.push(if last { FLAG_PUSH } else { 0x00 });
        packet.push(sn);
        packet.push(DATATYPE_DISPLAY);
        packet.push(TARGET_APP);
        packet.extend_from_slice(&(offset as u32).to_be_bytes());
        packet.extend_from_slice(&(chunk.len() as u16).to_be_bytes());
        packet.extend_from_slice(chunk);

        fragment_packet(&packet, sn, frag_capacity, &mut writes);
    }
    Ok(EncodedFrame {
        writes,
        packets: packets.len() as u32,
    })
}

/// Split one logical packet into BLE writes carrying the 4-byte fragment
/// header. `serial` identifies the packet; the remaining-count walks down to
/// zero on the final fragment, which is how the receiver knows to reassemble.
fn fragment_packet(packet: &[u8], serial: u8, frag_capacity: usize, out: &mut Vec<Vec<u8>>) {
    let chunks: Vec<&[u8]> = packet.chunks(frag_capacity).collect();
    let total = chunks.len();
    debug_assert!(total <= MAX_FRAGMENTS, "packet sizing must bound fragments");
    for (i, chunk) in chunks.iter().enumerate() {
        let mut write = Vec::with_capacity(FRAG_HEADER_LEN + chunk.len());
        write.push(serial);
        write.push(total as u8);
        write.push((total - 1 - i) as u8);
        write.push(0x00);
        write.extend_from_slice(chunk);
        out.push(write);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Reassemble fragments back into logical packets — the inverse of
    /// [`fragment_packet`], used to make round-trip assertions readable.
    fn reassemble(writes: &[Vec<u8>]) -> Vec<Vec<u8>> {
        let mut packets: Vec<Vec<u8>> = Vec::new();
        let mut current: Vec<u8> = Vec::new();
        for write in writes {
            let (header, payload) = write.split_at(FRAG_HEADER_LEN);
            assert_eq!(header[3], 0x00, "fragment header byte 3 is reserved");
            current.extend_from_slice(payload);
            if header[2] == 0 {
                packets.push(std::mem::take(&mut current));
            }
        }
        assert!(current.is_empty(), "trailing unterminated fragment");
        packets
    }

    #[test]
    fn single_pixel_single_write_golden_bytes() {
        let frame = encode_display_frame(&[0xFF, 0x00, 0x7F], 1, 1, 0, 20).unwrap();
        assert_eq!(frame.packets, 1);
        assert_eq!(
            frame.writes,
            vec![vec![
                0x00, 0x01, 0x00, 0x00, // fragment: serial 0, 1 total, 0 remaining
                0x01, 0x00, 0x01, 0x01, // DDP: PUSH, sn 0, DISPLAY, target 1
                0x00, 0x00, 0x00, 0x00, // offset 0
                0x00, 0x03, // psize 3
                0xFF, 0x00, 0x7F, // the pixel
            ]],
        );
    }

    #[test]
    fn packet_larger_than_one_write_fragments_with_countdown() {
        // 2x2 frame = 12 pixel bytes + 10 header = 22 > 16 usable -> 2 writes.
        let rgb: Vec<u8> = (0..12).collect();
        let frame = encode_display_frame(&rgb, 2, 2, 5, 20).unwrap();
        assert_eq!(frame.packets, 1, "one logical packet, two fragments");
        let writes = frame.writes;
        assert_eq!(writes.len(), 2);
        // Both fragments carry the same serial (the frame index), the total,
        // and a remaining-count that walks 1 -> 0.
        assert_eq!(&writes[0][..4], &[5, 2, 1, 0]);
        assert_eq!(&writes[1][..4], &[5, 2, 0, 0]);
        assert_eq!(writes[0].len(), 20);
        assert_eq!(writes[1].len(), 4 + (22 - 16));

        let packets = reassemble(&writes);
        assert_eq!(packets.len(), 1);
        assert_eq!(packets[0][0], FLAG_PUSH);
        assert_eq!(packets[0][1], 5); // sn = frame index
        assert_eq!(&packets[0][8..10], &[0x00, 12]); // psize
        assert_eq!(&packets[0][10..], rgb.as_slice());
    }

    #[test]
    fn large_frame_splits_into_offset_packets_push_on_last() {
        // With payload 20, one packet carries at most 16*255-10 = 4070 pixel
        // bytes. 40x34 RGB = 4080 bytes -> two DDP packets.
        let (w, h) = (40u32, 34u32);
        let rgb = vec![0xAB; (w * h * 3) as usize];
        let frame = encode_display_frame(&rgb, w, h, 7, 20).unwrap();
        assert_eq!(frame.packets, 2, "callers must advance frame_index by 2");

        let packets = reassemble(&frame.writes);
        assert_eq!(packets.len(), 2);

        // First packet: no PUSH, offset 0, full capacity.
        assert_eq!(packets[0][0], 0x00);
        assert_eq!(packets[0][1], 7);
        assert_eq!(&packets[0][4..8], &0u32.to_be_bytes());
        assert_eq!(&packets[0][8..10], &4070u16.to_be_bytes());

        // Second packet: PUSH latches the frame, offset continues, sn steps.
        assert_eq!(packets[1][0], FLAG_PUSH);
        assert_eq!(packets[1][1], 8);
        assert_eq!(&packets[1][4..8], &4070u32.to_be_bytes());
        assert_eq!(&packets[1][8..10], &10u16.to_be_bytes());

        let body: Vec<u8> = packets
            .iter()
            .flat_map(|p| p[DDP_HEADER_LEN..].to_vec())
            .collect();
        assert_eq!(body, rgb);
    }

    #[test]
    fn larger_mtu_shrinks_write_count() {
        let rgb = vec![0x11; 16 * 16 * 3];
        let small = encode_display_frame(&rgb, 16, 16, 0, 20).unwrap();
        let large = encode_display_frame(&rgb, 16, 16, 0, 509).unwrap();
        assert!(large.writes.len() < small.writes.len());
        // 768 + 10 = 778 bytes at 505 usable payload -> 2 writes.
        assert_eq!(large.writes.len(), 2);
        assert_eq!(reassemble(&small.writes), reassemble(&large.writes));
    }

    #[test]
    fn frame_index_drives_serials_and_wraps() {
        let rgb = [0u8; 3];
        let w255 = encode_display_frame(&rgb, 1, 1, 255, 20).unwrap();
        assert_eq!(w255.writes[0][0], 255);
        let w256 = encode_display_frame(&rgb, 1, 1, 256, 20).unwrap();
        assert_eq!(w256.writes[0][0], 0, "serial wraps at u8");
    }

    #[test]
    fn wrong_buffer_length_is_rejected() {
        let err = encode_display_frame(&[0u8; 5], 2, 2, 0, 20).unwrap_err();
        assert!(err.to_string().contains("needs 12"), "got: {err}");
    }

    #[test]
    fn zero_dimensions_are_rejected() {
        assert!(encode_display_frame(&[], 0, 4, 0, 20).is_err());
        assert!(encode_display_frame(&[], 4, 0, 0, 20).is_err());
    }

    #[test]
    fn tiny_payload_budget_is_rejected() {
        let err = encode_display_frame(&[0u8; 3], 1, 1, 0, 8).unwrap_err();
        assert!(err.to_string().contains("BLE minimum"), "got: {err}");
    }

    #[test]
    fn overflowing_dimensions_are_rejected() {
        assert!(encode_display_frame(&[], u32::MAX, u32::MAX, 0, 20).is_err());
    }
}

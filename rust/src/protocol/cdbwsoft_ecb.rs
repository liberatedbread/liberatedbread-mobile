// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Image-frame encoder for the Magic Display / AiTURE LED matrices —
//! `protocol_handler: "cdbwsoft_ecb"`
//! (`vendor/protocol-specs/device-specs/devices/magic-display.yaml`).
//!
//! THE WIRE FORMAT (the spec's `device.notes` and per-characteristic notes,
//! and `vendor/protocol-specs/docs/devices/magic-display.md`, both verified
//! against the vendor app `com.tirohk.magicdisplay` 1.5.6 by static analysis
//! — the 2026-08-14 correction in the spec supersedes an earlier
//! sibling-derived reading that had this channel unencrypted):
//!
//! Every packet on every channel is exactly one AES-128-ECB block under the
//! static key the spec records on the characteristic. Commands are ASCII, in
//! plaintext before encryption:
//!
//! ```text
//!   [length] [ASCII name…] [args…] [zero pad to 16]
//! ```
//!
//! and a bulk transfer is three of them:
//!
//! ```text
//!   1. DATS  on WRITE1  [8, "DATS", len_hi, len_lo, 0, link_flag]
//!      — the bitmap's byte count, big-endian.       device answers DATSOK
//!   2. data  on WRITE2  [payload_len, …up to 15 bytes…]
//!      — one AES block per write, 60 ms apart, NO per-block ack: the string
//!        "REOK" appears nowhere in this app, unlike the sibling's flow.
//!   3. DATCP on WRITE1  [5, "DATCP"]                device answers DATCPOK
//! ```
//!
//! BITMAP ENCODING is column-major, one bit per pixel, and its shape depends
//! on the panel — the doc's display-type table pins two of the three:
//!
//! ```text
//!   16 rows: 2 bytes/column, byte 0 = rows 0-7 (bits 7-0), byte 1 = rows 8-15
//!    5 rows: 1 byte/column,  bits 4-0 = rows 0-4
//!   12 rows: column PAIRS packed into 3 bytes — order NOT stated, refused
//! ```
//!
//! In both stated cases the top row of a byte's group sits at that group's
//! highest used bit, which is what [`column_bytes`] implements; the 12x48
//! type packs differently and is rejected by name rather than guessed at.
//!
//! 1-BIT THRESHOLD: the spec states its own rule — "any RGB channel >= 128 =
//! ON" — so this handler does NOT use the shared luma mask. The two disagree
//! on saturated blue (luma 0.114, channel 255), and the spec's rule is the
//! one the vendor app rasterizes by.
//!
//! Pacing (60 ms between blocks, 50 ms for animation frames) and waiting for
//! DATSOK/DATCPOK are the transport's job; this encoder only orders the
//! writes.
//!
//! The SIBLING SHARING THIS HANDLER, `shining-glasses.yaml`, is deliberately
//! out of reach: its DATS is a different shape (`[9, "DATS", len_hi, len_lo,
//! datalen_hi, datalen_lo, type]`, then unencrypted `[len+1, index, …]`
//! frames with REOK per frame), and it declares no `image_upload` feature, so
//! nothing routes here. That is why the two framing commands below are
//! resolved from the spec's own templates rather than built in code: a device
//! whose DATS differs states a different template, and one that states none
//! is refused instead of being sent this one's bytes.

use super::image_upload::{
    declared_static_key, image_feature, is_writable, validate_rgb_canvas, MIN_PAYLOAD_PER_WRITE,
};
use super::{EncodedFrame, EncodedWrite};
use crate::codec::types::encode_command;
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, DeviceSpec};
use aes::cipher::{BlockEncrypt, KeyInit};
use std::collections::HashMap;

/// `protocol_handler` name this module implements (see the device spec's
/// top-level `protocol_handler` key).
pub const HANDLER_NAME: &str = "cdbwsoft_ecb";

/// Cipher the command and bulk channels must declare for this build to drive
/// them. Matched against the spec's `encryption.algorithm`.
const ALGORITHM: &str = "aes-128-ecb";

/// Every packet is one cipher block, which is also the whole packet framing:
/// "all commands are exactly 16 bytes".
const BLOCK: usize = 16;

/// Bulk block layout: one length byte, then payload.
const BULK_PAYLOAD_PER_BLOCK: usize = BLOCK - 1;

/// Spec commands that open and close a bulk transfer. The characteristic
/// declaring the first IS the command channel — the same anchoring the
/// iDotMatrix handler uses, so no UUID is written down here.
const CMD_TRANSFER_START: &str = "data_transfer_start";
const CMD_TRANSFER_COMPLETE: &str = "data_transfer_complete";

/// `link_flag` argument of DATS. The command declares the parameter and
/// bounds it to 0..=1, and LEDFIRST/LEDSECOND elsewhere in the spec address
/// a daisy chain, but nothing states which value means "this display alone".
// SPEC-GAP: the flag's vocabulary should be declared (e.g. an enum on the
// `data_transfer_start` parameter), so a chained upload becomes a parameter
// rather than a rebuild. Zero — the neutral value, and the only one a single
// unlinked display can mean — until it is.
const LINK_FLAG_SINGLE: f64 = 0.0;

/// Panel heights whose column packing the vendored doc states. 12 rows is
/// deliberately absent: that type packs column PAIRS into 3 bytes and the doc
/// does not say in what order.
const PINNED_PANEL_HEIGHTS: [u32; 2] = [5, 16];

/// Name fragment identifying the bulk channel among the writable
/// characteristics.
// SPEC-GAP: WRITE2 and WRITE3 are structurally identical in the spec — both
// write-only, both declaring the same `encryption` block — so the only field
// that tells them apart is `name`. Which channel an upload streams over
// should be declarable (the `image_upload` feature's `channel_tag`, or a
// `framing.channel_tag` on the characteristic), the way the Daniao specs
// already say it. Until then this matches the name the spec and the vendored
// doc both use, and refuses rather than falling back to a sibling channel:
// pixels written to WRITE3 would land in the live-DIY/visualizer path.
const BULK_CHANNEL_NAME: &str = "WRITE2";

/// Encode one RGB888 canvas as a complete bulk transfer: DATS on the command
/// channel, the column-major bitmap in AES blocks on the bulk channel, then
/// DATCP. The panel keeps no partial state between transfers, so
/// `frame_index` changes nothing — an animation is a sequence of whole
/// transfers, exactly as the vendor app sends them.
pub fn encode_bitmap_transfer(
    spec: &DeviceSpec,
    rgb: &[u8],
    width: u32,
    height: u32,
    _frame_index: u32,
    max_payload_per_write: usize,
) -> Result<EncodedFrame, ProtocolError> {
    validate_rgb_canvas(spec, rgb, width, height)?;
    if max_payload_per_write < MIN_PAYLOAD_PER_WRITE {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "max_payload_per_write {max_payload_per_write} is below the BLE minimum of \
                 {MIN_PAYLOAD_PER_WRITE}"
            ),
        });
    }

    let command_char = resolve_command_channel(spec)?;
    let bulk_char = resolve_bulk_channel(spec, &command_char.uuid)?;
    let command_key = declared_static_key(command_char, ALGORITHM)?;
    let bulk_key = declared_static_key(bulk_char, ALGORITHM)?;

    // The panel's row count is the spec's `image_upload.max_height`: it is
    // the display type, and the display type is what picks the packing.
    let panel_rows = image_feature(spec)
        .and_then(|f| f.max_height)
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: "spec declares no image_upload.max_height, which is the panel's row count \
                     and picks the column packing"
                .to_string(),
        })?;
    if !PINNED_PANEL_HEIGHTS.contains(&panel_rows) {
        return Err(ProtocolError::ImageUploadUnsupported {
            reason: format!(
                "the spec declares a {panel_rows}-row panel; the vendored documentation pins \
                 the column packing only for the 5-row and 16-row display types (the 12-row \
                 type packs column PAIRS into 3 bytes by an order it does not state)"
            ),
        });
    }
    let bytes_per_column = (panel_rows as usize).div_ceil(8);

    // ── the bitmap, column-major ────────────────────────────────────────
    let lit = channel_mask(rgb);
    let w = width as usize;
    let mut bitmap = Vec::with_capacity(w * bytes_per_column);
    for x in 0..w {
        bitmap.extend_from_slice(&column_bytes(&lit, w, height as usize, panel_rows, x));
    }
    if bitmap.len() > u16::MAX as usize {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "{width}x{height} needs {} bitmap bytes; DATS states the length in a uint16",
                bitmap.len()
            ),
        });
    }

    // ── DATS, the bitmap blocks, DATCP ──────────────────────────────────
    let len = bitmap.len() as u16;
    let dats = command_frame(
        command_char,
        CMD_TRANSFER_START,
        &HashMap::from([
            ("len_hi".to_string(), f64::from(len >> 8)),
            ("len_lo".to_string(), f64::from(len & 0xFF)),
            ("link_flag".to_string(), LINK_FLAG_SINGLE),
        ]),
    )?;
    let datcp = command_frame(command_char, CMD_TRANSFER_COMPLETE, &HashMap::new())?;

    let mut writes = vec![EncodedWrite {
        characteristic_uuid: command_char.uuid.clone(),
        bytes: encrypt_block(&command_key, dats)?,
    }];
    for chunk in bitmap.chunks(BULK_PAYLOAD_PER_BLOCK) {
        let mut block = Vec::with_capacity(BLOCK);
        block.push(chunk.len() as u8);
        block.extend_from_slice(chunk);
        // A short tail block is zero-filled to the cipher's block: its own
        // length byte, not the block length, says how much of it is bitmap.
        block.resize(BLOCK, 0);
        writes.push(EncodedWrite {
            characteristic_uuid: bulk_char.uuid.clone(),
            bytes: encrypt_block(&bulk_key, block)?,
        });
    }
    writes.push(EncodedWrite {
        characteristic_uuid: command_char.uuid.clone(),
        bytes: encrypt_block(&command_key, datcp)?,
    });

    // One AES block per BLE write, so packets and writes are the same count.
    let packets = writes.len() as u32;
    Ok(EncodedFrame { writes, packets })
}

/// The 1-bit mask the spec states for this family: "any RGB channel >= 128 =
/// ON". Deliberately not the shared luma mask — the two disagree on
/// saturated blue, and this is the rule the vendor app rasterizes by.
fn channel_mask(rgb: &[u8]) -> Vec<bool> {
    rgb.chunks_exact(3)
        .map(|px| px.iter().any(|&c| c >= 128))
        .collect()
}

/// One column of the panel, packed the way the doc's display-type table
/// states: the top row of each byte's group sits at that group's highest used
/// bit. On a 16-row panel that is byte 0 = rows 0-7 at bits 7-0 and byte 1 =
/// rows 8-15; on a 5-row panel, one byte with rows 0-4 at bits 4-0.
///
/// Canvas rows past `height` stay dark — the column is a physical strip of
/// LEDs, so a shorter canvas leaves its bottom unlit rather than shifting.
fn column_bytes(lit: &[bool], width: usize, height: usize, panel_rows: u32, x: usize) -> Vec<u8> {
    let panel_rows = panel_rows as usize;
    let bytes = panel_rows.div_ceil(8);
    (0..bytes)
        .map(|b| {
            let first = b * 8;
            let in_group = (panel_rows - first).min(8);
            let mut byte = 0u8;
            for k in 0..in_group {
                let y = first + k;
                if y < height && lit[y * width + x] {
                    byte |= 1 << (in_group - 1 - k);
                }
            }
            byte
        })
        .collect()
}

/// One command frame: the spec's own template, zero-padded to the cipher's
/// block. "Commands are fixed 16-byte ASCII-named packets: [length,
/// ASCII_CMD..., params..., zero_pad]" — zeros here, unlike the Shining Mask
/// sibling, which fills the tail from its RNG.
fn command_frame(
    characteristic: &Characteristic,
    name: &str,
    params: &HashMap<String, f64>,
) -> Result<Vec<u8>, ProtocolError> {
    let command = characteristic
        .commands
        .as_ref()
        .and_then(|m| m.get(name))
        .ok_or_else(|| ProtocolError::CommandNotFound {
            uuid: characteristic.uuid.clone(),
            command: name.to_string(),
        })?;
    let mut frame = encode_command(command, params)?;
    if frame.len() > BLOCK {
        return Err(ProtocolError::ImageUploadUnsupported {
            reason: format!(
                "'{name}' renders {} bytes; a command is one {BLOCK}-byte cipher block",
                frame.len()
            ),
        });
    }
    frame.resize(BLOCK, 0);
    Ok(frame)
}

/// Encrypt one 16-byte packet in place. ECB is a single block application —
/// no IV, no chaining — which is exactly why every packet here is padded to
/// the block size before it gets here.
fn encrypt_block(key: &[u8; 16], packet: Vec<u8>) -> Result<Vec<u8>, ProtocolError> {
    if packet.len() != BLOCK {
        return Err(ProtocolError::ImageUploadUnsupported {
            reason: format!(
                "a {BLOCK}-byte cipher block was built {} bytes wide",
                packet.len()
            ),
        });
    }
    let mut block = [0u8; BLOCK];
    block.copy_from_slice(&packet);
    aes::Aes128::new(key.into()).encrypt_block((&mut block).into());
    Ok(block.to_vec())
}

/// The command channel: the writable characteristic declaring the transfer's
/// opening command. On the vendored spec that is WRITE1 (0x…9600).
fn resolve_command_channel(spec: &DeviceSpec) -> Result<&Characteristic, ProtocolError> {
    spec.services
        .iter()
        .flat_map(|s| &s.characteristics)
        .filter(|c| is_writable(c))
        .find(|c| {
            c.commands
                .as_ref()
                .is_some_and(|m| m.contains_key(CMD_TRANSFER_START))
        })
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: format!(
                "spec has no writable characteristic declaring '{CMD_TRANSFER_START}', \
                 which anchors the transfer's command channel"
            ),
        })
}

/// The bulk channel: the OTHER writable characteristic the spec names WRITE2.
fn resolve_bulk_channel<'a>(
    spec: &'a DeviceSpec,
    command_uuid: &str,
) -> Result<&'a Characteristic, ProtocolError> {
    spec.services
        .iter()
        .flat_map(|s| &s.characteristics)
        .filter(|c| is_writable(c) && !c.uuid.eq_ignore_ascii_case(command_uuid))
        .find(|c| c.name.contains(BULK_CHANNEL_NAME))
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: format!(
                "spec has no writable characteristic named '{BULK_CHANNEL_NAME}' to stream \
                 the bitmap over"
            ),
        })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;
    use aes::cipher::BlockDecrypt;

    /// A minimal spec shaped like the vendored `magic-display.yaml`: the FEE9
    /// service with WRITE1 (its two framing commands and the static key),
    /// WRITE2 and the structurally-identical WRITE3 decoy, plus the feature
    /// bounds of the 16x64 display type.
    const SPEC_YAML: &str = r#"
device:
  name: "Magic Display"
  manufacturer: "tirohk / AiTURE"
  manufacturer_status: "abandoned"
  protocol: "ble"
  category: "display"
  identification:
    service_uuids:
      - "0000fee9-0000-1000-8000-00805f9b34fb"
protocol_handler: "cdbwsoft_ecb"
features:
  - type: "image_upload"
    format: "1bit-bitmap"
    max_width: 64
    max_height: 16
services:
  - uuid: "0000fee9-0000-1000-8000-00805f9b34fb"
    name: "QPP Service"
    characteristics:
      - uuid: "d44bc439-abfd-45a2-b575-925416129600"
        name: "Command (WRITE1)"
        properties: ["write"]
        encryption:
          algorithm: "aes-128-ecb"
          key_derivation: "static"
          static_key: "34522a5b7a6e492c08090a9d8d2a23f8"
        commands:
          led_on:
            description: "Turn LED display on"
            value: [0x05, 0x4C, 0x45, 0x44, 0x4F, 0x4E]
          data_transfer_start:
            description: "Start bulk data transfer. hi/lo = big-endian 16-bit data length."
            template: [0x08, 0x44, 0x41, 0x54, 0x53, "{len_hi}", "{len_lo}", 0x00, "{link_flag}"]
            parameters:
              len_hi:
                type: "uint8"
                min: 0
                max: 255
              len_lo:
                type: "uint8"
                min: 0
                max: 255
              link_flag:
                type: "uint8"
                min: 0
                max: 1
          data_transfer_complete:
            description: "Signal bulk data transfer complete"
            value: [0x05, 0x44, 0x41, 0x54, 0x43, 0x50]
      - uuid: "d44bc439-abfd-45a2-b575-925416129601"
        name: "Notification"
        properties: ["notify"]
      - uuid: "d44bc439-abfd-45a2-b575-92541612960a"
        name: "Bulk Data (WRITE2)"
        properties: ["write"]
        encryption:
          algorithm: "aes-128-ecb"
          key_derivation: "static"
          static_key: "34522a5b7a6e492c08090a9d8d2a23f8"
      - uuid: "d44bc439-abfd-45a2-b575-92541612960b"
        name: "Auxiliary (WRITE3)"
        properties: ["write"]
        encryption:
          algorithm: "aes-128-ecb"
          key_derivation: "static"
          static_key: "34522a5b7a6e492c08090a9d8d2a23f8"
"#;

    const WRITE1: &str = "d44bc439-abfd-45a2-b575-925416129600";
    const WRITE2: &str = "d44bc439-abfd-45a2-b575-92541612960a";
    const KEY: [u8; 16] = [
        0x34, 0x52, 0x2A, 0x5B, 0x7A, 0x6E, 0x49, 0x2C, 0x08, 0x09, 0x0A, 0x9D, 0x8D, 0x2A, 0x23,
        0xF8,
    ];

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC_YAML).unwrap()
    }

    fn decrypt(bytes: &[u8]) -> Vec<u8> {
        let mut block = [0u8; BLOCK];
        block.copy_from_slice(bytes);
        aes::Aes128::new(&KEY.into()).decrypt_block((&mut block).into());
        block.to_vec()
    }

    /// A 4x16 canvas lighting exactly one pixel per column, at the four rows
    /// that pin the packing: 0 and 7 (the ends of byte 0) and 8 and 15 (the
    /// ends of byte 1).
    fn corners_4x16() -> Vec<u8> {
        let (w, h) = (4usize, 16usize);
        let mut rgb = vec![0u8; w * h * 3];
        for (x, y) in [(0, 0), (1, 7), (2, 8), (3, 15)] {
            let i = (y * w + x) * 3;
            rgb[i..i + 3].copy_from_slice(&[255, 255, 255]);
        }
        rgb
    }

    /// The whole transfer for the 4x16 corners, as ciphertext — the golden
    /// bytes an implementation actually puts on the wire.
    ///
    /// Derived plaintext, from the doc's transfer protocol and display-type
    /// table (4 columns x 2 bytes = 8 bitmap bytes, so DATS states 0x0008):
    ///
    /// ```text
    ///   WRITE1  08 44 41 54 53 00 08 00 00 | 00 x7   DATS, len 8, link 0
    ///   WRITE2  08 80 00 01 00 00 80 00 01 | 00 x7   len 8, then the columns
    ///   WRITE1  05 44 41 54 43 50 | 00 x10           DATCP
    /// ```
    ///
    /// Column x=0 lights row 0 -> byte 0 bit 7 -> `80 00`; x=1 lights row 7
    /// -> byte 0 bit 0 -> `01 00`; x=2 lights row 8 -> byte 1 bit 7 ->
    /// `00 80`; x=3 lights row 15 -> byte 1 bit 0 -> `00 01`.
    ///
    /// The ciphertexts are AES-128-ECB of those blocks under the spec's own
    /// static key, computed independently (pycryptodome) rather than read
    /// back from this code.
    #[test]
    fn golden_4x16_transfer() {
        let frame = encode_bitmap_transfer(&spec(), &corners_4x16(), 4, 16, 0, 509).unwrap();
        assert_eq!(frame.packets, 3, "DATS + one bitmap block + DATCP");
        assert_eq!(frame.writes.len(), 3);
        assert!(
            frame.writes.iter().all(|w| w.bytes.len() == BLOCK),
            "every packet is exactly one cipher block"
        );

        assert_eq!(frame.writes[0].characteristic_uuid, WRITE1);
        assert_eq!(
            frame.writes[0].bytes,
            vec![
                0xE5, 0x62, 0x66, 0xE2, 0x55, 0x5B, 0xA2, 0xAB, 0x92, 0xE7, 0x3F, 0x27, 0x0B, 0x27,
                0x74, 0xB5
            ],
            "DATS with the bitmap's byte count, big-endian"
        );

        assert_eq!(frame.writes[1].characteristic_uuid, WRITE2);
        assert_eq!(
            frame.writes[1].bytes,
            vec![
                0x57, 0xDE, 0x66, 0x32, 0x56, 0x17, 0x22, 0xCA, 0x4F, 0xFF, 0x5F, 0x01, 0x4D, 0xFA,
                0xAB, 0x14
            ],
            "the column-major bitmap, length-prefixed inside its block"
        );

        assert_eq!(frame.writes[2].characteristic_uuid, WRITE1);
        assert_eq!(
            frame.writes[2].bytes,
            vec![
                0x8A, 0xC8, 0x6A, 0xE0, 0x7A, 0x14, 0x36, 0x22, 0x44, 0x37, 0xD4, 0xD2, 0xC1, 0xCF,
                0x45, 0x03
            ],
            "DATCP"
        );

        // And the same three, read back as the plaintext the doc states.
        assert_eq!(
            decrypt(&frame.writes[0].bytes),
            vec![0x08, b'D', b'A', b'T', b'S', 0x00, 0x08, 0x00, 0x00, 0, 0, 0, 0, 0, 0, 0]
        );
        assert_eq!(
            decrypt(&frame.writes[1].bytes),
            vec![0x08, 0x80, 0x00, 0x01, 0x00, 0x00, 0x80, 0x00, 0x01, 0, 0, 0, 0, 0, 0, 0]
        );
        assert_eq!(
            decrypt(&frame.writes[2].bytes),
            vec![0x05, b'D', b'A', b'T', b'C', b'P', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        );
    }

    /// A full 64x64-column panel frame: 128 bitmap bytes — the byte count the
    /// doc's display-type table gives for STYPE16X64 — cut into blocks of 15.
    #[test]
    fn a_full_panel_frame_is_the_documented_128_bytes() {
        let frame =
            encode_bitmap_transfer(&spec(), &vec![0xFFu8; 64 * 16 * 3], 64, 16, 0, 509).unwrap();
        // 128 bytes / 15 per block = 9 blocks, the last carrying 8.
        assert_eq!(frame.writes.len(), 1 + 9 + 1);
        let dats = decrypt(&frame.writes[0].bytes);
        assert_eq!(&dats[5..7], &[0x00, 0x80], "128, big-endian");
        let blocks: Vec<Vec<u8>> = frame.writes[1..10]
            .iter()
            .map(|w| decrypt(&w.bytes))
            .collect();
        for block in &blocks[..8] {
            assert_eq!(block[0], 15);
            assert_eq!(&block[1..16], &[0xFFu8; 15], "every LED lit");
        }
        assert_eq!(blocks[8][0], 8, "the tail block carries the remaining 8");
        assert_eq!(&blocks[8][1..9], &[0xFFu8; 8]);
        assert_eq!(
            &blocks[8][9..],
            &[0u8; 7],
            "and is zero-padded to the block"
        );
    }

    /// The threshold is the spec's own — "any RGB channel >= 128 = ON" — not
    /// the shared luma mask, which the two disagree on for saturated blue.
    #[test]
    fn the_threshold_is_any_channel_at_or_above_128() {
        let px = |r: u8, g: u8, b: u8| {
            let mut rgb = vec![0u8; 16 * 3];
            rgb[0..3].copy_from_slice(&[r, g, b]);
            let frame = encode_bitmap_transfer(&spec(), &rgb, 1, 16, 0, 509).unwrap();
            decrypt(&frame.writes[1].bytes)[1]
        };
        assert_eq!(
            px(0, 0, 255),
            0x80,
            "saturated blue is ON by the channel rule"
        );
        assert_eq!(px(0, 128, 0), 0x80, "exactly 128 is ON");
        assert_eq!(px(127, 127, 127), 0x00, "127 in every channel is OFF");
    }

    /// A canvas shorter than the panel leaves the bottom of each column
    /// unlit; the column is still a whole 2-byte strip.
    #[test]
    fn a_short_canvas_leaves_the_rest_of_the_column_dark() {
        let frame = encode_bitmap_transfer(&spec(), &[0xFFu8; 2 * 3], 1, 2, 0, 509).unwrap();
        let block = decrypt(&frame.writes[1].bytes);
        assert_eq!(block[0], 2, "one column is still two bytes");
        assert_eq!(&block[1..3], &[0xC0, 0x00], "rows 0-1 lit, 2-15 dark");
    }

    /// The panel's row count is the spec's, and it picks the packing: retype
    /// the feature to the 5-row display and a column becomes one byte with
    /// its rows right-aligned into bits 4-0.
    #[test]
    fn the_five_row_panel_packs_one_right_aligned_byte_per_column() {
        let yaml = SPEC_YAML.replace("max_height: 16", "max_height: 5");
        let s = parse_device_spec(&yaml).unwrap();
        let mut rgb = vec![0u8; 5 * 3];
        rgb[0..3].copy_from_slice(&[255, 255, 255]); // row 0 -> bit 4
        let frame = encode_bitmap_transfer(&s, &rgb, 1, 5, 0, 509).unwrap();
        let dats = decrypt(&frame.writes[0].bytes);
        assert_eq!(&dats[5..7], &[0x00, 0x01], "one column, one byte");
        assert_eq!(decrypt(&frame.writes[1].bytes)[1], 0x10, "row 0 at bit 4");
    }

    /// The 12-row display type packs column PAIRS into three bytes by an
    /// order the vendored doc does not state, so it is refused by name rather
    /// than encoded by analogy.
    #[test]
    fn the_undocumented_twelve_row_packing_is_refused() {
        let yaml = SPEC_YAML.replace("max_height: 16", "max_height: 12");
        let s = parse_device_spec(&yaml).unwrap();
        let err = encode_bitmap_transfer(&s, &[0u8; 4 * 12 * 3], 4, 12, 0, 509).unwrap_err();
        assert!(
            format!("{err:?}").contains("12-row"),
            "the error should name the packing it will not guess, got {err:?}"
        );
    }

    /// Both framing commands come from the spec's templates: change the DATS
    /// bytes and the wire changes with them.
    #[test]
    fn the_framing_commands_come_from_the_spec_templates() {
        let yaml = SPEC_YAML.replace(
            r#"template: [0x08, 0x44, 0x41, 0x54, 0x53, "{len_hi}", "{len_lo}", 0x00, "{link_flag}"]"#,
            r#"template: [0x09, 0x44, 0x41, 0x54, 0x53, "{len_hi}", "{len_lo}", 0x00, "{link_flag}", 0x77]"#,
        );
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_bitmap_transfer(&s, &corners_4x16(), 4, 16, 0, 509).unwrap();
        let dats = decrypt(&frame.writes[0].bytes);
        assert_eq!(dats[0], 0x09);
        assert_eq!(dats[9], 0x77);
    }

    /// A spec declaring no DATS is refused rather than sent this device's
    /// bytes — which is what keeps the sibling `shining-glasses.yaml`, whose
    /// DATS is a different shape, out of this encoder.
    #[test]
    fn a_spec_without_the_framing_commands_errors_helpfully() {
        let yaml = SPEC_YAML.replace("data_transfer_start:", "some_other_command:");
        let s = parse_device_spec(&yaml).unwrap();
        let err = encode_bitmap_transfer(&s, &corners_4x16(), 4, 16, 0, 509).unwrap_err();
        assert!(format!("{err:?}").contains("data_transfer_start"));

        let yaml = SPEC_YAML.replace("data_transfer_complete:", "some_other_command:");
        let s = parse_device_spec(&yaml).unwrap();
        let err = encode_bitmap_transfer(&s, &corners_4x16(), 4, 16, 0, 509).unwrap_err();
        assert!(format!("{err:?}").contains("data_transfer_complete"));
    }

    /// The key is the spec's: change it and every packet changes.
    #[test]
    fn the_key_comes_from_the_spec() {
        let yaml = SPEC_YAML.replace(
            "34522a5b7a6e492c08090a9d8d2a23f8",
            "000102030405060708090a0b0c0d0e0f",
        );
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_bitmap_transfer(&s, &corners_4x16(), 4, 16, 0, 509).unwrap();
        let original = encode_bitmap_transfer(&spec(), &corners_4x16(), 4, 16, 0, 509).unwrap();
        assert_ne!(frame.writes[0].bytes, original.writes[0].bytes);
    }

    /// A characteristic declaring a cipher this build cannot run is refused
    /// rather than written in the clear.
    #[test]
    fn an_unimplemented_cipher_is_refused_rather_than_written_plain() {
        let yaml = SPEC_YAML.replace("aes-128-ecb", "aes-128-gcm");
        let s = parse_device_spec(&yaml).unwrap();
        let err = encode_bitmap_transfer(&s, &corners_4x16(), 4, 16, 0, 509).unwrap_err();
        assert!(format!("{err:?}").contains("aes-128-ecb"));
    }

    /// WRITE3 is structurally identical to WRITE2 in the spec, and pixels
    /// written to it would land in the live-DIY path. It is never the target.
    #[test]
    fn the_auxiliary_write3_channel_is_never_the_target() {
        let frame = encode_bitmap_transfer(&spec(), &corners_4x16(), 4, 16, 0, 509).unwrap();
        assert!(frame
            .writes
            .iter()
            .all(|w| w.characteristic_uuid == WRITE1 || w.characteristic_uuid == WRITE2));
    }

    #[test]
    fn a_canvas_over_the_declared_bounds_is_rejected() {
        let err =
            encode_bitmap_transfer(&spec(), &vec![0u8; 65 * 16 * 3], 65, 16, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn wrong_buffer_length_is_rejected() {
        let err = encode_bitmap_transfer(&spec(), &[0; 5], 4, 16, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }
}

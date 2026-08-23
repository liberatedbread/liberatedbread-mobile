// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Image-frame encoder for the generic "wang"/LSLED Bluetooth LED name badge
//! — `protocol_handler: "ledbadge_bitmap"`
//! (`vendor/protocol-specs/device-specs/devices/bluetooth-led-name-badge.yaml`).
//!
//! THE WIRE FORMAT (the spec's `write_badge_data` command doc and
//! `device.notes`, verified upstream against a full static analysis of the
//! vendor app and cross-checked with the Elektor sniff, Nilhcem and
//! FOSSASIA): everything is plain 16-byte acknowledged writes to the Badge
//! Data characteristic — no length prefix, no checksum. A transfer is a
//! 64-byte header (4 chunks) followed by the bitmap, zero-padded to whole
//! chunks:
//!
//! ```text
//!   [0-3]   magic "wang" (77 61 6E 67 — the spec command's own value bytes)
//!   [4]     reserved 0
//!   [5]     brightness (0x00=100%, 0x10=75%, 0x20=50%, 0x40=25%)
//!   [6]     flash bits (bit N = slot N blinks)
//!   [7]     marquee bits (bit N = slot N gets the animated border)
//!   [8-15]  mode+speed per slot: upper nibble = speed-1, lower = mode-1
//!   [16-31] per-slot message length, uint16 BIG-endian, in 8-column stripes
//!   [32-37] reserved zeros
//!   [38-43] date (year, month, day, hour, minute, second)
//!   [44-62] reserved zeros;  [63] 0x00
//! ```
//!
//! Bitmap data is STRIPE-major: the image is cut into 8-column-wide stripes
//! of `height` bytes each, one byte per row, MSB = leftmost pixel, bit 1 =
//! LED lit. The badge holds 8 message slots; this upload writes slot 0 as a
//! fixed (non-scrolling) image and leaves the rest empty — a whole transfer
//! replaces everything the badge stores, so empty slots are genuinely empty.
//!
//! 1-BIT POLARITY: a pixel at or above 50% luma is a LIT LED. The spec's
//! feature comment ("white pixel -> bit 0, any other color -> bit 1")
//! describes the vendor app's rasterizer, which draws dark text on a WHITE
//! canvas — content dark, background white. This app's LED editor draws
//! bright content on a black canvas, so "content -> lit" means bright -> 1
//! here; following the comment literally would floodlight the background
//! and blank the drawing.
//!
//! Pacing (300 ms before the first data chunk, 25 ms between chunks, 3 s
//! ack timeout) is the transport's job; this encoder only orders the writes.

use super::image_upload::{
    brightness_mask, declared_max_chunk_size, is_writable, validate_rgb_canvas,
    MIN_PAYLOAD_PER_WRITE,
};
use super::{EncodedFrame, EncodedWrite};
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, DeviceSpec};

/// `protocol_handler` name this module implements (see the device spec's
/// top-level `protocol_handler` key).
pub const HANDLER_NAME: &str = "ledbadge_bitmap";

/// Spec command whose byte `value` is the header magic and whose declaring
/// characteristic is the upload channel.
const ANCHOR_COMMAND: &str = "write_badge_data";

const HEADER_LEN: usize = 64;
const SLOTS: usize = 8;

/// Chunk size when the characteristic declares no `framing.max_chunk_size`
/// — the protocol's raw 16-byte writes, kept as a fallback for a spec pack
/// written before the key existed (the vendored spec declares it).
const DEFAULT_CHUNK: usize = 16;

/// Slot 0's mode+speed byte: speed 1 (upper nibble 0), mode "fixed/static"
/// (low nibble 0x04 per the vendored protocol doc's mode table,
/// `docs/devices/bluetooth-led-name-badge.md` — scroll modes are 0x00-0x03,
/// fixed is 0x04).
// SPEC-GAP: the spec YAML gives the nibble packing ("upper nibble =
// speed-1, lower nibble = mode-1") but not the mode enumeration; the mode
// table lives only in the vendored doc and should become a declared
// vocabulary on the `write_badge_data` command (e.g. `modes:`) so a static
// image upload can name "fixed" from data.
const SLOT0_FIXED_MODE_SPEED1: u8 = 0x04;

/// Total bitmap payload ceiling, from the vendored protocol doc ("max 8192
/// bytes total payload", `docs/devices/bluetooth-led-name-badge.md`).
// SPEC-GAP: the spec YAML bounds only `max_height`; the 8192-byte flash
// ceiling should become a declared field (e.g. `max_payload_bytes`) on the
// image_upload feature.
const MAX_BITMAP_BYTES: usize = 8192;

/// Encode one RGB888 frame as the complete badge transfer that stores it in
/// slot 0: 4 header chunks then the stripe-major bitmap, all on the Badge
/// Data characteristic. Stateless per the protocol — every transfer
/// replaces the badge's stored messages, so `frame_index` changes nothing.
pub fn encode_badge_bitmap(
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

    let (badge_char, magic) = resolve_badge_channel(spec)?;
    let chunk = declared_max_chunk_size(badge_char).unwrap_or(DEFAULT_CHUNK);
    if chunk > max_payload_per_write {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "the badge's {chunk}-byte chunks do not fit the {max_payload_per_write}-byte \
                 write budget — raise the ATT MTU"
            ),
        });
    }

    // Stripes: 8-column-wide, `height` bytes each. The per-slot length
    // field counts them (the Elektor sniff shows the vendor app sending
    // 00 07 for a 7-character = 7-stripe message).
    let stripes = (width as usize).div_ceil(8);
    let bitmap_len = stripes * height as usize;
    if bitmap_len > MAX_BITMAP_BYTES {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "{width}x{height} needs {bitmap_len} bitmap bytes; the badge stores at most \
                 {MAX_BITMAP_BYTES}"
            ),
        });
    }
    if stripes > u16::MAX as usize {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!("{stripes} stripes overflow the u16 slot-length field"),
        });
    }

    // ── 64-byte header ──────────────────────────────────────────────────
    let mut payload = Vec::with_capacity(HEADER_LEN + bitmap_len);
    // [0-3] magic "wang"; [4] reserved; [5] brightness 100%; [6] no flash;
    // [7] no marquee.
    payload.extend_from_slice(magic);
    payload.extend_from_slice(&[0x00, 0x00, 0x00, 0x00]);
    // [8-15] mode+speed per slot: slot 0 fixed at speed 1, the rest empty.
    payload.push(SLOT0_FIXED_MODE_SPEED1);
    payload.extend_from_slice(&[0u8; SLOTS - 1]);
    // [16-31] per-slot length in stripes, u16 big-endian: slot 0 only.
    payload.extend_from_slice(&(stripes as u16).to_be_bytes());
    payload.extend_from_slice(&[0u8; 2 * (SLOTS - 1)]);
    // [32-37] reserved.
    payload.extend_from_slice(&[0u8; 6]);
    // [38-43] date (year, month, day, hour, minute, second). Zeros,
    // deliberately: the field is metadata the badge stores with the message,
    // no documented behavior depends on it, and a deterministic transfer is
    // byte-for-byte testable.
    payload.extend_from_slice(&[0u8; 6]);
    // [44-62] reserved, [63] 0x00.
    payload.extend_from_slice(&[0u8; 20]);
    debug_assert_eq!(payload.len(), HEADER_LEN);

    // ── stripe-major bitmap ─────────────────────────────────────────────
    // Bright pixel = lit LED = bit 1, MSB = leftmost column of the stripe;
    // columns past the canvas width stay 0.
    let lit = brightness_mask(rgb);
    for stripe in 0..stripes {
        for y in 0..height as usize {
            let mut byte = 0u8;
            for k in 0..8 {
                let x = stripe * 8 + k;
                if x < width as usize && lit[y * width as usize + x] {
                    byte |= 0x80 >> k;
                }
            }
            payload.push(byte);
        }
    }

    // Zero-pad the bitmap into whole chunks (spec: "bitmap zero-padded into
    // 16-byte chunks") and emit one write per chunk. The header is 64 bytes
    // = 4 chunks at the declared 16.
    let pad = (chunk - payload.len() % chunk) % chunk;
    payload.extend(std::iter::repeat_n(0u8, pad));

    let writes: Vec<EncodedWrite> = payload
        .chunks(chunk)
        .map(|part| EncodedWrite {
            characteristic_uuid: badge_char.uuid.clone(),
            bytes: part.to_vec(),
        })
        .collect();
    let packets = writes.len() as u32;
    Ok(EncodedFrame { writes, packets })
}

/// The Badge Data channel and the header magic, both from the spec: the
/// writable characteristic declaring `write_badge_data`, whose fixed `value`
/// bytes ARE the "wang" magic. The undocumented 0xFEE7 service's writable
/// characteristic declares no commands, so it can never be picked.
fn resolve_badge_channel(spec: &DeviceSpec) -> Result<(&Characteristic, &[u8]), ProtocolError> {
    let badge_char = spec
        .services
        .iter()
        .flat_map(|s| &s.characteristics)
        .filter(|c| is_writable(c))
        .find(|c| {
            c.commands
                .as_ref()
                .is_some_and(|m| m.contains_key(ANCHOR_COMMAND))
        })
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: format!(
                "spec has no writable characteristic declaring '{ANCHOR_COMMAND}', \
                 which anchors the badge upload channel"
            ),
        })?;
    let magic = badge_char.commands.as_ref().unwrap()[ANCHOR_COMMAND]
        .value
        .as_deref()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: format!(
                "'{ANCHOR_COMMAND}' declares no value bytes to use as the header magic"
            ),
        })?;
    Ok((badge_char, magic))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A minimal spec shaped like the vendored
    /// `bluetooth-led-name-badge.yaml`: same characteristic layout (the
    /// FEE1 data channel with its framing block and command, the
    /// undocumented FEE7 write characteristic as the decoy), same feature.
    const SPEC_YAML: &str = r#"
device:
  name: "Bluetooth LED Name Badge"
  manufacturer: "Generic (multiple OEMs)"
  manufacturer_status: "active"
  protocol: "ble"
  category: "display"
  identification:
    local_name_prefix: "LS"
protocol_handler: "ledbadge_bitmap"
features:
  - type: "image_upload"
    format: "1bit-bitmap"
    max_height: 16
services:
  - uuid: "0000fee0-0000-1000-8000-00805f9b34fb"
    name: "Badge Service"
    characteristics:
      - uuid: "0000fee1-0000-1000-8000-00805f9b34fb"
        name: "Badge Data"
        properties: ["read", "write", "notify"]
        framing:
          length_prefix: false
          max_chunk_size: 16
        commands:
          write_badge_data:
            description: "Write badge payload in 16-byte chunks."
            value: [0x77, 0x61, 0x6E, 0x67]
  - uuid: "0000fee7-0000-1000-8000-00805f9b34fb"
    name: "Badge Secondary Service"
    characteristics:
      - uuid: "0000fec7-0000-1000-8000-00805f9b34fb"
        name: "FEC7 (write)"
        properties: ["write"]
"#;

    const BADGE_CHAR: &str = "0000fee1-0000-1000-8000-00805f9b34fb";

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC_YAML).unwrap()
    }

    /// An 8x11 canvas lighting the diagonal: pixel (x=y, y) is white for
    /// y < 8, everything else black.
    fn diagonal_8x11() -> Vec<u8> {
        let (w, h) = (8usize, 11usize);
        let mut rgb = vec![0u8; w * h * 3];
        for y in 0..8 {
            let i = (y * w + y) * 3;
            rgb[i..i + 3].copy_from_slice(&[255, 255, 255]);
        }
        rgb
    }

    /// The whole transfer for the 8x11 diagonal, derived chunk by chunk
    /// from the spec's documented header layout:
    ///
    /// - one 8-column stripe of 11 rows -> slot-0 length 0x0001 (u16 BE)
    /// - header: "wang", reserved 0, brightness 0 (100%), flash 0,
    ///   marquee 0, slot bytes [0x04 fixed/speed-1, then 7 empty], lengths
    ///   [00 01, then 7x 00 00], reserved/date/tail zeros
    /// - bitmap: row y has bit (0x80 >> y) for y < 8 (the diagonal), rows
    ///   8-10 empty; 11 bytes zero-padded to one 16-byte chunk
    #[test]
    fn golden_8x11_diagonal_transfer() {
        let frame = encode_badge_bitmap(&spec(), &diagonal_8x11(), 8, 11, 0, 509).unwrap();
        assert_eq!(frame.packets, 5, "4 header chunks + 1 bitmap chunk");
        assert_eq!(frame.writes.len(), 5);
        for w in &frame.writes {
            assert_eq!(w.characteristic_uuid, BADGE_CHAR);
            assert_eq!(w.bytes.len(), 16, "raw 16-byte chunks, no prefix");
        }
        assert_eq!(
            frame.writes[0].bytes,
            [0x77, 0x61, 0x6E, 0x67, 0, 0, 0, 0, 0x04, 0, 0, 0, 0, 0, 0, 0],
            "magic, reserved, brightness/flash/marquee, slot mode bytes"
        );
        assert_eq!(
            frame.writes[1].bytes,
            [0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
            "slot 0 holds one stripe, big-endian, other slots empty"
        );
        assert_eq!(frame.writes[2].bytes, [0u8; 16], "reserved + zeroed date");
        assert_eq!(frame.writes[3].bytes, [0u8; 16], "reserved tail");
        assert_eq!(
            frame.writes[4].bytes,
            [0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01, 0, 0, 0, 0, 0, 0, 0, 0],
            "diagonal bitmap: MSB = leftmost, bit 1 = lit, padded to 16"
        );
    }

    #[test]
    fn width_beyond_one_stripe_emits_stripe_major_data() {
        // 10x11: two stripes. Light the top-left pixel and the top pixel of
        // column 9 (second stripe, k=1): stripe 0's bytes come first (all 11
        // rows), then stripe 1's.
        let (w, h) = (10usize, 11usize);
        let mut rgb = vec![0u8; w * h * 3];
        rgb[0..3].copy_from_slice(&[255, 255, 255]); // (0,0) -> stripe 0
        rgb[9 * 3..9 * 3 + 3].copy_from_slice(&[255, 255, 255]); // (9,0) -> stripe 1
        let frame = encode_badge_bitmap(&spec(), &rgb, 10, 11, 0, 509).unwrap();
        // Header 4 chunks + 22 bitmap bytes -> 2 chunks.
        assert_eq!(frame.writes.len(), 6);
        assert_eq!(
            frame.writes[1].bytes[..2],
            [0, 2],
            "two stripes in the slot-0 length"
        );
        let bitmap: Vec<u8> = frame.writes[4..]
            .iter()
            .flat_map(|w| w.bytes.iter().copied())
            .collect();
        assert_eq!(bitmap[0], 0x80, "stripe 0 row 0: leftmost pixel");
        assert_eq!(&bitmap[1..11], &[0u8; 10], "stripe 0 rows 1-10 empty");
        assert_eq!(bitmap[11], 0x40, "stripe 1 row 0: column 9 is bit 1 of 8");
        assert_eq!(&bitmap[12..22], &[0u8; 10], "stripe 1 rows 1-10 empty");
        assert_eq!(&bitmap[22..], &[0u8; 10], "zero padding to the chunk");
    }

    #[test]
    fn dim_pixels_stay_dark_and_bright_colors_light() {
        // 50% luma threshold: pure green (luma 0.587) lights, pure red
        // (0.299) and pure blue (0.114) do not — a colored-on-black doodle
        // keeps its bright strokes without floodlighting the background.
        let rgb = vec![
            0, 255, 0, // green -> lit
            255, 0, 0, // red -> dark
            0, 0, 255, // blue -> dark
            255, 255, 255, // white -> lit
        ];
        let frame = encode_badge_bitmap(&spec(), &rgb, 4, 1, 0, 509).unwrap();
        // One stripe, one row: bits 0 and 3 (MSB-first) = 0b1001_0000.
        assert_eq!(frame.writes[4].bytes[0], 0x90);
    }

    #[test]
    fn the_chunk_size_is_whatever_the_spec_declares() {
        let yaml = SPEC_YAML.replace("max_chunk_size: 16", "max_chunk_size: 32");
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_badge_bitmap(&s, &diagonal_8x11(), 8, 11, 0, 509).unwrap();
        // 64-byte header + 11-byte bitmap -> 75 bytes, padded to 96 = 3x32.
        assert_eq!(frame.writes.len(), 3);
        assert!(frame.writes.iter().all(|w| w.bytes.len() == 32));
    }

    #[test]
    fn a_spec_without_the_declared_chunk_size_still_writes_16() {
        let yaml = SPEC_YAML.replace("          max_chunk_size: 16\n", "");
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_badge_bitmap(&s, &diagonal_8x11(), 8, 11, 0, 509).unwrap();
        assert_eq!(frame.writes.len(), 5);
        assert!(frame.writes.iter().all(|w| w.bytes.len() == 16));
    }

    #[test]
    fn the_magic_comes_from_the_spec_command_value() {
        let yaml = SPEC_YAML.replace("[0x77, 0x61, 0x6E, 0x67]", "[0x11, 0x22, 0x33, 0x44]");
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_badge_bitmap(&s, &diagonal_8x11(), 8, 11, 0, 509).unwrap();
        assert_eq!(&frame.writes[0].bytes[..4], &[0x11, 0x22, 0x33, 0x44]);
    }

    #[test]
    fn the_undocumented_fee7_write_characteristic_is_never_the_target() {
        let frame = encode_badge_bitmap(&spec(), &diagonal_8x11(), 8, 11, 0, 509).unwrap();
        assert!(frame
            .writes
            .iter()
            .all(|w| w.characteristic_uuid == BADGE_CHAR));
    }

    #[test]
    fn height_over_the_declared_ceiling_is_rejected() {
        let err = encode_badge_bitmap(&spec(), &vec![0u8; 8 * 17 * 3], 8, 17, 0, 509).unwrap_err();
        assert!(
            format!("{err:?}").contains("16"),
            "the error should quote the spec's max_height, got {err:?}"
        );
    }

    #[test]
    fn a_payload_past_the_badge_flash_ceiling_is_rejected() {
        // 8192-byte ceiling: 4100 stripes x 2 rows = 8200 bytes. Width
        // 32800 = 4100 stripes.
        let (w, h) = (32800usize, 2usize);
        let err = encode_badge_bitmap(&spec(), &vec![0u8; w * h * 3], w as u32, h as u32, 0, 509)
            .unwrap_err();
        assert!(
            format!("{err:?}").contains("8192"),
            "the error should quote the ceiling, got {err:?}"
        );
    }

    #[test]
    fn a_spec_without_the_anchor_command_errors_helpfully() {
        let yaml = SPEC_YAML.replace("write_badge_data:", "not_the_command:");
        let s = parse_device_spec(&yaml).unwrap();
        let err = encode_badge_bitmap(&s, &diagonal_8x11(), 8, 11, 0, 509).unwrap_err();
        assert!(
            format!("{err:?}").contains("write_badge_data"),
            "the error should name the missing anchor, got {err:?}"
        );
    }

    #[test]
    fn wrong_buffer_length_is_rejected() {
        let err = encode_badge_bitmap(&spec(), &[0; 5], 8, 11, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }
}

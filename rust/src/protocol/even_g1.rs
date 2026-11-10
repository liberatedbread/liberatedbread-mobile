// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Even Realities G1 smart glasses: the BMP image transfer
//! (`vendor/protocol-specs/device-specs/devices/even-g1-glasses.yaml`,
//! `protocol_details.bmp`).
//!
//! The picture is a complete 1-bit `.bmp` file, header and palette included,
//! sent as-is in 194-byte slices:
//!
//! ```text
//!   bmp_first_packet  15 00 | 00 1C 00 00 | file[0..194]      seq 0 + address
//!   bmp_packet        15 <seq> | file[194*seq..]              seq 1..n
//!   bmp_end           20 0D 0E          → wait for 20 C9
//!   bmp_crc           16 <crc32 BE>     → reply 16 <crc> C9 = shown
//! ```
//!
//! The CRC is CRC-32/XZ (zlib's parameters) over the four address bytes and
//! then the whole file, sent big-endian. Every frame is rendered from the
//! spec's own command templates; what lives here is the BMP file, the CRC, and
//! the order.
//!
//! # Two temples
//!
//! Each temple is its own BLE peripheral and draws only what it is sent. The
//! spec's side rule for 0x15/0x20/0x16 is "both, independently and at the same
//! time", so the plan is the same bytes for either temple and the order
//! between them does not matter. This encoder produces one temple's plan; the
//! caller sends it to each temple it holds. The app's image editor drives the
//! one temple it is connected to; a device group holding both temples sends
//! to each in turn.
//!
//! # Which spec this is
//!
//! The spec names no `protocol_handler`. [`bind_handler`] adopts a spec by
//! what it declares — a 1-bit `image_upload` beside a writable characteristic
//! carrying all four BMP commands — never by device name, and leaves any spec
//! that names a handler of its own alone.
//!
//! Nothing here has been run against a G1: the spec marks every byte
//! `reported`, from the vendor's demo app and community captures.

use super::idotmatrix::Crc32;
use super::image_upload::{brightness_mask, image_feature, is_writable, validate_rgb_canvas};
use super::{EncodedFrame, EncodedWrite, ReplyField, ReplyWait};
use crate::codec::types::encode_command_with_bytes;
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, CharacteristicProperty, DeviceSpec};
use std::collections::HashMap;

/// The handler name [`bind_handler`] gives a spec that declares the G1's BMP
/// transfer. Not a name the catalogue writes.
pub const HANDLER_NAME: &str = "even_g1_bmp";

const CMD_FIRST: &str = "bmp_first_packet";
const CMD_PACKET: &str = "bmp_packet";
const CMD_END: &str = "bmp_end";
const CMD_CRC: &str = "bmp_crc";
const BMP_COMMANDS: [&str; 4] = [CMD_FIRST, CMD_PACKET, CMD_END, CMD_CRC];

/// The `image_upload.format` the transfer carries.
const FORMAT: &str = "1bit-bitmap";

/// `protocol_details.bmp.storage_address`: ahead of the data in the first
/// packet, and ahead of the file in the CRC.
pub const STORAGE_ADDRESS: [u8; 4] = [0x00, 0x1C, 0x00, 0x00];

/// `protocol_details.bmp.chunk_bytes`: file bytes per packet.
pub const CHUNK_BYTES: usize = 194;

/// The first packet is the largest write: opcode, seq, address, a full chunk.
const FIRST_WRITE_LEN: usize = 2 + STORAGE_ADDRESS.len() + CHUNK_BYTES;

/// "54-byte header + 8-byte palette + rows".
const BMP_HEADER_LEN: usize = 54;
const BMP_PALETTE_LEN: usize = 8;

/// Status bytes (`protocol_details.framing.status_codes`).
const STATUS_OK: u8 = 0xC9;
const STATUS_FAIL: u8 = 0xCA;

/// Opcodes of the two replies the transfer waits on.
const OP_END: u8 = 0x20;
const OP_CRC: u8 = 0x16;

/// Where the CRC reply's status sits: "16 <crc, 4 bytes> <status>".
const CRC_STATUS_OFFSET: usize = 5;

/// The vendor demo's pacing: 5 ms between chunks on Android, 8 ms on iOS.
/// The slower of the two, since one pace has to serve both.
const INTER_WRITE_DELAY_MS: u32 = 8;

/// `bmp_end`: "retries up to 10 times, 1 s apart, on a 3 s timeout". The
/// plan runner does not retry a write past the first, so this is one try.
const END_TIMEOUT_MS: u32 = 3_000;

/// The CRC reply is the one that draws the picture. The spec gives no figure;
/// the end's own timeout is the nearest one it does give.
const CRC_TIMEOUT_MS: u32 = 3_000;

/// Give a spec that declares the G1's BMP transfer its handler name, so the
/// image-upload DTO and the encoder find it. A spec naming any handler of its
/// own is left alone.
pub fn bind_handler(spec: &mut DeviceSpec) {
    if spec.protocol_handler.is_some() {
        return;
    }
    let one_bit = image_feature(spec).is_some_and(|f| f.format.as_deref() == Some(FORMAT));
    if one_bit && bmp_channel(spec).is_some() {
        spec.protocol_handler = Some(HANDLER_NAME.to_string());
    }
}

/// The writable characteristic declaring all four BMP commands.
fn bmp_channel(spec: &DeviceSpec) -> Option<&Characteristic> {
    spec.services
        .iter()
        .flat_map(|s| &s.characteristics)
        .filter(|c| is_writable(c))
        .find(|c| {
            c.commands
                .as_ref()
                .is_some_and(|m| BMP_COMMANDS.iter().all(|name| m.contains_key(*name)))
        })
}

/// The notify characteristic in the same service as `write`: "write to
/// 6e400002 and listen on 6e400003 of the temple the command is meant for".
fn reply_channel<'a>(spec: &'a DeviceSpec, write: &Characteristic) -> Option<&'a Characteristic> {
    spec.services
        .iter()
        .find(|s| {
            s.characteristics
                .iter()
                .any(|c| c.uuid.eq_ignore_ascii_case(&write.uuid))
        })?
        .characteristics
        .iter()
        .find(|c| {
            c.properties.iter().any(|p| {
                matches!(
                    p,
                    CharacteristicProperty::Notify | CharacteristicProperty::Indicate
                )
            })
        })
}

/// Encode one RGB888 canvas as the complete transfer for one temple. The
/// canvas sits at the top left of the spec's full display, the rest dark. A
/// pixel at least half bright is lit.
pub fn encode_image(
    spec: &DeviceSpec,
    rgb: &[u8],
    width: u32,
    height: u32,
    _frame_index: u32,
    max_payload_per_write: usize,
) -> Result<EncodedFrame, ProtocolError> {
    validate_rgb_canvas(spec, rgb, width, height)?;
    let unsupported = |reason: String| ProtocolError::ImageUploadUnsupported { reason };
    if max_payload_per_write < FIRST_WRITE_LEN {
        return Err(unsupported(format!(
            "the glasses take {CHUNK_BYTES}-byte image chunks, {FIRST_WRITE_LEN} bytes per write, \
             and this link carries {max_payload_per_write}; raise the ATT MTU (the spec asks \
             for 251)"
        )));
    }
    let feature = image_feature(spec).ok_or_else(|| unsupported("no image_upload".into()))?;
    let (Some(display_w), Some(display_h)) = (feature.max_width, feature.max_height) else {
        return Err(unsupported(
            "the image_upload feature states no display size".to_string(),
        ));
    };
    let channel = bmp_channel(spec)
        .ok_or_else(|| unsupported("no characteristic declares the BMP commands".into()))?;
    let notify = reply_channel(spec, channel)
        .ok_or_else(|| unsupported("the BMP channel's service has no notify channel".into()))?;

    let file = encode_bmp(
        rgb,
        width as usize,
        height as usize,
        display_w as usize,
        display_h as usize,
    );
    let crc = transfer_crc(&file);

    let command = |name: &str,
                   params: &[(&str, f64)],
                   data: Option<&[u8]>|
     -> Result<EncodedWrite, ProtocolError> {
        let declared = channel
            .commands
            .as_ref()
            .and_then(|m| m.get(name))
            .ok_or_else(|| ProtocolError::CommandNotFound {
                uuid: channel.uuid.clone(),
                command: name.to_string(),
            })?;
        let params: HashMap<String, f64> =
            params.iter().map(|(k, v)| (k.to_string(), *v)).collect();
        let bytes: HashMap<String, Vec<u8>> = data
            .map(|d| HashMap::from([("data".to_string(), d.to_vec())]))
            .unwrap_or_default();
        Ok(EncodedWrite {
            characteristic_uuid: channel.uuid.clone(),
            bytes: encode_command_with_bytes(declared, &params, &bytes)?,
        })
    };

    let chunks: Vec<&[u8]> = file.chunks(CHUNK_BYTES).collect();
    if chunks.len() > 256 {
        return Err(unsupported(format!(
            "a {}-byte file needs {} chunks, past the 256 a sequence byte numbers",
            file.len(),
            chunks.len()
        )));
    }
    let mut writes = Vec::with_capacity(chunks.len() + 2);
    for (seq, chunk) in chunks.iter().enumerate() {
        writes.push(if seq == 0 {
            command(CMD_FIRST, &[], Some(chunk))?
        } else {
            command(CMD_PACKET, &[("seq", seq as f64)], Some(chunk))?
        });
    }
    let end = writes.len();
    writes.push(command(CMD_END, &[], None)?);
    let crc_write = writes.len();
    writes.push(command(CMD_CRC, &[("crc32", f64::from(crc))], None)?);

    let mut crc_reply = vec![OP_CRC];
    crc_reply.extend_from_slice(&crc.to_be_bytes());
    Ok(EncodedFrame {
        packets: writes.len() as u32,
        inter_write_delay_ms: INTER_WRITE_DELAY_MS,
        reply_waits: vec![
            ReplyWait {
                after_write: end,
                characteristic_uuid: notify.uuid.clone(),
                expect_prefix: vec![OP_END, STATUS_OK],
                must_carry: None,
                error_prefixes: vec![vec![OP_END, STATUS_FAIL]],
                timeout_ms: END_TIMEOUT_MS,
            },
            ReplyWait {
                after_write: crc_write,
                characteristic_uuid: notify.uuid.clone(),
                expect_prefix: crc_reply,
                must_carry: Some(ReplyField {
                    offset: CRC_STATUS_OFFSET,
                    bytes: vec![STATUS_OK],
                }),
                error_prefixes: Vec::new(),
                timeout_ms: CRC_TIMEOUT_MS,
            },
        ],
        completion_poll: None,
        writes,
    })
}

/// CRC-32/XZ of the storage address followed by the file
/// (`protocol_details.bmp.crc`).
pub fn transfer_crc(file: &[u8]) -> u32 {
    let mut crc = Crc32::new();
    crc.update(&STORAGE_ADDRESS);
    crc.update(file);
    crc.finish()
}

/// A complete 1-bit BMP of `display_w` x `display_h`, the canvas at its top
/// left. Palette entry 0 is black and 1 is white, so a set bit is a lit pixel.
/// Rows are stored bottom-up (a positive height), each padded to 4 bytes.
///
/// The spec fixes the header and palette sizes but not the palette order or
/// the row direction; these are the BMP defaults, recorded as open in
/// SPECS_TO_FIX.md.
pub fn encode_bmp(
    rgb: &[u8],
    width: usize,
    height: usize,
    display_w: usize,
    display_h: usize,
) -> Vec<u8> {
    let row_bytes = display_w.div_ceil(32) * 4;
    let pixels_len = row_bytes * display_h;
    let offset = BMP_HEADER_LEN + BMP_PALETTE_LEN;
    let file_len = offset + pixels_len;

    let mut file = Vec::with_capacity(file_len);
    // BITMAPFILEHEADER
    file.extend_from_slice(b"BM");
    file.extend_from_slice(&(file_len as u32).to_le_bytes());
    file.extend_from_slice(&[0; 4]);
    file.extend_from_slice(&(offset as u32).to_le_bytes());
    // BITMAPINFOHEADER
    file.extend_from_slice(&40u32.to_le_bytes());
    file.extend_from_slice(&(display_w as i32).to_le_bytes());
    file.extend_from_slice(&(display_h as i32).to_le_bytes());
    file.extend_from_slice(&1u16.to_le_bytes()); // planes
    file.extend_from_slice(&1u16.to_le_bytes()); // bits per pixel
    file.extend_from_slice(&0u32.to_le_bytes()); // BI_RGB
    file.extend_from_slice(&(pixels_len as u32).to_le_bytes());
    file.extend_from_slice(&2835u32.to_le_bytes()); // 72 dpi
    file.extend_from_slice(&2835u32.to_le_bytes());
    file.extend_from_slice(&2u32.to_le_bytes()); // colours used
    file.extend_from_slice(&0u32.to_le_bytes());
    // Palette: black, white (B, G, R, reserved).
    file.extend_from_slice(&[0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0x00]);

    let lit = brightness_mask(rgb);
    let mut pixels = vec![0u8; pixels_len];
    for y in 0..height.min(display_h) {
        let row = (display_h - 1 - y) * row_bytes;
        for x in 0..width.min(display_w) {
            if lit[y * width + x] {
                pixels[row + x / 8] |= 0x80 >> (x % 8);
            }
        }
    }
    file.extend_from_slice(&pixels);
    file
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn vendored() -> DeviceSpec {
        let path = format!(
            "{}/../vendor/protocol-specs/device-specs/devices/even-g1-glasses.yaml",
            env!("CARGO_MANIFEST_DIR")
        );
        parse_device_spec(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    const WRITE: &str = "6e400002-b5a3-f393-e0a9-e50e24dcca9e";
    const NOTIFY: &str = "6e400003-b5a3-f393-e0a9-e50e24dcca9e";

    #[test]
    fn the_crc_is_zlibs() {
        // "check value 0xCBF43926 for "123456789"" (bmp_crc).
        let mut crc = Crc32::new();
        crc.update(b"123456789");
        assert_eq!(crc.finish(), 0xCBF4_3926);
    }

    #[test]
    fn the_transfer_crc_covers_the_address_then_the_file() {
        let file = b"123456789";
        let mut whole = STORAGE_ADDRESS.to_vec();
        whole.extend_from_slice(file);
        let mut crc = Crc32::new();
        crc.update(&whole);
        assert_eq!(transfer_crc(file), crc.finish());
        assert_ne!(transfer_crc(file), 0xCBF4_3926, "the address is included");
    }

    #[test]
    fn the_bmp_is_header_palette_and_rows() {
        let file = encode_bmp(&[], 0, 0, 576, 136);
        // 54-byte header + 8-byte palette + 136 rows of 72 bytes.
        assert_eq!(file.len(), 54 + 8 + 72 * 136);
        assert_eq!(&file[0..2], b"BM");
        assert_eq!(
            u32::from_le_bytes(file[2..6].try_into().unwrap()),
            file.len() as u32
        );
        assert_eq!(u32::from_le_bytes(file[10..14].try_into().unwrap()), 62);
        assert_eq!(u32::from_le_bytes(file[14..18].try_into().unwrap()), 40);
        assert_eq!(i32::from_le_bytes(file[18..22].try_into().unwrap()), 576);
        assert_eq!(i32::from_le_bytes(file[22..26].try_into().unwrap()), 136);
        assert_eq!(u16::from_le_bytes(file[28..30].try_into().unwrap()), 1);
        assert_eq!(&file[54..62], &[0, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0]);
        assert!(file[62..].iter().all(|b| *b == 0), "dark canvas");
    }

    #[test]
    fn a_lit_pixel_lands_top_left_in_the_last_stored_row() {
        // 2x2 canvas: only (0,0) white.
        let rgb = [255, 255, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0];
        let file = encode_bmp(&rgb, 2, 2, 576, 136);
        let last_row = 62 + 135 * 72;
        assert_eq!(file[last_row], 0x80);
        assert_eq!(file[62..].iter().filter(|b| **b != 0).count(), 1);
    }

    #[test]
    fn the_vendored_spec_binds_to_this_handler() {
        let spec = vendored();
        assert_eq!(spec.protocol_handler.as_deref(), Some(HANDLER_NAME));
    }

    #[test]
    fn a_spec_naming_its_own_handler_keeps_it() {
        let path = format!(
            "{}/../vendor/protocol-specs/device-specs/devices/even-g1-glasses.yaml",
            env!("CARGO_MANIFEST_DIR")
        );
        let yaml = std::fs::read_to_string(path).unwrap() + "\nprotocol_handler: \"other\"\n";
        let spec = parse_device_spec(&yaml).unwrap();
        assert_eq!(spec.protocol_handler.as_deref(), Some("other"));
    }

    #[test]
    fn the_vendored_spec_encodes_the_whole_transfer_in_order() {
        let spec = vendored();
        let rgb = vec![0u8; 576 * 136 * 3];
        let frame = encode_image(&spec, &rgb, 576, 136, 0, 248).unwrap();
        let file = encode_bmp(&rgb, 576, 136, 576, 136);
        // 9854 bytes: 50 full chunks and one of 154 — "about 51 chunks".
        let chunks = file.len().div_ceil(CHUNK_BYTES);
        assert_eq!(chunks, 51);
        assert_eq!(frame.writes.len(), chunks + 2);
        assert!(frame.writes.iter().all(|w| w.characteristic_uuid == WRITE));

        let first = &frame.writes[0].bytes;
        assert_eq!(&first[..6], &[0x15, 0x00, 0x00, 0x1C, 0x00, 0x00]);
        assert_eq!(&first[6..], &file[..194]);
        let second = &frame.writes[1].bytes;
        assert_eq!(&second[..2], &[0x15, 0x01]);
        assert_eq!(&second[2..], &file[194..388]);
        let last = &frame.writes[chunks - 1].bytes;
        assert_eq!(last[1], 50);
        assert_eq!(&last[2..], &file[50 * 194..]);

        assert_eq!(frame.writes[chunks].bytes, [0x20, 0x0D, 0x0E]);
        let crc = transfer_crc(&file);
        let mut crc_frame = vec![0x16];
        crc_frame.extend_from_slice(&crc.to_be_bytes());
        assert_eq!(frame.writes[chunks + 1].bytes, crc_frame);

        let [end, shown] = &frame.reply_waits[..] else {
            panic!("two waits")
        };
        assert_eq!(end.after_write, chunks);
        assert_eq!(end.expect_prefix, [0x20, 0xC9]);
        assert_eq!(end.characteristic_uuid, NOTIFY);
        assert_eq!(shown.after_write, chunks + 1);
        assert_eq!(shown.expect_prefix, crc_frame);
        let carry = shown.must_carry.as_ref().unwrap();
        assert_eq!((carry.offset, carry.bytes.as_slice()), (5, &[0xC9][..]));
        assert_eq!(frame.inter_write_delay_ms, 8);
    }

    #[test]
    fn a_small_canvas_is_padded_to_the_display() {
        let spec = vendored();
        let frame = encode_image(&spec, &[255; 8 * 4 * 3], 8, 4, 0, 248).unwrap();
        assert_eq!(frame.writes.len(), 51 + 2);
    }

    #[test]
    fn a_link_too_small_for_a_chunk_is_refused() {
        let spec = vendored();
        let err = encode_image(&spec, &[0; 3], 1, 1, 0, 199).unwrap_err();
        assert!(err.to_string().contains("MTU"), "{err}");
        assert!(encode_image(&spec, &[0; 3], 1, 1, 0, 200).is_ok());
    }

    #[test]
    fn an_oversized_canvas_is_refused() {
        let spec = vendored();
        assert!(encode_image(&spec, &vec![0; 577 * 3], 577, 1, 0, 248).is_err());
    }
}

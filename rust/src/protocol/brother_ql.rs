// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Raster print-job encoder and status decoder for the Brother QL-series
//! network label printers — `protocol_handler: "brother_ql_raster"`
//! (`vendor/protocol-specs/device-specs/devices/brother-ql-1110nwb.yaml`).
//!
//! Unlike the BLE thermal printers (which emit per-characteristic
//! [`super::EncodedFrame`]s), a QL consumes ONE raw byte stream, identical on
//! every carriage — TCP 9100, LPR/LPD 515, FTP, Bluetooth-Classic SPP, USB
//! bulk — with no framing and no authentication. So this module produces a
//! `Vec<u8>` for the raw-stream transport to write, not GATT writes.
//!
//! THE JOB, exactly the spec's `job_structure`:
//! ```text
//!   1B 69 61 01            switch to raster mode
//!   00 × 200               invalidate (clear a half-eaten command)
//!   1B 40                  ESC @ initialize
//!   1B 69 7A + 10 bytes    media & quality (flags, type, width/length mm,
//!                          raster-row count u32 LE, page, 00)
//!   1B 69 4D 40            auto-cut on            } when auto_cut
//!   1B 69 41 01            cut every 1 page       }
//!   1B 69 4B 08            expanded mode: cut at end
//!   1B 69 64 <u16 LE>      margin/feed amount in dots
//!   raster rows            67 00 <len> <data>  (or 5A for an all-white row)
//!   1A                     print the final page
//! ```
//!
//! ROW ENCODING (spec `raster_rows`): 1 bit per pixel, MSB first, 1 = black,
//! padded to the head width (`image_upload.max_width` / 8 bytes) with white.
//! The image is mirrored left-to-right before packing — the head maps bit 7 of
//! byte 0 to the RIGHT edge — so image column 0 lands at the highest bit index
//! (the left edge of the print). A pixel darker than 50% luma prints (black);
//! that is [`brightness_mask`] inverted.
//!
//! CALIBRATION CAVEAT: a canvas NARROWER than the head is left-aligned here
//! (white padded toward the wire's byte 0 / right edge). Real narrow DK media
//! is often centred or carries the head's 44-dot right dead zone
//! (`geometry.additional_offset_right_dots`); getting that exactly right is a
//! hardware-calibration question this project has not driven, so a caller that
//! wants precise placement should size the canvas to the media's printable
//! dots. The command stream, framing, polarity and mirror are golden-tested;
//! narrow-media horizontal offset is the one thing a test print would refine.
//!
//! PackBits row compression (`4D 02` then compressed `67 00` payloads) is
//! documented but NOT emitted — uncompressed rows are always accepted, and a
//! label is small. Two-colour rows (`77 …`, QL-800 red layer) do not apply to
//! this monochrome head.

use super::image_upload::{brightness_mask, printhead_row_bytes, validate_rgb_canvas};
use crate::error::ProtocolError;
use crate::spec::types::DeviceSpec;

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "brother_ql_raster";

// -- Raster-language constants (spec `commands:` payload_hex, QL series). --
const SWITCH_TO_RASTER_MODE: [u8; 4] = [0x1B, 0x69, 0x61, 0x01];
const INITIALIZE: [u8; 2] = [0x1B, 0x40];
const STATUS_REQUEST: [u8; 3] = [0x1B, 0x69, 0x53];
const MEDIA_AND_QUALITY: [u8; 3] = [0x1B, 0x69, 0x7A];
const AUTOCUT_ON: [u8; 4] = [0x1B, 0x69, 0x4D, 0x40];
const CUT_EVERY_ONE_PAGE: [u8; 4] = [0x1B, 0x69, 0x41, 0x01];
const EXPANDED_CUT_AT_END: [u8; 4] = [0x1B, 0x69, 0x4B, 0x08];
const MARGIN: [u8; 3] = [0x1B, 0x69, 0x64];
const RASTER_ROW: [u8; 2] = [0x67, 0x00];
const BLANK_ROW: u8 = 0x5A;
const PRINT_FINAL_PAGE: u8 = 0x1A;

/// `geometry.invalidate_bytes` — 200 for the QL series (brother_ql uses the
/// same count for every QL model, so it is a language constant here, not a
/// per-model number the way the head width is).
const INVALIDATE_BYTES: usize = 200;

/// The 32-byte status reply's fixed header (`response_header_hex: 802042`).
const STATUS_HEADER: [u8; 3] = [0x80, 0x20, 0x42];
const STATUS_REPLY_LEN: usize = 32;

// media/quality "valid flags" (spec `commands.media_and_quality`).
const FLAG_VALID: u8 = 0x80; // bit 7, always set
const FLAG_MEDIA_TYPE: u8 = 0x02; // bit 1
const FLAG_MEDIA_WIDTH: u8 = 0x04; // bit 2
const FLAG_MEDIA_LENGTH: u8 = 0x08; // bit 3
const FLAG_HIGH_QUALITY: u8 = 0x40; // bit 6

/// The loaded media's kind (`status_reply` offset 11 / `media_and_quality`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MediaType {
    /// Continuous-length tape (`0x0A`): the raster-row count sets the length.
    Continuous,
    /// Die-cut labels (`0x0B`): fixed length per label.
    DieCut,
}

impl MediaType {
    fn wire(self) -> u8 {
        match self {
            MediaType::Continuous => 0x0A,
            MediaType::DieCut => 0x0B,
        }
    }

    fn from_wire(byte: u8) -> Option<MediaType> {
        match byte {
            0x0A => Some(MediaType::Continuous),
            0x0B => Some(MediaType::DieCut),
            _ => None,
        }
    }
}

/// The media the job is printed on. `length_mm` is 0 for continuous tape (the
/// row count decides the length). Both are millimetres, as the wire carries
/// them.
#[derive(Clone, Copy, Debug)]
pub struct Media {
    pub media_type: MediaType,
    pub width_mm: u8,
    pub length_mm: u8,
}

/// Print-time options. Defaults: auto-cut on, standard quality, a 35-dot feed
/// margin (the spec's typical value).
#[derive(Clone, Copy, Debug)]
pub struct JobOptions {
    pub auto_cut: bool,
    pub high_quality: bool,
    pub margin_dots: u16,
}

impl Default for JobOptions {
    fn default() -> Self {
        JobOptions {
            auto_cut: true,
            high_quality: false,
            margin_dots: 35,
        }
    }
}

/// The bytes that ask for the 32-byte status reply (`1B 69 53`).
pub fn status_request() -> [u8; 3] {
    STATUS_REQUEST
}

/// Encode one RGB888 canvas as a complete raster job — the whole byte stream
/// to write to TCP 9100 (or any equivalent carriage).
pub fn encode_print_job(
    spec: &DeviceSpec,
    rgb: &[u8],
    width: u32,
    height: u32,
    media: Media,
    options: JobOptions,
) -> Result<Vec<u8>, ProtocolError> {
    validate_rgb_canvas(spec, rgb, width, height)?;
    // Head width in whole bytes, from the spec's declared paper width. This is
    // the per-model number (162 bytes / 1296 dots on the QL-1110NWB).
    let row_bytes = printhead_row_bytes(spec)?;
    let head_dots = row_bytes * 8;

    let mut out = Vec::new();
    out.extend_from_slice(&SWITCH_TO_RASTER_MODE);
    out.resize(out.len() + INVALIDATE_BYTES, 0x00);
    out.extend_from_slice(&INITIALIZE);

    // Media & quality: ESC i z + 10 bytes.
    let mut flags = FLAG_VALID | FLAG_MEDIA_TYPE | FLAG_MEDIA_WIDTH;
    if media.length_mm != 0 {
        flags |= FLAG_MEDIA_LENGTH;
    }
    if options.high_quality {
        flags |= FLAG_HIGH_QUALITY;
    }
    out.extend_from_slice(&MEDIA_AND_QUALITY);
    out.push(flags);
    out.push(media.media_type.wire());
    out.push(media.width_mm);
    out.push(media.length_mm);
    out.extend_from_slice(&height.to_le_bytes()); // raster-row count, u32 LE
    out.push(0x00); // starting page (0 = the first/only page)
    out.push(0x00); // trailing fixed byte

    if options.auto_cut {
        out.extend_from_slice(&AUTOCUT_ON);
        out.extend_from_slice(&CUT_EVERY_ONE_PAGE);
    }
    out.extend_from_slice(&EXPANDED_CUT_AT_END);
    out.extend_from_slice(&MARGIN);
    out.extend_from_slice(&options.margin_dots.to_le_bytes());

    // Rows: dark pixel = black dot = bit 1, MSB first, image mirrored L-R so
    // column 0 is the highest bit index, padded white to the head width.
    let bright = brightness_mask(rgb);
    let w = width as usize;
    for y in 0..height as usize {
        let mut row = vec![0u8; row_bytes];
        let mut any_black = false;
        for x in 0..w {
            if !bright[y * w + x] {
                any_black = true;
                let i = head_dots - 1 - x;
                row[i / 8] |= 0x80 >> (i % 8);
            }
        }
        if any_black {
            out.extend_from_slice(&RASTER_ROW);
            // row_bytes <= 255 (printhead_row_bytes bounds the width at 2040
            // dots for exactly this one-byte length field).
            out.push(row_bytes as u8);
            out.extend_from_slice(&row);
        } else {
            out.push(BLANK_ROW);
        }
    }
    out.push(PRINT_FINAL_PAGE);
    Ok(out)
}

/// A decoded 32-byte status reply (`status_reply`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BrotherQlStatus {
    /// Loaded media width in mm (offset 10), 0 when no media is loaded.
    pub media_width_mm: u8,
    /// Loaded media kind (offset 11), None for "no media" / unknown.
    pub media_type: Option<MediaType>,
    /// Loaded media length in mm (offset 17), 0 for continuous.
    pub media_length_mm: u8,
    /// Status kind (offset 18): 0x00 reply-to-request, 0x01 printing complete,
    /// 0x02 error, 0x05 notification, 0x06 phase change.
    pub status_type: u8,
    /// Phase (offset 19): 0x00 waiting to receive, 0x01 printing.
    pub phase: u8,
    /// Human-readable errors decoded from the two error bytes (offsets 8, 9);
    /// empty when the printer reports none.
    pub errors: Vec<String>,
}

impl BrotherQlStatus {
    /// Whether a job can be sent right now: no reported error and media loaded.
    pub fn ready_to_print(&self) -> bool {
        self.errors.is_empty() && self.media_type.is_some() && self.media_width_mm > 0
    }
}

/// Decode a 32-byte status reply. Errors when the buffer is the wrong length or
/// carries the wrong header (so a stray reply or a truncated read is refused
/// rather than read as junk media).
pub fn decode_status(bytes: &[u8]) -> Result<BrotherQlStatus, ProtocolError> {
    if bytes.len() != STATUS_REPLY_LEN {
        return Err(ProtocolError::BufferTooShort {
            needed: STATUS_REPLY_LEN,
            got: bytes.len(),
        });
    }
    if bytes[0..3] != STATUS_HEADER {
        return Err(ProtocolError::InvalidFraming {
            reason: format!(
                "status reply header is {:02X?}, expected {:02X?}",
                &bytes[0..3],
                STATUS_HEADER
            ),
        });
    }
    let mut errors = Vec::new();
    let e1 = bytes[8];
    for (bit, msg) in [
        (0, "no media"),
        (1, "end of media"),
        (2, "cutter jam"),
        (4, "main unit in use"),
        (5, "printer off"),
        (7, "fan failure"),
    ] {
        if e1 & (1 << bit) != 0 {
            errors.push(msg.to_string());
        }
    }
    let e2 = bytes[9];
    for (bit, msg) in [
        (0, "replace media"),
        (1, "expansion buffer full"),
        (2, "communication error"),
        (4, "cover open"),
        (6, "media cannot be fed"),
        (7, "system error"),
    ] {
        if e2 & (1 << bit) != 0 {
            errors.push(msg.to_string());
        }
    }
    Ok(BrotherQlStatus {
        media_width_mm: bytes[10],
        media_type: MediaType::from_wire(bytes[11]),
        media_length_mm: bytes[17],
        status_type: bytes[18],
        phase: bytes[19],
        errors,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A QL-shaped spec with a deliberately TINY head (16 dots = 2 bytes/row)
    /// so the golden row bytes are legible. Real geometry (1296/162) is the
    /// same code path with a bigger width.
    const SPEC_YAML: &str = r#"
device:
  name: "Brother QL-1110NWB Label Printer"
  manufacturer: "Brother Industries"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "printer"
  transport: "tcp-raw"
  identification:
    local_name_prefixes: ["Brother QL-1110NWB"]
    default_port: 9100
  features:
    - type: "image_upload"
      max_width: 16
      max_height: 35434
      format: "1bit-bitmap"
  protocol_handler: "brother_ql_raster"
"#;

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC_YAML).unwrap()
    }

    fn white_row() -> Vec<u8> {
        vec![255u8; 16 * 3]
    }

    /// The fixed job preamble for continuous 12mm media, `rows` rows,
    /// auto-cut on, default 35-dot margin — everything up to the raster rows.
    fn preamble(rows: u32) -> Vec<u8> {
        let mut e = Vec::new();
        e.extend_from_slice(&[0x1B, 0x69, 0x61, 0x01]); // raster mode
        e.resize(e.len() + 200, 0x00); // invalidate
        e.extend_from_slice(&[0x1B, 0x40]); // init
                                            // media/quality: flags 0x86 (valid|type|width; no length for
                                            // continuous), type 0x0A, width 12, length 0, rows LE, page, 00.
        e.extend_from_slice(&[0x1B, 0x69, 0x7A, 0x86, 0x0A, 0x0C, 0x00]);
        e.extend_from_slice(&rows.to_le_bytes());
        e.extend_from_slice(&[0x00, 0x00]);
        e.extend_from_slice(&[0x1B, 0x69, 0x4D, 0x40]); // auto-cut on
        e.extend_from_slice(&[0x1B, 0x69, 0x41, 0x01]); // cut every 1
        e.extend_from_slice(&[0x1B, 0x69, 0x4B, 0x08]); // cut at end
        e.extend_from_slice(&[0x1B, 0x69, 0x64, 0x23, 0x00]); // margin 35
        e
    }

    fn media() -> Media {
        Media {
            media_type: MediaType::Continuous,
            width_mm: 12,
            length_mm: 0,
        }
    }

    #[test]
    fn golden_job_all_white_row_is_5a() {
        // One all-white row -> the single blank-row opcode, then print.
        let out =
            encode_print_job(&spec(), &white_row(), 16, 1, media(), JobOptions::default()).unwrap();
        let mut expected = preamble(1);
        expected.push(0x5A); // blank row
        expected.push(0x1A); // print final page
        assert_eq!(out, expected);
    }

    #[test]
    fn golden_job_full_black_row_packs_ones_then_mirrors() {
        // 16 black dots -> a full 2-byte row of 0xFF (mirror of all-ones is
        // all-ones), framed 67 00 02 FF FF.
        let out = encode_print_job(
            &spec(),
            &[0u8; 16 * 3],
            16,
            1,
            media(),
            JobOptions::default(),
        )
        .unwrap();
        let mut expected = preamble(1);
        expected.extend_from_slice(&[0x67, 0x00, 0x02, 0xFF, 0xFF]);
        expected.push(0x1A);
        assert_eq!(out, expected);
    }

    #[test]
    fn the_image_is_mirrored_left_to_right() {
        // Only the LEFTMOST image column (x=0) black. Mirrored, column 0 lands
        // at the highest bit index (15): byte 1, bit 0 (LSB) -> row = [00 01].
        let mut rgb = vec![255u8; 16 * 3];
        rgb[0..3].copy_from_slice(&[0, 0, 0]);
        let out = encode_print_job(&spec(), &rgb, 16, 1, media(), JobOptions::default()).unwrap();
        let row_at = out
            .windows(3)
            .position(|w| w == [0x67, 0x00, 0x02])
            .unwrap();
        assert_eq!(&out[row_at + 3..row_at + 5], &[0x00, 0x01]);

        // The RIGHTMOST column (x=15) -> bit index 0 -> byte 0, bit 7 (MSB).
        let mut rgb = vec![255u8; 16 * 3];
        rgb[15 * 3..15 * 3 + 3].copy_from_slice(&[0, 0, 0]);
        let out = encode_print_job(&spec(), &rgb, 16, 1, media(), JobOptions::default()).unwrap();
        let row_at = out
            .windows(3)
            .position(|w| w == [0x67, 0x00, 0x02])
            .unwrap();
        assert_eq!(&out[row_at + 3..row_at + 5], &[0x80, 0x00]);
    }

    #[test]
    fn a_narrow_canvas_is_padded_white_to_the_head_width() {
        // 8 black dots on a 16-dot head: still a full 2-byte row, content in
        // the high bit indices (bytes toward the end), white toward byte 0.
        let out =
            encode_print_job(&spec(), &[0u8; 8 * 3], 8, 1, media(), JobOptions::default()).unwrap();
        let row_at = out
            .windows(3)
            .position(|w| w == [0x67, 0x00, 0x02])
            .unwrap();
        // columns 0..7 -> bit indices 15..8 -> all of byte 1, none of byte 0.
        assert_eq!(&out[row_at + 3..row_at + 5], &[0x00, 0xFF]);
    }

    #[test]
    fn continuous_media_sets_no_length_flag_die_cut_does() {
        let die = Media {
            media_type: MediaType::DieCut,
            width_mm: 102,
            length_mm: 51,
        };
        let out =
            encode_print_job(&spec(), &white_row(), 16, 1, die, JobOptions::default()).unwrap();
        let mq = out
            .windows(3)
            .position(|w| w == [0x1B, 0x69, 0x7A])
            .unwrap();
        // flags valid|type|width|length = 0x8E, type 0x0B, width 102, length 51.
        assert_eq!(&out[mq + 3..mq + 7], &[0x8E, 0x0B, 102, 51]);
    }

    #[test]
    fn auto_cut_off_omits_the_cut_commands() {
        let out = encode_print_job(
            &spec(),
            &white_row(),
            16,
            1,
            media(),
            JobOptions {
                auto_cut: false,
                ..JobOptions::default()
            },
        )
        .unwrap();
        assert!(
            out.windows(4).all(|w| w != [0x1B, 0x69, 0x4D, 0x40]),
            "no auto-cut command"
        );
        assert!(
            out.windows(4).all(|w| w != [0x1B, 0x69, 0x41, 0x01]),
            "no cut-every-1 command"
        );
        // Cut-at-end still present (it is independent of per-page auto-cut).
        assert!(out.windows(4).any(|w| w == [0x1B, 0x69, 0x4B, 0x08]));
    }

    #[test]
    fn the_row_count_rides_the_media_command_little_endian() {
        let out = encode_print_job(
            &spec(),
            &[255u8; 16 * 3 * 300],
            16,
            300,
            media(),
            JobOptions::default(),
        )
        .unwrap();
        let mq = out
            .windows(3)
            .position(|w| w == [0x1B, 0x69, 0x7A])
            .unwrap();
        // rows = 300 = 0x012C -> LE 2C 01 00 00 at offset 3+4 (after flags,
        // type, width, length).
        assert_eq!(&out[mq + 7..mq + 11], &[0x2C, 0x01, 0x00, 0x00]);
    }

    #[test]
    fn a_canvas_wider_than_the_head_is_rejected() {
        let err = encode_print_job(
            &spec(),
            &[0u8; 17 * 3],
            17,
            1,
            media(),
            JobOptions::default(),
        )
        .unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn wrong_buffer_length_is_rejected() {
        let err = encode_print_job(&spec(), &[0u8; 5], 16, 1, media(), JobOptions::default())
            .unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn status_request_is_esc_i_s() {
        assert_eq!(status_request(), [0x1B, 0x69, 0x53]);
    }

    #[test]
    fn decode_status_reads_media_and_no_errors() {
        let mut r = [0u8; 32];
        r[0..3].copy_from_slice(&STATUS_HEADER);
        r[10] = 62; // 62mm media
        r[11] = 0x0A; // continuous
        r[17] = 0; // continuous -> length 0
        r[18] = 0x00; // reply to request
        r[19] = 0x00; // waiting to receive
        let s = decode_status(&r).unwrap();
        assert_eq!(s.media_width_mm, 62);
        assert_eq!(s.media_type, Some(MediaType::Continuous));
        assert!(s.errors.is_empty());
        assert!(s.ready_to_print());
    }

    #[test]
    fn decode_status_reports_errors_and_blocks_printing() {
        let mut r = [0u8; 32];
        r[0..3].copy_from_slice(&STATUS_HEADER);
        r[8] = 0b0000_0001; // no media
        r[9] = 0b0001_0000; // cover open
        r[11] = 0x00; // no media loaded
        let s = decode_status(&r).unwrap();
        assert!(s.errors.contains(&"no media".to_string()));
        assert!(s.errors.contains(&"cover open".to_string()));
        assert!(!s.ready_to_print());
    }

    #[test]
    fn decode_status_rejects_a_wrong_header_or_length() {
        let mut r = [0u8; 32];
        r[0..3].copy_from_slice(&[0x00, 0x00, 0x00]);
        assert!(matches!(
            decode_status(&r),
            Err(ProtocolError::InvalidFraming { .. })
        ));
        assert!(matches!(
            decode_status(&[0x80, 0x20, 0x42]),
            Err(ProtocolError::BufferTooShort { .. })
        ));
    }
}

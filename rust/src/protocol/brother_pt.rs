// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Brother P-touch Cube tape printers (PT-P300BT, PT-P710BT, PT-P910BT):
//! the PT raster language over Bluetooth Classic SPP
//! (`vendor/protocol-specs/device-specs/devices/brother-ptouch-cube.yaml`).
//!
//! Like the QL in `brother_ql.rs` the job is ONE unframed byte stream, but
//! the language differs where it matters — 16- or 70-byte lines, PackBits
//! compression, and a transposed image — so it is its own module. The job is
//! the spec's `protocol_details.job_sequence`:
//!
//! ```text
//!   00 × invalidate_bytes          the variant's print_geometry
//!   1B 40                          initialize
//!   1B 69 61 01                    raster mode
//!   1B 69 21 00                    push status while printing
//!   1B 69 7A f t w 00 <n u32> p 00 print information
//!   1B 69 4D 40                    various mode (auto cut)
//!   1B 69 4B 08                    advanced mode (no chain printing)
//!   1B 69 64 <margin u16>          feed margin
//!   4D 02                          PackBits
//!   47 <len u16> <packed> | 5A     one per raster line
//!   1A                             print and feed
//! ```
//!
//! # Orientation
//!
//! The composer hands over a canvas `width` dots across the tape and
//! `height` rows along it. Row n is raster line n; within a line, canvas
//! column 0 is the first byte's top bit, which is the spec's
//! `raster_orientation` (column-major after the label is turned upright).
//! The tape's printable dots sit at `right_margin_dots` from the start of the
//! line when the media states it, centred in the head otherwise, and a canvas
//! narrower than that is centred within it.
//!
//! # Which variant
//!
//! The spec carries one `image_upload` entry per head (PT-P300BT, PT-P710BT,
//! PT-P910BT), so every function here takes the variant the caller is
//! printing to; none given means the first entry.
//!
//! Nothing here has been run against a printer: the spec says every fact is
//! `reported`. The byte layouts are tested against the spec's own
//! `test_vectors`.

use super::image_upload::brightness_mask;
use super::raster_print::raster_feature_for;
use crate::error::ProtocolError;
use crate::spec::types::{DeviceSpec, Feature, PrintMedia};

/// The handler name [`bind_handler`] gives a spec that declares this job.
/// Not a name the catalogue writes.
pub const HANDLER_NAME: &str = "brother_pt_raster";

/// The transport every command of the job declares.
const TRANSPORT: &str = "rfcomm";

/// The commands whose presence, on the `rfcomm` transport, marks the PT
/// raster language.
const JOB_COMMANDS: [&str; 4] = [
    "print_information",
    "set_compression",
    "raster_line",
    "print_last_page_and_feed",
];

const INITIALIZE: [u8; 2] = [0x1B, 0x40];
const REQUEST_STATUS: [u8; 3] = [0x1B, 0x69, 0x53];
const RASTER_MODE: [u8; 4] = [0x1B, 0x69, 0x61, 0x01];
const AUTO_STATUS: [u8; 3] = [0x1B, 0x69, 0x21];
const PRINT_INFORMATION: [u8; 3] = [0x1B, 0x69, 0x7A];
const VARIOUS_MODE: [u8; 3] = [0x1B, 0x69, 0x4D];
const ADVANCED_MODE: [u8; 3] = [0x1B, 0x69, 0x4B];
const MARGIN: [u8; 3] = [0x1B, 0x69, 0x64];
const COMPRESSION_PACKBITS: [u8; 2] = [0x4D, 0x02];
const RASTER_LINE: u8 = 0x47;
const ZERO_RASTER_LINE: u8 = 0x5A;
const PRINT_AND_FEED: u8 = 0x1A;

/// Each command's parameter default when the spec gives none; the spec's own
/// defaults are read first ([`param_default`]).
const FALLBACK_VALID_FLAGS: i64 = 0x84;
const FALLBACK_VARIOUS_MODE: i64 = 0x40;
const FALLBACK_ADVANCED_MODE: i64 = 0x08;
const FALLBACK_MARGIN: i64 = 14;
/// "0 = notify (default)".
const AUTO_STATUS_NOTIFY: u8 = 0x00;
/// The invalidate count of the command when the variant states none.
const FALLBACK_INVALIDATE: usize = 100;

const STATUS_LEN: usize = 32;
const STATUS_HEADER: [u8; 4] = [0x80, 0x20, 0x42, 0x30];

/// Give a spec that declares the PT raster job its handler name. A spec
/// naming a handler of its own is left alone.
pub fn bind_handler(spec: &mut DeviceSpec) {
    if spec.protocol_handler.is_some() || !super::raster_print::is_raster_printer(spec) {
        return;
    }
    let declares_job = JOB_COMMANDS.iter().all(|name| {
        spec.commands
            .get(*name)
            .is_some_and(|c| c.transport.as_deref() == Some(TRANSPORT))
    });
    if declares_job {
        spec.protocol_handler = Some(HANDLER_NAME.to_string());
    }
}

/// A parameter's declared default in one of the spec's top-level commands.
fn param_default(spec: &DeviceSpec, command: &str, param: &str) -> Option<i64> {
    spec.commands
        .get(command)?
        .parameters
        .get(param)?
        .default
        .as_ref()?
        .as_i64()
}

fn byte_default(spec: &DeviceSpec, command: &str, param: &str, fallback: i64) -> u8 {
    param_default(spec, command, param)
        .and_then(|v| u8::try_from(v).ok())
        .unwrap_or(fallback as u8)
}

/// The tape a print goes on, resolved against the variant's media table.
pub struct Tape<'a> {
    pub feature: &'a Feature,
    pub media: &'a PrintMedia,
    /// Dots of the line the tape takes.
    pub print_dots: usize,
    /// Where those dots start in the line.
    pub offset_dots: usize,
    /// Bytes in one uncompressed line.
    pub line_bytes: usize,
}

/// The variant's media entry for a tape `width_mm` wide, as the status
/// reports it (a 3.5 mm tape reports 4).
pub fn tape<'a>(
    spec: &'a DeviceSpec,
    variant: Option<&str>,
    width_mm: u8,
) -> Result<Tape<'a>, ProtocolError> {
    let unsupported = |reason: String| ProtocolError::ImageUploadUnsupported { reason };
    let feature = raster_feature_for(spec, variant)
        .ok_or_else(|| unsupported("the spec declares no raster print surface".into()))?;
    let geometry = feature.print_geometry.clone().unwrap_or_default();
    let head = geometry
        .head_dots
        .ok_or_else(|| unsupported("the print surface states no head_dots".into()))?
        as usize;
    let line_bytes = geometry
        .bytes_per_row
        .map(|b| b as usize)
        .unwrap_or(head.div_ceil(8));
    let media = feature
        .media
        .iter()
        .find(|m| m.width_mm.round() as i64 == i64::from(width_mm))
        .ok_or_else(|| {
            unsupported(format!(
                "{} lists no {width_mm} mm tape",
                variant.unwrap_or("this printer")
            ))
        })?;
    let print_dots = media.print_width_dots.ok_or_else(|| {
        unsupported(format!(
            "the spec does not say how many dots of {} print on {}",
            media.name,
            variant.unwrap_or("this printer")
        ))
    })? as usize;
    if print_dots > head || line_bytes * 8 < head {
        return Err(unsupported(format!(
            "{} is {print_dots} dots on a {head}-dot head of {line_bytes}-byte lines",
            media.name
        )));
    }
    let offset_dots = media
        .right_margin_dots
        .map(|m| m as usize)
        .unwrap_or((head - print_dots) / 2);
    if offset_dots + print_dots > head {
        return Err(unsupported(format!(
            "{} overruns the head ({offset_dots} + {print_dots} > {head})",
            media.name
        )));
    }
    Ok(Tape {
        feature,
        media,
        print_dots,
        offset_dots,
        line_bytes,
    })
}

/// Invalidate, initialize and a status request: what to write before reading
/// the 32-byte status that says which tape is loaded.
pub fn status_request(spec: &DeviceSpec, variant: Option<&str>) -> Vec<u8> {
    let mut out = vec![0u8; invalidate_bytes(spec, variant)];
    out.extend_from_slice(&INITIALIZE);
    out.extend_from_slice(&REQUEST_STATUS);
    out
}

fn invalidate_bytes(spec: &DeviceSpec, variant: Option<&str>) -> usize {
    raster_feature_for(spec, variant)
        .and_then(|f| f.print_geometry.as_ref())
        .and_then(|g| g.invalidate_bytes)
        .map(|n| n as usize)
        .unwrap_or(FALLBACK_INVALIDATE)
}

/// Encode one black-and-white RGB888 canvas as a whole single-page job.
pub fn encode_print_job(
    spec: &DeviceSpec,
    variant: Option<&str>,
    tape_width_mm: u8,
    rgb: &[u8],
    width: u32,
    height: u32,
) -> Result<Vec<u8>, ProtocolError> {
    let invalid = |reason: String| ProtocolError::ImageDimensionsInvalid { reason };
    let tape = tape(spec, variant, tape_width_mm)?;
    let (w, h) = (width as usize, height as usize);
    if w == 0 || h == 0 || rgb.len() != w * h * 3 {
        return Err(invalid(format!(
            "expected {} bytes of RGB888 for {width}x{height}, got {}",
            w * h * 3,
            rgb.len()
        )));
    }
    if w > tape.print_dots {
        return Err(invalid(format!(
            "{width} dots across is wider than the {} printable on {}",
            tape.print_dots, tape.media.name
        )));
    }
    let geometry = tape.feature.print_geometry.clone().unwrap_or_default();
    if let Some(max) = geometry.max_length_dots {
        if height > max {
            return Err(invalid(format!(
                "{height} lines is longer than the {max} this printer takes"
            )));
        }
    }
    // A label shorter than the printer's minimum is padded with blank lines.
    let lines = h.max(geometry.min_length_dots.unwrap_or(0) as usize);

    let mut out = vec![0u8; invalidate_bytes(spec, variant)];
    out.extend_from_slice(&INITIALIZE);
    out.extend_from_slice(&RASTER_MODE);
    out.extend_from_slice(&AUTO_STATUS);
    out.push(AUTO_STATUS_NOTIFY);

    out.extend_from_slice(&PRINT_INFORMATION);
    out.push(byte_default(
        spec,
        "print_information",
        "valid_flags",
        FALLBACK_VALID_FLAGS,
    ));
    out.push(tape.media.media_type_code.unwrap_or(1) as u8);
    out.push(tape_width_mm);
    out.push(0x00); // media length: TZe tape is continuous
    out.extend_from_slice(&(lines as u32).to_le_bytes());
    out.push(0x00); // first page
    out.push(0x00);

    out.extend_from_slice(&VARIOUS_MODE);
    out.push(byte_default(
        spec,
        "set_various_mode",
        "flags",
        FALLBACK_VARIOUS_MODE,
    ));
    out.extend_from_slice(&ADVANCED_MODE);
    out.push(byte_default(
        spec,
        "set_advanced_mode",
        "flags",
        FALLBACK_ADVANCED_MODE,
    ));
    let margin = geometry
        .feed_margin_dots
        .map(i64::from)
        .or_else(|| param_default(spec, "set_margin", "margin"))
        .unwrap_or(FALLBACK_MARGIN);
    out.extend_from_slice(&MARGIN);
    out.extend_from_slice(&(margin.clamp(0, u16::MAX.into()) as u16).to_le_bytes());
    out.extend_from_slice(&COMPRESSION_PACKBITS);

    let dark: Vec<bool> = brightness_mask(rgb).into_iter().map(|b| !b).collect();
    let start = tape.offset_dots + (tape.print_dots - w) / 2;
    for y in 0..lines {
        let mut line = vec![0u8; tape.line_bytes];
        if y < h {
            for x in 0..w {
                if dark[y * w + x] {
                    let dot = start + x;
                    line[dot / 8] |= 0x80 >> (dot % 8);
                }
            }
        }
        push_line(&mut out, &line);
    }
    out.push(PRINT_AND_FEED);
    Ok(out)
}

/// One raster line: `Z` when blank, else `G <len u16 LE> <PackBits>`.
fn push_line(out: &mut Vec<u8>, line: &[u8]) {
    if line.iter().all(|b| *b == 0) {
        out.push(ZERO_RASTER_LINE);
        return;
    }
    let packed = packbits(line);
    out.push(RASTER_LINE);
    out.extend_from_slice(&(packed.len() as u16).to_le_bytes());
    out.extend_from_slice(&packed);
}

/// PackBits (TIFF compression 32773). A run of two or more equal bytes is
/// `(1 - n) b`; anything else is `(n - 1)` followed by n literal bytes. When
/// that comes out longer than the line, the line goes as one literal run, as
/// Brother's reference asks.
pub fn packbits(line: &[u8]) -> Vec<u8> {
    let out = packbits_runs(line);
    if out.len() > line.len() && line.len() <= 128 {
        let mut literal = vec![(line.len() - 1) as u8];
        literal.extend_from_slice(line);
        return literal;
    }
    out
}

fn packbits_runs(line: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(line.len() + 1);
    let mut i = 0;
    while i < line.len() {
        let mut run = 1;
        while i + run < line.len() && line[i + run] == line[i] && run < 128 {
            run += 1;
        }
        if run >= 2 {
            out.push((1i16 - run as i16) as u8);
            out.push(line[i]);
            i += run;
            continue;
        }
        let begin = i;
        while i < line.len() && i - begin < 128 {
            if i + 1 < line.len() && line[i + 1] == line[i] {
                break;
            }
            i += 1;
        }
        out.push((i - begin - 1) as u8);
        out.extend_from_slice(&line[begin..i]);
    }
    out
}

/// A decoded 32-byte status record.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PtStatus {
    /// Loaded tape in whole millimetres (3.5 mm reports 4); 0 = no cassette.
    pub media_width_mm: u8,
    /// Byte 11: 01 laminated, 03 non-laminated, 00 none, FF incompatible...
    pub media_type: u8,
    /// Byte 18: 00 reply, 01 completed, 02 error, 04 off, 05 notification,
    /// 06 phase change.
    pub status_type: u8,
    /// Byte 19: 00 editing (can receive), 01 printing.
    pub phase_type: u8,
    /// The named error bits that are set, in words.
    pub errors: Vec<String>,
}

pub const STATUS_COMPLETED: u8 = 0x01;
pub const STATUS_ERROR: u8 = 0x02;
pub const STATUS_TURNED_OFF: u8 = 0x04;

impl PtStatus {
    /// What `request_status` asks for before a job: no error bits, editing.
    pub fn ready_to_print(&self) -> bool {
        self.errors.is_empty() && self.phase_type == 0 && self.media_width_mm > 0
    }

    /// Whether this frame ends a job: completed, error, or turned off.
    pub fn ends_job(&self) -> bool {
        matches!(
            self.status_type,
            STATUS_COMPLETED | STATUS_ERROR | STATUS_TURNED_OFF
        )
    }
}

const ERROR_BITS_1: [(u8, &str); 4] = [
    (0x01, "no tape cassette"),
    (0x04, "cutter jam"),
    (0x08, "weak batteries"),
    (0x40, "wrong adapter (over-voltage)"),
];
const ERROR_BITS_2: [(u8, &str); 6] = [
    (0x01, "wrong tape for this label"),
    (0x04, "communication error"),
    (0x08, "communication buffer full"),
    (0x10, "cover open"),
    (0x20, "overheating"),
    (0x80, "system error"),
];

/// Decode one 32-byte status frame.
pub fn decode_status(bytes: &[u8]) -> Result<PtStatus, ProtocolError> {
    if bytes.len() < STATUS_LEN {
        return Err(ProtocolError::BufferTooShort {
            needed: STATUS_LEN,
            got: bytes.len(),
        });
    }
    if bytes[..4] != STATUS_HEADER {
        return Err(ProtocolError::ImageUploadUnsupported {
            reason: "not a P-touch status record (80 20 42 30)".to_string(),
        });
    }
    let mut errors = Vec::new();
    for (bit, name) in ERROR_BITS_1 {
        if bytes[8] & bit != 0 {
            errors.push(name.to_string());
        }
    }
    for (bit, name) in ERROR_BITS_2 {
        if bytes[9] & bit != 0 {
            errors.push(name.to_string());
        }
    }
    let unnamed = (bytes[8] & !ERROR_BITS_1.iter().fold(0, |a, (b, _)| a | b))
        | (bytes[9] & !ERROR_BITS_2.iter().fold(0, |a, (b, _)| a | b));
    if unnamed != 0 {
        errors.push(format!("printer error {:02X} {:02X}", bytes[8], bytes[9]));
    }
    Ok(PtStatus {
        media_width_mm: bytes[10],
        media_type: bytes[11],
        status_type: bytes[18],
        phase_type: bytes[19],
        errors,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn vendored() -> DeviceSpec {
        let path = format!(
            "{}/../vendor/protocol-specs/device-specs/devices/brother-ptouch-cube.yaml",
            env!("CARGO_MANIFEST_DIR")
        );
        parse_device_spec(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn hex(s: &str) -> Vec<u8> {
        s.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect()
    }

    #[test]
    fn packbits_matches_the_spec_vectors() {
        // protocol_details.test_vectors.packbits_lines
        for (raw, packed) in [
            (
                "00 00 00 00 00 00 FF FF FF FF 00 00 00 00 00 00",
                "FB 00 FD FF FB 00",
            ),
            (
                "00 00 00 00 00 18 3C 7E FF FF FF 00 00 00 00 00",
                "FC 00 02 18 3C 7E FE FF FC 00",
            ),
            ("FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF FF", "F1 FF"),
        ] {
            assert_eq!(packbits(&hex(raw)), hex(packed), "{raw}");
        }
    }

    #[test]
    fn a_line_packbits_would_grow_goes_literal() {
        // Pairs between singles: each pair and each single costs two bytes
        // packed, 21 in all against 16 raw.
        let line = [0u8, 0, 1, 2, 2, 3, 4, 4, 5, 6, 6, 7, 8, 8, 9, 10];
        assert!(packbits_runs(&line).len() > line.len());
        let packed = packbits(&line);
        assert_eq!(packed.len(), 17);
        assert_eq!(packed[0], 0x0F);
        assert_eq!(&packed[1..], &line[..]);
    }

    #[test]
    fn the_vendored_spec_binds_to_this_handler() {
        assert_eq!(vendored().protocol_handler.as_deref(), Some(HANDLER_NAME));
    }

    #[test]
    fn each_variant_takes_its_own_head() {
        let spec = vendored();
        let p710 = tape(&spec, Some("PT-P710BT"), 24).unwrap();
        assert_eq!((p710.print_dots, p710.offset_dots), (128, 0));
        assert_eq!(p710.line_bytes, 16);
        let p910 = tape(&spec, Some("PT-P910BT"), 36).unwrap();
        assert_eq!((p910.print_dots, p910.offset_dots), (454, 61));
        assert_eq!(p910.line_bytes, 70);
        let p300 = tape(&spec, Some("PT-P300BT"), 12).unwrap();
        assert_eq!((p300.print_dots, p300.offset_dots), (64, 32));
        // The P300BT has no 24 mm tape, and no stated dots for 6 mm.
        assert!(tape(&spec, Some("PT-P300BT"), 24).is_err());
        assert!(tape(&spec, Some("PT-P300BT"), 6).is_err());
        // The 3.5 mm tape reports 4.
        assert_eq!(tape(&spec, Some("PT-P710BT"), 4).unwrap().print_dots, 24);
    }

    #[test]
    fn the_two_line_24mm_job_is_the_spec_vector_with_its_own_margin() {
        // protocol_details.test_vectors.job_24mm_two_lines: dots 48-79 on,
        // then a blank line. The spec's vector is for a P710BT-class head
        // and carries a 2-line page; the P710BT declares min_length_dots 31,
        // so this job pads to 31 lines, and that is the only difference.
        let spec = vendored();
        let mut rgb = vec![255u8; 128 * 2 * 3];
        for x in 48..80 {
            rgb[x * 3..x * 3 + 3].fill(0);
        }
        let job = encode_print_job(&spec, Some("PT-P710BT"), 24, &rgb, 128, 2).unwrap();
        let mut expected = vec![0u8; 100];
        expected.extend(hex(
            "1B 40 1B 69 61 01 1B 69 21 00 1B 69 7A 84 01 18 00 1F 00 00 00 00 00 \
             1B 69 4D 40 1B 69 4B 08 1B 69 64 0E 00 4D 02 47 06 00 FB 00 FD FF FB 00",
        ));
        expected.extend(std::iter::repeat_n(0x5A, 30));
        expected.push(0x1A);
        assert_eq!(job, expected);
    }

    #[test]
    fn the_spec_print_information_frames() {
        // test_vectors.frames: 12 mm, 300 lines.
        let spec = vendored();
        let rgb = vec![255u8; 70 * 300 * 3];
        let job = encode_print_job(&spec, Some("PT-P710BT"), 12, &rgb, 70, 300).unwrap();
        let at = 100 + 2 + 4 + 4;
        assert_eq!(
            &job[at..at + 13],
            &hex("1B 69 7A 84 01 0C 00 2C 01 00 00 00 00")[..]
        );
        assert_eq!(
            &job[at + 13 + 8..at + 13 + 8 + 5],
            &hex("1B 69 64 0E 00")[..]
        );
    }

    #[test]
    fn a_narrow_canvas_is_centred_in_the_tape() {
        let spec = vendored();
        // 12 mm on the P710BT: 70 dots from dot 29. A 2-dot black canvas
        // lands at dots 29 + 34 = 63 and 64.
        let job = encode_print_job(&spec, Some("PT-P710BT"), 12, &[0; 6], 2, 1).unwrap();
        let line_at = job.iter().rposition(|b| *b == 0x47).unwrap();
        let len = u16::from_le_bytes([job[line_at + 1], job[line_at + 2]]) as usize;
        let packed = &job[line_at + 3..line_at + 3 + len];
        let mut expected = vec![0u8; 16];
        expected[7] = 0x01;
        expected[8] = 0x80;
        assert_eq!(packed, packbits(&expected));
    }

    #[test]
    fn the_p910bt_sends_its_own_invalidate_and_line_width() {
        let spec = vendored();
        let job = encode_print_job(&spec, Some("PT-P910BT"), 36, &[0; 3], 1, 1).unwrap();
        assert!(job[..200].iter().all(|b| *b == 0));
        assert_eq!(&job[200..202], &INITIALIZE);
        assert_eq!(status_request(&spec, Some("PT-P910BT")).len(), 205);
        assert_eq!(status_request(&spec, Some("PT-P710BT")).len(), 105);
    }

    #[test]
    fn a_canvas_wider_than_the_tape_is_refused() {
        let spec = vendored();
        assert!(encode_print_job(&spec, Some("PT-P710BT"), 12, &[0; 71 * 3], 71, 1).is_err());
    }

    #[test]
    fn status_replies_decode_as_the_spec_reads_them() {
        let reply = decode_status(&hex(
            "80 20 42 30 72 30 00 00 00 00 0C 01 00 00 00 00 00 00 00 00 00 00 00 00 01 08 00 00 00 00 00 00",
        ))
        .unwrap();
        assert_eq!((reply.media_width_mm, reply.media_type), (12, 1));
        assert!(reply.ready_to_print());
        assert!(!reply.ends_job());
        let printing = decode_status(&hex(
            "80 20 42 30 72 30 00 00 00 00 0C 01 00 00 00 00 00 00 06 01 00 00 00 00 01 08 00 00 00 00 00 00",
        ))
        .unwrap();
        assert!(!printing.ends_job());
        let done = decode_status(&hex(
            "80 20 42 30 72 30 00 00 00 00 0C 01 00 00 00 00 00 00 01 00 00 00 00 00 01 08 00 00 00 00 00 00",
        ))
        .unwrap();
        assert!(done.ends_job() && done.status_type == STATUS_COMPLETED);
        let open = decode_status(&hex(
            "80 20 42 30 72 30 00 00 00 10 0C 01 00 00 00 00 00 00 02 00 00 00 00 00 01 08 00 00 00 00 00 00",
        ))
        .unwrap();
        assert_eq!(open.errors, ["cover open"]);
        assert_eq!(open.status_type, STATUS_ERROR);
        assert!(decode_status(&[0x80; 31]).is_err());
    }
}

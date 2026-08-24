// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Print-job encoder for the Fichero / AiYin D11(s) thermal label printer —
//! `protocol_handler: "fichero_d11"`
//! (`vendor/protocol-specs/device-specs/devices/fichero-d11-printer.yaml`).
//!
//! THE WIRE FORMAT (spec `device.notes` plus the vendored research note
//! `vendor/protocol-specs/device-specs/research-notes/fichero-d11-printer.md`,
//! CONFIDENCE HIGH upstream — verified against D11s hardware on firmware
//! 2.4.6 by 0xMH/fichero-printer and re-checked against the current vendor
//! app): a BLE UART channel carrying two interleaved command families.
//!
//! Configuration and session control are AiYin `10 FF` opcodes, sent as bare
//! byte strings with no length, sequence or checksum:
//!
//! ```text
//!   10 FF 10 00 nn   set density   (0=light, 1=medium, 2=thick)
//!   10 FF 84 nn      set paper type (0=gap, 1=black mark, 2=continuous)
//!   10 FF FE 01      enable printer   ] AiYin device class; the Lujiang
//!   10 FF FE 45      stop printing    ] class uses 10 FF F1 03 / 10 FF F1 45
//! ```
//!
//! Raster data is plain ESC/POS `GS v 0`, which the spec names as such:
//!
//! ```text
//!   1D 76 30 <mode> <xL> <xH> <yL> <yH> <bitmap…>
//!            mode 0 = normal (1/2/3 double width/height/both)
//!            x = bytes per row, uint16 LE — 0C 00 on the 96-dot D11 head
//!            y = row count,     uint16 LE
//! ```
//!
//! Bitmap rows are MSB-first, 12 bytes each, and a bit means a heated dot —
//! `GS v 0`'s own definition, the same polarity as the sibling
//! [`super::cat_printer`]. So a pixel BELOW 50% luma prints: dark content on
//! paper, the printer's physics rather than a choice. A canvas narrower than
//! the head is padded on the right with blank paper.
//!
//! THE PRINT SEQUENCE, exactly the research note's seven steps:
//!
//! ```text
//!   1. set density        5. raster header + pixel data
//!   2. set paper type     6. form feed   (1D 0C)
//!   3. wake up (12 nulls) 7. stop print  (10 FF FE 45)
//!   4. enable printer
//! ```
//!
//! Getting step 4/7 wrong is the documented failure mode for this family:
//! send the Lujiang pair to an AiYin printer and it accepts the data and
//! silently never prints.
//!
//! The write characteristic is a byte stream, so the concatenated commands
//! are cut at the write budget without regard to command boundaries — as the
//! documented clients do (0xMH sends 200-byte chunks; the vendor app writes
//! `onePackSize` packets paced by 0xFF03 credits). Flow control, the 20 ms
//! inter-chunk delay and waiting for the stop-print acknowledgement are the
//! transport's business.
//!
//! SPEC-GAP: like the cat printer, this spec carries its whole command set in
//! PROSE — not one of its four UART services declares a `commands:` block —
//! so every opcode below is transcribed from `device.notes` and the research
//! note rather than resolved from a command template. They should become
//! named commands on the write characteristic (`set_density`,
//! `set_paper_type`, `wake_up`, `enable_printer`, `form_feed`, `stop_print`),
//! which is also how a Lujiang-class sibling would become a spec edit instead
//! of a code change.

use super::image_upload::{
    brightness_mask, declared_max_chunk_size, is_writable, printhead_row_bytes,
    validate_rgb_canvas, MIN_PAYLOAD_PER_WRITE,
};
use super::{EncodedFrame, EncodedWrite};
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, DeviceSpec};

/// `protocol_handler` name this module implements (see the device spec's
/// `protocol_handler` key).
pub const HANDLER_NAME: &str = "fichero_d11";

/// AiYin command prefix — every config/session opcode starts `10 FF`.
const AIYIN: [u8; 2] = [0x10, 0xFF];

/// `10 FF 10 00 nn` — print density.
const OP_SET_DENSITY: [u8; 2] = [0x10, 0x00];
/// `10 FF 84 nn` — label paper type.
const OP_SET_PAPER_TYPE: u8 = 0x84;
/// `10 FF FE 01` / `10 FF FE 45` — the AiYin device class's enable and stop.
const OP_SESSION: u8 = 0xFE;
const SESSION_ENABLE: u8 = 0x01;
const SESSION_STOP: u8 = 0x45;

/// Step 3: "Wake up: 12 null bytes".
const WAKE_UP: [u8; 12] = [0u8; 12];

/// ESC/POS `GS v 0` raster bit-image header.
const GS_V_0: [u8; 3] = [0x1D, 0x76, 0x30];
/// `GS v 0` mode byte: 0 = normal (1 = double width, 2 = double height,
/// 3 = both).
const RASTER_MODE_NORMAL: u8 = 0x00;

/// Step 6: "Form feed: `1D 0C`".
const FORM_FEED: [u8; 2] = [0x1D, 0x0C];

/// Density argument. The research note enumerates the values
/// (0=light, 1=medium, 2=thick) but the print sequence leaves the step's
/// argument as `nn`, so the middle of the three is what a job with no user
/// preference should carry.
// SPEC-GAP: the density vocabulary and the default a plain print job uses
// should become a declared field on the image_upload feature (e.g.
// `print_density`), so the app can offer the setting from data.
const DENSITY_MEDIUM: u8 = 0x01;

/// Paper-type argument. Unlike density this one IS pinned: the research
/// note's print sequence writes step 2 out in full as `10 FF 84 00`, and its
/// config table reads 0 = gap — die-cut gap labels, what the D11 ships with.
// SPEC-GAP: the paper-type vocabulary should likewise be a declared field, so
// black-mark and continuous stock become a control rather than a rebuild.
const PAPER_TYPE_GAP: u8 = 0x00;

/// Encode one RGB888 canvas as a complete print job on the write
/// characteristic. Every frame is a whole job — the printer keeps no image
/// state between jobs — so `frame_index` changes nothing.
pub fn encode_print_job(
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
    let tx = resolve_write_characteristic(spec)?;
    // 96 dots on the D11 head; the spec's `image_upload.max_width` states it.
    let row_bytes = printhead_row_bytes(spec)?;
    // `GS v 0` counts its rows in a u16, so a taller canvas cannot be asked
    // for in one command however tall the spec says the paper may run.
    if height > u16::MAX as u32 {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "{height} rows overflow the uint16 row count of one GS v 0 raster command"
            ),
        });
    }

    let mut stream = Vec::new();
    let mut packets: u32 = 0;
    let mut emit = |bytes: &[u8]| {
        stream.extend_from_slice(bytes);
        packets += 1;
    };

    // 1-2: density and paper stock.
    emit(&[
        AIYIN[0],
        AIYIN[1],
        OP_SET_DENSITY[0],
        OP_SET_DENSITY[1],
        DENSITY_MEDIUM,
    ]);
    emit(&[AIYIN[0], AIYIN[1], OP_SET_PAPER_TYPE, PAPER_TYPE_GAP]);
    // 3-4: wake the head, then enable printing (AiYin class).
    emit(&WAKE_UP);
    emit(&[AIYIN[0], AIYIN[1], OP_SESSION, SESSION_ENABLE]);

    // 5: one GS v 0 command carrying the whole raster. Dark pixel = heated
    // dot = bit 1, MSB-first, padded to the printhead width with blank paper.
    let mut raster = Vec::with_capacity(GS_V_0.len() + 5 + row_bytes * height as usize);
    raster.extend_from_slice(&GS_V_0);
    raster.push(RASTER_MODE_NORMAL);
    raster.extend_from_slice(&(row_bytes as u16).to_le_bytes());
    raster.extend_from_slice(&(height as u16).to_le_bytes());
    let bright = brightness_mask(rgb);
    let w = width as usize;
    let mut row = vec![0u8; row_bytes];
    for y in 0..height as usize {
        row.iter_mut().for_each(|b| *b = 0);
        for x in 0..w {
            if !bright[y * w + x] {
                row[x / 8] |= 0x80 >> (x % 8);
            }
        }
        raster.extend_from_slice(&row);
    }
    emit(&raster);

    // 6-7: eject the label, then close the print session.
    emit(&FORM_FEED);
    emit(&[AIYIN[0], AIYIN[1], OP_SESSION, SESSION_STOP]);

    // The channel's own declared ceiling where it makes one, the caller's
    // write budget otherwise — and never more than one write carries.
    let chunk = declared_max_chunk_size(tx)
        .unwrap_or(max_payload_per_write)
        .min(max_payload_per_write);
    let writes = stream
        .chunks(chunk)
        .map(|part| EncodedWrite {
            characteristic_uuid: tx.uuid.clone(),
            bytes: part.to_vec(),
        })
        .collect();
    Ok(EncodedFrame { writes, packets })
}

/// The write channel: the single writable characteristic of the service the
/// spec identifies the printer by (`identification.service_uuids`, 0x18F0 —
/// the one third-party clients drive and the spec recommends for cross-model
/// compatibility). The other three UART services are functionally
/// interchangeable but the spec does not identify the device by them, so they
/// are never candidates and the choice cannot silently move.
fn resolve_write_characteristic(spec: &DeviceSpec) -> Result<&Characteristic, ProtocolError> {
    let identifying: Vec<&str> = spec
        .device
        .identification
        .as_ref()
        .and_then(|i| i.service_uuids.as_ref())
        .map(|v| v.iter().map(String::as_str).collect())
        .unwrap_or_default();
    let candidates: Vec<&Characteristic> = spec
        .services
        .iter()
        .filter(|s| identifying.iter().any(|u| u.eq_ignore_ascii_case(&s.uuid)))
        .flat_map(|s| &s.characteristics)
        .filter(|c| is_writable(c))
        .collect();
    match candidates.as_slice() {
        [tx] => Ok(tx),
        [] => Err(ProtocolError::ImageUploadUnsupported {
            reason: "spec has no writable characteristic in the service it identifies the \
                     printer by"
                .to_string(),
        }),
        many => Err(ProtocolError::ImageUploadUnsupported {
            reason: format!(
                "spec identifies the printer by a service with {} writable characteristics; \
                 the write channel is ambiguous",
                many.len()
            ),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A minimal spec shaped like the vendored `fichero-d11-printer.yaml`:
    /// the identifying 0x18F0 service with its write (0x2AF1) and notify
    /// (0x2AF0) pair, one of the three interchangeable alternates as the
    /// decoy, and the 96-dot feature bounds — nested under `device:` exactly
    /// as the vendored file has them.
    const SPEC_YAML: &str = r#"
device:
  name: "Fichero / AiYin D11 Thermal Label Printer"
  manufacturer: "Xiamen Print Future Technology Co., Ltd"
  manufacturer_status: "unsupported"
  protocol: "ble"
  category: "printer"
  identification:
    local_name_prefix: "FICHERO"
    service_uuids:
      - "000018f0-0000-1000-8000-00805f9b34fb"
  features:
    - type: "image_upload"
      max_width: 96
      max_height: 65535
      format: "1bit-bitmap"
  protocol_handler: "fichero_d11"
services:
  - uuid: "000018f0-0000-1000-8000-00805f9b34fb"
    name: "Fichero UART Service (Third-Party Primary)"
    characteristics:
      - uuid: "00002af1-0000-1000-8000-00805f9b34fb"
        name: "Write"
        properties: ["write", "write_without_response"]
      - uuid: "00002af0-0000-1000-8000-00805f9b34fb"
        name: "Notify"
        properties: ["notify"]
  - uuid: "0000ff00-0000-1000-8000-00805f9b34fb"
    name: "Fichero UART Service (Vendor Primary)"
    characteristics:
      - uuid: "0000ff02-0000-1000-8000-00805f9b34fb"
        name: "Write"
        properties: ["write"]
      - uuid: "0000ff01-0000-1000-8000-00805f9b34fb"
        name: "Notify"
        properties: ["notify"]
"#;

    const TX: &str = "00002af1-0000-1000-8000-00805f9b34fb";

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC_YAML).unwrap()
    }

    fn stream_of(frame: &EncodedFrame) -> Vec<u8> {
        frame
            .writes
            .iter()
            .flat_map(|w| w.bytes.iter().copied())
            .collect()
    }

    /// An 8x2 canvas: row 0 alternates black and white starting black, row 1
    /// is white but for its last pixel. Black is a dot.
    fn stripes_8x2() -> Vec<u8> {
        let mut rgb = vec![0xFFu8; 8 * 2 * 3];
        for x in (0..8).step_by(2) {
            rgb[x * 3..x * 3 + 3].copy_from_slice(&[0, 0, 0]);
        }
        // Row 1, column 7: the last pixel of the canvas.
        let last = rgb.len() - 3;
        rgb[last..].copy_from_slice(&[0, 0, 0]);
        rgb
    }

    /// The whole job for the 8x2 stripes, byte for byte, derived from the
    /// research note's seven-step sequence:
    ///
    /// ```text
    ///   10 FF 10 00 01          density = medium
    ///   10 FF 84 00             paper type = gap
    ///   00 x12                  wake up
    ///   10 FF FE 01             enable (AiYin class)
    ///   1D 76 30 00 0C 00 02 00 GS v 0, normal, 12 bytes/row, 2 rows
    ///   AA 00 x11               row 0: dots at x=0,2,4,6 -> 0b10101010
    ///   01 00 x11               row 1: dot at x=7        -> 0b00000001
    ///   1D 0C                   form feed
    ///   10 FF FE 45             stop
    /// ```
    #[test]
    fn golden_8x2_job_is_the_documented_seven_step_sequence() {
        let frame = encode_print_job(&spec(), &stripes_8x2(), 8, 2, 0, 509).unwrap();
        assert_eq!(frame.packets, 7, "the seven documented steps");
        let mut want: Vec<u8> = vec![0x10, 0xFF, 0x10, 0x00, 0x01];
        want.extend_from_slice(&[0x10, 0xFF, 0x84, 0x00]);
        want.extend_from_slice(&[0u8; 12]);
        want.extend_from_slice(&[0x10, 0xFF, 0xFE, 0x01]);
        want.extend_from_slice(&[0x1D, 0x76, 0x30, 0x00, 0x0C, 0x00, 0x02, 0x00]);
        want.push(0xAA);
        want.extend_from_slice(&[0u8; 11]);
        want.push(0x01);
        want.extend_from_slice(&[0u8; 11]);
        want.extend_from_slice(&[0x1D, 0x0C]);
        want.extend_from_slice(&[0x10, 0xFF, 0xFE, 0x45]);
        assert_eq!(stream_of(&frame), want);
        assert!(frame.writes.iter().all(|w| w.characteristic_uuid == TX));
    }

    /// The row count is little-endian, which only a value above 255 can show.
    #[test]
    fn the_row_count_is_uint16_little_endian() {
        let frame = encode_print_job(&spec(), &vec![0xFFu8; 8 * 300 * 3], 8, 300, 0, 509).unwrap();
        let stream = stream_of(&frame);
        let at = stream
            .windows(3)
            .position(|w| w == GS_V_0)
            .expect("the raster header is in the stream");
        // 300 = 0x012C -> 2C 01.
        assert_eq!(&stream[at + 4..at + 8], &[0x0C, 0x00, 0x2C, 0x01]);
    }

    /// The printhead width is the spec's, not a constant: retype the feature
    /// and both the header's x field and every row grow with it.
    #[test]
    fn the_row_width_comes_from_the_declared_printhead_width() {
        let yaml = SPEC_YAML.replace("max_width: 96", "max_width: 384");
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_print_job(&s, &stripes_8x2(), 8, 2, 0, 509).unwrap();
        let stream = stream_of(&frame);
        let at = stream.windows(3).position(|w| w == GS_V_0).unwrap();
        assert_eq!(
            &stream[at + 4..at + 6],
            &[0x30, 0x00],
            "384 dots = 48 bytes per row"
        );
        // 48 bytes/row x 2 rows between the header and the form feed.
        assert_eq!(stream.len() - at - 8 - 6, 96);
    }

    /// Dark prints, bright does not — a 50% luma threshold, so pure green
    /// (0.587) stays paper-white while pure red (0.299) and blue (0.114)
    /// leave a dot.
    #[test]
    fn dark_pixels_print_and_bright_ones_do_not() {
        let rgb = vec![
            0, 255, 0, // green -> bright -> blank
            255, 0, 0, // red   -> dark   -> dot
            0, 0, 255, // blue  -> dark   -> dot
            255, 255, 255, // white -> blank
        ];
        let frame = encode_print_job(&spec(), &rgb, 4, 1, 0, 509).unwrap();
        let stream = stream_of(&frame);
        let at = stream.windows(3).position(|w| w == GS_V_0).unwrap();
        // Bits 1 and 2 MSB-first = 0b0110_0000.
        assert_eq!(stream[at + 8], 0x60);
    }

    /// A canvas narrower than the head is padded on the right with blank
    /// paper rather than shrinking the row.
    #[test]
    fn a_narrow_canvas_is_padded_to_the_printhead_width() {
        let frame = encode_print_job(&spec(), &[0u8; 8 * 3], 8, 1, 0, 509).unwrap();
        let stream = stream_of(&frame);
        let at = stream.windows(3).position(|w| w == GS_V_0).unwrap();
        assert_eq!(stream[at + 8], 0xFF, "all eight canvas dots print");
        assert_eq!(&stream[at + 9..at + 20], &[0u8; 11], "the rest is blank");
    }

    /// The byte stream is cut at the write budget, not at command
    /// boundaries — the characteristic is a UART, as the documented clients
    /// treat it.
    #[test]
    fn the_stream_is_cut_at_the_write_budget() {
        let frame = encode_print_job(&spec(), &stripes_8x2(), 8, 2, 0, 20).unwrap();
        assert!(frame.writes.iter().all(|w| w.bytes.len() <= 20));
        assert_eq!(frame.writes.len(), stream_of(&frame).len().div_ceil(20));
        assert_eq!(frame.packets, 7, "packets count steps, not writes");
    }

    /// A declared `framing.max_chunk_size` binds tighter than the budget.
    #[test]
    fn a_declared_chunk_size_binds_tighter_than_the_write_budget() {
        let yaml = SPEC_YAML.replace(
            r#"        properties: ["write", "write_without_response"]"#,
            "        properties: [\"write\", \"write_without_response\"]\n        framing:\n          max_chunk_size: 16",
        );
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_print_job(&s, &stripes_8x2(), 8, 2, 0, 509).unwrap();
        assert!(frame.writes.iter().all(|w| w.bytes.len() <= 16));
    }

    /// The vendor-primary 0xFF00 service also carries a write
    /// characteristic; the spec does not identify the printer by it, so it is
    /// never the target.
    #[test]
    fn the_non_identifying_uart_service_is_never_the_target() {
        let frame = encode_print_job(&spec(), &stripes_8x2(), 8, 2, 0, 509).unwrap();
        assert!(frame.writes.iter().all(|w| w.characteristic_uuid == TX));
    }

    #[test]
    fn a_spec_identifying_no_uart_service_errors_helpfully() {
        let yaml = SPEC_YAML.replace(
            r#"      - "000018f0-0000-1000-8000-00805f9b34fb""#,
            r#"      - "0000ffff-0000-1000-8000-00805f9b34fb""#,
        );
        let s = parse_device_spec(&yaml).unwrap();
        let err = encode_print_job(&s, &stripes_8x2(), 8, 2, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageUploadUnsupported { .. }));
    }

    #[test]
    fn a_canvas_wider_than_the_printhead_is_rejected() {
        let err = encode_print_job(&spec(), &vec![0u8; 97 * 3], 97, 1, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn wrong_buffer_length_is_rejected() {
        let err = encode_print_job(&spec(), &[0; 5], 8, 2, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }
}

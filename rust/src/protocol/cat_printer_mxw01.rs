// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Print-job encoder for the MXW01 mini thermal printer —
//! `protocol_handler: "cat_printer_mxw01"`
//! (`vendor/protocol-specs/device-specs/devices/cat-printer-mxw01.yaml`).
//!
//! It shares its UUIDs with the legacy family in `cat_printer.rs` and nothing
//! else. Commands go to 0xAE01 as whole frames,
//!
//! ```text
//!   22 21 <cmd> 00 <payload_len u16le> <payload…> <crc8(payload)> FF
//! ```
//!
//! and rows go to 0xAE03 as raw bytes: 48 per row, LSB = leftmost pixel,
//! 1 = black, with no bit reversal. A buffer under 90 rows does not print, so
//! a short image is padded with blank rows and the print request counts them.
//!
//! Every frame comes from the spec's own command table, including its
//! `auto: crc8`, so no frame layout or CRC is restated here. What is here is
//! the print sequence from the spec's notes:
//!
//! ```text
//!   set_intensity (default) ─ get_status until flag 0 ─ print_request ─ accepted?
//!   ─ rows ─ print_data_flush ─ print_complete ─ eject_paper (default)
//! ```
//!
//! Intensity and eject are the spec's optional steps. They are sent at the
//! defaults the spec gives them, since a job with no eject leaves the end of
//! the image inside the printer.
//!
//! The spec notes that paper emerges bottom-first and that a client may rotate
//! the image 180 degrees if it should exit right-side-up. Rows here go
//! top-to-bottom as the spec's image section says, so a torn strip reads
//! correctly once turned the right way up.
//!
//! The 4bpp grayscale mode is not implemented: the `image_upload` feature
//! declares 1-bit, and so does this. Nothing here has been run against
//! hardware; `testing.status` in the spec says the same of its own bytes.

use super::image_upload::{
    brightness_mask, declared_max_chunk_size, is_writable, printhead_row_bytes,
    validate_rgb_canvas, MIN_PAYLOAD_PER_WRITE,
};
use super::{CompletionPoll, EncodedFrame, EncodedWrite, ReplyField, ReplyWait};
use crate::codec::types::encode_command;
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, CharacteristicProperty, DeviceSpec};
use std::collections::HashMap;

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "cat_printer_mxw01";

const CMD_SET_INTENSITY: &str = "set_intensity";
const CMD_GET_STATUS: &str = "get_status";
const CMD_PRINT_REQUEST: &str = "print_request";
const CMD_FLUSH: &str = "print_data_flush";
const CMD_EJECT: &str = "eject_paper";

/// The bulk command, which anchors the bulk channel the way
/// [`CMD_PRINT_REQUEST`] anchors the command channel. Its bytes are the rows.
const CMD_WRITE_ROWS: &str = "write_image_rows";

/// The status field whose declaration anchors the notify channel, and whose
/// offset says where a status reply's verdict is. 0 is OK.
const FIELD_ERROR_FLAG: &str = "error_flag";

/// "Pad the buffer with 0x00 to at least 4320 bytes (90 rows); shorter buffers
/// do not print."
const MIN_ROWS: usize = 90;

/// Print mode 0: 1bpp mono.
const MODE_MONO: f64 = 0.0;

/// Every reply opens `22 21 <cmd>`, with the byte after it "not always 0x00",
/// so the prefix stops there.
const REPLY_HEAD: [u8; 2] = [0x22, 0x21];
const REPLY_STATUS: u8 = 0xA1;
const REPLY_PRINT_REQUEST: u8 = 0xA9;
const REPLY_PRINT_COMPLETE: u8 = 0xAA;

/// Where a reply's `payload[0]` sits, past the 6-byte header. A print request's
/// reply puts its verdict there: "payload[0] must be 0x00".
const REPLY_PAYLOAD_OFFSET: usize = 6;

/// "48-byte row chunks with ~15 ms gaps". The printer has no flow control.
const INTER_WRITE_DELAY_MS: u32 = 15;

/// How long a status or print-request reply may take. The spec states no
/// figure, and these are the replies of an idle printer.
const REPLY_TIMEOUT_MS: u32 = 5_000;
const STATUS_POLL_INTERVAL_MS: u32 = 500;

/// "Scale the timeout with line count (~15 lines/sec plus a base margin)."
const LINES_PER_SECOND: u32 = 15;
const COMPLETE_MARGIN_MS: u32 = 30_000;

/// Encode one RGB888 canvas as a complete print job. The printer keeps no image
/// state between jobs, so `frame_index` changes nothing.
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
    let unsupported = |reason: &str| ProtocolError::ImageUploadUnsupported {
        reason: reason.to_string(),
    };
    let writable_with = |command: &str| {
        spec.services
            .iter()
            .flat_map(|s| &s.characteristics)
            .filter(|c| is_writable(c))
            .find(|c| c.commands.as_ref().is_some_and(|m| m.contains_key(command)))
    };
    let control = writable_with(CMD_PRINT_REQUEST)
        .ok_or_else(|| unsupported("spec has no characteristic declaring print_request"))?;
    let bulk = writable_with(CMD_WRITE_ROWS)
        .ok_or_else(|| unsupported("spec has no characteristic declaring write_image_rows"))?;
    let (notify, flag_offset) = resolve_notify_channel(spec)
        .ok_or_else(|| unsupported("spec has no notify characteristic declaring error_flag"))?;

    let row_bytes = printhead_row_bytes(spec)?;
    let bitmap = encode_rows(rgb, width as usize, height as usize, row_bytes);
    let lines = bitmap.len() / row_bytes;
    let chunk = declared_max_chunk_size(bulk)
        .unwrap_or(row_bytes)
        .min(max_payload_per_write);

    let mut writes = Vec::with_capacity(bitmap.len() / chunk + 5);
    let command = |name: &str, params: &[(&str, f64)]| -> Result<EncodedWrite, ProtocolError> {
        Ok(EncodedWrite {
            characteristic_uuid: control.uuid.clone(),
            bytes: control_frame(control, name, params)?,
        })
    };

    writes.push(command(CMD_SET_INTENSITY, &[])?);
    let print_request = writes.len();
    writes.push(command(
        CMD_PRINT_REQUEST,
        &[("lines", lines as f64), ("mode", MODE_MONO)],
    )?);
    for part in bitmap.chunks(chunk) {
        writes.push(EncodedWrite {
            characteristic_uuid: bulk.uuid.clone(),
            bytes: part.to_vec(),
        });
    }
    let flush = writes.len();
    writes.push(command(CMD_FLUSH, &[])?);
    writes.push(command(CMD_EJECT, &[])?);

    let reply = |cmd: u8| vec![REPLY_HEAD[0], REPLY_HEAD[1], cmd];
    Ok(EncodedFrame {
        packets: writes.len() as u32,
        inter_write_delay_ms: INTER_WRITE_DELAY_MS,
        // Step 3: "abort unless the overall flag is 0". A printer reporting an
        // error is asked again until the deadline, so feeding paper in time
        // saves the job, and a deadline passed means nothing was printed.
        completion_poll: Some(CompletionPoll {
            before_write: print_request,
            request: command(CMD_GET_STATUS, &[])?,
            characteristic_uuid: notify.uuid.clone(),
            reply_prefix: reply(REPLY_STATUS),
            done_offset: flag_offset,
            done_bytes: vec![0x00],
            interval_ms: STATUS_POLL_INTERVAL_MS,
            timeout_ms: REPLY_TIMEOUT_MS,
        }),
        reply_waits: vec![
            ReplyWait {
                after_write: print_request,
                characteristic_uuid: notify.uuid.clone(),
                expect_prefix: reply(REPLY_PRINT_REQUEST),
                must_carry: Some(ReplyField {
                    offset: REPLY_PAYLOAD_OFFSET,
                    bytes: vec![0x00],
                }),
                error_prefixes: Vec::new(),
                timeout_ms: REPLY_TIMEOUT_MS,
            },
            ReplyWait {
                after_write: flush,
                characteristic_uuid: notify.uuid.clone(),
                expect_prefix: reply(REPLY_PRINT_COMPLETE),
                must_carry: None,
                error_prefixes: Vec::new(),
                timeout_ms: COMPLETE_MARGIN_MS
                    .saturating_add((lines as u32).saturating_mul(1000 / LINES_PER_SECOND)),
            },
        ],
        writes,
    })
}

/// The notify characteristic whose `format` declares the status flag, and that
/// field's offset into a status frame.
fn resolve_notify_channel(spec: &DeviceSpec) -> Option<(&Characteristic, usize)> {
    spec.services
        .iter()
        .flat_map(|s| &s.characteristics)
        .filter(|c| c.properties.contains(&CharacteristicProperty::Notify))
        .find_map(|c| {
            let field = c
                .format
                .as_ref()?
                .iter()
                .find(|f| f.name == FIELD_ERROR_FLAG)?;
            Some((c, field.offset))
        })
}

/// One frame from the spec's command table. A parameter left out takes the
/// default the spec declares for it, and the encoder fills the CRC.
fn control_frame(
    control: &Characteristic,
    name: &str,
    params: &[(&str, f64)],
) -> Result<Vec<u8>, ProtocolError> {
    let command = control
        .commands
        .as_ref()
        .and_then(|m| m.get(name))
        .ok_or_else(|| ProtocolError::CommandNotFound {
            uuid: control.uuid.clone(),
            command: name.to_string(),
        })?;
    let params: HashMap<String, f64> = params.iter().map(|(k, v)| (k.to_string(), *v)).collect();
    encode_command(command, &params)
}

/// The whole image buffer: a dark pixel is a dot is a set bit, the leftmost
/// pixel in the low bit, padded on the right to the paper's width and at the
/// bottom to [`MIN_ROWS`].
fn encode_rows(rgb: &[u8], width: usize, height: usize, row_bytes: usize) -> Vec<u8> {
    let bright = brightness_mask(rgb);
    let mut bitmap = vec![0u8; height.max(MIN_ROWS) * row_bytes];
    for y in 0..height {
        for x in 0..width {
            if !bright[y * width + x] {
                bitmap[y * row_bytes + x / 8] |= 1 << (x % 8);
            }
        }
    }
    bitmap
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    const CONTROL: &str = "0000ae01-0000-1000-8000-00805f9b34fb";
    const NOTIFY: &str = "0000ae02-0000-1000-8000-00805f9b34fb";
    const BULK: &str = "0000ae03-0000-1000-8000-00805f9b34fb";

    /// The real spec, since every frame here comes out of its command table.
    fn spec() -> DeviceSpec {
        let path = format!(
            "{}/../vendor/protocol-specs/device-specs/devices/cat-printer-mxw01.yaml",
            env!("CARGO_MANIFEST_DIR")
        );
        parse_device_spec(&std::fs::read_to_string(path).unwrap()).unwrap()
    }

    fn control(spec: &DeviceSpec) -> &Characteristic {
        spec.find_writable_characteristic(CONTROL).unwrap().1
    }

    /// An 8x2 canvas: row 0 all black, row 1 black on odd columns only.
    fn tiny() -> Vec<u8> {
        let mut rgb = vec![0u8; 8 * 2 * 3];
        for x in (0..8).step_by(2) {
            let i = (8 + x) * 3;
            rgb[i..i + 3].copy_from_slice(&[255, 255, 255]);
        }
        rgb
    }

    fn job() -> EncodedFrame {
        encode_print_job(&spec(), &tiny(), 8, 2, 0, 244).unwrap()
    }

    /// The fixed frames, byte for byte as the spec's device notes lay them out
    /// and its command table states them. CRC-8 of a zero payload is zero.
    #[test]
    fn the_fixed_frames_are_the_specs() {
        let spec = spec();
        let frame = |name| control_frame(control(&spec), name, &[]).unwrap();
        assert_eq!(
            frame(CMD_GET_STATUS),
            [0x22, 0x21, 0xA1, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFF]
        );
        assert_eq!(
            frame(CMD_FLUSH),
            [0x22, 0x21, 0xAD, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFF]
        );
    }

    /// The templated frames at the spec's defaults, with CRC-8 (poly 0x07,
    /// init 0, over the payload only) worked out separately: 0x94 over `5D`,
    /// and 0x8E over `5A 00`. The same CRC over the ASCII "123456789" gives the
    /// algorithm's published check value 0xF4, so those two are the right CRC.
    #[test]
    fn templated_frames_carry_the_crc_the_spec_defines() {
        let spec = spec();
        assert_eq!(
            control_frame(control(&spec), CMD_SET_INTENSITY, &[]).unwrap(),
            [0x22, 0x21, 0xA2, 0x00, 0x01, 0x00, 0x5D, 0x94, 0xFF]
        );
        assert_eq!(
            control_frame(control(&spec), CMD_EJECT, &[]).unwrap(),
            [0x22, 0x21, 0xA3, 0x00, 0x02, 0x00, 0x5A, 0x00, 0x8E, 0xFF]
        );
    }

    /// `[line count u16 LE, 0x30, mode]`, CRC-8 worked out separately.
    #[test]
    fn a_print_request_states_lines_little_endian_then_the_mode() {
        let spec = spec();
        assert_eq!(
            control_frame(
                control(&spec),
                CMD_PRINT_REQUEST,
                &[("lines", 200.0), ("mode", 0.0)]
            )
            .unwrap(),
            [0x22, 0x21, 0xA9, 0x00, 0x04, 0x00, 0xC8, 0x00, 0x30, 0x00, 0xE3, 0xFF]
        );
    }

    /// LSB = leftmost, 1 = black, no bit reversal: the opposite of the legacy
    /// family's bytes for the same pixels.
    #[test]
    fn rows_put_the_leftmost_pixel_in_the_low_bit() {
        let bitmap = encode_rows(&tiny(), 8, 2, 48);
        assert_eq!(bitmap[0], 0xFF);
        assert_eq!(bitmap[48], 0b1010_1010);

        // A single black pixel at x=0 and at x=9.
        let mut rgb = vec![255u8; 10 * 3];
        rgb[..3].fill(0);
        rgb[27..30].fill(0);
        let bitmap = encode_rows(&rgb, 10, 1, 48);
        assert_eq!(bitmap[0], 0x01);
        assert_eq!(bitmap[1], 0x02);
    }

    #[test]
    fn a_short_image_is_padded_to_ninety_blank_rows_and_a_tall_one_is_not() {
        let bitmap = encode_rows(&tiny(), 8, 2, 48);
        assert_eq!(bitmap.len(), 4320);
        assert!(bitmap[96..].iter().all(|b| *b == 0));

        let tall = vec![0u8; 8 * 100 * 3];
        assert_eq!(encode_rows(&tall, 8, 100, 48).len(), 4800);
    }

    /// The print sequence, in the spec's order, on the spec's channels.
    #[test]
    fn the_job_follows_the_print_sequence() {
        let frame = job();
        let channels: Vec<&str> = frame
            .writes
            .iter()
            .map(|w| w.characteristic_uuid.as_str())
            .collect();
        // Intensity, request, 90 rows of 48 bytes, flush, eject.
        assert_eq!(channels.len(), 94);
        assert_eq!(channels[0], CONTROL);
        assert_eq!(channels[1], CONTROL);
        assert!(channels[2..92].iter().all(|c| *c == BULK));
        assert_eq!(channels[92], CONTROL);
        assert_eq!(channels[93], CONTROL);

        assert_eq!(frame.writes[0].bytes[2], 0xA2);
        // The request counts the padded rows: 90, CRC worked out separately.
        assert_eq!(
            frame.writes[1].bytes,
            [0x22, 0x21, 0xA9, 0x00, 0x04, 0x00, 0x5A, 0x00, 0x30, 0x00, 0x99, 0xFF]
        );
        assert!(frame.writes[2..92].iter().all(|w| w.bytes.len() == 48));
        assert_eq!(frame.writes[2].bytes[0], 0xFF);
        assert_eq!(frame.writes[92].bytes[2], 0xAD);
        assert_eq!(frame.writes[93].bytes[2], 0xA3);
        assert_eq!(frame.inter_write_delay_ms, 15);
    }

    /// The status poll stands in front of the print request, and judges the
    /// spec's own `error_flag`: `payload[6]`, raw offset 12.
    #[test]
    fn nothing_is_requested_until_status_reports_no_error() {
        let frame = job();
        let poll = frame.completion_poll.as_ref().unwrap();
        assert_eq!(poll.before_write, 1);
        assert_eq!(poll.request.characteristic_uuid, CONTROL);
        assert_eq!(poll.request.bytes[2], 0xA1);
        assert_eq!(poll.characteristic_uuid, NOTIFY);
        assert_eq!(poll.reply_prefix, [0x22, 0x21, 0xA1]);
        assert_eq!(poll.done_offset, 12);
        assert_eq!(poll.done_bytes, [0x00]);
    }

    /// A request's reply decides at `payload[0]`, and the frame's end waits for
    /// the unsolicited print-complete before the eject.
    #[test]
    fn the_rows_wait_for_acceptance_and_the_eject_for_completion() {
        let frame = job();
        let [accepted, complete] = frame.reply_waits.as_slice() else {
            panic!("two waits: {:?}", frame.reply_waits);
        };
        assert_eq!(accepted.after_write, 1);
        assert_eq!(accepted.characteristic_uuid, NOTIFY);
        assert_eq!(accepted.expect_prefix, [0x22, 0x21, 0xA9]);
        let verdict = accepted.must_carry.as_ref().unwrap();
        assert_eq!((verdict.offset, verdict.bytes.as_slice()), (6, &[0u8][..]));

        assert_eq!(complete.after_write, 92);
        assert_eq!(complete.expect_prefix, [0x22, 0x21, 0xAA]);
        assert!(complete.must_carry.is_none());
    }

    /// "~15 lines/sec plus a base margin", on the padded count.
    #[test]
    fn the_completion_deadline_scales_with_the_lines() {
        let timeout = |height: u32| {
            let rgb = vec![0u8; 8 * height as usize * 3];
            encode_print_job(&spec(), &rgb, 8, height, 0, 244)
                .unwrap()
                .reply_waits[1]
                .timeout_ms
        };
        assert_eq!(timeout(2), timeout(90));
        assert_eq!(timeout(90), 30_000 + 90 * 66);
        assert!(timeout(900) > timeout(90));
    }

    /// A link too small for a whole row streams it in link-sized writes, as
    /// the spec's MTU-sized clients do, with every byte still in order.
    #[test]
    fn a_small_link_splits_rows_without_losing_bytes() {
        let frame = encode_print_job(&spec(), &tiny(), 8, 2, 0, 20).unwrap();
        let rows: Vec<u8> = frame
            .writes
            .iter()
            .filter(|w| w.characteristic_uuid == BULK)
            .flat_map(|w| w.bytes.iter().copied())
            .collect();
        assert_eq!(rows, encode_rows(&tiny(), 8, 2, 48));
        assert!(frame
            .writes
            .iter()
            .filter(|w| w.characteristic_uuid == BULK)
            .all(|w| w.bytes.len() <= 20));
    }

    #[test]
    fn an_impossible_job_is_refused() {
        assert!(encode_print_job(&spec(), &tiny(), 8, 2, 0, 19).is_err());
        assert!(encode_print_job(&spec(), &[0u8; 2], 8, 2, 0, 244).is_err());
        let too_wide = vec![0u8; 385 * 3];
        assert!(encode_print_job(&spec(), &too_wide, 385, 1, 0, 244).is_err());
    }

    /// A spec missing the commands that anchor the channels is refused rather
    /// than sent to a guessed characteristic.
    #[test]
    fn a_spec_without_the_anchoring_commands_is_refused() {
        let mut stripped = spec();
        for service in &mut stripped.services {
            for characteristic in &mut service.characteristics {
                characteristic.commands = None;
            }
        }
        assert!(encode_print_job(&stripped, &tiny(), 8, 2, 0, 244).is_err());
    }
}

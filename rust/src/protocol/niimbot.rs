// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! NIIMBOT D110 label printer: one label as a reply-gated BLE print task.
//!
//! Everything here is read from the spec — `niimbot-d110.yaml`'s commands
//! block and `protocol_details.niimbot_print_task` — which transcribes
//! MultiMote/niimbluelib (MIT). Not run on hardware by this project.
//!
//! ```text
//! packet:  55 55 <cmd> <len> <data...> <xor(cmd,len,data)> AA AA
//! task:    connect → set_density → set_label_type → print_start →
//!          print_clear → page_start → set_page_size → set_print_quantity →
//!          rows (0x84 / 0x83 / 0x85, no reply) → page_end →
//!          poll print_status until the page is done → print_end
//! ```
//!
//! Every control packet is answered (0xC1→0xC2, 0x21→0x31, …) and the next
//! one must wait for it; the plan carries those as reply waits and the
//! status poll as a completion poll, so the transport stays generic.
//!
//! ROWS: 1 bit per dot, MSB of byte 0 = head dot 0, 1 = black. Identical
//! consecutive rows go once with a repeat count. A blank row is 0x84
//! `[row u16][repeat]`; one with at most six black dots is 0x83
//! `[row u16][counts ×3][repeat][dot index u16 …]`; any other is 0x85
//! `[row u16][counts ×3][repeat][row bytes]`. The counts are black dots per
//! third of the head (split mode) — always the case on the 96-dot D110.

use std::collections::HashMap;
use std::sync::Arc;

use super::generic::GenericProtocol;
use super::image_upload::{brightness_mask, validate_rgb_canvas};
use super::traits::DeviceProtocol;
use super::{CompletionPoll, EncodedFrame, EncodedWrite, ReplyWait};
use crate::error::ProtocolError;
use crate::spec::types::DeviceSpec;

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "niimbot";

const HEAD: [u8; 2] = [0x55, 0x55];
const TAIL: [u8; 2] = [0xAA, 0xAA];

const CMD_PRINT_EMPTY_ROW: u8 = 0x84;
const CMD_PRINT_BITMAP_ROW: u8 = 0x85;
const CMD_PRINT_BITMAP_ROW_INDEXED: u8 = 0x83;

/// Replies that mean the printer refused: 0xDB is a print error, 0x00 is
/// "command not supported" (`protocol_details.niimbot_print_task.replies`).
const ERROR_REPLIES: [u8; 2] = [0xDB, 0x00];

/// Rows with at most this many black dots go as dot indexes; niimbluelib
/// records a printer powering off when sent more that way.
const MAX_INDEXED_DOTS: usize = 6;

/// How long a control packet's reply may take.
const REPLY_TIMEOUT_MS: u32 = 3_000;
/// PrintStatus cadence and ceiling (`status_reply`: ~300 ms, 5 s per reply;
/// the page itself can take far longer to feed, hence the overall ceiling).
const POLL_INTERVAL_MS: u32 = 300;
const POLL_TIMEOUT_MS: u32 = 30_000;

/// The control commands of the task, in order, with the reply id each one
/// waits for. `rows` go between `set_print_quantity` and `page_end`.
const BEFORE_ROWS: &[(&str, u8)] = &[
    ("connect", 0xC2),
    ("set_density", 0x31),
    ("set_label_type", 0x33),
    ("print_start", 0x02),
    ("print_clear", 0x30),
    ("page_start", 0x04),
    ("set_page_size", 0x14),
    ("set_print_quantity", 0x16),
];
const PAGE_END: (&str, u8) = ("page_end", 0xE4);
const PRINT_END: (&str, u8) = ("print_end", 0xF4);
const PRINT_STATUS_REPLY: u8 = 0xB3;

/// Wrap `data` in the packet envelope.
pub fn packet(cmd: u8, data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len() + 7);
    out.extend_from_slice(&HEAD);
    out.push(cmd);
    out.push(data.len() as u8);
    out.extend_from_slice(data);
    let xor = data
        .iter()
        .fold(cmd ^ data.len() as u8, |acc, byte| acc ^ byte);
    out.push(xor);
    out.extend_from_slice(&TAIL);
    out
}

/// Black dots per third of the head (split mode), or the total when the row
/// is wider than three chunks — emitted `[0, lo, hi]` as niimbluelib does
/// (`remaining_unknowns` records that byte order as unestablished).
fn black_dot_counts(row: &[u8], head_dots: usize) -> [u8; 3] {
    let chunk = (head_dots / 8 / 3).max(1);
    let total: u32 = row.iter().map(|b| b.count_ones()).sum();
    if row.len() <= chunk * 3 {
        let mut parts = [0u32; 3];
        for (i, byte) in row.iter().enumerate() {
            parts[(i / chunk).min(2)] += byte.count_ones();
        }
        parts.map(|p| p.min(255) as u8)
    } else {
        let t = total.min(u16::MAX as u32) as u16;
        [0, (t & 0xFF) as u8, (t >> 8) as u8]
    }
}

/// One run of identical rows as its packet.
fn row_packet(index: u16, row: &[u8], repeat: u8, head_dots: usize) -> Vec<u8> {
    let pos = index.to_be_bytes();
    let dots: Vec<u16> = row
        .iter()
        .enumerate()
        .flat_map(|(i, byte)| {
            (0..8u16)
                .filter_map(move |bit| (byte & (0x80 >> bit) != 0).then_some(i as u16 * 8 + bit))
        })
        .collect();
    if dots.is_empty() {
        return packet(CMD_PRINT_EMPTY_ROW, &[pos[0], pos[1], repeat]);
    }
    let counts = black_dot_counts(row, head_dots);
    let mut data = vec![pos[0], pos[1], counts[0], counts[1], counts[2], repeat];
    if dots.len() <= MAX_INDEXED_DOTS {
        for dot in dots {
            data.extend_from_slice(&dot.to_be_bytes());
        }
        packet(CMD_PRINT_BITMAP_ROW_INDEXED, &data)
    } else {
        data.extend_from_slice(row);
        packet(CMD_PRINT_BITMAP_ROW, &data)
    }
}

/// The page's row packets: rows packed MSB-first, runs of identical rows
/// merged up to the repeat byte's 255.
pub fn row_packets(
    rgb: &[u8],
    width: usize,
    height: usize,
    row_bytes: usize,
    head_dots: usize,
) -> Vec<Vec<u8>> {
    let bright = brightness_mask(rgb);
    let rows: Vec<Vec<u8>> = (0..height)
        .map(|y| {
            let mut row = vec![0u8; row_bytes];
            for x in 0..width.min(row_bytes * 8) {
                if !bright[y * width + x] {
                    row[x / 8] |= 0x80 >> (x % 8);
                }
            }
            row
        })
        .collect();
    let mut out = Vec::new();
    let mut y = 0;
    while y < rows.len() {
        let mut run = 1;
        while y + run < rows.len() && run < 255 && rows[y + run] == rows[y] {
            run += 1;
        }
        out.push(row_packet(y as u16, &rows[y], run as u8, head_dots));
        y += run;
    }
    out
}

/// The characteristic that carries the print task: the one declaring its
/// commands. Writes and replies share it (`notify` + `write_without_response`).
fn print_characteristic(spec: &DeviceSpec) -> Result<String, ProtocolError> {
    spec.services
        .iter()
        .flat_map(|s| &s.characteristics)
        .find(|c| {
            c.commands
                .as_ref()
                .is_some_and(|cmds| cmds.contains_key("set_page_size"))
        })
        .map(|c| c.uuid.to_ascii_lowercase())
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: "the spec declares no characteristic carrying the NIIMBOT print task"
                .to_string(),
        })
}

/// Encode one label as the D110 print task. `frame_index` is unused (the
/// protocol numbers rows, not frames); `max_payload_per_write` splits a
/// packet longer than one write across several, back to back.
pub fn encode_print_job(
    spec: &DeviceSpec,
    rgb: &[u8],
    width: u32,
    height: u32,
    _frame_index: u32,
    max_payload_per_write: usize,
) -> Result<EncodedFrame, ProtocolError> {
    validate_rgb_canvas(spec, rgb, width, height)?;
    if height > u16::MAX as u32 {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!("{height} rows overflow the u16 row index"),
        });
    }
    if max_payload_per_write < 20 {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "max_payload_per_write {max_payload_per_write} is below the BLE minimum of 20"
            ),
        });
    }
    let feature = super::image_upload::image_feature(spec);
    let geometry = feature
        .and_then(|f| f.print_geometry.clone())
        .unwrap_or_default();
    let head_dots = geometry
        .head_dots
        .or(feature.and_then(|f| f.max_width))
        .unwrap_or(96) as usize;
    let row_bytes = (width as usize).div_ceil(8).min(head_dots.div_ceil(8));
    let char_uuid = print_characteristic(spec)?;
    let protocol = GenericProtocol::new(Arc::new(spec.clone()));

    let mut frame = EncodedFrame::default();
    let push = |frame: &mut EncodedFrame, bytes: Vec<u8>| {
        for chunk in bytes.chunks(max_payload_per_write) {
            frame.writes.push(EncodedWrite {
                characteristic_uuid: char_uuid.clone(),
                bytes: chunk.to_vec(),
            });
        }
        frame.packets += 1;
    };
    let wait = |frame: &mut EncodedFrame, reply: u8| {
        frame.reply_waits.push(ReplyWait {
            after_write: frame.writes.len() - 1,
            characteristic_uuid: char_uuid.clone(),
            expect_prefix: vec![HEAD[0], HEAD[1], reply],
            error_prefixes: ERROR_REPLIES
                .iter()
                .map(|e| vec![HEAD[0], HEAD[1], *e])
                .collect(),
            timeout_ms: REPLY_TIMEOUT_MS,
        });
    };
    let command = |name: &str, params: &[(&str, f64)]| {
        let params: HashMap<String, f64> =
            params.iter().map(|(k, v)| (k.to_string(), *v)).collect();
        protocol.encode_command(&char_uuid, name, &params)
    };

    for (name, reply) in BEFORE_ROWS {
        let bytes = match *name {
            "set_page_size" => command(
                name,
                &[("rows", height as f64), ("cols", (row_bytes * 8) as f64)],
            )?,
            "set_print_quantity" => command(name, &[("quantity", 1.0)])?,
            _ => command(name, &[])?,
        };
        push(&mut frame, bytes);
        wait(&mut frame, *reply);
    }
    for row in row_packets(rgb, width as usize, height as usize, row_bytes, head_dots) {
        push(&mut frame, row);
    }
    push(&mut frame, command(PAGE_END.0, &[])?);
    wait(&mut frame, PAGE_END.1);

    // PrintEnd only once the printer says the page is done: [page u16 BE]
    // at data offset 0, i.e. reply bytes 4-5, reaches the one page sent.
    frame.completion_poll = Some(CompletionPoll {
        before_write: frame.writes.len(),
        request: EncodedWrite {
            characteristic_uuid: char_uuid.clone(),
            bytes: command("print_status", &[])?,
        },
        characteristic_uuid: char_uuid.clone(),
        reply_prefix: vec![HEAD[0], HEAD[1], PRINT_STATUS_REPLY],
        done_offset: 4,
        done_bytes: vec![0x00, 0x01],
        interval_ms: POLL_INTERVAL_MS,
        timeout_ms: POLL_TIMEOUT_MS,
    });
    push(&mut frame, command(PRINT_END.0, &[])?);
    wait(&mut frame, PRINT_END.1);
    Ok(frame)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The S2 spec, as a fixture until the vendored copy is refreshed with it.
    fn spec() -> DeviceSpec {
        let path = format!(
            "{}/tests/specs/niimbot-d110.yaml",
            env!("CARGO_MANIFEST_DIR")
        );
        crate::spec::parser::parse_device_spec(&std::fs::read_to_string(path).unwrap())
            .expect("the NIIMBOT spec parses")
    }

    fn white(w: usize, h: usize) -> Vec<u8> {
        vec![255u8; w * h * 3]
    }

    #[test]
    fn the_envelope_xors_cmd_len_and_data() {
        assert_eq!(
            packet(0x01, &[0x01]),
            vec![0x55, 0x55, 0x01, 0x01, 0x01, 0x01, 0xAA, 0xAA]
        );
    }

    #[test]
    fn the_documented_indexed_row_is_reproduced() {
        // protocol_details.niimbot_print_task.example: row 126, dots 39-42.
        let mut row = vec![0u8; 12];
        for dot in [39usize, 40, 41, 42] {
            row[dot / 8] |= 0x80 >> (dot % 8);
        }
        assert_eq!(
            row_packet(126, &row, 1, 96),
            vec![
                0x55, 0x55, 0x83, 0x0E, 0x00, 0x7E, 0x00, 0x04, 0x00, 0x01, 0x00, 0x27, 0x00, 0x28,
                0x00, 0x29, 0x00, 0x2A, 0xFA, 0xAA, 0xAA
            ]
        );
    }

    #[test]
    fn rows_pick_their_packet_by_black_dots_and_merge_runs() {
        // 16 wide: two white rows, three identical dense rows, one 2-dot row.
        let (w, h) = (16usize, 6usize);
        let mut rgb = white(w, h);
        let mut black = |x: usize, y: usize| {
            let i = (y * w + x) * 3;
            rgb[i..i + 3].copy_from_slice(&[0, 0, 0]);
        };
        for y in 2..5 {
            for x in 0..10 {
                black(x, y);
            }
        }
        black(0, 5);
        black(15, 5);
        let packets = row_packets(&rgb, w, h, 2, 96);
        assert_eq!(packets.len(), 3);
        // Blank rows 0-1, once, repeat 2.
        assert_eq!(packets[0], packet(0x84, &[0, 0, 2]));
        // Rows 2-4: ten dots each → a bitmap row, repeat 3, counts all in
        // the first third (a 2-byte row lies inside chunk 0).
        assert_eq!(packets[1][2], 0x85);
        assert_eq!(&packets[1][4..10], &[0, 2, 10, 0, 0, 3]);
        assert_eq!(&packets[1][10..12], &[0xFF, 0xC0]);
        // Row 5: two dots → indexed, dots 0 and 15.
        assert_eq!(packets[2][2], 0x83);
        assert_eq!(
            &packets[2][4..],
            &packet(0x83, &[0, 5, 2, 0, 0, 1, 0, 0, 0, 15])[4..]
        );
    }

    #[test]
    fn split_counts_are_per_third_of_the_head() {
        let row = [0xFF; 12];
        assert_eq!(black_dot_counts(&row, 96), [32, 32, 32]);
        let mut row = [0u8; 12];
        row[11] = 0x01;
        assert_eq!(black_dot_counts(&row, 96), [0, 0, 1]);
    }

    #[test]
    fn a_long_run_splits_at_the_repeat_byte() {
        let packets = row_packets(&white(8, 300), 8, 300, 1, 96);
        assert_eq!(packets.len(), 2);
        assert_eq!(packets[0], packet(0x84, &[0, 0, 255]));
        assert_eq!(packets[1], packet(0x84, &[0, 255, 45]));
    }

    #[test]
    fn the_job_is_the_task_in_order_with_its_reply_waits() {
        let spec = spec();
        let (w, h) = (96u32, 240u32);
        let mut rgb = white(w as usize, h as usize);
        rgb[..3].copy_from_slice(&[0, 0, 0]);
        let frame = encode_print_job(&spec, &rgb, w, h, 0, 180).unwrap();

        // The first writes are the spec's own fixed packets.
        assert_eq!(
            frame.writes[0].bytes,
            vec![0x03, 0x55, 0x55, 0xC1, 0x01, 0x01, 0xC1, 0xAA, 0xAA]
        );
        assert_eq!(frame.writes[1].bytes, packet(0x21, &[2]));
        assert_eq!(frame.writes[2].bytes, packet(0x23, &[1]));
        assert_eq!(frame.writes[3].bytes, packet(0x01, &[1]));
        assert_eq!(frame.writes[4].bytes, packet(0x20, &[1]));
        assert_eq!(frame.writes[5].bytes, packet(0x03, &[1]));
        assert_eq!(
            frame.writes[6].bytes,
            packet(0x13, &[0x00, 0xF0, 0x00, 0x60])
        );
        assert_eq!(frame.writes[7].bytes, packet(0x15, &[0x00, 0x01]));
        let last = frame.writes.len() - 1;
        assert_eq!(frame.writes[last].bytes, packet(0xF3, &[1]));
        assert_eq!(frame.writes[last - 1].bytes, packet(0xE3, &[1]));

        // One wait after each control packet, none on rows.
        let replies: Vec<u8> = frame
            .reply_waits
            .iter()
            .map(|w| w.expect_prefix[2])
            .collect();
        assert_eq!(
            replies,
            vec![0xC2, 0x31, 0x33, 0x02, 0x30, 0x04, 0x14, 0x16, 0xE4, 0xF4]
        );
        let after: Vec<usize> = frame.reply_waits.iter().map(|w| w.after_write).collect();
        assert_eq!(&after[..8], &[0, 1, 2, 3, 4, 5, 6, 7]);
        assert_eq!(after[8], last - 1);
        assert_eq!(after[9], last);
        for w in &frame.reply_waits {
            assert_eq!(
                w.error_prefixes,
                vec![vec![0x55, 0x55, 0xDB], vec![0x55, 0x55, 0x00]]
            );
        }

        // PrintEnd is held until the page is reported done.
        let poll = frame.completion_poll.as_ref().unwrap();
        assert_eq!(poll.before_write, last);
        assert_eq!(poll.request.bytes, packet(0xA3, &[1]));
        assert_eq!(poll.reply_prefix, vec![0x55, 0x55, 0xB3]);
        assert_eq!((poll.done_offset, poll.done_bytes.clone()), (4, vec![0, 1]));

        // Every write targets the print characteristic.
        assert!(frame
            .writes
            .iter()
            .all(|w| w.characteristic_uuid == "bef8d6c9-9c21-4c9e-b632-bd58c1009f9f"));
    }

    #[test]
    fn a_small_mtu_splits_packets_without_moving_the_waits_early() {
        let spec = spec();
        let mut rgb = white(96, 4);
        for px in rgb.chunks_exact_mut(3).take(96) {
            px.copy_from_slice(&[0, 0, 0]);
        }
        let frame = encode_print_job(&spec, &rgb, 96, 4, 0, 20).unwrap();
        assert!(frame.writes.iter().all(|w| w.bytes.len() <= 20));
        // The full 0x85 row is 25 bytes, so it went as two writes.
        let joined: Vec<u8> = frame.writes.iter().flat_map(|w| w.bytes.clone()).collect();
        let row = row_packet(0, &[0xFF; 12], 1, 96);
        assert!(joined.windows(row.len()).any(|w| w == row.as_slice()));
        // A wait still follows the LAST fragment of its packet.
        for wait in &frame.reply_waits {
            let written = &frame.writes[wait.after_write].bytes;
            assert_eq!(&written[written.len() - 2..], &[0xAA, 0xAA]);
        }
    }

    #[test]
    fn a_wider_canvas_than_the_head_is_refused() {
        let spec = spec();
        assert!(encode_print_job(&spec, &white(200, 2), 200, 2, 0, 180).is_err());
    }
}

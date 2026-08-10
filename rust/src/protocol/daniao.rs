// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Image/animation-frame encoder for Hangzhou Daniao's "DDP" BLE platform —
//! the stack behind SmartDawn / SuperPix / SmartPixel addressable-RGB lights.
//!
//! SPEC-DRIVEN: every byte-level fact (message types, channel tags, the
//! fragment framing, and which characteristic each write targets) is resolved
//! from the device spec (`smartdawn-smart-lights.yaml`) at encode time — this
//! module only carries the pixel ALGORITHM the spec cannot express
//! declaratively (palette-indexed run-length encoding) and the handler's
//! knowledge of WHICH commands open a doodle session. The message-type bytes
//! for those commands come from the spec's command templates, not from
//! constants here.
//!
//! THE LIVE-VERIFIED PATH (JY25CUT curtain, unit DN0B88, 2026-08-08 — renders
//! full images, sequential images, and ~5fps animation):
//!
//! 1. **Session open** (once, frame 0, on the DDP command characteristic —
//!    the `daniao_fragment` char with `channel_tag: 0`): the spec's
//!    `ui_end_sync` command (M_UI_END_SYNC, mt 2411) to suspend UI-mirror
//!    playback, then `doodle_start` (M_DOODLE_START, mt 2701). NOT
//!    `M_DEV_START` (mt 235) — that is the developer/raw-pixel mode and it
//!    BLANKS the doodle canvas.
//! 2. **Per frame** (on the BIN bulk characteristic — the `daniao_fragment`
//!    char with no fixed `channel_tag`): the canvas as one or more
//!    `TUTU_RESTORE` (buffer tag 4) chunks. Each chunk MUST fit in a single
//!    BLE write: the device does NOT reassemble BIN fragments (a split chunk
//!    renders only its first strand), so a large negotiated ATT MTU is
//!    required — the app requests 512.
//!
//! Chunk format (ported from the vendor H5 bundle's `TuTu.sendRecoveData`):
//! header `[start_x][start_y][palette_count]` + `palette_count` RGB triplets
//! (first ≤16 distinct colors in row-major scan order), then a COLUMN-MAJOR
//! run-length stream of palette indices — a run < 16 is one byte
//! `(index << 4) | run_len`; a longer run is `(index << 4)` then count bytes
//! (`0xFF` per full 127, then the remainder). A chunk is flushed at ~200
//! bytes; the next chunk's header carries the (x, y) where its data resumes.
//!
//! The encoder is stateless: callers pass a `frame_index` and fragment serials
//! derive from it, so streaming N frames produces distinct serials without
//! shared state across the FFI boundary.

use super::{EncodedFrame, EncodedWrite};
use crate::codec::types::encode_command;
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, CharacteristicProperty, DeviceSpec};
use serde::Deserialize;
use std::collections::HashMap;

/// `protocol_handler` name this module implements (see the device spec's
/// top-level `protocol_handler` key).
pub const HANDLER_NAME: &str = "daniao_ddp";

/// The platform's single custom GATT service (also declared in the spec).
pub const SERVICE_UUID: &str = "00000074-1972-1925-3022-077119514e44";

/// Named fragment scheme this handler understands (spec `framing.scheme`).
const FRAGMENT_SCHEME: &str = "daniao_fragment";
const FRAG_HEADER_LEN: usize = 4;
const MAX_PALETTE: usize = 16;
/// Chunk flush threshold from the vendor encoder: header + pixel bytes < 200.
const CHUNK_LIMIT: usize = 200;
/// Maximum pixels in one emitted run. A longer solid region is split into
/// consecutive same-colour runs (identical on the device) so a single run's
/// tokens (<= 2 + ceil(MAX_RUN/127) bytes) can never bloat a chunk past a BLE
/// write. Well above any real per-strand run, so the 20x20 curtain is unaffected.
const MAX_RUN: usize = 1016; // 8 * 127 -> <= 10 token bytes per run
/// The BLE 4.0 minimum ATT payload (MTU 23 - 3). The vendor app requests MTU
/// 512; a chunk that cannot fit one write over the negotiated MTU is rejected.
const MIN_PAYLOAD_PER_WRITE: usize = 20;

/// BIN buffer-type tag for a full-canvas redraw (spec's BIN Write notes:
/// 1=TUTU_DOODLE, 2=TUTU_ERASE, 4=TUTU_RESTORE, 16=MUSIC_BIN). Not a fixed
/// `channel_tag` in the spec because the bulk channel picks its tag per
/// transfer; this handler pushes full canvases, hence RESTORE.
const TAG_TUTU_RESTORE: u8 = 0x04;

/// Command names, resolved from the spec's command templates, that open a
/// doodle/pixel session. Their message-type bytes live in the spec, not here.
const SESSION_OPEN_COMMANDS: &[&str] = &["ui_end_sync", "doodle_start"];

/// The `framing` block of a characteristic, deserialized from the spec's
/// opaque value on demand (the shared `Characteristic` type keeps it untyped
/// because most devices have no framing).
#[derive(Debug, Deserialize)]
struct Framing {
    scheme: Option<String>,
    channel_tag: Option<u8>,
}

fn framing_of(c: &Characteristic) -> Option<Framing> {
    c.framing
        .as_ref()
        .and_then(|v| serde_yaml::from_value(v.clone()).ok())
}

fn is_writable(c: &Characteristic) -> bool {
    c.properties.iter().any(|p| {
        matches!(
            p,
            CharacteristicProperty::Write | CharacteristicProperty::WriteWithoutResponse
        )
    })
}

/// Resolve a `daniao_fragment` characteristic from the spec by its channel tag:
/// the command channel is `channel_tag: 0`; the bulk channel omits it.
fn resolve_char(
    spec: &DeviceSpec,
    want_command_channel: bool,
) -> Option<(&Characteristic, u8)> {
    for service in &spec.services {
        for c in &service.characteristics {
            if !is_writable(c) {
                continue;
            }
            let Some(f) = framing_of(c) else { continue };
            if f.scheme.as_deref() != Some(FRAGMENT_SCHEME) {
                continue;
            }
            match (want_command_channel, f.channel_tag) {
                (true, Some(0)) => return Some((c, 0)),
                (false, None) => return Some((c, TAG_TUTU_RESTORE)),
                _ => {}
            }
        }
    }
    None
}

/// Encode one RGB frame as the ordered BLE writes of the doodle flow, driven
/// by `spec`.
///
/// `rgb` is row-major RGB888 (`width * height * 3` bytes) using at most 16
/// distinct colors — the palette limit; more is an error rather than a silent
/// quantization, so what the device shows matches what the caller previewed.
/// `max_payload_per_write` is the usable bytes per BLE write (negotiated ATT
/// MTU minus 3; 20 when unknown).
///
/// When `frame_index` is 0 the plan opens the doodle session first (the spec's
/// `ui_end_sync` then `doodle_start` commands on the DDP characteristic);
/// later frames send only their pixel chunks. The returned
/// [`EncodedFrame::packets`] counts logical packets (and therefore fragment
/// serials) consumed — callers MUST advance `frame_index` by it.
pub fn encode_doodle_frame(
    spec: &DeviceSpec,
    rgb: &[u8],
    width: u32,
    height: u32,
    frame_index: u32,
    max_payload_per_write: usize,
) -> Result<EncodedFrame, ProtocolError> {
    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|px| px.checked_mul(3))
        .ok_or_else(|| ProtocolError::ImageDimensionsInvalid {
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
    // Chunk headers pack start_x/start_y as single bytes, so pixel indices must
    // fit a u8 — a dimension over 256 would silently wrap coordinates and
    // scramble the image. Reject rather than corrupt.
    if width > 256 || height > 256 {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "{width}x{height} exceeds 256 in a dimension; TUTU chunk coordinates are u8"
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

    // Resolve the two channels from the spec's framing declarations.
    let (command_char, command_tag) =
        resolve_char(spec, true).ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: "spec has no daniao_fragment command characteristic (channel_tag: 0)"
                .to_string(),
        })?;
    let (bulk_char, bulk_tag) =
        resolve_char(spec, false).ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: "spec has no daniao_fragment bulk characteristic (no channel_tag)".to_string(),
        })?;

    let chunks = encode_tutu_restore(rgb, width as usize, height as usize)?;

    let frag_capacity = max_payload_per_write - FRAG_HEADER_LEN;

    // The device honors ONLY the first BLE write of a BIN transfer, so every
    // TUTU chunk must fit one write. Fail loudly rather than paint a partial
    // image if the MTU is too small.
    if let Some(biggest) = chunks.iter().map(Vec::len).max() {
        if biggest > frag_capacity {
            return Err(ProtocolError::ImageDimensionsInvalid {
                reason: format!(
                    "a TUTU chunk is {biggest} B but only {frag_capacity} B fit in one BLE \
                     write, and the device does not reassemble BIN fragments — raise the ATT \
                     MTU (need >= {} bytes) before pushing images",
                    biggest + FRAG_HEADER_LEN + 3
                ),
            });
        }
    }

    let mut serial = frame_index;
    let mut writes = Vec::new();

    // One logical packet -> one or more BLE writes sharing a serial, with the
    // 4-byte daniao_fragment header and a remaining-count walking to 0.
    let mut push_framed = |packet: &[u8], char_uuid: &str, tag: u8, serial: &mut u32| {
        let s = *serial as u8;
        *serial = serial.wrapping_add(1);
        let parts: Vec<&[u8]> = packet.chunks(frag_capacity).collect();
        let total = parts.len().max(1);
        for (i, part) in parts.iter().enumerate() {
            let mut bytes = Vec::with_capacity(FRAG_HEADER_LEN + part.len());
            bytes.extend_from_slice(&[s, total as u8, (total - 1 - i) as u8, tag]);
            bytes.extend_from_slice(part);
            writes.push(EncodedWrite {
                characteristic_uuid: char_uuid.to_string(),
                bytes,
            });
        }
    };

    if frame_index == 0 {
        let commands = command_char
            .commands
            .as_ref()
            .ok_or_else(|| ProtocolError::NoCommands {
                uuid: command_char.uuid.clone(),
            })?;
        for name in SESSION_OPEN_COMMANDS {
            let command = commands
                .get(*name)
                .ok_or_else(|| ProtocolError::CommandNotFound {
                    uuid: command_char.uuid.clone(),
                    command: (*name).to_string(),
                })?;
            let packet = encode_command(command, &HashMap::new())?;
            push_framed(&packet, &command_char.uuid, command_tag, &mut serial);
        }
    }

    for chunk in &chunks {
        push_framed(chunk, &bulk_char.uuid, bulk_tag, &mut serial);
    }

    let packets = serial.wrapping_sub(frame_index);
    // The fragment serial is a u8, so a frame that needs more than 256 distinct
    // serials would reuse a byte mid-frame and corrupt reassembly on the device.
    if packets > 256 {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "frame needs {packets} logical packets; the u8 fragment serial allows at most 256 \
                 per frame — reduce the image's distinct-run count or size"
            ),
        });
    }
    Ok(EncodedFrame { writes, packets })
}

/// Port of the vendor H5 `sendRecoveData` chunk builder — see the module docs
/// for the format. Returns the ordered `TUTU_RESTORE` chunk payloads.
fn encode_tutu_restore(
    rgb: &[u8],
    width: usize,
    height: usize,
) -> Result<Vec<Vec<u8>>, ProtocolError> {
    // Palette: first ≤16 distinct colors in row-major scan order.
    let mut palette: Vec<[u8; 3]> = Vec::new();
    let mut index_of = HashMap::new();
    for px in rgb.chunks_exact(3) {
        let color = [px[0], px[1], px[2]];
        if let std::collections::hash_map::Entry::Vacant(slot) = index_of.entry(color) {
            if palette.len() >= MAX_PALETTE {
                return Err(ProtocolError::ImageDimensionsInvalid {
                    reason: format!(
                        "image uses more than {MAX_PALETTE} distinct colors; the TUTU doodle \
                         format is palette-indexed — reduce the color count"
                    ),
                });
            }
            slot.insert(palette.len() as u8);
            palette.push(color);
        }
    }

    let header = |x: u8, y: u8| -> Vec<u8> {
        let mut h = vec![x, y, palette.len() as u8];
        for c in &palette {
            h.extend_from_slice(c);
        }
        h
    };
    let header_len = header(0, 0).len();

    let mut chunks: Vec<Vec<u8>> = Vec::new();
    let mut tokens: Vec<u8> = Vec::new();
    let mut cur: Option<u8> = None;
    let mut run: usize = 0;
    let mut chunk_start = (0u8, 0u8);
    let mut run_start = (0u8, 0u8);

    fn emit_run(tokens: &mut Vec<u8>, index: u8, run: usize) {
        let first = index << 4;
        if run < 16 {
            tokens.push(first | run as u8);
        } else {
            tokens.push(first);
            let mut r = run;
            while r >= 127 {
                tokens.push(255);
                r -= 127;
            }
            // ALWAYS emit a terminating remainder byte (0..=126), even when the
            // run is an exact multiple of 127. The decoder stops on the first
            // byte < 255 (confirmed by the live red=400 case, which ends in 19);
            // without this, a 127/254/381-pixel run would leave the decoder
            // reading the next run's token as its count and corrupt the image.
            tokens.push(r as u8);
        }
    }

    // Column-major traversal, exactly like the vendor encoder.
    for x in 0..width {
        for y in 0..height {
            if header_len + tokens.len() >= CHUNK_LIMIT {
                let mut chunk = header(chunk_start.0, chunk_start.1);
                chunk.append(&mut tokens);
                chunks.push(chunk);
                chunk_start = run_start;
            }
            let idx = index_of[&[
                rgb[(y * width + x) * 3],
                rgb[(y * width + x) * 3 + 1],
                rgb[(y * width + x) * 3 + 2],
            ]];
            match cur {
                None => {
                    cur = Some(idx);
                    run = 1;
                }
                Some(c) if c != idx => {
                    run_start = (x as u8, y as u8);
                    emit_run(&mut tokens, c, run);
                    cur = Some(idx);
                    run = 1;
                }
                // Cap the run length so one run can never emit a token blob big
                // enough to overflow a chunk past a BLE write. A capped run is
                // flushed and continued as a fresh SAME-colour run at this
                // pixel — the decoder paints consecutive same-index runs
                // identically, so the image is unchanged, but the between-run
                // flush can now bound every chunk (a 256x256 solid would
                // otherwise be one ~518-byte chunk no MTU can carry).
                Some(c) if run >= MAX_RUN => {
                    run_start = (x as u8, y as u8);
                    emit_run(&mut tokens, c, run);
                    run = 1;
                }
                Some(_) => run += 1,
            }
        }
    }
    if let Some(c) = cur {
        emit_run(&mut tokens, c, run);
    }
    let mut chunk = header(chunk_start.0, chunk_start.1);
    chunk.append(&mut tokens);
    chunks.push(chunk);
    Ok(chunks)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    const SPEC_YAML: &str = r#"
device:
  name: "SmartDawn"
  manufacturer: "Daniao"
  manufacturer_status: "active"
  protocol: "ble"
  category: "light"
  identification:
    local_name_prefix: "DN"
    service_uuids: ["00000074-1972-1925-3022-077119514e44"]
protocol_handler: "daniao_ddp"
services:
  - uuid: "00000074-1972-1925-3022-077119514e44"
    name: "Daniao DDP Service"
    characteristics:
      - uuid: "01020074-1972-1925-3022-077119514e44"
        name: "DDP Write"
        properties: ["write", "write_without_response"]
        framing: { scheme: "daniao_fragment", channel_tag: 0 }
        commands:
          ui_end_sync:
            description: "suspend UI mirror"
            template: [0xF0, 0x04, "{sn}", "{len}", 0x09, 0x6B, "{cid}", "{osn}", 0x00, "{ts}", 0x00, 0x00, 0x00, 0x00]
            parameters:
              sn: { type: "uint16", endianness: "big", auto: "sequence" }
              len: { type: "uint16", endianness: "big", auto: "packet_length" }
              cid: { type: "uint32", endianness: "big", default: 0 }
              osn: { type: "uint16", endianness: "big", default: 1 }
              ts: { type: "uint8", default: 0 }
          doodle_start:
            description: "open doodle"
            template: [0xF0, 0x04, "{sn}", "{len}", 0x0A, 0x8D, "{cid}", "{osn}", 0x00, "{ts}", 0x00, 0x00, 0x00, 0x00]
            parameters:
              sn: { type: "uint16", endianness: "big", auto: "sequence" }
              len: { type: "uint16", endianness: "big", auto: "packet_length" }
              cid: { type: "uint32", endianness: "big", default: 0 }
              osn: { type: "uint16", endianness: "big", default: 1 }
              ts: { type: "uint8", default: 0 }
      - uuid: "02020074-1972-1925-3022-077119514e44"
        name: "BIN Write"
        properties: ["write", "write_without_response"]
        framing: { scheme: "daniao_fragment" }
"#;

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC_YAML).unwrap()
    }

    const DDP: &str = "01020074-1972-1925-3022-077119514e44";
    const BIN: &str = "02020074-1972-1925-3022-077119514e44";

    /// A 2x2 RGB canvas of two colors: red, green / green, red.
    fn tiny() -> Vec<u8> {
        vec![255, 0, 0, 0, 255, 0, 0, 255, 0, 255, 0, 0]
    }

    /// A 20x20 trans flag (5 horizontal stripes) for realistic chunk sizes.
    fn trans_flag() -> Vec<u8> {
        let rows = [
            [0x5B, 0xCE, 0xFA],
            [0xF5, 0xA9, 0xB8],
            [0xFF, 0xFF, 0xFF],
            [0xF5, 0xA9, 0xB8],
            [0x5B, 0xCE, 0xFA],
        ];
        let mut px = Vec::new();
        for y in 0..20 {
            let c = rows[y / 4];
            for _ in 0..20 {
                px.extend_from_slice(&c);
            }
        }
        px
    }

    #[test]
    fn first_frame_opens_session_from_spec_then_streams_chunks() {
        let frame = encode_doodle_frame(&spec(), &trans_flag(), 20, 20, 0, 509).unwrap();
        // 2 session commands + 1 chunk = 3 logical packets/serials.
        assert_eq!(frame.packets, 3);
        let w = &frame.writes;
        // ui_end_sync then doodle_start on the DDP char, tag 0, mt from spec.
        assert_eq!(w[0].characteristic_uuid, DDP);
        assert_eq!(&w[0].bytes[..4], &[0, 1, 0, 0]);
        assert_eq!(&w[0].bytes[10..12], &[0x09, 0x6B]); // mt 2411 (UI_END_SYNC)
        assert_eq!(w[1].characteristic_uuid, DDP);
        assert_eq!(&w[1].bytes[..4], &[1, 1, 0, 0]);
        assert_eq!(&w[1].bytes[10..12], &[0x0A, 0x8D]); // mt 2701 (DOODLE_START)
                                                        // Then the pixel chunk on the BIN char, tag 4, single write.
        assert_eq!(w[2].characteristic_uuid, BIN);
        assert_eq!(&w[2].bytes[..4], &[2, 1, 0, TAG_TUTU_RESTORE]);
    }

    #[test]
    fn later_frames_skip_session_open_and_stream_on_bin() {
        let frame = encode_doodle_frame(&spec(), &trans_flag(), 20, 20, 5, 509).unwrap();
        assert_eq!(frame.packets, 1, "one chunk, no session packets");
        assert_eq!(frame.writes.len(), 1);
        assert_eq!(frame.writes[0].characteristic_uuid, BIN);
        assert_eq!(&frame.writes[0].bytes[..4], &[5, 1, 0, TAG_TUTU_RESTORE]);
    }

    #[test]
    fn chunk_too_big_for_one_write_is_rejected() {
        // The device honors only the first BLE write of a BIN transfer, so a
        // chunk that cannot fit one write is a hard error, not a partial paint.
        let err = encode_doodle_frame(&spec(), &trans_flag(), 20, 20, 5, 20).unwrap_err();
        match err {
            ProtocolError::ImageDimensionsInvalid { reason } => {
                assert!(reason.contains("does not reassemble"), "got: {reason}");
            }
            other => panic!("expected ImageDimensionsInvalid, got {other:?}"),
        }
    }

    #[test]
    fn tiny_canvas_round_trips_palette_and_runs() {
        let frame = encode_doodle_frame(&spec(), &tiny(), 2, 2, 5, 509).unwrap();
        let chunk = &frame.writes[0].bytes[4..];
        // header: start (0,0), 2 colors, then RGB of red, green.
        assert_eq!(&chunk[..3], &[0, 0, 2]);
        assert_eq!(&chunk[3..9], &[255, 0, 0, 0, 255, 0]);
    }

    #[test]
    fn too_many_colors_is_rejected() {
        // 17 distinct colors in a 1x17 canvas exceeds the 16-entry palette.
        let mut rgb = Vec::new();
        for i in 0..17u8 {
            rgb.extend_from_slice(&[i, 0, 0]);
        }
        let err = encode_doodle_frame(&spec(), &rgb, 17, 1, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn wrong_buffer_length_is_rejected() {
        let err = encode_doodle_frame(&spec(), &[0; 5], 2, 2, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn missing_session_command_in_spec_errors() {
        // A spec whose DDP char lacks the session-open commands must fail
        // clearly, not silently skip opening the session.
        let yaml = SPEC_YAML.replace("ui_end_sync:", "not_the_command:");
        let s = parse_device_spec(&yaml).unwrap();
        let err = encode_doodle_frame(&s, &tiny(), 2, 2, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::CommandNotFound { .. }));
    }

    #[test]
    fn long_runs_use_extension_bytes() {
        // A solid 20x20 canvas: one 400-pixel run -> (0<<4) then 255,255,255,19.
        let rgb = vec![0x11u8; 20 * 20 * 3];
        let chunks = encode_tutu_restore(&rgb, 20, 20).unwrap();
        assert_eq!(chunks.len(), 1);
        assert_eq!(&chunks[0][..6], &[0, 0, 1, 0x11, 0x11, 0x11]);
        assert_eq!(&chunks[0][6..], &[0x00, 255, 255, 255, 19]);
    }

    #[test]
    fn run_that_is_an_exact_multiple_of_127_still_terminates() {
        // 127 identical pixels (127x1): the run must end with a remainder byte
        // (here 0), not just a trailing 0xFF, or the decoder would swallow the
        // next run's token.
        let rgb = vec![0x22u8; 127 * 3];
        let chunks = encode_tutu_restore(&rgb, 127, 1).unwrap();
        assert_eq!(chunks.len(), 1);
        assert_eq!(&chunks[0][6..], &[0x00, 0xFF, 0x00]);
    }

    #[test]
    fn dimension_over_256_is_rejected() {
        // Chunk coordinates are u8; a 257-wide canvas would wrap them.
        let err = encode_doodle_frame(&spec(), &vec![0u8; 257 * 3], 257, 1, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn frame_needing_more_than_256_serials_is_rejected() {
        // A 256x256 two-color checkerboard has no runs longer than 1, so it
        // produces far more than 256 ~200-byte chunks — the u8 fragment serial
        // would wrap and collide, so the encoder must reject it.
        let (w, h) = (256usize, 256usize);
        let mut rgb = Vec::with_capacity(w * h * 3);
        for y in 0..h {
            for x in 0..w {
                let on = (x + y) % 2 == 0;
                rgb.extend_from_slice(if on { &[255, 255, 255] } else { &[0, 0, 0] });
            }
        }
        let err = encode_doodle_frame(&spec(), &rgb, w as u32, h as u32, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn large_solid_canvas_encodes_with_every_chunk_fitting_one_write() {
        // A 256x256 solid colour is one 65536-pixel run. Run-capping splits it
        // into consecutive same-colour runs so no chunk overflows a BLE write
        // (the old atomic-run encoder produced a ~518-byte chunk no MTU carries).
        let rgb = vec![0x11u8; 256 * 256 * 3];
        let frame = encode_doodle_frame(&spec(), &rgb, 256, 256, 0, 509).unwrap();
        for w in &frame.writes {
            assert!(w.bytes.len() <= 509, "every write fits the MTU payload");
        }
    }
}

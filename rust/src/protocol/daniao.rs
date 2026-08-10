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
//! (`0xFF` per full 127, then the remainder). A chunk is flushed at the
//! vendor's ~200-byte limit or at the negotiated write budget, whichever is
//! smaller — each chunk must fit ONE BLE write, so a mid-range MTU (iOS
//! commonly negotiates 185) gets smaller chunks rather than a rejection. The
//! next chunk's header carries the (x, y) where its data resumes.
//!
//! The encoder is stateless: callers pass a `frame_index` and fragment serials
//! derive from it, so streaming N frames produces distinct serials without
//! shared state across the FFI boundary.

use super::{EncodedFrame, EncodedWrite};
use crate::codec::types::encode_command;
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, CharacteristicProperty, DeviceSpec, Feature};
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
/// Maximum pixels in one emitted run. A longer solid region is split into
/// consecutive same-colour runs (identical on the device) so a single run's
/// tokens (<= MAX_RUN_TOKENS bytes) can never bloat a chunk past a BLE
/// write. Well above any real per-strand run, so the 20x20 curtain is unaffected.
const MAX_RUN: usize = 1016; // 8 * 127 -> <= 10 token bytes per run
/// Worst-case token bytes one `emit_run` call can append: the leading
/// `(index << 4)` byte, one `0xFF` per full 127 pixels, and the terminating
/// remainder byte.
const MAX_RUN_TOKENS: usize = 2 + MAX_RUN / 127;
/// The BLE 4.0 minimum ATT payload (MTU 23 - 3). The vendor app requests MTU
/// 512; a chunk that cannot fit one write over the negotiated MTU is rejected.
const MIN_PAYLOAD_PER_WRITE: usize = 20;

/// Fallbacks for the three things the spec now states, kept for a spec pack
/// written before it did.
///
/// Each was a constant here first, and each was the wrong place for it: they
/// describe SmartDawn's flow, not the fragment scheme, so a sibling device on
/// the same platform with a different opener or buffer tag needed a code
/// change to work. They are read from the spec's `image_upload` feature and
/// the bulk channel's `framing` now — `session_open`, `channel_tag` and
/// `max_chunk_size` — and these values only apply when a spec is silent.
///
/// TUTU_RESTORE is the full-canvas redraw tag (the BIN channel also carries
/// 1=TUTU_DOODLE, 2=TUTU_ERASE, 16=MUSIC_BIN); 200 is the vendor encoder's
/// chunk ceiling; and the opener pair is the sequence verified on hardware,
/// where sending `M_DEV_START` instead blanks the canvas.
const DEFAULT_BULK_TAG: u8 = 0x04;
const DEFAULT_CHUNK_LIMIT: usize = 200;
const DEFAULT_SESSION_OPEN: &[&str] = &["ui_end_sync", "doodle_start"];

/// The `framing` block of a characteristic, deserialized from the spec's
/// opaque value on demand (the shared `Characteristic` type keeps it untyped
/// because most devices have no framing).
#[derive(Debug, Deserialize)]
struct Framing {
    scheme: Option<String>,
    channel_tag: Option<u8>,
    /// The chunk ceiling this channel's encoder flushes at. The effective
    /// per-chunk budget is the SMALLER of this and what one BLE write carries,
    /// so a link with a mid-range MTU still encodes (in more, smaller chunks)
    /// rather than being rejected.
    max_chunk_size: Option<usize>,
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

/// The `image_upload` feature this handler drives, if the spec declares one.
fn image_feature(spec: &DeviceSpec) -> Option<&Feature> {
    spec.features
        .iter()
        .find(|f| f.feature_type == "image_upload")
}

/// Resolve a `daniao_fragment` characteristic from the spec by its channel tag:
/// the command channel is `channel_tag: 0`; the bulk channel is the one that
/// is not the command channel.
///
/// The bulk channel is identified by *not* being channel 0 rather than by
/// omitting a tag, because omitting one is a statement about the channel (its
/// tag varies per transfer) and not an identifier. Its tag for THIS flow comes
/// from the feature, which is the layer that knows which buffer type an image
/// upload writes.
fn resolve_char(spec: &DeviceSpec, want_command_channel: bool) -> Option<(&Characteristic, u8)> {
    let flow_tag = image_feature(spec)
        .and_then(|f| f.channel_tag)
        .unwrap_or(DEFAULT_BULK_TAG);
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
                // A bulk channel may fix its own tag; when it does not, the
                // flow's tag applies.
                (false, Some(tag)) if tag != 0 => return Some((c, tag)),
                (false, None) => return Some((c, flow_tag)),
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

    let frag_capacity = max_payload_per_write - FRAG_HEADER_LEN;

    // Chunks are sized to the write, not just to the vendor's ceiling: the
    // device honors only the first BLE write of a BIN transfer, so a chunk
    // that fits one write is the actual requirement, and a mid-range MTU
    // (iOS commonly negotiates 185) simply gets more, smaller chunks.
    // The chunk ceiling is the bulk channel's own `framing.max_chunk_size`
    // where it states one: it is a property of that channel's encoder, not of
    // this handler.
    let chunk_limit = framing_of(bulk_char)
        .and_then(|f| f.max_chunk_size)
        .filter(|n| *n > 0)
        .unwrap_or(DEFAULT_CHUNK_LIMIT);
    let chunks = encode_tutu_restore(
        rgb,
        width as usize,
        height as usize,
        chunk_limit.min(frag_capacity),
    )?;

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
        // Which commands open a session, and in what order, is the spec's to
        // say — the bytes are already in their templates, and a sibling device
        // on this platform with a different opener should be a spec change.
        // An absent key is "unspecified", so the pre-key default applies. An
        // empty list is a statement — this device opens no session — and must
        // not be turned back into the default, or a device that says it wants
        // no preamble gets SmartDawn's.
        let declared = image_feature(spec).and_then(|f| f.session_open.as_ref());
        let session_open: Vec<&str> = match declared {
            Some(names) => names.iter().map(String::as_str).collect(),
            None => DEFAULT_SESSION_OPEN.to_vec(),
        };
        for name in session_open {
            let command = commands
                .get(name)
                .ok_or_else(|| ProtocolError::CommandNotFound {
                    uuid: command_char.uuid.clone(),
                    command: name.to_string(),
                })?;
            // The spec's `sn` is `auto: sequence`, which encodes as 0 unless a
            // stateful caller supplies it. Reuse the fragment serial this
            // packet is about to consume: it costs no extra state, and it
            // keeps ui_end_sync and doodle_start distinguishable to firmware
            // that de-duplicates DNX messages by serial (both went out as
            // sn=0 before, which the live-verified unit tolerated but nothing
            // guarantees others do).
            let params = HashMap::from([("sn".to_string(), serial as f64)]);
            let packet = encode_command(command, &params)?;
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
/// for the format. Returns the ordered `TUTU_RESTORE` chunk payloads, each no
/// larger than `chunk_budget` bytes (header included) so every chunk fits the
/// one BLE write the device honors.
fn encode_tutu_restore(
    rgb: &[u8],
    width: usize,
    height: usize,
    chunk_budget: usize,
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

    // Every chunk repeats the palette header, and the flush logic below can
    // overshoot its threshold by up to two runs' tokens (the run emitted
    // after the per-pixel check plus the final flush after the loop). A
    // budget that cannot carry header + that slack cannot make progress, so
    // reject it with the fix spelled out rather than emitting chunks the
    // `biggest > frag_capacity` backstop then refuses one by one.
    if chunk_budget < header_len + 2 * MAX_RUN_TOKENS {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "the {}-color palette needs {header_len}-byte chunk headers but only \
                 {chunk_budget} B fit one BLE write — raise the ATT MTU (need >= {} bytes) \
                 before pushing images",
                palette.len(),
                header_len + 2 * MAX_RUN_TOKENS + FRAG_HEADER_LEN + 3
            ),
        });
    }

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

    // Column-major traversal, exactly like the vendor encoder. The flush
    // threshold leaves room for the two emits that can land after a check —
    // this pixel's run and the post-loop flush, MAX_RUN_TOKENS each — so no
    // chunk can exceed the budget.
    for x in 0..width {
        for y in 0..height {
            if header_len + tokens.len() + 2 * MAX_RUN_TOKENS > chunk_budget {
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

    /// Shared with device_api's routing tests — one fixture, so an edit to
    /// the command templates or framing cannot leave one test module
    /// exercising a stale spec shape while the other passes.
    const SPEC_YAML: &str = include_str!("test_specs/smartdawn_doodle.yaml");

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

    /// Parse a variant of the test spec with one substring swapped, so a case
    /// can change exactly one declaration and watch the encoding follow.
    fn spec_with(from: &str, to: &str) -> DeviceSpec {
        assert!(
            SPEC_YAML.contains(from),
            "fixture no longer contains {from:?} — the substitution below is stale"
        );
        parse_device_spec(&SPEC_YAML.replace(from, to)).unwrap()
    }

    /// The session-open sequence comes from the spec, not from this file.
    ///
    /// The three cases below are the difference between "driven by the spec"
    /// and "happens to agree with the spec": every value the handler reads is
    /// also the value it used to hardcode, so a test that only checks the
    /// shipped spec passes either way. Each of these changes one declaration
    /// and asserts the bytes move with it.
    #[test]
    fn the_session_open_sequence_is_whatever_the_spec_lists() {
        // Reversed: doodle_start (mt 2701) must now precede ui_end_sync
        // (mt 2411). Order is the whole point — the hardware verification
        // found that opening with the wrong command blanks the canvas.
        let reversed = spec_with(
            r#"session_open: ["ui_end_sync", "doodle_start"]"#,
            r#"session_open: ["doodle_start", "ui_end_sync"]"#,
        );
        let frame = encode_doodle_frame(&reversed, &trans_flag(), 20, 20, 0, 509).unwrap();
        assert_eq!(&frame.writes[0].bytes[10..12], &[0x0A, 0x8D]);
        assert_eq!(&frame.writes[1].bytes[10..12], &[0x09, 0x6B]);

        // Shortened: one opener, so one session-open write before the chunks.
        let single = spec_with(
            r#"session_open: ["ui_end_sync", "doodle_start"]"#,
            r#"session_open: ["doodle_start"]"#,
        );
        let frame = encode_doodle_frame(&single, &trans_flag(), 20, 20, 0, 509).unwrap();
        assert_eq!(&frame.writes[0].bytes[10..12], &[0x0A, 0x8D]);
        assert_eq!(
            frame.writes[1].characteristic_uuid, BIN,
            "with one opener the second write is already a pixel chunk"
        );

        // A name the spec's commands do not define is an error naming the
        // command, not a silent fallback to the old hardcoded pair.
        let bogus = spec_with(
            r#"session_open: ["ui_end_sync", "doodle_start"]"#,
            r#"session_open: ["no_such_command"]"#,
        );
        let err = encode_doodle_frame(&bogus, &trans_flag(), 20, 20, 0, 509).unwrap_err();
        assert!(
            format!("{err:?}").contains("no_such_command"),
            "the error should name the missing command, got {err:?}"
        );
    }

    /// The bulk buffer tag comes from the feature, not from this file.
    #[test]
    fn the_bulk_channel_tag_is_whatever_the_feature_declares() {
        // 0x01 is TUTU_DOODLE where 0x04 is TUTU_RESTORE: same channel, same
        // framing, different buffer. It rides in fragment-header byte 3.
        let doodle = spec_with("channel_tag: 0x04", "channel_tag: 0x01");
        let frame = encode_doodle_frame(&doodle, &trans_flag(), 20, 20, 0, 509).unwrap();
        let chunk = frame
            .writes
            .iter()
            .find(|w| w.characteristic_uuid == BIN)
            .expect("a pixel chunk");
        assert_eq!(chunk.bytes[3], 0x01);

        // The command channel is unaffected: its tag is fixed at 0 by its own
        // framing block, which is a statement about the channel rather than
        // about this flow.
        assert_eq!(frame.writes[0].bytes[3], 0);
    }

    /// The chunk ceiling comes from the bulk channel's framing block.
    #[test]
    fn the_chunk_ceiling_is_whatever_the_bulk_channel_declares() {
        // A 20x20 trans flag at a large MTU: with the vendor's 200-byte
        // ceiling it fits few chunks, and a much smaller ceiling must produce
        // strictly more of them. Nothing else changes.
        let wide = encode_doodle_frame(&spec(), &trans_flag(), 20, 20, 1, 509).unwrap();
        let narrow_spec = spec_with("max_chunk_size: 200", "max_chunk_size: 40");
        let narrow = encode_doodle_frame(&narrow_spec, &trans_flag(), 20, 20, 1, 509).unwrap();
        assert!(
            narrow.writes.len() > wide.writes.len(),
            "a smaller declared ceiling must cut the canvas into more chunks: \
             {} vs {}",
            narrow.writes.len(),
            wide.writes.len()
        );
        for w in &narrow.writes {
            assert!(
                w.bytes.len() - FRAG_HEADER_LEN <= 40,
                "every chunk must respect the declared ceiling"
            );
        }
    }

    /// An empty `session_open` is a statement, not a missing one.
    ///
    /// The schema says an empty list means "this device takes pixel data with
    /// no preamble". Reading it as the absent case would send SmartDawn's
    /// openers to a device that said it wants none — and on this platform the
    /// wrong opener is not a no-op, it blanks the canvas.
    #[test]
    fn an_empty_session_open_means_no_preamble_not_the_default() {
        let none = spec_with(
            r#"session_open: ["ui_end_sync", "doodle_start"]"#,
            "session_open: []",
        );
        let frame = encode_doodle_frame(&none, &trans_flag(), 20, 20, 0, 509).unwrap();
        assert!(
            frame.writes.iter().all(|w| w.characteristic_uuid == BIN),
            "an explicit empty opener list must send pixels only, no DDP preamble"
        );

        // And it is genuinely distinct from the absent key, which still gets
        // the pre-key default.
        let absent = spec_with(r#"session_open: ["ui_end_sync", "doodle_start"]"#, "");
        let frame = encode_doodle_frame(&absent, &trans_flag(), 20, 20, 0, 509).unwrap();
        assert_eq!(frame.writes[0].characteristic_uuid, DDP);
    }

    /// A spec pack written before these keys existed still encodes.
    ///
    /// The fallbacks are not dead code: third-party packs update on their own
    /// schedule, and the values they fall back to are the ones this handler
    /// used before the spec could state them, so an older pack behaves exactly
    /// as it did.
    #[test]
    fn a_spec_that_states_none_of_them_falls_back_to_what_it_used_to_do() {
        let bare = parse_device_spec(
            &SPEC_YAML
                .replace(r#"session_open: ["ui_end_sync", "doodle_start"]"#, "")
                .replace("channel_tag: 0x04", "")
                .replace(", max_chunk_size: 200", ""),
        )
        .unwrap();
        let old_way = encode_doodle_frame(&bare, &trans_flag(), 20, 20, 0, 509).unwrap();
        let declared = encode_doodle_frame(&spec(), &trans_flag(), 20, 20, 0, 509).unwrap();
        assert_eq!(old_way.writes.len(), declared.writes.len());
        for (a, b) in old_way.writes.iter().zip(&declared.writes) {
            assert_eq!(a.bytes, b.bytes);
            assert_eq!(a.characteristic_uuid, b.characteristic_uuid);
        }
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
                                                        // Each command's DNX serial is the fragment serial it consumed
                                                        // (packet offset 2..4, big-endian u16, behind the 4-byte fragment
                                                        // header) — distinguishable to firmware that de-dupes by sn.
        assert_eq!(&w[0].bytes[6..8], &[0, 0]);
        assert_eq!(&w[1].bytes[6..8], &[0, 1]);
        // Then the pixel chunk on the BIN char, tag 4, single write.
        assert_eq!(w[2].characteristic_uuid, BIN);
        assert_eq!(&w[2].bytes[..4], &[2, 1, 0, DEFAULT_BULK_TAG]);
    }

    #[test]
    fn later_frames_skip_session_open_and_stream_on_bin() {
        let frame = encode_doodle_frame(&spec(), &trans_flag(), 20, 20, 5, 509).unwrap();
        assert_eq!(frame.packets, 1, "one chunk, no session packets");
        assert_eq!(frame.writes.len(), 1);
        assert_eq!(frame.writes[0].characteristic_uuid, BIN);
        assert_eq!(&frame.writes[0].bytes[..4], &[5, 1, 0, DEFAULT_BULK_TAG]);
    }

    #[test]
    fn chunk_too_big_for_one_write_is_rejected() {
        // The device honors only the first BLE write of a BIN transfer, so a
        // write budget that cannot carry even one chunk header plus its run
        // slack is a hard error naming the fix, not a partial paint.
        let err = encode_doodle_frame(&spec(), &trans_flag(), 20, 20, 5, 20).unwrap_err();
        match err {
            ProtocolError::ImageDimensionsInvalid { reason } => {
                assert!(reason.contains("raise the ATT MTU"), "got: {reason}");
            }
            other => panic!("expected ImageDimensionsInvalid, got {other:?}"),
        }
    }

    #[test]
    fn mid_range_mtu_sizes_chunks_to_the_write_budget() {
        // A 20x20 two-colour checkerboard is ~400 one-pixel runs — several
        // chunks' worth of tokens. At iOS's commonly negotiated MTU 185
        // (payload 182) the old fixed ~200-byte flush built chunks no write
        // could carry and rejected the send outright; the budget-aware
        // encoder must fit every write instead.
        let (w, h) = (20usize, 20usize);
        let mut rgb = Vec::with_capacity(w * h * 3);
        for y in 0..h {
            for x in 0..w {
                let on = (x + y) % 2 == 0;
                rgb.extend_from_slice(if on { &[255, 255, 255] } else { &[255, 0, 0] });
            }
        }
        let frame = encode_doodle_frame(&spec(), &rgb, 20, 20, 5, 182).unwrap();
        assert!(frame.writes.len() > 1, "several small chunks, not one big");
        for wr in &frame.writes {
            assert!(
                wr.bytes.len() <= 182,
                "write of {} B exceeds the 182 B payload",
                wr.bytes.len()
            );
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
        let chunks = encode_tutu_restore(&rgb, 20, 20, DEFAULT_CHUNK_LIMIT).unwrap();
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
        let chunks = encode_tutu_restore(&rgb, 127, 1, DEFAULT_CHUNK_LIMIT).unwrap();
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

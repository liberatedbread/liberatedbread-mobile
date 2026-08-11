// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Builds the "DN" AMX container that the Hangzhou Daniao platform stores as a
//! standalone, disconnect-surviving microapp (the vendor's 图文 / "image-text"
//! program). Paired with [`super::daniao_upload`], which carries the finished
//! container to the device.
//!
//! # It is built entirely on-device — no cloud
//!
//! This is a byte-for-byte port of the SmartDawn H5 bundle's `merge()` and its
//! sub-encoders (`packageText`, `packageImage`, `packageEasyOptions`, and the
//! `TinyProgram` protobuf). The vendor app fetches two things over HTTP —
//! a `cid` and a base template — but neither is content and neither is
//! required:
//!
//! - The base template (`commons/tuwen.amx`, 180 bytes) is a STATIC asset,
//!   identical for every device and every upload. It is bundled here
//!   ([`BASE_AMX`]); the capture's embedded copy matches it byte-for-byte.
//! - The `cid` names the stored slot. Hardware accepts a novel, app-chosen cid
//!   (verified live: a cid the device had never seen was stored and played), so
//!   the caller supplies one.
//!
//! Verified against `smartdawn_capture_a_lot_of_custom_animations.pcapng`: a
//! custom microapp the vendor app built and uploaded, whose 256-byte "DN"
//! header, `TinyProgram` protobuf, embedded base AMX and options block this
//! module reproduces. See the tests.
//!
//! # Layout
//!
//! ```text
//!   [256B "DN" header ][ 180B base AMX ][ options ][ text layer ][ image layer? ]
//!    magic,cid,cn,crc,   tuwen.amx        nn block   packageText   packageImage
//!    TinyProgram@10                                   (1-bit)       (16-color)
//!   └──────────────────────── padded to cn * 4096, header CRC8 over [10..] ──────┘
//! ```
//!
//! A stored microapp always carries a text layer; an image layer is optional.
//! To store the pixel canvas the LED editor draws, the canvas goes in as the
//! IMAGE layer (16-colour palette + 4-bit indices — the same palette ceiling
//! the live doodle path already quantises to) over a blank text layer, exactly
//! as the vendor app composes a picture with no caption.

/// The static base AMX template every stored microapp embeds
/// (`cdn.daniaokeji.com/data/amx/commons/tuwen.amx`). Content-free and
/// device-independent; the capture's embedded copy is byte-identical.
pub const BASE_AMX: &[u8] = include_bytes!("assets/tuwen.amx");

/// The AMX container's own header carries a CRC8 (poly 0x97) at byte 9 over
/// bytes `[10..]`; the transport layer applies the same CRC per packet. Shared
/// with [`super::daniao_upload::crc8`] — identical polynomial, one definition.
pub use super::daniao_upload::crc8;

/// Scroll direction of a stored microapp, matching the vendor's `MoveEnum`
/// mapped through `packageEasyOptions`' move-code table.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scroll {
    /// No scroll — the picture is shown in place (move code 0).
    None,
    Left,
    Right,
    Up,
    Down,
}

impl Scroll {
    /// The move-code byte `packageEasyOptions` writes at options[10] for the
    /// first (index-1) layer: LEFT=3, RIGHT=4, UP=1, DOWN=2, none=0.
    fn move_code(self) -> u8 {
        match self {
            Scroll::None => 0,
            Scroll::Up => 1,
            Scroll::Down => 2,
            Scroll::Left => 3,
            Scroll::Right => 4,
        }
    }
}

/// Everything the caller chooses about a stored microapp. The pixels come
/// separately; this is the choreography around them.
#[derive(Debug, Clone)]
pub struct StoredProgram<'a> {
    /// Display name stored on the device (the vendor truncates to 15 chars;
    /// this does not, leaving policy to the caller/UI).
    pub name: &'a str,
    /// The slot id to store under. Novel ids are accepted by hardware.
    pub cid: u32,
    /// How long the program runs, in seconds. `frames` is `time * 20` (the
    /// device plays at 20 fps), so this is also the scroll duration.
    pub time_secs: u32,
    /// Scroll direction, or [`Scroll::None`] for a static picture.
    pub scroll: Scroll,
    /// Scroll speed byte, as the vendor's 1..=N slider (options[12]).
    pub speed: u8,
    /// The picture: a 16-colour-max RGB888 canvas, row-major, `w*h*3` bytes.
    pub image: ImageLayer<'a>,
}

/// The pixel canvas to store, already reduced to at most 16 distinct colours
/// (the LED editor quantises to this before it ever reaches here).
#[derive(Debug, Clone)]
pub struct ImageLayer<'a> {
    pub width: u32,
    pub height: u32,
    /// Row-major RGB888, `width * height * 3` bytes.
    pub rgb: &'a [u8],
}

/// A scrolling-text program: everything about the marquee except the glyphs.
#[derive(Debug, Clone)]
pub struct StoredText<'a> {
    pub name: &'a str,
    pub cid: u32,
    pub time_secs: u32,
    pub scroll: Scroll,
    pub speed: u8,
    pub text: TextContent<'a>,
}

/// A rendered text bitmap: one byte per pixel, `0` = off / `non-zero` = lit,
/// row-major. The width is the text's full run — usually wider than the panel,
/// which is what lets it scroll. The caller rasterises the string (font choice
/// and layout are a UI concern); this only packs the pixels the vendor's
/// `packageText` way.
#[derive(Debug, Clone)]
pub struct TextContent<'a> {
    pub width: u32,
    pub height: u32,
    /// `width * height` bytes, row-major; each `0` (off) or non-zero (lit).
    pub bits: &'a [u8],
}

/// A multi-frame animation: several equally-sized RGB screens the device plays
/// in sequence. Stored in the vendor's raw "DNMX" `.eff` format, NOT the "DN"
/// AMX microapp — a different container, played the same way (by cid).
#[derive(Debug, Clone)]
pub struct StoredAnimation<'a> {
    pub name: &'a str,
    pub cid: u32,
    pub width: u32,
    pub height: u32,
    /// Each frame is row-major RGB888, `width * height * 3` bytes, in play order.
    pub frames: &'a [&'a [u8]],
}

/// The largest palette the image layer's 4-bit indices can address.
const MAX_PALETTE: usize = 16;

use crate::error::ProtocolError;

/// Build the "DN" AMX container for a stored image microapp.
///
/// Returns the finished, `4096`-multiple-padded container ready to hand to the
/// upload transport. Errors only on a malformed canvas (wrong byte count, zero
/// size, or more than 16 colours — which the editor's quantiser prevents).
pub fn build_image_container(program: &StoredProgram<'_>) -> Result<Vec<u8>, ProtocolError> {
    let img = &program.image;
    let expected = (img.width as usize)
        .checked_mul(img.height as usize)
        .and_then(|px| px.checked_mul(3))
        .ok_or_else(|| ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "{}x{} overflows the pixel buffer size",
                img.width, img.height
            ),
        })?;
    if expected == 0 {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!("{}x{} has no pixels", img.width, img.height),
        });
    }
    if img.rgb.len() != expected {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "expected {expected} bytes of RGB888 for {}x{}, got {}",
                img.width,
                img.height,
                img.rgb.len()
            ),
        });
    }

    // Data layers, in the vendor's order: a blank text layer (no caption) then
    // the picture as the image layer. `merge()` always emits a text layer even
    // for a pure picture, so a stored image with no caption is a blank one.
    let text = package_text_blank(img.width, img.height);
    let image = package_image(img)?;

    // Two records: text is layer index 1, image is index 2. Rainbow is off for
    // an image (its palette supplies the colours).
    let nn = options_block(&[
        easy_options(
            program.time_secs,
            program.scroll,
            program.speed,
            1,
            LayerType::Text,
            false,
            program.cid,
        ),
        easy_options(
            program.time_secs,
            program.scroll,
            program.speed,
            2,
            LayerType::Image,
            false,
            program.cid,
        ),
    ]);
    assemble_container(
        program.name,
        program.cid,
        program.time_secs,
        &nn,
        &[&text, &image],
    )
}

/// Build the "DN" AMX container for scrolling text — a 1-bit marquee.
///
/// The text bitmap is usually wider than the panel; the device scrolls it in
/// the chosen direction, which is how the vendor's (and the captured "Fuuuck")
/// marquee works. Colour is rainbow, matching the vendor default and the
/// capture. This is the same container the image path builds, with a single
/// real text layer and no image (the vendor's `Q`-falsy, `count = 1` case).
pub fn build_text_container(program: &StoredText<'_>) -> Result<Vec<u8>, ProtocolError> {
    let t = &program.text;
    let expected = (t.width as usize)
        .checked_mul(t.height as usize)
        .ok_or_else(|| ProtocolError::ImageDimensionsInvalid {
            reason: format!("{}x{} overflows the text bitmap size", t.width, t.height),
        })?;
    if expected == 0 {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!("{}x{} text bitmap has no pixels", t.width, t.height),
        });
    }
    if t.bits.len() != expected {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "expected {expected} bytes of 1-bit text for {}x{}, got {}",
                t.width,
                t.height,
                t.bits.len()
            ),
        });
    }
    let text = package_text(t);
    // count = 1: text only. Rainbow on (the marquee supplies no palette).
    let nn = options_block(&[easy_options(
        program.time_secs,
        program.scroll,
        program.speed,
        1,
        LayerType::Text,
        true,
        program.cid,
    )]);
    assemble_container(program.name, program.cid, program.time_secs, &nn, &[&text])
}

/// Build the raw "DNMX" `.eff` container for a multi-frame animation.
///
/// A port of the vendor H5 bundle's `startExec` + `encode` + `writeItemHeader`
/// (the video/animation path), which is a DIFFERENT container from the "DN" AMX
/// microapp above — raw column-major RGB frames rather than a palette-indexed
/// program:
///
/// ```text
///   [ 4096B "DNMX" header ][ 4096B "DNX2" item header ][ frame0 ][ frame1 ]…  → pad to 4096
///    magic,w,h,frame_size,   magic,size,frames,w,h,      column-major RGB, one screen each
///    cid,ts,name,descriptor  name
/// ```
///
/// Each frame is `width*height*3` bytes, **column-major** (all rows of column 0,
/// then column 1, …) — the vendor's `encode` traversal, and the same axis order
/// its live doodle path uses. No compression (`rgbd = 0`), so the pixels are
/// raw. Uploaded as `file_type: 0` with a `<cid>.eff` path (see
/// [`super::stored_upload`]).
///
/// NOTE: unlike the "DN" builder, this format has no capture to byte-match — it
/// is ported from the vendor code and its structure is asserted in tests, but
/// the render wants hardware confirmation.
pub fn build_animation_container(anim: &StoredAnimation<'_>) -> Result<Vec<u8>, ProtocolError> {
    let width = anim.width as usize;
    let height = anim.height as usize;
    let frame_px = width
        .checked_mul(height)
        .and_then(|px| px.checked_mul(3))
        .ok_or_else(|| ProtocolError::ImageDimensionsInvalid {
            reason: format!("{width}x{height} overflows the frame size"),
        })?;
    if frame_px == 0 {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!("{width}x{height} has no pixels"),
        });
    }
    if anim.frames.is_empty() {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: "animation has no frames".to_string(),
        });
    }
    for (i, frame) in anim.frames.iter().enumerate() {
        if frame.len() != frame_px {
            return Err(ProtocolError::ImageDimensionsInvalid {
                reason: format!(
                    "frame {i} is {} bytes, expected {frame_px} for {width}x{height}",
                    frame.len()
                ),
            });
        }
    }
    let frame_count = anim.frames.len();
    if frame_count > u16::MAX as usize {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!("{frame_count} frames exceeds the u16 frame count"),
        });
    }

    // The vendor rounds each frame's byte length up to a multiple of 4 when not
    // compressing; for a 3-byte-pixel canvas that only matters when width*height
    // is not a multiple of 4.
    let stride = frame_px.next_multiple_of(4);

    // Both header blocks are 4096 bytes; the DNMX descriptor points at the DNX2
    // block at offset 4096, and the frames follow at 8192.
    let mut buf = vec![0u8; 8192];

    // ── DNMX header (block 0) ──
    buf[0..4].copy_from_slice(b"DNMX");
    // [4] is 3 when a frame fits a u16 size field, 4 when it needs u32.
    buf[4] = if stride > u16::MAX as usize { 4 } else { 3 };
    buf[5] = 1;
    write_u16_le(&mut buf, 6, anim.width as u16);
    write_u16_le(&mut buf, 8, anim.height as u16);
    write_u32_le(&mut buf, 10, frame_px as u32);
    write_u32_le(&mut buf, 14, anim.cid);
    // [18..22] timestamp — left 0; it is metadata the device does not key on,
    // and a deterministic build is worth more than a clock read here.
    write_name(&mut buf, 38, anim.name, 24);
    buf[124] = 20;
    // Item descriptor @128: offset of the DNX2 block, the (4-padded) frame size,
    // the frame count, then the vendor's [0,0,1,_,_,0] trailer.
    write_u32_le(&mut buf, 128, 4096);
    if stride > u16::MAX as usize {
        write_u32_le(&mut buf, 132, stride as u32);
        write_u16_le(&mut buf, 136, frame_count as u16);
        buf[138] = 0;
        buf[139] = 0;
        buf[140] = 1;
    } else {
        write_u16_le(&mut buf, 132, stride as u16);
        write_u16_le(&mut buf, 134, frame_count as u16);
        buf[136] = 0;
        buf[137] = 0;
        buf[138] = 1;
    }

    // ── DNX2 item header (block 1, at offset 4096) ──
    let h = 4096;
    buf[h..h + 4].copy_from_slice(b"DNX2");
    buf[h + 4] = 3;
    write_u32_le(&mut buf, h + 5, stride as u32);
    write_u32_le(&mut buf, h + 9, frame_count as u32);
    write_u16_le(&mut buf, h + 13, anim.width as u16);
    write_u16_le(&mut buf, h + 15, anim.height as u16);
    write_name(&mut buf, h + 56, anim.name, 32);
    buf[h + 157] = 1;
    buf[h + 158] = 20;

    // ── Frames (from offset 8192), each column-major, padded to `stride` ──
    for frame in anim.frames {
        let mut out = vec![0u8; stride];
        let mut o = 0;
        for col in 0..width {
            for row in 0..height {
                let src = (row * width + col) * 3;
                out[o] = frame[src];
                out[o + 1] = frame[src + 1];
                out[o + 2] = frame[src + 2];
                o += 3;
            }
        }
        buf.extend_from_slice(&out);
    }

    // Pad the whole container to a 4096-byte multiple.
    let pad = buf.len().next_multiple_of(4096) - buf.len();
    buf.extend(std::iter::repeat_n(0u8, pad));
    Ok(buf)
}

/// Copy up to `max` bytes of `name` into `buf` at `at` (the vendor truncates the
/// stored name to a fixed field).
fn write_name(buf: &mut [u8], at: usize, name: &str, max: usize) {
    let bytes = name.as_bytes();
    let n = bytes.len().min(max);
    buf[at..at + n].copy_from_slice(&bytes[..n]);
}

fn write_u16_le(buf: &mut [u8], at: usize, v: u16) {
    buf[at..at + 2].copy_from_slice(&v.to_le_bytes());
}

fn write_u32_le(buf: &mut [u8], at: usize, v: u32) {
    buf[at..at + 4].copy_from_slice(&v.to_le_bytes());
}

/// The options block `nn`: a 10-byte header stating the record count and total
/// options length, then the 51-byte `packageEasyOptions` records in order.
fn options_block(records: &[[u8; 51]]) -> Vec<u8> {
    let count = records.len();
    let payload_len = 2 + 51 * count; // the vendor's `2 + 51*(Q?2:1)`
    let mut nn = Vec::with_capacity(10 + 51 * count);
    nn.extend_from_slice(&[0xFD, 0x0A, 0x00, 0x00]);
    nn.push((payload_len >> 8) as u8);
    nn.push(payload_len as u8);
    nn.extend_from_slice(&[0x00, 0x00, 0x00, count as u8]);
    for record in records {
        nn.extend_from_slice(record);
    }
    nn
}

/// Lay down a finished "DN" AMX container: the 256-byte header (TinyProgram
/// protobuf, cid, block count, CRC), then the base AMX, the options block and
/// the data layers, padded to a 4096-byte multiple. Shared by every "DN"
/// container (image, text, image+text).
fn assemble_container(
    name: &str,
    cid: u32,
    time_secs: u32,
    nn: &[u8],
    layers: &[&[u8]],
) -> Result<Vec<u8>, ProtocolError> {
    let binsize = BASE_AMX.len();
    let layers_len: usize = layers.iter().map(|l| l.len()).sum();
    let datasize = nn.len() + layers_len;
    let frames = time_secs.saturating_mul(20);

    // Total unpadded length, then round up to a 4096 multiple (the vendor's
    // `floor((un + 4095) / 4096)`).
    let unpadded = 256 + binsize + datasize;
    let cn = unpadded.div_ceil(4096).max(1);
    if cn > u8::MAX as usize {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!("container needs {cn} 4096-byte blocks; the cn header byte allows 255"),
        });
    }
    let total = cn * 4096;

    let tiny = encode_tiny_program(name, cid, frames, binsize as u32, datasize as u32);
    let mut buf = vec![0u8; total];
    buf[0] = b'D';
    buf[1] = b'N';
    buf[2] = 1; // nr
    buf[3] = 254; // pn
    buf[4..8].copy_from_slice(&cid.to_le_bytes());
    buf[8] = cn as u8;
    // buf[9] is the header CRC, filled after the body is laid down.
    buf[10..10 + tiny.len()].copy_from_slice(&tiny);

    let mut off = 256;
    buf[off..off + binsize].copy_from_slice(BASE_AMX);
    off += binsize;
    buf[off..off + nn.len()].copy_from_slice(nn);
    off += nn.len();
    for layer in layers {
        buf[off..off + layer.len()].copy_from_slice(layer);
        off += layer.len();
    }

    // Header CRC8 covers everything from offset 10 to the end, padding included.
    buf[9] = crc8(&buf[10..]);
    Ok(buf)
}

/// The `TinyProgram` protobuf as `merge()` fills it, emitting exactly the
/// fields the vendor object carries (including set-but-zero scalars, which
/// protobufjs writes because the property is present). Field order follows the
/// proto declaration; empty repeated fields (caplist, authlist) are omitted.
fn encode_tiny_program(name: &str, cid: u32, frames: u32, binsize: u32, datasize: u32) -> Vec<u8> {
    let mut b = Vec::new();
    pb_varint(&mut b, 1, 0); // version
    pb_bytes(&mut b, 2, name.as_bytes()); // name
    pb_bytes(&mut b, 3, name.as_bytes()); // description (== name)
    pb_bytes(&mut b, 4, b""); // tags (empty string, still written)
    pb_varint(&mut b, 5, 1); // apptype = 1 (image-text microapp)
    pb_varint(&mut b, 6, cid as u64); // cid
    pb_varint(&mut b, 7, frames as u64); // frames = time * 20
    pb_varint(&mut b, 8, binsize as u64); // binsize = base AMX length
    pb_varint(&mut b, 9, datasize as u64); // datasize = nn + text + image
    pb_bytes(&mut b, 10, &[0x08, 0x00]); // colorcap = ColorItem { type: 0 }
    pb_bytes(&mut b, 12, &[0x00]); // events = [0] (packed repeated int32)
    pb_varint(&mut b, 13, 0); // authcheck = 0
    b
}

/// A blank text layer sized to the canvas: `packageText` of an all-off bitmap.
/// The 8-byte header is `[253, 1, height, width, len_hi, len_lo, type=1,
/// bytes_per_row]` followed by `bytes_per_row * height` zero bytes.
fn package_text_blank(width: u32, height: u32) -> Vec<u8> {
    let bytes_per_row = width.div_ceil(8);
    let data_len = (bytes_per_row * height) as usize;
    let mut out = Vec::with_capacity(8 + data_len);
    out.push(253);
    out.push(1);
    out.push(height as u8);
    out.push(width as u8);
    out.push((data_len >> 8) as u8);
    out.push(data_len as u8);
    out.push(1); // type index
    out.push(bytes_per_row as u8);
    out.resize(8 + data_len, 0); // all pixels off
    out
}

/// A real 1-bit text layer from a rendered bitmap (`packageText`).
///
/// Header `[253, 1, height, width, len_hi, len_lo, type=1, bytes_per_row]` then,
/// per row, `bytes_per_row` bytes with each pixel packed LSB-first (column `c`
/// sets bit `c % 8` of byte `c / 8`) — the vendor's bit order.
fn package_text(t: &TextContent<'_>) -> Vec<u8> {
    let width = t.width as usize;
    let height = t.height as usize;
    let bytes_per_row = t.width.div_ceil(8) as usize;
    let mut out = Vec::with_capacity(8 + bytes_per_row * height);
    out.push(253);
    out.push(1);
    out.push(t.height as u8);
    out.push(t.width as u8);
    let data_len = bytes_per_row * height;
    out.push((data_len >> 8) as u8);
    out.push(data_len as u8);
    out.push(1); // type index
    out.push(bytes_per_row as u8);
    for row in 0..height {
        for byte_col in 0..bytes_per_row {
            let mut byte = 0u8;
            for bit in 0..8 {
                let col = byte_col * 8 + bit;
                if col < width && t.bits[row * width + col] != 0 {
                    byte |= 1 << bit;
                }
            }
            out.push(byte);
        }
    }
    out
}

/// The image layer: `packageImage`'s format — an 8-byte header
/// `[254, 1, height, width, len_hi, len_lo, type=2, 16]`, then the palette as
/// RGB triplets, then the per-pixel 4-bit indices packed two to a byte.
///
/// The vendor runs k-means to reduce to 16 colours; the canvas reaching here is
/// already at most 16 (the editor's quantiser guarantees it), so the palette is
/// just the distinct colours in first-seen order — lossless, and no k-means
/// needed.
fn package_image(img: &ImageLayer<'_>) -> Result<Vec<u8>, ProtocolError> {
    let mut palette: Vec<[u8; 3]> = Vec::with_capacity(MAX_PALETTE);
    let mut indices: Vec<u8> = Vec::with_capacity((img.width * img.height) as usize);
    for px in img.rgb.chunks_exact(3) {
        let color = [px[0], px[1], px[2]];
        let idx = match palette.iter().position(|c| *c == color) {
            Some(i) => i,
            None => {
                if palette.len() >= MAX_PALETTE {
                    return Err(ProtocolError::ImageDimensionsInvalid {
                        reason: format!(
                            "stored image has more than {MAX_PALETTE} colours; \
                             quantise the canvas before storing"
                        ),
                    });
                }
                palette.push(color);
                palette.len() - 1
            }
        };
        indices.push(idx as u8);
    }

    let palette_bytes: Vec<u8> = palette.iter().flatten().copied().collect();
    let packed = pack_u4(&indices);
    let data_len = palette_bytes.len() + packed.len();

    let mut out = Vec::with_capacity(8 + data_len);
    out.push(254);
    out.push(1);
    out.push(img.height as u8);
    out.push(img.width as u8);
    out.push((data_len >> 8) as u8);
    out.push(data_len as u8);
    out.push(2); // type index
    out.push(16); // palette ceiling
    out.extend_from_slice(&palette_bytes);
    out.extend_from_slice(&packed);
    Ok(out)
}

/// Pack a slice of 4-bit values two-per-byte, high nibble first — the vendor's
/// `u8tu4` (a trailing odd value pairs with 0).
fn pack_u4(vals: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(vals.len().div_ceil(2));
    let mut i = 0;
    while i < vals.len() {
        let hi = vals[i] & 0x0F;
        let lo = vals.get(i + 1).copied().unwrap_or(0) & 0x0F;
        out.push((hi << 4) | lo);
        i += 2;
    }
    out
}

/// Which layer an options record describes (its `TypeEnum` byte at options[8]).
#[derive(Clone, Copy)]
enum LayerType {
    Text,
    Image,
}

impl LayerType {
    fn type_byte(self) -> u8 {
        match self {
            LayerType::Text => 0,
            LayerType::Image => 1,
        }
    }
}

/// One 51-byte `packageEasyOptions` record.
///
/// `[0..4]=0`, `[4..8]=time` (LE u32), `[8]=layer type`, `[9]=layer index`,
/// `[10]=move code` (index-1 layer only), `[11]=dir`, `[12]=speed`,
/// `[13]=rainbow?0:1`. For the image layer, `[42..46]=cid`, `[46..50]=slot`,
/// `[50]=transparency`. Everything else is zero.
///
/// The move code lands only on layer 1, matching the vendor: the layers scroll
/// together, driven by the first record's direction. `rainbow` off writes the
/// [13]=1 byte the image path uses (its palette supplies colour); on ([13]=0)
/// is the marquee default.
#[allow(clippy::too_many_arguments)]
fn easy_options(
    time_secs: u32,
    scroll: Scroll,
    speed: u8,
    index: u8,
    layer: LayerType,
    rainbow: bool,
    cid: u32,
) -> [u8; 51] {
    let mut o = [0u8; 51];
    o[4..8].copy_from_slice(&time_secs.to_le_bytes());
    o[8] = layer.type_byte();
    o[9] = index;
    o[10] = if index == 1 { scroll.move_code() } else { 0 };
    o[11] = 0; // dir
    o[12] = speed;
    o[13] = if rainbow { 0 } else { 1 };
    if matches!(layer, LayerType::Image) {
        o[42..46].copy_from_slice(&cid.to_le_bytes());
        o[46..50].copy_from_slice(&0u32.to_le_bytes()); // slot
        o[50] = 0; // transparency
    }
    o
}

// ── protobuf wire helpers (proto3, explicit-presence like protobufjs) ────────

fn pb_varint(out: &mut Vec<u8>, field: u8, value: u64) {
    out.push(field << 3); // wire type 0
    write_varint(out, value);
}

fn pb_bytes(out: &mut Vec<u8>, field: u8, bytes: &[u8]) {
    out.push((field << 3) | 2); // wire type 2
    write_varint(out, bytes.len() as u64);
    out.extend_from_slice(bytes);
}

fn write_varint(out: &mut Vec<u8>, mut value: u64) {
    loop {
        let b = (value & 0x7F) as u8;
        value >>= 7;
        if value == 0 {
            out.push(b);
            break;
        }
        out.push(b | 0x80);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Solid 2x2 red canvas, so palette + index packing is easy to reason about.
    fn red_2x2() -> Vec<u8> {
        let mut v = Vec::new();
        for _ in 0..4 {
            v.extend_from_slice(&[0xFF, 0x00, 0x00]);
        }
        v
    }

    #[test]
    fn base_amx_matches_the_captured_embedded_copy() {
        // The container in smartdawn_capture_a_lot_of_custom_animations.pcapng
        // embedded this exact 180-byte template at offset 256.
        assert_eq!(BASE_AMX.len(), 180);
        assert_eq!(&BASE_AMX[..4], &[0x4B, 0xFF, 0xFF, 0xFF]);
    }

    #[test]
    fn tiny_program_matches_the_captured_bytes() {
        // Reconstruct the capture's TinyProgram: name="Fuuuck", cid=79008,
        // frames=1200 (time 60 * 20), binsize=180, datasize=141. These bytes
        // are lifted verbatim from frame 5684's DN header (offset 10..).
        let program = StoredProgram {
            name: "Fuuuck",
            cid: 79008,
            time_secs: 60,
            scroll: Scroll::Left,
            speed: 5,
            image: ImageLayer {
                width: 2,
                height: 2,
                rgb: &red_2x2(),
            },
        };
        let tiny = encode_tiny_program(program.name, program.cid, 1200, 180, 141);
        let want = hex(
            "08 00 12 06 46 75 75 75 63 6b 1a 06 46 75 75 75 63 6b 22 00 28 01 \
             30 a0 e9 04 38 b0 09 40 b4 01 48 8d 01 52 02 08 00 62 01 00 68 00",
        );
        assert_eq!(
            tiny, want,
            "TinyProgram protobuf must byte-match the capture"
        );
    }

    #[test]
    fn text_record_and_options_header_match_the_capture() {
        // The capture's options block (frame 5684, offset 436) was a text-only
        // microapp: a 10-byte header for a single record (count=1), then the
        // text record with time=60 (0x3c), move=LEFT (3), speed=5, rainbow on.
        // build_text_container reproduces exactly this shape, so byte-match the
        // whole nn block against the capture.
        let text = easy_options(60, Scroll::Left, 5, 1, LayerType::Text, true, 79008);
        assert_eq!(&text[0..4], &[0, 0, 0, 0]);
        assert_eq!(&text[4..8], &60u32.to_le_bytes());
        assert_eq!(text[8], 0, "text layer type byte");
        assert_eq!(text[9], 1, "layer index");
        assert_eq!(text[10], 3, "move code LEFT");
        assert_eq!(text[12], 5, "speed");
        assert_eq!(text[13], 0, "rainbow on");

        // The full options block for one text record, byte-for-byte from the
        // capture: fd 0a 00 00 00 35 00 00 00 01 then the 51-byte record.
        let nn = options_block(&[text]);
        assert_eq!(&nn[0..10], &[0xFD, 0x0A, 0, 0, 0x00, 0x35, 0, 0, 0, 1]);
        assert_eq!(nn.len(), 61);
    }

    #[test]
    fn text_layer_packs_bits_lsb_first() {
        // A 10x1 marquee: pixels 0 and 9 lit. Row byte 0 has bit 0 set (col 0);
        // byte 1 has bit 1 set (col 9 -> 9%8=1).
        let bits: Vec<u8> = (0..10).map(|c| u8::from(c == 0 || c == 9)).collect();
        let layer = package_text(&TextContent {
            width: 10,
            height: 1,
            bits: &bits,
        });
        assert_eq!(&layer[0..4], &[253, 1, 1, 10], "header h/w");
        assert_eq!(layer[6], 1, "text type byte");
        assert_eq!(layer[7], 2, "bytes per row = ceil(10/8)");
        assert_eq!(&layer[8..10], &[0b0000_0001, 0b0000_0010]);
    }

    #[test]
    fn text_container_is_a_valid_single_layer_dn_blob() {
        let bits = vec![1u8; 48 * 12];
        let buf = build_text_container(&StoredText {
            name: "hello",
            cid: 900002,
            time_secs: 8,
            scroll: Scroll::Left,
            speed: 4,
            text: TextContent {
                width: 48,
                height: 12,
                bits: &bits,
            },
        })
        .unwrap();
        assert_eq!(buf.len() % 4096, 0);
        assert_eq!(&buf[0..2], b"DN");
        assert_eq!(&buf[4..8], &900002u32.to_le_bytes());
        assert_eq!(buf[9], crc8(&buf[10..]));
        assert_eq!(&buf[256..256 + BASE_AMX.len()], BASE_AMX);
        // Single text record: nn count byte is 1.
        assert_eq!(buf[256 + BASE_AMX.len() + 9], 1, "one options record");
    }

    #[test]
    fn animation_container_has_dnmx_and_dnx2_headers_and_column_major_frames() {
        // Two 2x2 frames: frame 0 = red top row / green bottom row (row-major),
        // frame 1 all blue. Column-major means the wire order visits rows within
        // a column, so frame 0 becomes R,G (col 0) then R,G (col 1).
        let f0: Vec<u8> = vec![
            0xFF, 0, 0, 0xFF, 0, 0, // row 0: red, red
            0, 0xFF, 0, 0, 0xFF, 0, // row 1: green, green
        ];
        let f1 = vec![0u8, 0, 0xFF].repeat(4);
        let frames: Vec<&[u8]> = vec![&f0, &f1];
        let buf = build_animation_container(&StoredAnimation {
            name: "anim",
            cid: 900003,
            width: 2,
            height: 2,
            frames: &frames,
        })
        .unwrap();

        assert_eq!(buf.len() % 4096, 0);
        assert_eq!(&buf[0..4], b"DNMX");
        assert_eq!(buf[4], 3, "frame fits a u16 size field");
        assert_eq!(&buf[6..8], &2u16.to_le_bytes(), "width");
        assert_eq!(&buf[8..10], &2u16.to_le_bytes(), "height");
        assert_eq!(&buf[10..14], &12u32.to_le_bytes(), "frame byte size");
        assert_eq!(&buf[14..18], &900003u32.to_le_bytes(), "cid");
        // Item descriptor: DNX2 lives at offset 4096, 2 frames.
        assert_eq!(&buf[128..132], &4096u32.to_le_bytes());
        assert_eq!(&buf[132..134], &12u16.to_le_bytes(), "padded frame size");
        assert_eq!(&buf[134..136], &2u16.to_le_bytes(), "frame count");

        // DNX2 item header at 4096.
        assert_eq!(&buf[4096..4100], b"DNX2");
        assert_eq!(&buf[4096 + 9..4096 + 13], &2u32.to_le_bytes(), "frames");

        // Frame 0 begins at 8192, column-major: col0 rows -> red, green.
        let frame0 = &buf[8192..8192 + 12];
        assert_eq!(&frame0[0..3], &[0xFF, 0, 0], "col0 row0 = red");
        assert_eq!(&frame0[3..6], &[0, 0xFF, 0], "col0 row1 = green");
        assert_eq!(&frame0[6..9], &[0xFF, 0, 0], "col1 row0 = red");
        assert_eq!(&frame0[9..12], &[0, 0xFF, 0], "col1 row1 = green");
        // Frame 1 (all blue) follows.
        assert_eq!(&buf[8204..8207], &[0, 0, 0xFF]);
    }

    #[test]
    fn animation_rejects_empty_and_mismatched_frames() {
        assert!(build_animation_container(&StoredAnimation {
            name: "x",
            cid: 1,
            width: 2,
            height: 2,
            frames: &[],
        })
        .is_err());

        let short = vec![0u8; 3];
        let frames: Vec<&[u8]> = vec![&short];
        assert!(build_animation_container(&StoredAnimation {
            name: "x",
            cid: 1,
            width: 2,
            height: 2,
            frames: &frames,
        })
        .is_err());
    }

    #[test]
    fn text_bitmap_wrong_length_is_rejected() {
        assert!(build_text_container(&StoredText {
            name: "x",
            cid: 1,
            time_secs: 1,
            scroll: Scroll::None,
            speed: 1,
            text: TextContent {
                width: 8,
                height: 2,
                bits: &[1, 2, 3],
            },
        })
        .is_err());
    }

    #[test]
    fn image_layer_builds_palette_and_indices() {
        let rgb = red_2x2();
        let img = ImageLayer {
            width: 2,
            height: 2,
            rgb: &rgb,
        };
        let layer = package_image(&img).unwrap();
        // header [254,1,h,w,len_hi,len_lo,2,16], one palette colour (red), then
        // four 4-bit zero indices packed into two bytes.
        assert_eq!(&layer[0..4], &[254, 1, 2, 2]);
        assert_eq!(layer[6], 2, "image type byte");
        assert_eq!(layer[7], 16, "palette ceiling");
        let data = &layer[8..];
        assert_eq!(&data[0..3], &[0xFF, 0x00, 0x00], "palette entry 0 = red");
        assert_eq!(&data[3..5], &[0x00, 0x00], "all four indices are 0");
        let len = ((layer[4] as usize) << 8) | layer[5] as usize;
        assert_eq!(len, data.len());
    }

    #[test]
    fn over_palette_canvas_is_rejected() {
        // 17 distinct colours in a 17x1 canvas.
        let mut rgb = Vec::new();
        for i in 0..17u8 {
            rgb.extend_from_slice(&[i, 0, 0]);
        }
        let img = ImageLayer {
            width: 17,
            height: 1,
            rgb: &rgb,
        };
        assert!(package_image(&img).is_err());
    }

    #[test]
    fn container_is_4096_aligned_with_valid_header() {
        let rgb = red_2x2();
        let program = StoredProgram {
            name: "hi",
            cid: 900001,
            time_secs: 10,
            scroll: Scroll::None,
            speed: 3,
            image: ImageLayer {
                width: 2,
                height: 2,
                rgb: &rgb,
            },
        };
        let buf = build_image_container(&program).unwrap();
        assert_eq!(buf.len() % 4096, 0);
        assert_eq!(&buf[0..2], b"DN");
        assert_eq!(&buf[4..8], &900001u32.to_le_bytes());
        assert_eq!(buf[8] as usize, buf.len() / 4096, "cn = block count");
        // Header CRC is over [10..] and self-consistent.
        assert_eq!(buf[9], crc8(&buf[10..]));
        // Base AMX sits right after the 256-byte header.
        assert_eq!(&buf[256..256 + BASE_AMX.len()], BASE_AMX);
    }

    fn hex(s: &str) -> Vec<u8> {
        s.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect()
    }
}

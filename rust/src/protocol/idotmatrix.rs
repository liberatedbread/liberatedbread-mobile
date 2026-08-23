// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Image-frame encoder for iDotMatrix BLE pixel displays — the framed
//! CRC32 upload protocol behind `protocol_handler: "idotmatrix_image"`
//! (`vendor/protocol-specs/device-specs/devices/idotmatrix.yaml`).
//!
//! THE WIRE FORMAT (spec `device.notes`, hardware-verified on 0xFA02 per the
//! spec's evidence list — 8none1 btsnoop captures, derkalle4's library, the
//! Homey client — and byte-for-byte confirmed in the vendor app):
//!
//! The device accepts an encoded image FILE — every hardware-verified client
//! uploads a PNG (static) or GIF (animated) and the device decodes it; there
//! is no raw-pixel wire format. The file is cut into payload chunks (4096
//! bytes each), and every chunk is prefixed with a 16-byte header:
//!
//! ```text
//!   [0-1]   this framed packet's total length (payload + 16), uint16 LE
//!   [2]     command type: 1=GIF, 2=Image, 3=Text, 6=Phrase
//!   [3]     sub-type: 0x00 in framed uploads
//!   [4]     chunk flag: 0x00=first, 0x02=continuation
//!   [5-8]   total data (file) length, uint32 LE
//!   [9-12]  CRC32 of the ENTIRE file (java.util.zip.CRC32 = ISO-HDLC), LE
//!   [13-14] time/delay, uint16 LE
//!   [15]    speed/type byte
//!   [16+]   payload
//! ```
//!
//! Bytes [0-1] are LITTLE-endian (spec: 8none1's "de 0c" decodes 0x0cde =
//! 3294; on full chunks the 4096+16 = 0x1010 value is byte-palindromic, which
//! masked the endianness until a short final chunk exposed it). The framed
//! packets are then written to the 0xFA02 Write Data characteristic as plain
//! BLE-write-sized slices (509 bytes at a negotiated MTU, 18 otherwise — the
//! caller's `max_payload_per_write` decides).
//!
//! SPEC-DRIVEN: the DIY-mode opener's bytes come from the spec's
//! `enter_diy_mode` command template, the upload characteristic is resolved
//! as the writable characteristic DECLARING that command (the spec documents
//! the app routing every command through it), and the chunk ceiling honours a
//! `framing.max_chunk_size` on that characteristic when one is declared.
//! This module carries only the algorithms YAML cannot express: PNG assembly
//! and the CRC32.
//!
//! What this handler produces per frame is a complete STATIC image upload
//! (command type 2). The spec's `animation: true` rides on GIF uploads
//! (command type 1) — a whole-file format this per-frame encoder cannot
//! assemble, so "animation" here means replacing the displayed image each
//! frame, exactly like the live paths of the other displays.

use super::image_upload::{
    declared_max_chunk_size, image_feature, is_writable, validate_rgb_canvas, MIN_PAYLOAD_PER_WRITE,
};
use super::{EncodedFrame, EncodedWrite};
use crate::codec::types::encode_command;
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, DeviceSpec};
use std::collections::HashMap;

/// `protocol_handler` name this module implements (see the device spec's
/// top-level `protocol_handler` key).
pub const HANDLER_NAME: &str = "idotmatrix_image";

/// Framed-upload command type for a static image (spec: "2=Image").
const CMD_TYPE_IMAGE: u8 = 0x02;
/// Framed-upload sub-type (spec: "always 0x00 in framed uploads").
const SUB_TYPE_FRAMED: u8 = 0x00;
/// Chunk flags (spec: "0=first, 2=continuation").
const CHUNK_FIRST: u8 = 0x00;
const CHUNK_CONTINUATION: u8 = 0x02;
const FRAME_HEADER_LEN: usize = 16;

/// Command that opens the DIY image canvas before the first frame, resolved
/// from the spec's command templates (jadx evidence in the spec: the app's
/// DIY flow, `BleProtocolN.java:138-140`). Sent with `mode: 1` (enable).
const SESSION_OPEN_DEFAULT: &str = "enter_diy_mode";

/// Payload bytes per framed chunk when the upload characteristic declares no
/// `framing.max_chunk_size`.
// SPEC-GAP: the 4096-byte framed-chunk payload is stated in the spec's
// `device.notes` ("16-byte header per 4096-byte payload chunk") and declared
// as `framing.max_chunk_size` only on the APP-PROVEN-UNUSED 0xFEE9
// characteristic — it should become `framing.max_chunk_size` on the 0xFA02
// Write Data characteristic the upload actually runs over.
const DEFAULT_CHUNK_PAYLOAD: usize = 4096;

/// Header time/delay and speed/type bytes for a static image.
// SPEC-GAP: the spec names the fields ("[13-14] time/delay", "[15]
// speed/type") but states no value for a static image upload — the spec
// should grow e.g. `image_upload.frame_header_defaults` for them. Zero, the
// neutral value, until it does.
const IMAGE_TIME_DELAY: u16 = 0;
const IMAGE_SPEED_TYPE: u8 = 0;

/// Encode one RGB888 frame as a complete framed static-image upload.
///
/// Frame 0 opens the DIY canvas first (the spec's `enter_diy_mode` template,
/// `mode: 1`); later frames re-upload the image only. Every write targets the
/// characteristic that declares the opener — the 0xFA02 Write Data channel on
/// the vendored spec.
pub fn encode_framed_upload(
    spec: &DeviceSpec,
    rgb: &[u8],
    width: u32,
    height: u32,
    frame_index: u32,
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

    let upload_char = resolve_upload_characteristic(spec)?;
    let mut writes = Vec::new();
    let mut packets: u32 = 0;

    if frame_index == 0 {
        // An absent `session_open` falls back to the DIY opener this handler
        // always needed; an EMPTY declared list is a statement ("no
        // preamble") and is honoured as one — same contract as the generic
        // pipeline.
        let feature = image_feature(spec);
        let declared = feature.and_then(|f| f.session_open.as_ref());
        let openers: Vec<&str> = match declared {
            Some(names) => names.iter().map(String::as_str).collect(),
            None => vec![SESSION_OPEN_DEFAULT],
        };
        if !openers.is_empty() {
            let commands =
                upload_char
                    .commands
                    .as_ref()
                    .ok_or_else(|| ProtocolError::NoCommands {
                        uuid: upload_char.uuid.clone(),
                    })?;
            // `mode: 1` enables the DIY canvas; a declared opener that does
            // not reference {mode} simply ignores the entry.
            let params = HashMap::from([("mode".to_string(), 1.0)]);
            for name in openers {
                let command = commands
                    .get(name)
                    .ok_or_else(|| ProtocolError::CommandNotFound {
                        uuid: upload_char.uuid.clone(),
                        command: name.to_string(),
                    })?;
                let bytes = encode_command(command, &params)?;
                push_packet(&mut writes, &upload_char.uuid, bytes, max_payload_per_write);
                packets += 1;
            }
        }
    }

    // The image file the device decodes, and the whole-file facts every
    // chunk header repeats.
    let png = encode_png(rgb, width, height);
    let total_len = png.len() as u32;
    let crc = crc32_ieee(&png);

    // Chunk ceiling: the upload characteristic's own declaration when it
    // makes one, the protocol's documented 4096 otherwise. The u16 packet
    // length field bounds it either way.
    let chunk_payload = declared_max_chunk_size(upload_char)
        .unwrap_or(DEFAULT_CHUNK_PAYLOAD)
        .min(u16::MAX as usize - FRAME_HEADER_LEN);

    for (i, chunk) in png.chunks(chunk_payload).enumerate() {
        let mut packet = Vec::with_capacity(FRAME_HEADER_LEN + chunk.len());
        packet.extend_from_slice(&((chunk.len() + FRAME_HEADER_LEN) as u16).to_le_bytes());
        packet.push(CMD_TYPE_IMAGE);
        packet.push(SUB_TYPE_FRAMED);
        packet.push(if i == 0 {
            CHUNK_FIRST
        } else {
            CHUNK_CONTINUATION
        });
        packet.extend_from_slice(&total_len.to_le_bytes());
        packet.extend_from_slice(&crc.to_le_bytes());
        packet.extend_from_slice(&IMAGE_TIME_DELAY.to_le_bytes());
        packet.push(IMAGE_SPEED_TYPE);
        packet.extend_from_slice(chunk);
        push_packet(
            &mut writes,
            &upload_char.uuid,
            packet,
            max_payload_per_write,
        );
        packets += 1;
    }

    Ok(EncodedFrame { writes, packets })
}

/// The characteristic the upload runs over: the writable characteristic that
/// declares the DIY opener this flow sends. On the vendored spec that is the
/// 0xFA02 Write Data characteristic — the one the spec documents every
/// command routing through — and never the app-proven-unused 0xFEE9 pair.
fn resolve_upload_characteristic(spec: &DeviceSpec) -> Result<&Characteristic, ProtocolError> {
    spec.services
        .iter()
        .flat_map(|s| &s.characteristics)
        .filter(|c| is_writable(c))
        .find(|c| {
            c.commands
                .as_ref()
                .is_some_and(|m| m.contains_key(SESSION_OPEN_DEFAULT))
        })
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: format!(
                "spec has no writable characteristic declaring '{SESSION_OPEN_DEFAULT}', \
                 which anchors the framed upload channel"
            ),
        })
}

/// One logical packet, split into BLE-write-sized slices in order. The
/// protocol has no per-write framing — the characteristic is a byte stream —
/// so slicing at the write budget reproduces exactly what the documented
/// clients send (509-byte chunks at a negotiated MTU, 18 otherwise).
fn push_packet(
    writes: &mut Vec<EncodedWrite>,
    uuid: &str,
    packet: Vec<u8>,
    max_payload_per_write: usize,
) {
    for part in packet.chunks(max_payload_per_write) {
        writes.push(EncodedWrite {
            characteristic_uuid: uuid.to_string(),
            bytes: part.to_vec(),
        });
    }
}

// ── PNG assembly ─────────────────────────────────────────────────────────────
//
// A minimal, deterministic PNG writer: 8-bit truecolor, filter 0 on every
// row, and STORED (uncompressed) deflate blocks inside the zlib stream. A
// stored-block PNG is a fully conformant PNG — the device runs a real
// decoder — and determinism is what makes golden-byte tests possible. At the
// panel's 64x64 ceiling the file is ~12 KiB, so compression buys nothing
// worth a dependency.

/// Deterministic PNG encoding of a row-major RGB888 canvas.
fn encode_png(rgb: &[u8], width: u32, height: u32) -> Vec<u8> {
    let mut png = Vec::with_capacity(rgb.len() + rgb.len() / 32 + 128);
    // Signature.
    png.extend_from_slice(&[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);

    // IHDR: dimensions, bit depth 8, color type 2 (truecolor), default
    // compression/filter, no interlace.
    let mut ihdr = Vec::with_capacity(13);
    ihdr.extend_from_slice(&width.to_be_bytes());
    ihdr.extend_from_slice(&height.to_be_bytes());
    ihdr.extend_from_slice(&[8, 2, 0, 0, 0]);
    push_png_chunk(&mut png, b"IHDR", &ihdr);

    // Raw scanline data: each row prefixed by filter byte 0 (None).
    let row_len = width as usize * 3;
    let mut raw = Vec::with_capacity((row_len + 1) * height as usize);
    for row in rgb.chunks(row_len) {
        raw.push(0);
        raw.extend_from_slice(row);
    }

    // zlib stream: CMF/FLG 0x78 0x01 (deflate, 32K window, fastest — valid
    // for stored blocks), stored blocks of <= 65535 bytes, Adler-32 trailer.
    let mut idat = vec![0x78, 0x01];
    let mut blocks = raw.chunks(65535).peekable();
    loop {
        let block = blocks.next().unwrap_or(&[]);
        let last = blocks.peek().is_none();
        idat.push(u8::from(last));
        idat.extend_from_slice(&(block.len() as u16).to_le_bytes());
        idat.extend_from_slice(&(!(block.len() as u16)).to_le_bytes());
        idat.extend_from_slice(block);
        if last {
            break;
        }
    }
    idat.extend_from_slice(&adler32(&raw).to_be_bytes());
    push_png_chunk(&mut png, b"IDAT", &idat);

    push_png_chunk(&mut png, b"IEND", &[]);
    png
}

/// One PNG chunk: length (BE), type, data, CRC32 over type + data (BE).
fn push_png_chunk(png: &mut Vec<u8>, chunk_type: &[u8; 4], data: &[u8]) {
    png.extend_from_slice(&(data.len() as u32).to_be_bytes());
    png.extend_from_slice(chunk_type);
    png.extend_from_slice(data);
    let mut crc = Crc32::new();
    crc.update(chunk_type);
    crc.update(data);
    png.extend_from_slice(&crc.finish().to_be_bytes());
}

/// CRC-32/ISO-HDLC — the algorithm of both PNG chunks and
/// `java.util.zip.CRC32`, which the spec names for the upload header's
/// whole-file checksum. Bitwise: the inputs are a few KiB at most.
struct Crc32(u32);

impl Crc32 {
    fn new() -> Self {
        Crc32(0xFFFF_FFFF)
    }
    fn update(&mut self, bytes: &[u8]) {
        for &b in bytes {
            self.0 ^= u32::from(b);
            for _ in 0..8 {
                let low = self.0 & 1;
                self.0 >>= 1;
                if low != 0 {
                    self.0 ^= 0xEDB8_8320;
                }
            }
        }
    }
    fn finish(self) -> u32 {
        !self.0
    }
}

fn crc32_ieee(bytes: &[u8]) -> u32 {
    let mut crc = Crc32::new();
    crc.update(bytes);
    crc.finish()
}

/// Adler-32 (RFC 1950), the zlib stream trailer.
fn adler32(bytes: &[u8]) -> u32 {
    const MOD: u32 = 65_521;
    let (mut a, mut b) = (1u32, 0u32);
    for chunk in bytes.chunks(5552) {
        for &byte in chunk {
            a += u32::from(byte);
            b += a;
        }
        a %= MOD;
        b %= MOD;
    }
    (b << 16) | a
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A minimal spec shaped like the vendored `idotmatrix.yaml`: the same
    /// characteristic layout (an unused 0xFEE9 pair carrying the only
    /// `framing` block, the 0xFA02 command/upload channel), the same command
    /// template, the same feature bounds.
    const SPEC_YAML: &str = r#"
device:
  name: "iDotMatrix"
  manufacturer: "iDotMatrix / Tech"
  manufacturer_status: "unsupported"
  protocol: "ble"
  category: "display"
  identification:
    local_name_prefix: "IDM-"
protocol_handler: "idotmatrix_image"
features:
  - type: "image_upload"
    format: "png"
    animation: true
    max_width: 64
    max_height: 64
services:
  - uuid: "0000fee9-0000-1000-8000-00805f9b34fb"
    name: "Unused library-default service"
    characteristics:
      - uuid: "d44bc439-abfd-45a2-b575-925416129600"
        name: "Data Write/Read (app-proven-unused)"
        properties: ["write", "read"]
        framing:
          length_prefix: true
          checksum: "crc32"
          max_chunk_size: 4096
  - uuid: "0000fa02-0000-1000-8000-00805f9b34fb"
    name: "iDotMatrix Command/Upload Service"
    characteristics:
      - uuid: "0000fa02-0000-1000-8000-00805f9b34fb"
        name: "Write Data"
        properties: ["write"]
        commands:
          enter_diy_mode:
            description: "Enter DIY image mode"
            template: [0x05, 0x00, 0x04, 0x01, "{mode}"]
            parameters:
              mode:
                type: "uint8"
                min: 0
                max: 1
      - uuid: "0000fa03-0000-1000-8000-00805f9b34fb"
        name: "Notify/Ack Data"
        properties: ["read", "notify"]
"#;

    const UPLOAD_CHAR: &str = "0000fa02-0000-1000-8000-00805f9b34fb";

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC_YAML).unwrap()
    }

    /// A 2x2 canvas: red, green / blue, white.
    fn tiny() -> Vec<u8> {
        vec![255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255]
    }

    /// The exact PNG this encoder must produce for the 2x2 canvas, derived
    /// field by field from the PNG/zlib RFCs (checksums cross-checked
    /// against Python's zlib, an independent implementation):
    ///
    /// - signature `89 50 4E 47 0D 0A 1A 0A`
    /// - IHDR: len 13, `49 48 44 52`, width/height 2 (u32 BE), bit depth 8,
    ///   color type 2, compression/filter/interlace 0; CRC32 `FD D4 9A 73`
    /// - IDAT: len 25, `49 44 41 54`; zlib header `78 01`; one final stored
    ///   block `01`, LEN `0E 00` (14 = 2 rows x (1 filter byte + 6 px
    ///   bytes)), NLEN `F1 FF`; raw scanlines `00 FF 00 00 00 FF 00` and
    ///   `00 00 00 FF FF FF FF`; Adler-32 `1F EE 05 FB`; CRC32
    ///   `DE DD EC 2B`
    /// - IEND: len 0, `49 45 4E 44`, CRC32 `AE 42 60 82`
    const TINY_PNG: [u8; 82] = [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // signature
        0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, // IHDR len + type
        0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, // 2 x 2
        0x08, 0x02, 0x00, 0x00, 0x00, // depth 8, truecolor
        0xFD, 0xD4, 0x9A, 0x73, // IHDR CRC
        0x00, 0x00, 0x00, 0x19, 0x49, 0x44, 0x41, 0x54, // IDAT len + type
        0x78, 0x01, // zlib CMF/FLG
        0x01, 0x0E, 0x00, 0xF1, 0xFF, // final stored block, LEN, NLEN
        0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, // row 0 (filter 0)
        0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, // row 1 (filter 0)
        0x1F, 0xEE, 0x05, 0xFB, // Adler-32
        0xDE, 0xDD, 0xEC, 0x2B, // IDAT CRC
        0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, // IEND len + type
        0xAE, 0x42, 0x60, 0x82, // IEND CRC
    ];

    #[test]
    fn png_assembly_matches_the_rfc_derivation() {
        assert_eq!(encode_png(&tiny(), 2, 2), TINY_PNG);
    }

    #[test]
    fn first_frame_opens_diy_mode_then_uploads_one_framed_chunk() {
        let frame = encode_framed_upload(&spec(), &tiny(), 2, 2, 0, 509).unwrap();
        assert_eq!(frame.packets, 2, "one opener + one framed chunk");
        assert_eq!(frame.writes.len(), 2, "both fit a 509-byte write");
        for w in &frame.writes {
            assert_eq!(w.characteristic_uuid, UPLOAD_CHAR);
        }
        // The opener's bytes come from the spec template with mode=1.
        assert_eq!(frame.writes[0].bytes, vec![0x05, 0x00, 0x04, 0x01, 0x01]);

        // The framed packet, header derived field by field from the spec's
        // documented layout: the 82-byte PNG fits one chunk, so
        // [0-1] = 82 + 16 = 98 = 0x0062 LE; type 2 (Image); sub-type 0;
        // flag 0 (first); total length 82 u32 LE; CRC32 of the whole PNG
        // 0x0B87B603 (java.util.zip.CRC32, cross-checked against Python's
        // zlib.crc32) LE; time/delay 0; speed/type 0; then the file.
        let packet = &frame.writes[1].bytes;
        assert_eq!(
            &packet[..FRAME_HEADER_LEN],
            &[
                0x62, 0x00, // packet length 98 LE
                0x02, 0x00, // Image, framed sub-type
                0x00, // first chunk
                0x52, 0x00, 0x00, 0x00, // total data length 82 LE
                0x03, 0xB6, 0x87, 0x0B, // CRC32 0x0B87B603 LE
                0x00, 0x00, // time/delay
                0x00, // speed/type
            ]
        );
        assert_eq!(&packet[FRAME_HEADER_LEN..], TINY_PNG);
    }

    #[test]
    fn later_frames_skip_the_opener() {
        let frame = encode_framed_upload(&spec(), &tiny(), 2, 2, 3, 509).unwrap();
        assert_eq!(frame.packets, 1);
        assert_eq!(&frame.writes[0].bytes[2..4], &[0x02, 0x00], "image chunk");
    }

    #[test]
    fn an_empty_declared_session_open_means_no_preamble() {
        let yaml = SPEC_YAML.replace("animation: true", "animation: true\n    session_open: []");
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_framed_upload(&s, &tiny(), 2, 2, 0, 509).unwrap();
        assert_eq!(frame.packets, 1, "no opener even on frame 0");
        assert_eq!(&frame.writes[0].bytes[2..4], &[0x02, 0x00]);
    }

    #[test]
    fn a_declared_session_open_names_the_commands_it_wants() {
        // Point the opener list at a second command and the bytes must
        // follow the spec, not this module's default.
        let yaml = SPEC_YAML
            .replace(
                "animation: true",
                r#"animation: true
    session_open: ["screen_on"]"#,
            )
            .replace(
                "        commands:\n",
                "        commands:\n          screen_on:\n            description: \"on\"\n            value: [0x05, 0x00, 0x07, 0x01, 0x01]\n",
            );
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_framed_upload(&s, &tiny(), 2, 2, 0, 509).unwrap();
        assert_eq!(frame.writes[0].bytes, vec![0x05, 0x00, 0x07, 0x01, 0x01]);
    }

    #[test]
    fn a_small_write_budget_slices_the_framed_packet() {
        // 18-byte writes are the protocol's own unnegotiated-MTU case... but
        // the pipeline floor is 20, so use that: the 98-byte packet becomes
        // ceil(98/20) = 5 writes after the opener.
        let frame = encode_framed_upload(&spec(), &tiny(), 2, 2, 0, 20).unwrap();
        assert_eq!(frame.packets, 2, "slicing does not change packet count");
        assert_eq!(frame.writes.len(), 1 + 5);
        let rebuilt: Vec<u8> = frame.writes[1..]
            .iter()
            .flat_map(|w| w.bytes.iter().copied())
            .collect();
        assert_eq!(&rebuilt[FRAME_HEADER_LEN..], TINY_PNG, "stream is intact");
    }

    #[test]
    fn a_file_larger_than_the_chunk_ceiling_continues_with_flag_two() {
        // Shrink the declared ceiling instead of inflating the canvas: give
        // the upload characteristic a 64-byte max_chunk_size and the 82-byte
        // PNG must split into a first + a continuation packet.
        let yaml = SPEC_YAML.replace(
            "        commands:",
            "        framing: { max_chunk_size: 64 }\n        commands:",
        );
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_framed_upload(&s, &tiny(), 2, 2, 1, 509).unwrap();
        assert_eq!(frame.packets, 2);
        let first = &frame.writes[0].bytes;
        let second = &frame.writes[1].bytes;
        // First: 64 payload bytes -> length 80, flag 0.
        assert_eq!(&first[..2], &[80, 0]);
        assert_eq!(first[4], CHUNK_FIRST);
        // Continuation: remaining 18 bytes -> length 34, flag 2; the
        // whole-file length and CRC repeat unchanged.
        assert_eq!(&second[..2], &[34, 0]);
        assert_eq!(second[4], CHUNK_CONTINUATION);
        assert_eq!(&second[5..13], &first[5..13]);
        // Payloads concatenate back to the file.
        let mut file = first[FRAME_HEADER_LEN..].to_vec();
        file.extend_from_slice(&second[FRAME_HEADER_LEN..]);
        assert_eq!(file, TINY_PNG);
    }

    #[test]
    fn canvas_over_the_declared_ceiling_is_rejected() {
        let err =
            encode_framed_upload(&spec(), &vec![0u8; 65 * 64 * 3], 65, 64, 0, 509).unwrap_err();
        assert!(
            format!("{err:?}").contains("65"),
            "the error should quote the offending width, got {err:?}"
        );
    }

    #[test]
    fn wrong_buffer_length_is_rejected() {
        let err = encode_framed_upload(&spec(), &[0; 5], 2, 2, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn a_spec_without_the_diy_opener_errors_helpfully() {
        let yaml = SPEC_YAML.replace("enter_diy_mode:", "not_the_command:");
        let s = parse_device_spec(&yaml).unwrap();
        let err = encode_framed_upload(&s, &tiny(), 2, 2, 0, 509).unwrap_err();
        assert!(
            format!("{err:?}").contains("enter_diy_mode"),
            "the error should name the missing anchor command, got {err:?}"
        );
    }

    #[test]
    fn the_unused_fee9_characteristic_is_never_the_target() {
        // The library-default 0xFEE9 pair is writable and carries the only
        // framing block, which is exactly the trap: resolution anchors on
        // the DIY opener, so every write must land on 0xFA02.
        let frame = encode_framed_upload(&spec(), &tiny(), 2, 2, 0, 509).unwrap();
        assert!(frame
            .writes
            .iter()
            .all(|w| w.characteristic_uuid == UPLOAD_CHAR));
    }

    #[test]
    fn crc32_matches_the_java_util_zip_reference() {
        // zlib.crc32(b"123456789") == 0xCBF43926, the ISO-HDLC check value.
        assert_eq!(crc32_ieee(b"123456789"), 0xCBF4_3926);
    }

    #[test]
    fn adler32_matches_the_rfc_1950_reference() {
        // zlib.adler32(b"123456789") == 0x091E01DE.
        assert_eq!(adler32(b"123456789"), 0x091E_01DE);
    }
}

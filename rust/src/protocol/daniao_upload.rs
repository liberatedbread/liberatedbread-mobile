// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Device-side STORAGE upload for the Hangzhou Daniao platform — persisting an
//! effect/animation on the controller so it plays standalone. Decoded from an
//! over-the-air capture (SmartDawn app, 2026-08-08) and confirmed live: the
//! handshake was replayed byte-for-byte and the device accepted it (mt=2931),
//! including for a cid it had never seen.
//!
//! The whole transfer runs on the Uploader characteristic (`27923001-…`, the
//! writable char with NO `daniao_fragment` framing — it carries its own
//! 8-byte header instead); the device answers on the DDP Notify characteristic
//! with M_UPLOAD_START_RESPONSE (mt=2931, i1==0 = accept, i3 = resume offset)
//! and M_UPLOAD_COMPLETE (mt=2934, i1==0 = success).
//!
//! Packet layout (both packet kinds share an 8-byte header):
//!   [id u8][packetnum u16 BE][0x11][0xFF][field u16 BE][crc8]
//! - START packet: `field` = packetnum; body = `UploadRequest` protobuf; the
//!   crc8 covers the WHOLE packet (header included, with the crc byte zeroed).
//! - DATA packet:  `field` = remaining (counts down packetnum-1 → 0); body =
//!   up to `framesize` payload bytes; the crc8 covers the PAYLOAD ONLY.
//!
//! CRC8 is polynomial 0x97, MSB-first, init 0, no reflection/final-xor.
//!
//! This module encodes the TRANSPORT for an already-built file blob (e.g. a
//! `.eff` effect, or a `DN` AMX animation container). Building the AMX
//! container for a CUSTOM animation (256-byte "DN" header + `TinyProgram`
//! protobuf, padded to 4096) is a separate step that needs the `TinyProgram`
//! schema — see the device spec's Uploader notes.

use super::EncodedWrite;
use crate::error::ProtocolError;
use crate::spec::types::{CharacteristicProperty, DeviceSpec};

/// Upload framing constants read from the captured vendor transfer.
const HEADER_LEN: usize = 8;
const HDR_CONST_3: u8 = 0x11;
const HDR_CONST_4: u8 = 0xFF;
/// Frames larger than this are split; the vendor uses 500.
pub const DEFAULT_FRAME_SIZE: usize = 500;

/// CRC8 used by the uploader channel: polynomial 0x97, MSB-first, init 0.
///
/// Shared with the container builder ([`super::daniao_store`]), whose "DN"
/// header CRC uses the same polynomial. Verified against
/// `smartdawn_capture_a_lot_of_custom_animations.pcapng`: a captured data
/// packet's header CRC equals `crc8` of its 500-byte payload.
pub fn crc8(data: &[u8]) -> u8 {
    let mut crc = 0u8;
    for &byte in data {
        let mut a = crc ^ byte;
        for _ in 0..8 {
            a = if a & 0x80 != 0 {
                (a << 1) ^ 0x97
            } else {
                a << 1
            };
        }
        crc = a;
    }
    crc
}

/// Append a protobuf `varint` scalar field (wire type 0).
fn push_varint_field(out: &mut Vec<u8>, field: u8, mut value: u64) {
    out.push(field << 3); // (field << 3) | 0  (wire type 0 = varint)
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

/// Append a protobuf length-delimited (wire type 2) bytes field.
fn push_len_field(out: &mut Vec<u8>, field: u8, bytes: &[u8]) {
    out.push((field << 3) | 2);
    push_varint_len(out, bytes.len() as u64);
    out.extend_from_slice(bytes);
}

fn push_varint_len(out: &mut Vec<u8>, mut value: u64) {
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

/// The `UploadRequest` protobuf body. `crc8` field 7 stays 0 — the real CRC is
/// in the packet header. `path` is omitted for animations (they key on `cid`).
fn upload_request(
    id: u8,
    file_type: u32,
    size: u32,
    packetnum: u32,
    framesize: u32,
    cid: u32,
    path: Option<&str>,
) -> Vec<u8> {
    let mut b = Vec::new();
    push_varint_field(&mut b, 1, id as u64); // id
    push_varint_field(&mut b, 2, file_type as u64); // type
    push_varint_field(&mut b, 3, size as u64); // size
    push_varint_field(&mut b, 4, 0); // offset
    push_varint_field(&mut b, 5, packetnum as u64); // packetnum
    push_varint_field(&mut b, 6, framesize as u64); // framesize
    push_varint_field(&mut b, 7, 0); // crc8 (real one is in the header)
    if let Some(p) = path {
        push_len_field(&mut b, 8, p.as_bytes()); // path
    }
    push_varint_field(&mut b, 9, cid as u64); // cid
    b
}

fn header(id: u8, packetnum: u16, field: u16) -> [u8; HEADER_LEN] {
    [
        id,
        (packetnum >> 8) as u8,
        packetnum as u8,
        HDR_CONST_3,
        HDR_CONST_4,
        (field >> 8) as u8,
        field as u8,
        0, // crc, filled by the caller for the right scope
    ]
}

/// One uploader transfer, encoded as ordered writes to the Uploader
/// characteristic: a START packet then `packetnum` DATA packets.
pub struct UploadTransfer {
    pub writes: Vec<EncodedWrite>,
    /// The characteristic every write targets (resolved from the spec).
    pub characteristic_uuid: String,
}

/// Encode a full storage upload of `payload` (a pre-built file blob) as the
/// ordered writes to the Uploader characteristic, resolved from `spec`.
///
/// `id` is the transfer id echoed by the device in its response; `file_type`
/// is the vendor file kind (0 = effect `.eff`, 3 = animation); `cid` names the
/// stored item (the device accepts a novel cid). `path` is included only when
/// `Some` (effects use `"<cid>.eff"`; animations omit it).
pub fn encode_upload(
    spec: &DeviceSpec,
    id: u8,
    file_type: u32,
    cid: u32,
    payload: &[u8],
    path: Option<&str>,
    framesize: usize,
) -> Result<UploadTransfer, ProtocolError> {
    if payload.is_empty() {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: "upload payload is empty".to_string(),
        });
    }
    let framesize = framesize.clamp(1, u16::MAX as usize);
    let char_uuid =
        uploader_characteristic(spec).ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: "spec has no Uploader characteristic (writable, no daniao_fragment framing)"
                .to_string(),
        })?;

    let size = payload.len();
    let packetnum = size.div_ceil(framesize);
    if packetnum > u16::MAX as usize {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!("upload needs {packetnum} packets; the 16-bit count allows 65535"),
        });
    }

    let mut writes = Vec::with_capacity(packetnum + 1);

    // START packet: 8-byte header (field = packetnum) + UploadRequest; the crc
    // covers the whole packet.
    let body = upload_request(
        id,
        file_type,
        size as u32,
        packetnum as u32,
        framesize as u32,
        cid,
        path,
    );
    let mut start = Vec::with_capacity(HEADER_LEN + body.len());
    start.extend_from_slice(&header(id, packetnum as u16, packetnum as u16));
    start.extend_from_slice(&body);
    start[7] = crc8(&start); // whole packet, crc byte currently 0
    writes.push(EncodedWrite {
        characteristic_uuid: char_uuid.clone(),
        bytes: start,
    });

    // DATA packets: field = remaining, counting down to 0; crc over payload.
    for (i, chunk) in payload.chunks(framesize).enumerate() {
        let remaining = (packetnum - 1 - i) as u16;
        let mut hdr = header(id, packetnum as u16, remaining);
        hdr[7] = crc8(chunk); // payload only
        let mut bytes = Vec::with_capacity(HEADER_LEN + chunk.len());
        bytes.extend_from_slice(&hdr);
        bytes.extend_from_slice(chunk);
        writes.push(EncodedWrite {
            characteristic_uuid: char_uuid.clone(),
            bytes,
        });
    }

    Ok(UploadTransfer {
        writes,
        characteristic_uuid: char_uuid,
    })
}

/// The Uploader characteristic: the writable char that does NOT declare
/// `daniao_fragment` framing (the DDP/BIN command channels do; the uploader
/// carries its own 8-byte header instead).
fn uploader_characteristic(spec: &DeviceSpec) -> Option<String> {
    for service in &spec.services {
        for c in &service.characteristics {
            let writable = c.properties.iter().any(|p| {
                matches!(
                    p,
                    CharacteristicProperty::Write | CharacteristicProperty::WriteWithoutResponse
                )
            });
            if !writable {
                continue;
            }
            let has_fragment = c
                .framing
                .as_ref()
                .and_then(|v| v.get("scheme"))
                .and_then(|s| s.as_str())
                .is_some();
            if !has_fragment {
                return Some(c.uuid.clone());
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    const SPEC: &str = r#"
device:
  name: "SmartDawn"
  manufacturer: "Daniao"
  manufacturer_status: "active"
  protocol: "ble"
  category: "light"
  identification:
    local_name_prefix: "DN"
    service_uuids: ["00000074-1972-1925-3022-077119514e44"]
services:
  - uuid: "00000074-1972-1925-3022-077119514e44"
    name: "Daniao DDP Service"
    characteristics:
      - uuid: "01020074-1972-1925-3022-077119514e44"
        name: "DDP Write"
        properties: ["write"]
        framing: { scheme: "daniao_fragment", channel_tag: 0 }
      - uuid: "02020074-1972-1925-3022-077119514e44"
        name: "BIN Write"
        properties: ["write"]
        framing: { scheme: "daniao_fragment" }
      - uuid: "27923001-2072-1925-3022-077119514e44"
        name: "Uploader"
        properties: ["write"]
"#;

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC).unwrap()
    }

    #[test]
    fn crc8_matches_captured_start_packet() {
        // The captured START packet header CRC was 0xD4 over the whole packet.
        let body = upload_request(0x27, 3, 4096, 9, 500, 78847, None);
        let mut pkt = Vec::new();
        pkt.extend_from_slice(&header(0x27, 9, 9));
        pkt.extend_from_slice(&body);
        pkt[7] = crc8(&pkt);
        assert_eq!(pkt[7], 0xD4);
    }

    #[test]
    fn start_packet_byte_matches_the_capture() {
        // smartdawn_longer2.pcapng frame 6214, byte for byte.
        let want =
            "27 00 09 11 ff 00 09 d4 08 27 10 03 18 80 20 20 00 28 09 30 f4 03 38 00 48 ff e7 04";
        let transfer = encode_upload(&spec(), 0x27, 3, 78847, &vec![0u8; 4096], None, 500).unwrap();
        let start = &transfer.writes[0].bytes;
        let got: String = start
            .iter()
            .map(|b| format!("{b:02x}"))
            .collect::<Vec<_>>()
            .join(" ");
        assert_eq!(got, want);
        assert_eq!(
            transfer.characteristic_uuid,
            "27923001-2072-1925-3022-077119514e44"
        );
    }

    #[test]
    fn data_packets_count_down_and_crc_the_payload() {
        // 1200 bytes at framesize 500 -> 3 data packets (500,500,200), remaining
        // 2,1,0; each crc is over the payload slice only.
        let payload: Vec<u8> = (0..1200u32).map(|i| (i * 7) as u8).collect();
        let transfer = encode_upload(&spec(), 0x10, 3, 900001, &payload, None, 500).unwrap();
        assert_eq!(transfer.writes.len(), 1 + 3, "start + 3 data packets");
        let data = &transfer.writes[1..];
        let rems: Vec<u16> = data
            .iter()
            .map(|w| ((w.bytes[5] as u16) << 8) | w.bytes[6] as u16)
            .collect();
        assert_eq!(rems, vec![2, 1, 0]);
        for (i, w) in data.iter().enumerate() {
            let chunk = &w.bytes[HEADER_LEN..];
            assert_eq!(w.bytes[7], crc8(chunk), "data crc is over the payload only");
            let expect_len = if i < 2 { 500 } else { 200 };
            assert_eq!(chunk.len(), expect_len);
        }
    }

    #[test]
    fn effect_upload_includes_the_path_field() {
        let transfer = encode_upload(&spec(), 1, 0, 5, &[1, 2, 3], Some("5.eff"), 500).unwrap();
        // field 8 (path) tag 0x42 appears in the start body for effects.
        assert!(transfer.writes[0].bytes.contains(&0x42));
    }

    #[test]
    fn empty_payload_is_rejected() {
        assert!(encode_upload(&spec(), 1, 0, 5, &[], None, 500).is_err());
    }
}

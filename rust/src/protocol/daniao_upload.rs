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

/// One inbound message on the stored-upload response channel (the spec's
/// `response_characteristic`), decoded from a single BLE notification.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum UploadEvent {
    /// M_UPLOAD_START_RESPONSE with i1==0: the device accepts the transfer.
    /// `resume_offset` is its i3 — 0 means start fresh.
    StartAccepted { resume_offset: u64 },
    /// M_UPLOAD_START_RESPONSE with i1!=0: the device refuses the transfer.
    StartRejected { code: u64 },
    /// M_UPLOAD_PROGRESS, streamed during the transfer.
    Progress { value: u64 },
    /// M_UPLOAD_COMPLETE with i1==0: the item is committed and playable.
    Complete,
    /// M_UPLOAD_COMPLETE with i1!=0: the transfer failed device-side.
    Failed { code: u64 },
}

const MT_UPLOAD_START_RESPONSE: u16 = 2931;
const MT_UPLOAD_PROGRESS: u16 = 2933;
const MT_UPLOAD_COMPLETE: u16 = 2934;

/// Decode ONE notification from the response characteristic into an
/// [`UploadEvent`], or `None` when it is some other push (device info, play
/// progress, …) or not parseable as a DNX packet at all.
///
/// The channel fragments with the standard 4-byte `[serial][total][remaining]
/// [tag]` header. Only the FIRST fragment is examined: the 8-byte DNX header
/// and the SimpleMessage's small varint fields sit well inside any fragment's
/// payload, so a split packet still decides here — and a continuation
/// fragment (which carries raw tail bytes, no DNX header) returns `None`
/// instead of a misparse.
pub fn parse_upload_event(notification: &[u8]) -> Option<UploadEvent> {
    use super::daniao::FRAG_HEADER_LEN;
    // DNX header: [0xF0][0x04][sn u16 BE][len u16 BE][mt u16 BE].
    if notification.len() < FRAG_HEADER_LEN + 8 {
        return None;
    }
    let total = notification[1];
    let remaining = notification[2];
    if total == 0 || remaining != total - 1 {
        return None; // not the first fragment of a packet
    }
    let dnx = &notification[FRAG_HEADER_LEN..];
    if dnx[0] != 0xF0 || dnx[1] != 0x04 {
        return None;
    }
    let mt = u16::from_be_bytes([dnx[6], dnx[7]]);
    if !matches!(
        mt,
        MT_UPLOAD_START_RESPONSE | MT_UPLOAD_PROGRESS | MT_UPLOAD_COMPLETE
    ) {
        return None;
    }

    // SimpleMessage: varint fields i1=1, i2=2, i3=3 (play_effect's captured
    // payload `08 a1 e9 04 10 00` is this same shape from the other side).
    // Unset fields default to 0, like protobuf itself.
    let mut i1 = 0u64;
    let mut i3 = 0u64;
    let mut body = &dnx[8..];
    while let Some((&tag, rest)) = body.split_first() {
        if tag & 0x07 != 0 {
            break; // not a varint field; nothing past here is ours
        }
        let (value, rest) = parse_varint(rest)?;
        match tag >> 3 {
            1 => i1 = value,
            3 => i3 = value,
            _ => {}
        }
        body = rest;
    }

    Some(match mt {
        MT_UPLOAD_START_RESPONSE if i1 == 0 => UploadEvent::StartAccepted { resume_offset: i3 },
        MT_UPLOAD_START_RESPONSE => UploadEvent::StartRejected { code: i1 },
        MT_UPLOAD_PROGRESS => UploadEvent::Progress { value: i1 },
        _ if i1 == 0 => UploadEvent::Complete,
        _ => UploadEvent::Failed { code: i1 },
    })
}

/// Parse a protobuf varint, returning the value and the remaining bytes.
fn parse_varint(mut bytes: &[u8]) -> Option<(u64, &[u8])> {
    let mut value = 0u64;
    let mut shift = 0u32;
    while let Some((&b, rest)) = bytes.split_first() {
        value |= u64::from(b & 0x7F) << shift;
        if b & 0x80 == 0 {
            return Some((value, rest));
        }
        shift += 7;
        if shift >= 64 {
            return None;
        }
        bytes = rest;
    }
    None // truncated mid-varint (split across fragments): treat as not ours
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

    /// A single-fragment DDP push carrying a DNX packet with `mt` and a
    /// SimpleMessage body — the shape every upload response arrives in.
    fn response(mt: u16, body: &[u8]) -> Vec<u8> {
        let mut v = vec![0x01, 1, 0, 0]; // [serial][total=1][remaining=0][tag]
        v.extend_from_slice(&[0xF0, 0x04, 0x00, 0x07]); // magic + sn
        let len = (8 + body.len()) as u16;
        v.extend_from_slice(&len.to_be_bytes());
        v.extend_from_slice(&mt.to_be_bytes());
        v.extend_from_slice(body);
        v
    }

    #[test]
    fn upload_responses_decode_to_events() {
        // M_UPLOAD_COMPLETE i1==0: the item is committed.
        assert_eq!(
            parse_upload_event(&response(2934, &[0x08, 0x00])),
            Some(UploadEvent::Complete)
        );
        // i1!=0 is a device-side failure with its code.
        assert_eq!(
            parse_upload_event(&response(2934, &[0x08, 0x05])),
            Some(UploadEvent::Failed { code: 5 })
        );
        // M_UPLOAD_START_RESPONSE accept, resume offset in i3 (1024 as a
        // 2-byte varint).
        assert_eq!(
            parse_upload_event(&response(2931, &[0x08, 0x00, 0x18, 0x80, 0x08])),
            Some(UploadEvent::StartAccepted {
                resume_offset: 1024
            })
        );
        assert_eq!(
            parse_upload_event(&response(2931, &[0x08, 0x02])),
            Some(UploadEvent::StartRejected { code: 2 })
        );
        // An i1 the encoder never wrote decodes as 0, protobuf-style.
        assert_eq!(
            parse_upload_event(&response(2934, &[])),
            Some(UploadEvent::Complete)
        );
        assert_eq!(
            parse_upload_event(&response(2933, &[0x08, 0x32])),
            Some(UploadEvent::Progress { value: 50 })
        );
    }

    #[test]
    fn non_upload_pushes_and_fragments_tails_are_not_events() {
        // Another DDP push on the same channel (M_DEVICE_INFO_NOTIFY).
        assert_eq!(parse_upload_event(&response(2103, &[0x08, 0x00])), None);
        // A continuation fragment: remaining != total-1, and its payload is
        // raw tail bytes that must not be misread as a DNX header.
        let mut cont = response(2934, &[0x08, 0x00]);
        cont[1] = 2; // total 2
        cont[2] = 0; // remaining 0 -> this is the SECOND fragment
        assert_eq!(parse_upload_event(&cont), None);
        // Wrong magic.
        let mut bad = response(2934, &[0x08, 0x00]);
        bad[4] = 0xAB;
        assert_eq!(parse_upload_event(&bad), None);
        // Too short to carry a DNX header at all.
        assert_eq!(parse_upload_event(&[0x01, 1, 0, 0, 0xF0]), None);
    }
}

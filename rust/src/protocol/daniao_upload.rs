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
pub(crate) const HEADER_LEN: usize = 8;
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

/// The Uploader characteristic the transfer's packets are written to.
///
/// The spec says which, on the `stored_upload` feature's
/// `uploader_characteristic`. When it does not, fall back to the heuristic
/// that has served since before there was a field to read: the first writable
/// characteristic that does NOT declare `daniao_fragment` framing (the
/// DDP/BIN command channels do; the uploader carries its own 8-byte header
/// instead). That is right on every spec in the catalogue, but it is still a
/// guess — a device that grew a second unframed writable characteristic would
/// silently upload to whichever the spec listed first, and the failure would
/// look like a device that ignores its uploads.
///
/// A declared UUID is honoured even if the spec's own service list does not
/// carry it: [`super::service_for_characteristic`] is what resolves the
/// service to open, and letting that fail loudly is better than quietly
/// guessing a different characteristic than the author named.
fn uploader_characteristic(spec: &DeviceSpec) -> Option<String> {
    let declared = spec
        .features
        .iter()
        .find(|f| f.feature_type == "stored_upload")
        .and_then(|f| f.uploader_characteristic.clone());
    if declared.is_some() {
        return declared;
    }
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
const MT_EFFECT_LIST: u16 = 2904;

/// One stored effect as the device lists it: its id (cid) and the device-
/// assigned slot. A stored custom must be addressed by its slot in a playlist
/// (play-by-cid alone accepts slot 0, but the playlist resolves items by slot —
/// verified: our stored frames register at slots 45..48, and a slot-0 playlist
/// did not cycle).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EffectEntry {
    pub cid: u32,
    pub slot: u32,
    /// Effect kind the device filed this under (protobuf field 2). The captures
    /// only ever show playable DIY microapps as `type = 3` (AMX); a `.eff`
    /// upload we sent as `type = 0` shows up here (or is absent) so we can see
    /// which family the firmware actually accepted.
    pub type_: u32,
    /// Whether the device considers this a user "DIY" effect (field 7) versus a
    /// built-in. Distinguishes the designs we stored from the factory catalogue.
    pub diy: u32,
}

/// Parse ONE M_EFFECT_LIST notification (mt 2904) into its effect entries.
///
/// The device answers a list request with several framed notifications, each
/// carrying a batch of entries; a caller decodes each and merges them. Each
/// entry is a protobuf sub-message `{1: slot, 2: type, 3: index, 4: cid,
/// 6: name}`; only slot and cid are read here. A notification that is not an
/// effect list, or is truncated, yields an empty list rather than an error.
///
/// This reads a notification as a whole frame, so it only sees the entries
/// that fit the FIRST fragment of a message the device split: the entry
/// straddling the boundary stops the loop, and a continuation fragment (no
/// `F1 01`) yields nothing. That is silent — a missing cid reads as a design
/// the device never stored, and the caller falls back to slot 0, which is a
/// playlist that does not cycle. Where the caller holds the whole collection
/// window (both of them do), [`parse_effect_list_frames`] is the entry point:
/// it reassembles first and cannot lose an entry to an MTU.
pub fn parse_effect_list(notification: &[u8]) -> Vec<EffectEntry> {
    use super::daniao::FRAG_HEADER_LEN;
    if notification.len() < FRAG_HEADER_LEN {
        return Vec::new();
    }
    parse_effect_list_frame(&notification[FRAG_HEADER_LEN..])
}

/// Parse a whole collection window of notifications into its effect entries.
///
/// Reassembles by serial first ([`reassemble_notifications`]), then reads each
/// completed frame — the discipline `device_info_resolution`'s caller already
/// follows on this same characteristic, and the one `parse_effect_list` alone
/// cannot: a list frame long enough to split loses its straddling entry and
/// every entry after it when each notification is decoded on its own.
///
/// Entries come back in frame order, deduplicated by nothing: a caller merging
/// by cid keeps merging by cid.
pub fn parse_effect_list_frames(notifications: &[Vec<u8>]) -> Vec<EffectEntry> {
    reassemble_notifications(notifications)
        .iter()
        .flat_map(|frame| parse_effect_list_frame(frame))
        .collect()
}

/// The entry reader, over ONE reassembled `F1 01 …` frame (no fragment
/// header). Shared by the per-notification and the whole-window entry points
/// so the two cannot disagree about what an entry is.
fn parse_effect_list_frame(dnx: &[u8]) -> Vec<EffectEntry> {
    if dnx.len() < 20 {
        return Vec::new();
    }
    if dnx[0] != 0xF1 || dnx[1] != 0x01 {
        return Vec::new();
    }
    if u16::from_be_bytes([dnx[6], dnx[7]]) != MT_EFFECT_LIST {
        return Vec::new();
    }
    // Entries follow the 12-byte extended header (dnx[8..20]).
    let mut body = &dnx[20..];
    let mut out = Vec::new();
    // Each entry is field 1 of the outer message: tag 0x0a (field 1,
    // length-delimited).
    while let Some((&tag, rest)) = body.split_first() {
        if tag != 0x0A {
            break; // only concatenated entry sub-messages here
        }
        let Some((len, rest)) = parse_varint(rest) else {
            break;
        };
        let len = len as usize;
        if rest.len() < len {
            break;
        }
        let (entry, tail) = rest.split_at(len);
        if let Some(e) = parse_effect_entry(entry) {
            out.push(e);
        }
        body = tail;
    }
    out
}

/// M_DEVICE_INFO_NOTIFY message type (2103) — the device pushes it on connect
/// (and answers M_GET_RUNNING_STATUS with it), carrying the panel's real size.
const MT_DEVICE_INFO: u16 = 2103;

/// Reassemble DDP notification fragments into complete `F1 01 …` frames.
///
/// Each notification is `[serial][total][remaining][tag]` + a chunk of the
/// frame; chunks sharing a serial concatenate — `remaining`-descending, so the
/// start fragment (remaining = total-1) comes first — into one frame. A
/// single-fragment message (total = 1) passes through as its lone chunk.
/// Grouping by serial keeps unrelated messages in the same batch apart. Needed
/// because at a 23-byte MTU a ~130-byte DeviceInfo spans ~9 notifications, and
/// its width/height fields sit past the first fragment.
///
/// `total` IS checked, and it is the whole difference between a frame and a
/// guess. Concatenating every fragment that shares a serial and calling the
/// result a frame was wrong twice: a message one notification short of its
/// `total` — a dropped BLE notify, a collection window that closed early —
/// came back as a SHORTER frame that still starts `F1 01` and still carries a
/// message type, so `device_info_resolution` read a truncated protobuf and
/// answered from whatever fields survived; and the serial is one byte, so two
/// unrelated messages that happened to reuse it in one batch were spliced into
/// a single frame. A message is emitted only once its `remaining` values are
/// exactly `total-1 … 0`, each seen once; a serial that starts over mid-group
/// (a repeated `remaining`, or a different `total`) begins a NEW message and
/// abandons the incomplete one rather than absorbing it.
///
/// Arrival order within a serial does not matter — the fragments are placed by
/// their own `remaining`, not by when they turned up.
pub fn reassemble_notifications(fragments: &[Vec<u8>]) -> Vec<Vec<u8>> {
    use super::daniao::FRAG_HEADER_LEN;
    use std::collections::BTreeMap;

    let mut groups: BTreeMap<u8, Vec<&Vec<u8>>> = BTreeMap::new();
    for f in fragments {
        // `total == 0` and `remaining >= total` are not fragment headers of
        // any message this scheme can describe; dropping them here keeps the
        // completeness test below arithmetic rather than defensive.
        if f.len() > FRAG_HEADER_LEN && f[1] > 0 && f[2] < f[1] {
            groups.entry(f[0]).or_default().push(f);
        }
    }

    let mut out = Vec::new();
    for group in groups.into_values() {
        // Fragments of ONE message, keyed by `remaining` so a duplicate is
        // visible and the order they arrived in is irrelevant.
        let mut held: BTreeMap<u8, &Vec<u8>> = BTreeMap::new();
        let mut total: Option<u8> = None;
        for f in group {
            let (declared, remaining) = (f[1], f[2]);
            if total != Some(declared) || held.contains_key(&remaining) {
                // Either a different message on a reused serial, or this one
                // starting over. What was accumulating can never complete now.
                held.clear();
                total = Some(declared);
            }
            held.insert(remaining, f);
            if held.len() == declared as usize {
                let mut buf = Vec::new();
                for chunk in held.values().rev() {
                    buf.extend_from_slice(&chunk[FRAG_HEADER_LEN..]);
                }
                out.push(buf);
                held.clear();
                total = None;
            }
        }
        // Whatever is still held is an incomplete message. It is dropped, not
        // emitted short: a truncated frame is indistinguishable from a real
        // one to every decoder downstream.
    }
    out
}

/// Read the panel `(width, height)` out of ONE reassembled
/// M_DEVICE_INFO_NOTIFY frame (mt=2103). The frame starts at the `F1 01`
/// marker; after the 12-byte extended header the payload is a protobuf whose
/// field 8 is width and field 9 is height (both varint). Returns `None` for any
/// other message or a frame missing either field.
pub fn device_info_resolution(frame: &[u8]) -> Option<(u32, u32)> {
    if frame.len() < 20 || frame[0] != 0xF1 || frame[1] != 0x01 {
        return None;
    }
    if u16::from_be_bytes([frame[6], frame[7]]) != MT_DEVICE_INFO {
        return None;
    }
    let mut body = &frame[20..];
    let mut width = None;
    let mut height = None;
    while let Some((&tag, rest)) = body.split_first() {
        let field = tag >> 3;
        match tag & 0x07 {
            0 => {
                let (v, rest) = parse_varint(rest)?;
                match field {
                    8 => width = Some(v as u32),
                    9 => height = Some(v as u32),
                    _ => {}
                }
                body = rest;
            }
            2 => {
                let (l, rest) = parse_varint(rest)?;
                let l = l as usize;
                if rest.len() < l {
                    break;
                }
                body = &rest[l..];
            }
            5 => {
                if rest.len() < 4 {
                    break;
                }
                body = &rest[4..];
            }
            1 => {
                if rest.len() < 8 {
                    break;
                }
                body = &rest[8..];
            }
            _ => break,
        }
        // width/height are early fields — stop as soon as both are in hand.
        if let (Some(w), Some(h)) = (width, height) {
            return Some((w, h));
        }
    }
    match (width, height) {
        (Some(w), Some(h)) => Some((w, h)),
        _ => None,
    }
}

/// Read `slot` (field 1), `type` (field 2), `cid` (field 4) and `diy`
/// (field 7) out of one effect-list entry, skipping the rest. Returns `None`
/// when the entry carries no cid.
fn parse_effect_entry(mut entry: &[u8]) -> Option<EffectEntry> {
    let mut slot = 0u32;
    let mut cid = 0u32;
    let mut type_ = 0u32;
    let mut diy = 0u32;
    while let Some((&tag, rest)) = entry.split_first() {
        let field = tag >> 3;
        let wire = tag & 0x07;
        match wire {
            0 => {
                let (v, rest) = parse_varint(rest)?;
                match field {
                    1 => slot = v as u32,
                    2 => type_ = v as u32,
                    4 => cid = v as u32,
                    7 => diy = v as u32,
                    _ => {}
                }
                entry = rest;
            }
            2 => {
                // Length-delimited (the name): skip it.
                let (l, rest) = parse_varint(rest)?;
                let l = l as usize;
                if rest.len() < l {
                    return None;
                }
                entry = &rest[l..];
            }
            _ => return None, // an unexpected wire type: stop, keep what we have
        }
    }
    (cid != 0).then_some(EffectEntry {
        cid,
        slot,
        type_,
        diy,
    })
}

/// Decode ONE notification from the response characteristic into an
/// [`UploadEvent`], or `None` when it is some other push (device info, play
/// progress, …) or not parseable as a DNX packet at all.
///
/// The channel fragments with the standard 4-byte `[serial][total][remaining]
/// [tag]` header, and only the FIRST fragment is examined — a continuation
/// fragment carries raw tail bytes and no DNX header, so it returns `None`
/// instead of a misparse.
///
/// A first fragment that does not reach the SimpleMessage returns `None` too,
/// and that is the point. The fields this decides on do NOT "sit well inside
/// any fragment's payload", which is what this comment used to claim: the DNX
/// header is 8 bytes and the extended header another 12, so the protobuf
/// starts at DNX offset 20, and a 23-byte MTU gives a notification 16 DNX
/// bytes. On that link every multi-fragment reply arrived with `i1` unread and
/// defaulted to 0 — which is the SUCCESS code — so a rejected START read as
/// StartAccepted and a device-side failure read as Complete, and the app
/// logged a stored design that was never stored. A single-fragment message
/// (`total == 1`) keeps the empty-body-means-success reading the live capture
/// relies on: the curtain omits `i1` entirely on success.
pub fn parse_upload_event(notification: &[u8]) -> Option<UploadEvent> {
    use super::daniao::FRAG_HEADER_LEN;
    // Inbound DNX header, read off the live JY25CUT curtain (2026-08-10):
    // [0xF1][0x01][sn u16 BE][len u16 BE][mt u16 BE] — the DEVICE-to-host
    // magic differs from the host's 0xF0 0x04 — then the same 12-byte
    // extended header the outbound templates carry (cid u32, osn u16, 0x00,
    // ts, four 0x00), and only THEN the SimpleMessage protobuf. e.g. a live
    // M_UPLOAD_COMPLETE: f1 01 00 27 00 16 0b 76 <12 header bytes> 10 09.
    if notification.len() < FRAG_HEADER_LEN + 8 {
        return None;
    }
    let total = notification[1];
    let remaining = notification[2];
    if total == 0 || remaining != total - 1 {
        return None; // not the first fragment of a packet
    }
    let dnx = &notification[FRAG_HEADER_LEN..];
    if dnx[0] != 0xF1 || dnx[1] != 0x01 {
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
    // Unset fields default to 0, like protobuf itself — the live curtain
    // omits i1 entirely on success.
    //
    // That default is only readable when the protobuf is actually in hand. A
    // FRAGMENTED packet whose first notification stops short of DNX offset 20
    // has not delivered the SimpleMessage at all, and "no fields" there means
    // "not yet", not "success". Returning None hands the caller nothing rather
    // than a verdict it invented; the caller reassembles (see
    // `reassemble_notifications`) or waits.
    if total > 1 && dnx.len() <= 20 {
        return None;
    }
    let mut i1 = 0u64;
    let mut i3 = 0u64;
    let mut body = if dnx.len() > 20 { &dnx[20..] } else { &[] };
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
    fn effect_list_entry_yields_cid_and_slot() {
        // One M_EFFECT_LIST notification carrying the capture's E-33 entry:
        // {slot: 33, type: 1, index: 33, cid: 79009 (a1 e9 04), name "E-33"}.
        let hex = concat!(
            "00010000",                 // frag [serial,total,remaining,tag]
            "f101",                     // inbound DNX flag
            "0001",                     // sn
            "0000",                     // len (unused by the parser)
            "0b58",                     // mt = M_EFFECT_LIST
            "000000000000000000000000", // 12-byte extended header
            "0a12082110011821",         // entry: len 18, slot 33, type 1, index 33
            "20a1e904",                 // cid 79009
            "3204452d3333",             // name "E-33"
            "3801",                     // trailing field
        );
        let bytes: Vec<u8> = (0..hex.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&hex[i..i + 2], 16).unwrap())
            .collect();
        let entries = parse_effect_list(&bytes);
        assert_eq!(
            entries,
            vec![EffectEntry {
                cid: 79009,
                slot: 33,
                type_: 1,
                diy: 1,
            }]
        );
    }

    /// A list frame long enough to split loses its straddling entry and every
    /// entry after it when each notification is decoded on its own: the
    /// continuation fragments carry no `F1 01`, so they read as "not an effect
    /// list". A caller that missed a cid falls back to slot 0, which the code
    /// itself documents as a playlist that does not cycle.
    /// `parse_effect_list_frames` reassembles first, so both entries survive.
    #[test]
    fn a_fragmented_effect_list_decodes_every_entry_after_reassembly() {
        let entry = |slot: u8, cid: &[u8], name: &str| {
            let mut e = vec![0x08, slot, 0x10, 0x01, 0x18, slot, 0x20];
            e.extend_from_slice(cid);
            e.push(0x32);
            e.push(name.len() as u8);
            e.extend_from_slice(name.as_bytes());
            e.extend_from_slice(&[0x38, 0x01]);
            let mut out = vec![0x0A, e.len() as u8];
            out.extend_from_slice(&e);
            out
        };
        let mut frame = vec![0xF1, 0x01, 0x00, 0x01, 0x00, 0x00, 0x0B, 0x58];
        frame.extend_from_slice(&[0u8; 12]); // extended header
        frame.extend(entry(33, &[0xA1, 0xE9, 0x04], "E-33"));
        frame.extend(entry(34, &[0xA2, 0xE9, 0x04], "E-34"));

        // Split it the way a 23-byte MTU does: 16 frame bytes per notify.
        let chunks: Vec<&[u8]> = frame.chunks(16).collect();
        let total = chunks.len() as u8;
        assert!(total > 1, "the fixture must actually fragment");
        let fragments: Vec<Vec<u8>> = chunks
            .iter()
            .enumerate()
            .map(|(i, chunk)| {
                let mut f = vec![0x55, total, total - 1 - i as u8, 0x00];
                f.extend_from_slice(chunk);
                f
            })
            .collect();

        // Per notification, the old way: only what fit fragment 0 survives.
        let per_notification: Vec<EffectEntry> = fragments
            .iter()
            .flat_map(|f| parse_effect_list(f))
            .collect();
        assert!(
            per_notification.len() < 2,
            "the fixture must be one a per-notification decode loses: {per_notification:?}"
        );

        let entries = parse_effect_list_frames(&fragments);
        assert_eq!(
            entries,
            vec![
                EffectEntry {
                    cid: 79009,
                    slot: 33,
                    type_: 1,
                    diy: 1
                },
                EffectEntry {
                    cid: 79010,
                    slot: 34,
                    type_: 1,
                    diy: 1
                },
            ]
        );
    }

    /// The unfragmented case still works through the whole-window entry point:
    /// a `total == 1` message is its own frame.
    #[test]
    fn an_unfragmented_effect_list_decodes_through_the_window_parser() {
        let mut frame = vec![0xF1, 0x01, 0x00, 0x01, 0x00, 0x00, 0x0B, 0x58];
        frame.extend_from_slice(&[0u8; 12]);
        frame.extend_from_slice(&[
            0x0A, 0x12, 0x08, 0x21, 0x10, 0x01, 0x18, 0x21, 0x20, 0xA1, 0xE9, 0x04, 0x32, 0x04,
            0x45, 0x2D, 0x33, 0x33, 0x38, 0x01,
        ]);
        let mut notification = vec![0x07, 1, 0, 0];
        notification.extend_from_slice(&frame);
        let entries = parse_effect_list_frames(&[notification]);
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].cid, 79009);
    }

    #[test]
    fn non_effect_list_notification_parses_empty() {
        // Zeroed bytes (no F1 01, wrong mt) are not an effect list.
        assert!(parse_effect_list(&[0u8; 32]).is_empty());
    }

    /// The real M_DEVICE_INFO_NOTIFY (mt=2103) DN0B88 pushes on connect, minus
    /// the 4-byte fragment header — i.e. the reassembled `F1 01 …` frame. Its
    /// protobuf field 8 is width=20, field 9 is height=20.
    fn captured_device_info_frame() -> Vec<u8> {
        let full = "dd010000f10100dd008908370000000000000d3c010000000a07302e302e302e\
                    30100418e807220536303030312a0c444e583a533130342d4a593a30bcfd0238\
                    0140144814a00142b001d3c88080f8ffffffff01b801df35d001c801e0011cea\
                    0106444e30423838f201069888e0520b888002e05da0029003a80204b80214c0\
                    0214c8029003d002c07ad8020f";
        let bytes: Vec<u8> = (0..full.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&full[i..i + 2], 16).unwrap())
            .collect();
        bytes[4..].to_vec() // strip the [serial][total][remaining][tag] header
    }

    #[test]
    fn device_info_resolution_reads_width_and_height() {
        let (w, h) = device_info_resolution(&captured_device_info_frame())
            .expect("captured DeviceInfo carries 20x20");
        assert_eq!((w, h), (20, 20));
    }

    #[test]
    fn device_info_resolution_ignores_other_messages() {
        // Wrong mt (an effect-list frame) yields nothing.
        let mut not_info = vec![0xF1, 0x01, 0x00, 0x01, 0x00, 0x00, 0x0B, 0x58];
        not_info.extend_from_slice(&[0u8; 16]);
        assert!(device_info_resolution(&not_info).is_none());
        assert!(device_info_resolution(&[0u8; 24]).is_none());
    }

    #[test]
    fn reassembly_rebuilds_a_fragmented_device_info() {
        // Re-fragment the frame the way a 23-byte MTU splits it: 16 frame bytes
        // per notification behind a [serial][total][remaining][tag] header. The
        // width/height fields land past the first fragment, so a decoder that
        // only read fragment 0 would miss them — reassembly must run first.
        let frame = captured_device_info_frame();
        let chunks: Vec<&[u8]> = frame.chunks(16).collect();
        let total = chunks.len() as u8;
        let mut fragments: Vec<Vec<u8>> = Vec::new();
        for (i, chunk) in chunks.iter().enumerate() {
            let remaining = total - 1 - i as u8;
            let mut frag = vec![0x55, total, remaining, 0x00];
            frag.extend_from_slice(chunk);
            fragments.push(frag);
        }
        // Deliver them out of order to prove the sort by `remaining` holds.
        fragments.reverse();
        let rebuilt = reassemble_notifications(&fragments);
        assert_eq!(rebuilt.len(), 1, "one serial -> one frame");
        assert_eq!(rebuilt[0], frame, "chunks reassemble to the original frame");
        assert_eq!(device_info_resolution(&rebuilt[0]), Some((20, 20)));
    }

    /// A message one fragment short of its `total` used to come back as a
    /// SHORTER frame that still starts `F1 01` and still carries a message
    /// type, so every decoder downstream read it as a real — and wrong —
    /// answer. It is dropped now.
    #[test]
    fn a_message_missing_a_fragment_yields_no_frame_at_all() {
        let frame = captured_device_info_frame();
        let chunks: Vec<&[u8]> = frame.chunks(16).collect();
        let total = chunks.len() as u8;
        let all: Vec<Vec<u8>> = chunks
            .iter()
            .enumerate()
            .map(|(i, chunk)| {
                let mut f = vec![0x55, total, total - 1 - i as u8, 0x00];
                f.extend_from_slice(chunk);
                f
            })
            .collect();

        // Every fragment but the last: a dropped notify, or a window that
        // closed a beat early.
        let short = &all[..all.len() - 1];
        assert!(
            reassemble_notifications(short).is_empty(),
            "an incomplete message must not surface as a truncated frame"
        );
        // And the whole batch still rebuilds.
        assert_eq!(reassemble_notifications(&all), vec![frame]);
    }

    /// The serial is ONE byte, so two unrelated messages in one collection
    /// window can reuse it. Concatenating everything that shared a serial
    /// spliced them into a single frame; they come back as two now.
    #[test]
    fn two_messages_reusing_one_serial_stay_apart() {
        let first = response(2934, &[0x08, 0x00]);
        let second = response(2933, &[0x08, 0x32]);
        // `response` already frames each as [serial=1][total=1][remaining=0].
        let frames = reassemble_notifications(&[first.clone(), second.clone()]);
        assert_eq!(frames.len(), 2, "one serial, two messages");
        assert_eq!(frames[0], first[4..]);
        assert_eq!(frames[1], second[4..]);
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

    /// With no `uploader_characteristic` declared, the heuristic picks the one
    /// writable characteristic that carries no framing block. That is what the
    /// vendored spec relies on today.
    #[test]
    fn the_heuristic_finds_the_unframed_writable_characteristic() {
        let transfer = encode_upload(&spec(), 1, 3, 5, &[1, 2, 3], None, 500).unwrap();
        assert_eq!(
            transfer.characteristic_uuid,
            "27923001-2072-1925-3022-077119514e44"
        );
    }

    /// A declared `uploader_characteristic` wins. The heuristic would pick the
    /// unframed "Uploader" here too, so the test makes the spec name a
    /// DIFFERENT characteristic: only a spec that is actually read can move
    /// the writes.
    #[test]
    fn a_declared_uploader_characteristic_overrides_the_heuristic() {
        let declared = format!(
            "{SPEC}features:\n  - type: \"stored_upload\"\n    \
             uploader_characteristic: \"02020074-1972-1925-3022-077119514e44\"\n"
        );
        let spec = parse_device_spec(&declared).unwrap();
        let transfer = encode_upload(&spec, 1, 3, 5, &[1, 2, 3], None, 500).unwrap();
        assert_eq!(
            transfer.characteristic_uuid, "02020074-1972-1925-3022-077119514e44",
            "the spec's word beats the guess"
        );
    }

    /// A single-fragment DDP push carrying an inbound DNX packet with `mt`
    /// and a SimpleMessage body — the shape every upload response arrives in
    /// (magic F1 01, then the 12-byte cid/osn/ts extended header, then the
    /// protobuf), matching the packets captured live off the curtain.
    fn response(mt: u16, body: &[u8]) -> Vec<u8> {
        let mut v = vec![0x01, 1, 0, 0]; // [serial][total=1][remaining=0][tag]
        v.extend_from_slice(&[0xF1, 0x01, 0x00, 0x07]); // inbound magic + sn
        let len = (20 + body.len()) as u16;
        v.extend_from_slice(&len.to_be_bytes());
        v.extend_from_slice(&mt.to_be_bytes());
        v.extend_from_slice(&[0u8; 12]); // cid, osn, 0, ts, four 0x00
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

    /// The verdict lives in `i1`, at DNX offset 20 — past the 8-byte DNX
    /// header and the 12-byte extended header. At a 23-byte MTU a notification
    /// carries 16 DNX bytes, so on a fragmented reply the first fragment does
    /// not hold it, and an unread `i1` defaults to 0, which is SUCCESS. A
    /// device-side failure (i1=5) therefore read as Complete, and the app
    /// logged a design it had committed nowhere. Fragment 1 now decides
    /// nothing; the reassembled frame decides.
    #[test]
    fn a_first_fragment_short_of_the_verdict_decides_nothing() {
        // A completion carrying i1=5, split into two 20-byte notifications.
        let whole = response(2934, &[0x08, 0x05]);
        let frame = &whole[4..];
        let chunks: Vec<&[u8]> = frame.chunks(16).collect();
        let total = chunks.len() as u8;
        assert_eq!(total, 2, "the fixture must split in two");
        let fragments: Vec<Vec<u8>> = chunks
            .iter()
            .enumerate()
            .map(|(i, chunk)| {
                let mut f = vec![0x27, total, total - 1 - i as u8, 0x00];
                f.extend_from_slice(chunk);
                f
            })
            .collect();

        assert_eq!(
            parse_upload_event(&fragments[0]),
            None,
            "a first fragment that has not delivered i1 must not report Complete"
        );
        assert_eq!(parse_upload_event(&fragments[1]), None, "a continuation");

        // Reassembled, the real verdict comes out — a failure, not a success.
        let rebuilt = reassemble_notifications(&fragments);
        assert_eq!(rebuilt.len(), 1);
        let mut framed = vec![0x27, 1, 0, 0];
        framed.extend_from_slice(&rebuilt[0]);
        assert_eq!(
            parse_upload_event(&framed),
            Some(UploadEvent::Failed { code: 5 })
        );
    }

    /// The single-fragment reading the live capture relies on is untouched:
    /// the curtain omits `i1` entirely on success, so an empty body on a
    /// `total == 1` message is still Complete.
    #[test]
    fn a_single_fragment_with_no_body_is_still_a_success() {
        assert_eq!(
            parse_upload_event(&response(2934, &[])),
            Some(UploadEvent::Complete)
        );
    }

    #[test]
    fn live_captured_curtain_responses_decode() {
        // Verbatim notifications from the JY25CUT curtain (2026-08-10),
        // pinned so the parser can never drift from the observed wire again.
        let complete = [
            0x27, 0x01, 0x00, 0x00, 0xf1, 0x01, 0x00, 0x27, 0x00, 0x16, 0x0b, 0x76, 0xc8, 0x34,
            0xc9, 0x3f, 0x00, 0x00, 0x38, 0x40, 0x00, 0x50, 0x19, 0x00, 0x10, 0x09,
        ];
        assert_eq!(parse_upload_event(&complete), Some(UploadEvent::Complete));

        let start_accept = [
            0x25, 0x01, 0x00, 0x00, 0xf1, 0x01, 0x00, 0x25, 0x00, 0x16, 0x0b, 0x73, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x3c,
        ];
        assert_eq!(
            parse_upload_event(&start_accept),
            Some(UploadEvent::StartAccepted { resume_offset: 0 })
        );

        // The play-progress stream (mt=2630) that floods the same channel.
        let play_progress = [
            0x26, 0x01, 0x00, 0x00, 0xf1, 0x01, 0x00, 0x26, 0x00, 0x16, 0x0a, 0x46, 0x00, 0x48,
            0x6d, 0x2f, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x10, 0x09,
        ];
        assert_eq!(parse_upload_event(&play_progress), None);
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

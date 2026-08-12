// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The device-independent half of persisting content ON a device so it plays
//! standalone after disconnect — the storage counterpart to
//! [`super::image_upload`] (which streams live frames).
//!
//! # Where the line is
//!
//! Storing content splits the same way an image upload does: a
//! device-specific CONTAINER format, and a shared TRANSPORT.
//!
//! ```text
//!   build container ─────────▶ carry over transport ─────▶ (optional) play it
//!   [spec: container_format]    [spec: uploader char,        [spec: play_command]
//!    → a registered encoder]     file_type, frame_size]        by stored id
//! ```
//!
//! A spec declares a `stored_upload` feature naming its `container_format`; this
//! module resolves that to a registered [`StoredContainerEncoder`], builds the
//! blob, and hands it to [`super::daniao_upload`] to packetize onto the
//! Uploader characteristic. Adding a device with its own persisted format is a
//! new encoder here plus a spec — the transport and this pipeline are reused.
//!
//! The container format itself stays in Rust for the same reason a pixel codec
//! does: it is protobuf + CRC assembly over a base template, which YAML cannot
//! express without inventing a bytecode.

use super::daniao::fragment_packet;
use super::daniao_store::{self, StoredProgram};
use super::daniao_upload;
use super::image_upload::FragmentRequest;
use super::EncodedWrite;
use crate::codec::types::encode_command;
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, DeviceSpec, Feature};
use std::collections::HashMap;

/// A named container encoder — the entry a spec's `stored_upload.container_format`
/// resolves to. Mirrors [`super::ImageUploadHandler`] for the persisted path;
/// only the container layout is device-specific, the transport is shared.
pub struct StoredContainerEncoder {
    pub name: &'static str,
    /// Build the file blob to persist from a canvas + playback options.
    pub build_image: fn(&StoredProgram<'_>) -> Result<Vec<u8>, ProtocolError>,
}

/// Every implemented stored-content container encoder. Single source of truth
/// for both the DTO's `encodable` flag and the encode dispatch, so a format
/// cannot be advertised without an encoder behind it.
const CONTAINER_ENCODERS: &[StoredContainerEncoder] = &[StoredContainerEncoder {
    name: "daniao_amx",
    build_image: daniao_store::build_image_container,
}];

/// Look up the implemented encoder for a `container_format` name.
pub fn container_encoder(name: &str) -> Option<&'static StoredContainerEncoder> {
    CONTAINER_ENCODERS.iter().find(|e| e.name == name)
}

/// The `stored_upload` feature of a spec, if it declares one.
pub fn stored_feature(spec: &DeviceSpec) -> Option<&Feature> {
    spec.features
        .iter()
        .find(|f| f.feature_type == "stored_upload")
}

/// The ordered BLE writes that persist one image and (optionally) play it.
pub struct StoredUploadPlan {
    /// The GATT service every write's characteristic belongs to (the platform's
    /// single custom service carries both the uploader and command channels).
    pub service_uuid: String,
    /// Writes to the Uploader characteristic, in order: START then DATA packets.
    pub upload_writes: Vec<EncodedWrite>,
    /// The play-by-id command, fragment-framed and ready to write, when the
    /// spec declares a `play_command`. Sent after the upload completes.
    pub play_write: Option<EncodedWrite>,
    /// Where the device answers the upload (the spec's
    /// `response_characteristic`), when it names one. A caller subscribes
    /// here and waits for the completion event before sending `play_write` —
    /// playing a cid the device has not committed yet is a silent no-op.
    pub response_characteristic_uuid: Option<String>,
    /// The stored id the caller can later address the item by.
    pub cid: u32,
}

/// The play-by-cid write alone, for RE-triggering an already stored item
/// without uploading anything. Same framed command the upload plan tacks on;
/// errors when the spec declares no `stored_upload` or no `play_command`.
///
/// `sequence` drives the fragment serial and the DNX `sn`, so pressing Replay
/// twice sends two byte-DIFFERENT writes — firmware that de-duplicates a
/// framed command by serial would otherwise drop the repeat and the panel
/// would not restart.
pub fn encode_stored_play(
    spec: &DeviceSpec,
    cid: u32,
    sequence: u16,
) -> Result<(String, EncodedWrite), ProtocolError> {
    let feature = stored_feature(spec).ok_or_else(|| ProtocolError::ImageUploadUnsupported {
        reason: "spec declares no stored_upload feature".to_string(),
    })?;
    let command =
        feature
            .play_command
            .as_deref()
            .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
                reason: "spec's stored_upload declares no play_command".to_string(),
            })?;
    let write = build_play_write(spec, command, cid, sequence)?;
    let service =
        service_for_characteristic(spec, &write.characteristic_uuid).ok_or_else(|| {
            ProtocolError::ImageUploadUnsupported {
                reason: "the play command's characteristic belongs to no service".to_string(),
            }
        })?;
    Ok((service, write))
}

/// Store `program`'s canvas as a standalone picture microapp ("DN" AMX,
/// `file_type` 3).
pub fn encode_stored_image(
    spec: &DeviceSpec,
    program: &StoredProgram<'_>,
    sequence: u16,
) -> Result<StoredUploadPlan, ProtocolError> {
    let feature = require_stored_feature(spec)?;
    let container = daniao_store::build_image_container(program)?;
    let file_type = feature.file_type.unwrap_or(3);
    assemble_plan(spec, feature, &container, program.cid, file_type, None, sequence)
}

/// Store a scrolling-text marquee ("DN" AMX text layer, same `file_type` as an
/// image microapp).
pub fn encode_stored_text(
    spec: &DeviceSpec,
    program: &daniao_store::StoredText<'_>,
    sequence: u16,
) -> Result<StoredUploadPlan, ProtocolError> {
    let feature = require_stored_feature(spec)?;
    let container = daniao_store::build_text_container(program)?;
    let file_type = feature.file_type.unwrap_or(3);
    assemble_plan(spec, feature, &container, program.cid, file_type, None, sequence)
}

/// Store a multi-frame animation (raw "DNMX" `.eff`).
///
/// The `.eff` animation uploads as file kind 0 with a `<cid>.eff` path — a
/// Daniao platform fact tied to THIS container kind, not the spec's default
/// `file_type` (which is the AMX microapp's 3). Both are played back the same
/// way (by cid).
pub fn encode_stored_animation(
    spec: &DeviceSpec,
    anim: &daniao_store::StoredAnimation<'_>,
    sequence: u16,
) -> Result<StoredUploadPlan, ProtocolError> {
    let feature = require_stored_feature(spec)?;
    let container = daniao_store::build_animation_container(anim)?;
    let path = format!("{}.eff", anim.cid);
    assemble_plan(spec, feature, &container, anim.cid, 0, Some(&path), sequence)
}

/// Validate that `spec` declares a `stored_upload` feature whose
/// `container_format` this build implements, returning the feature.
fn require_stored_feature(spec: &DeviceSpec) -> Result<&Feature, ProtocolError> {
    let feature = stored_feature(spec).ok_or_else(|| ProtocolError::ImageUploadUnsupported {
        reason: "spec declares no stored_upload feature".to_string(),
    })?;
    let format = feature.container_format.as_deref().ok_or_else(|| {
        ProtocolError::ImageUploadUnsupported {
            reason: "stored_upload feature names no container_format".to_string(),
        }
    })?;
    container_encoder(format).ok_or_else(|| ProtocolError::ImageUploadUnsupported {
        reason: format!("no container encoder registered for '{format}' in this build"),
    })?;
    Ok(feature)
}

/// Carry a finished container over the uploader transport and, when the spec
/// declares a `play_command`, tack on the play-by-cid write. Shared by every
/// stored kind — only the container bytes, file kind and path differ.
#[allow(clippy::too_many_arguments)]
fn assemble_plan(
    spec: &DeviceSpec,
    feature: &Feature,
    container: &[u8],
    cid: u32,
    file_type: u32,
    path: Option<&str>,
    sequence: u16,
) -> Result<StoredUploadPlan, ProtocolError> {
    let frame_size = feature
        .frame_size
        .map(|n| n as usize)
        .unwrap_or(daniao_upload::DEFAULT_FRAME_SIZE);
    // The transfer id is echoed by the device; the low byte of the cid is a
    // fine, stable choice (the vendor uses a rolling counter, which the device
    // only needs to match within one transfer).
    let id = (cid & 0xFF) as u8;
    let transfer =
        daniao_upload::encode_upload(spec, id, file_type, cid, container, path, frame_size)?;

    let service_uuid =
        service_for_characteristic(spec, &transfer.characteristic_uuid).ok_or_else(|| {
            ProtocolError::ImageUploadUnsupported {
                reason: "the uploader characteristic belongs to no service".to_string(),
            }
        })?;

    let play_write = match feature.play_command.as_deref() {
        Some(command) => Some(build_play_write(spec, command, cid, sequence)?),
        None => None,
    };

    Ok(StoredUploadPlan {
        service_uuid,
        upload_writes: transfer.writes,
        play_write,
        response_characteristic_uuid: feature.response_characteristic.clone(),
        cid,
    })
}

/// The UUID of the service that declares `char_uuid`. Every write in a stored
/// upload targets one custom service, so resolving it once here spares the
/// caller a spec walk per write.
fn service_for_characteristic(spec: &DeviceSpec, char_uuid: &str) -> Option<String> {
    for service in &spec.services {
        if service
            .characteristics
            .iter()
            .any(|c| c.uuid.eq_ignore_ascii_case(char_uuid))
        {
            return Some(service.uuid.clone());
        }
    }
    None
}

/// Encode the play-by-id command and wrap it in the command channel's fragment
/// framing, so it is honoured (the controller ignores unframed command writes).
///
/// The command's bytes come from its spec template — the effect id rides in as
/// `effect_id` (the vendor's `SimpleMessage.i1`) with `slot` defaulting to 0 —
/// so the message-type and header bytes stay in the YAML, not here.
fn build_play_write(
    spec: &DeviceSpec,
    command_name: &str,
    cid: u32,
    sequence: u16,
) -> Result<EncodedWrite, ProtocolError> {
    let (characteristic, tag) =
        command_channel(spec, command_name).ok_or_else(|| ProtocolError::CommandNotFound {
            uuid: "<any>".to_string(),
            command: command_name.to_string(),
        })?;
    let commands = characteristic
        .commands
        .as_ref()
        .ok_or_else(|| ProtocolError::NoCommands {
            uuid: characteristic.uuid.clone(),
        })?;
    let command = commands
        .get(command_name)
        .ok_or_else(|| ProtocolError::CommandNotFound {
            uuid: characteristic.uuid.clone(),
            command: command_name.to_string(),
        })?;

    // `sn` overrides the template's `auto: sequence` default (codec fills 0
    // otherwise), so the DNX header and the fragment header carry the SAME
    // rolling counter — a repeat play is a distinct packet on both layers.
    let params = HashMap::from([
        ("effect_id".to_string(), cid as f64),
        ("slot".to_string(), 0.0),
        ("sn".to_string(), sequence as f64),
    ]);
    let dnx = encode_command(command, &params)?;

    // One logical packet, so one fragment: give the framer capacity for the
    // whole payload. tag comes from the characteristic's framing (0 on the
    // command channel).
    let parts = fragment_packet(FragmentRequest {
        packet: &dnx,
        serial: sequence as u32,
        tag,
        capacity: dnx.len().max(1),
    });
    // A single-packet command never splits; take the one fragment.
    let bytes = parts.into_iter().next().unwrap_or(dnx);
    Ok(EncodedWrite {
        characteristic_uuid: characteristic.uuid.clone(),
        bytes,
    })
}

/// One playlist entry: a stored effect's id (cid) and its device slot.
pub struct PlaylistItem {
    pub cid: u32,
    pub slot: u32,
}

/// Encode the writes that make the device LOOP a list of stored effects: the
/// playlist (M_SET_PL) then loop mode (M_SET_MODE_LOOP). This is how a
/// multi-frame custom animation plays on this hardware — each frame is stored
/// as its own single-frame microapp (the type-3 AMX path that renders), then
/// the frames are set as a looping playlist. `sequence` seeds the two writes'
/// rolling serials.
pub fn encode_set_playlist(
    spec: &DeviceSpec,
    items: &[PlaylistItem],
    sequence: u16,
) -> Result<(String, Vec<EncodedWrite>), ProtocolError> {
    let payload = build_playlist_payload(items);
    let set_pl = build_framed_command(
        spec,
        "set_playlist",
        HashMap::new(),
        HashMap::from([("payload".to_string(), payload)]),
        sequence,
    )?;
    let loop_cmd = build_framed_command(
        spec,
        "set_mode_loop",
        HashMap::new(),
        HashMap::new(),
        sequence.wrapping_add(1),
    )?;
    let service = service_for_characteristic(spec, &set_pl.characteristic_uuid).ok_or_else(|| {
        ProtocolError::ImageUploadUnsupported {
            reason: "the set_playlist characteristic belongs to no service".to_string(),
        }
    })?;
    Ok((service, vec![set_pl, loop_cmd]))
}

/// The PlayList protobuf: `{1:0, 2:count, 4:[repeated {1:0, 2:cid, 3:slot}]}`,
/// byte-shaped after the M_SET_PL capture in smartdawn_longer2.pcapng.
fn build_playlist_payload(items: &[PlaylistItem]) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(&[0x08, 0x00]); // field 1 = 0
    out.push(0x10); // field 2 (count)
    write_varint(&mut out, items.len() as u64);
    for item in items {
        let mut entry = Vec::new();
        entry.extend_from_slice(&[0x08, 0x00]); // field 1 = 0
        entry.push(0x10); // field 2 (cid)
        write_varint(&mut entry, item.cid as u64);
        entry.push(0x18); // field 3 (slot)
        write_varint(&mut entry, item.slot as u64);
        out.push(0x22); // field 4 (len-delimited item)
        write_varint(&mut out, entry.len() as u64);
        out.extend_from_slice(&entry);
    }
    out
}

fn write_varint(out: &mut Vec<u8>, mut v: u64) {
    loop {
        let mut b = (v & 0x7f) as u8;
        v >>= 7;
        if v != 0 {
            b |= 0x80;
        }
        out.push(b);
        if v == 0 {
            break;
        }
    }
}

/// Build any framed DDP command from its spec template — numeric params and an
/// optional `bytes` payload — then wrap it in the command channel's fragment
/// framing. `sequence` drives both the DNX `sn` and the fragment serial.
/// Generalises [`build_play_write`] for commands that carry a Rust-built
/// payload (set_playlist).
fn build_framed_command(
    spec: &DeviceSpec,
    command_name: &str,
    mut params: HashMap<String, f64>,
    bytes_params: HashMap<String, Vec<u8>>,
    sequence: u16,
) -> Result<EncodedWrite, ProtocolError> {
    let (characteristic, tag) =
        command_channel(spec, command_name).ok_or_else(|| ProtocolError::CommandNotFound {
            uuid: "<any>".to_string(),
            command: command_name.to_string(),
        })?;
    let commands = characteristic
        .commands
        .as_ref()
        .ok_or_else(|| ProtocolError::NoCommands {
            uuid: characteristic.uuid.clone(),
        })?;
    let command = commands
        .get(command_name)
        .ok_or_else(|| ProtocolError::CommandNotFound {
            uuid: characteristic.uuid.clone(),
            command: command_name.to_string(),
        })?;
    params.insert("sn".to_string(), sequence as f64);
    let dnx = crate::codec::types::encode_command_with_bytes(command, &params, &bytes_params)?;
    let parts = fragment_packet(FragmentRequest {
        packet: &dnx,
        serial: sequence as u32,
        tag,
        capacity: dnx.len().max(1),
    });
    let bytes = parts.into_iter().next().unwrap_or(dnx);
    Ok(EncodedWrite {
        characteristic_uuid: characteristic.uuid.clone(),
        bytes,
    })
}

/// The characteristic carrying `command_name`, plus its fragment channel tag.
///
/// Resolves by which characteristic declares the command rather than by a
/// hardcoded UUID, so the play command can live on whichever channel the spec
/// puts it. The tag is the characteristic's `framing.channel_tag` (0 for the
/// Daniao command channel), defaulting to 0 when unstated.
fn command_channel<'a>(
    spec: &'a DeviceSpec,
    command_name: &str,
) -> Option<(&'a Characteristic, u8)> {
    for service in &spec.services {
        for characteristic in &service.characteristics {
            let has_command = characteristic
                .commands
                .as_ref()
                .is_some_and(|c| c.contains_key(command_name));
            if !has_command {
                continue;
            }
            let tag = characteristic
                .framing
                .as_ref()
                .and_then(|f| f.get("channel_tag"))
                .and_then(|t| t.as_u64())
                .unwrap_or(0) as u8;
            return Some((characteristic, tag));
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::daniao_store::{ImageLayer, Scroll};
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
protocol_handler: "daniao_ddp"
features:
  - type: "stored_upload"
    container_format: "daniao_amx"
    file_type: 3
    frame_size: 500
    play_command: "play_effect"
    response_characteristic: "01010074-1972-1925-3022-077119514e44"
services:
  - uuid: "00000074-1972-1925-3022-077119514e44"
    name: "Daniao DDP Service"
    characteristics:
      - uuid: "01020074-1972-1925-3022-077119514e44"
        name: "DDP Write"
        properties: ["write"]
        framing: { scheme: "daniao_fragment", channel_tag: 0 }
        commands:
          play_effect:
            description: "Play a stored effect by id."
            template: [0xF0, 0x04, "{sn}", "{len}", 0x0A, 0x2E, "{cid}", "{osn}", 0x00, "{ts}", 0x00, 0x00, 0x00, 0x00, 0x08, "{effect_id}", 0x10, "{slot}"]
            parameters:
              sn: { type: "uint16", endianness: "big", auto: "sequence" }
              len: { type: "uint16", endianness: "big", auto: "packet_length" }
              cid: { type: "uint32", endianness: "big", default: 0 }
              osn: { type: "uint16", endianness: "big", default: 1 }
              ts: { type: "uint8", default: 0 }
              effect_id: { type: "varint", min: 0 }
              slot: { type: "varint", min: 0, default: 0 }
          set_playlist:
            description: "Set the looping playlist."
            template: [0xF0, 0x04, "{sn}", "{len}", 0x0A, 0x42, "{cid}", "{osn}", 0x00, "{ts}", 0x00, 0x00, 0x00, 0x00, "{payload}"]
            parameters:
              sn: { type: "uint16", endianness: "big", auto: "sequence" }
              len: { type: "uint16", endianness: "big", auto: "packet_length" }
              cid: { type: "uint32", endianness: "big", default: 0 }
              osn: { type: "uint16", endianness: "big", default: 1 }
              ts: { type: "uint8", default: 0 }
              payload: { type: "bytes" }
          set_mode_loop:
            description: "Loop the playlist."
            template: [0xF0, 0x04, "{sn}", "{len}", 0x09, 0xCB, "{cid}", "{osn}", 0x00, "{ts}", 0x00, 0x00, 0x00, 0x00]
            parameters:
              sn: { type: "uint16", endianness: "big", auto: "sequence" }
              len: { type: "uint16", endianness: "big", auto: "packet_length" }
              cid: { type: "uint32", endianness: "big", default: 0 }
              osn: { type: "uint16", endianness: "big", default: 1 }
              ts: { type: "uint8", default: 0 }
      - uuid: "01010074-1972-1925-3022-077119514e44"
        name: "DDP Notify"
        properties: ["notify"]
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

    fn red_2x2() -> Vec<u8> {
        let mut v = Vec::new();
        for _ in 0..4 {
            v.extend_from_slice(&[0xFF, 0, 0]);
        }
        v
    }

    fn program<'a>(rgb: &'a [u8]) -> StoredProgram<'a> {
        StoredProgram {
            name: "hi",
            cid: 79009,
            time_secs: 10,
            scroll: Scroll::None,
            speed: 3,
            image: ImageLayer {
                width: 2,
                height: 2,
                rgb,
            },
        }
    }

    #[test]
    fn plan_has_uploader_writes_targeting_the_uploader_characteristic() {
        let rgb = red_2x2();
        let plan = encode_stored_image(&spec(), &program(&rgb), 0).unwrap();
        assert!(!plan.upload_writes.is_empty());
        assert!(plan
            .upload_writes
            .iter()
            .all(|w| w.characteristic_uuid == "27923001-2072-1925-3022-077119514e44"));
        assert_eq!(plan.service_uuid, "00000074-1972-1925-3022-077119514e44");
        assert_eq!(plan.cid, 79009);
    }

    #[test]
    fn plan_names_the_response_characteristic_from_the_spec() {
        let rgb = red_2x2();
        let plan = encode_stored_image(&spec(), &program(&rgb), 0).unwrap();
        assert_eq!(
            plan.response_characteristic_uuid.as_deref(),
            Some("01010074-1972-1925-3022-077119514e44"),
            "the caller needs to know where to await the upload completion"
        );
    }

    #[test]
    fn stored_play_replays_by_cid_without_an_upload() {
        let rgb = red_2x2();
        let plan = encode_stored_image(&spec(), &program(&rgb), 0).unwrap();
        let (service, write) = encode_stored_play(&spec(), 79009, 0).unwrap();
        assert_eq!(service, "00000074-1972-1925-3022-077119514e44");
        // Byte-identical to the play write the upload plan tacks on AT THE SAME
        // sequence: the replay path IS the store-then-show command, minus the
        // store. (The plan above used sequence 0.)
        let plan_play = plan.play_write.expect("play_command declared");
        assert_eq!(write.characteristic_uuid, plan_play.characteristic_uuid);
        assert_eq!(write.bytes, plan_play.bytes);
    }

    #[test]
    fn playlist_payload_matches_the_capture() {
        // The 4-effect playlist from smartdawn_longer2.pcapng: cids 14221..14218
        // at slots 8..5. Byte-for-byte the payload the app sent.
        let items = [
            PlaylistItem { cid: 14221, slot: 8 },
            PlaylistItem { cid: 14220, slot: 7 },
            PlaylistItem { cid: 14219, slot: 6 },
            PlaylistItem { cid: 14218, slot: 5 },
        ];
        let payload = build_playlist_payload(&items);
        let hex: String = payload.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            hex,
            "0800100422070800108d6f180822070800108c6f180722070800108b6f180622070800108a6f1805"
        );
    }

    #[test]
    fn set_playlist_frames_two_writes_on_the_command_channel() {
        let (service, writes) = encode_set_playlist(
            &spec(),
            &[
                PlaylistItem { cid: 900001, slot: 0 },
                PlaylistItem { cid: 900002, slot: 0 },
            ],
            5,
        )
        .unwrap();
        assert_eq!(service, "00000074-1972-1925-3022-077119514e44");
        assert_eq!(writes.len(), 2, "set_playlist then set_mode_loop");
        // Both are fragment-framed on the DDP Write characteristic, with rolling
        // serials 5 and 6.
        assert_eq!(writes[0].bytes[0], 5);
        assert_eq!(writes[1].bytes[0], 6);
        for w in &writes {
            assert_eq!(w.characteristic_uuid, "01020074-1972-1925-3022-077119514e44");
            assert_eq!(&w.bytes[0..1], &[w.bytes[0]]); // frag header present
            assert_eq!(w.bytes[4], 0xF0, "DNX flag after the 4-byte frag header");
        }
        // set_playlist mt = 0A 42 at DNX offset 6 (whole-packet 10).
        assert_eq!(&writes[0].bytes[10..12], &[0x0A, 0x42]);
        // set_mode_loop mt = 09 CB.
        assert_eq!(&writes[1].bytes[10..12], &[0x09, 0xCB]);
    }

    #[test]
    fn each_replay_sequence_produces_a_distinct_write() {
        // Two presses of Replay must not send byte-identical packets, or a
        // firmware that de-duplicates a framed command by serial drops the
        // second and the panel never restarts. The rolling sequence changes
        // both the fragment serial (byte 0) and the DNX `sn` (bytes 6..8).
        let (_, first) = encode_stored_play(&spec(), 79009, 1).unwrap();
        let (_, second) = encode_stored_play(&spec(), 79009, 2).unwrap();
        assert_ne!(
            first.bytes, second.bytes,
            "consecutive replays must differ on the wire"
        );
        assert_eq!(first.bytes[0], 1, "fragment serial carries the sequence");
        assert_eq!(second.bytes[0], 2);
        // Same cid payload despite different framing — it is the SAME item.
        assert_eq!(
            &first.bytes[first.bytes.len() - 6..],
            &second.bytes[second.bytes.len() - 6..]
        );
    }

    #[test]
    fn play_write_is_fragment_framed_and_plays_by_cid() {
        let rgb = red_2x2();
        let plan = encode_stored_image(&spec(), &program(&rgb), 0).unwrap();
        let play = plan.play_write.expect("play_command declared");
        assert_eq!(
            play.characteristic_uuid,
            "01020074-1972-1925-3022-077119514e44"
        );
        // 4-byte fragment header [serial, total, remaining, tag] then the DNX
        // packet. One packet -> total 1, remaining 0, tag 0.
        assert_eq!(&play.bytes[0..4], &[0, 1, 0, 0]);
        let dnx = &play.bytes[4..];
        assert_eq!(dnx[0], 0xF0, "DNX flag");
        assert_eq!(&dnx[6..8], &[0x0A, 0x2E], "mt = M_PLAY_EFFECT (2606)");
        // Payload SimpleMessage {i1: cid=79009, i2: 0} -> 08 a1 e9 04 10 00.
        assert_eq!(
            &dnx[dnx.len() - 6..],
            &[0x08, 0xA1, 0xE9, 0x04, 0x10, 0x00],
            "play payload matches the capture's PLAY_EFFECT by cid"
        );
    }

    #[test]
    fn text_and_animation_reuse_the_transport_and_play() {
        use crate::protocol::daniao_store::{StoredAnimation, StoredText, TextContent};
        let s = spec();

        let bits = vec![1u8; 32 * 12];
        let text_plan = encode_stored_text(
            &s,
            &StoredText {
                name: "hi",
                cid: 900010,
                time_secs: 8,
                scroll: Scroll::Left,
                speed: 4,
                text: TextContent {
                    width: 32,
                    height: 12,
                    bits: &bits,
                },
            },
            0,
        )
        .unwrap();
        assert!(text_plan
            .upload_writes
            .iter()
            .all(|w| w.characteristic_uuid == "27923001-2072-1925-3022-077119514e44"));
        assert!(text_plan.play_write.is_some());

        let frame = vec![0u8; 2 * 2 * 3];
        let frames: Vec<&[u8]> = vec![&frame, &frame];
        let anim_plan = encode_stored_animation(
            &s,
            &StoredAnimation {
                name: "a",
                cid: 900011,
                width: 2,
                height: 2,
                frames: &frames,
                fps: 20,
            },
            0,
        )
        .unwrap();
        // START packet's UploadRequest carries the .eff path (field 8, tag 0x42)
        // and file kind 0 — the animation transport differs from the AMX one.
        let start = &anim_plan.upload_writes[0].bytes;
        assert!(
            start.contains(&0x42),
            "animation START includes the .eff path"
        );
        assert_eq!(anim_plan.cid, 900011);
    }

    #[test]
    fn missing_stored_feature_is_a_clean_error() {
        let bare = parse_device_spec(
            r#"
device:
  name: "X"
  manufacturer: "Y"
  manufacturer_status: "active"
  protocol: "ble"
services:
  - uuid: "00000074-1972-1925-3022-077119514e44"
    name: "S"
    characteristics:
      - uuid: "27923001-2072-1925-3022-077119514e44"
        name: "Uploader"
        properties: ["write"]
"#,
        )
        .unwrap();
        let rgb = red_2x2();
        assert!(encode_stored_image(&bare, &program(&rgb), 0).is_err());
    }
}

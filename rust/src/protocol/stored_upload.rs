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

use super::daniao_store::{self, StoredAnimation, StoredProgram, StoredText};
use super::daniao_upload;
use super::image_upload;
use super::{service_for_characteristic, EncodedWrite};
use crate::codec::types::encode_command_with_bytes;
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, DeviceSpec, Feature};
use std::collections::HashMap;

/// A named container encoder — the entry a spec's `stored_upload.container_format`
/// resolves to. Mirrors [`super::ImageUploadHandler`] for the persisted path;
/// only the container layout is device-specific, the transport is shared.
///
/// Every stored kind is a field, so a new format must supply (or refuse) each
/// one: the encode functions dispatch through the RESOLVED encoder, and a
/// second format can never be handed Daniao's containers by default.
#[derive(Clone, Copy)]
pub struct StoredContainerEncoder {
    pub name: &'static str,
    /// Build the file blob to persist from a canvas + playback options.
    pub build_image: fn(&StoredProgram<'_>) -> Result<Vec<u8>, ProtocolError>,
    /// Build a scrolling-text marquee's file blob.
    pub build_text: fn(&StoredText<'_>) -> Result<Vec<u8>, ProtocolError>,
    /// Build a multi-frame animation's file blob.
    pub build_animation: fn(&StoredAnimation<'_>) -> Result<Vec<u8>, ProtocolError>,
    /// File kind an animation uploads as — a platform fact of this
    /// container, not the spec's `file_type` (the image/text kind).
    pub animation_file_type: u32,
    /// Upload path an animation is filed under, from its cid.
    pub animation_path: fn(u32) -> String,
}

/// Daniao files an `.eff` animation as `<cid>.eff`.
fn daniao_animation_path(cid: u32) -> String {
    format!("{cid}.eff")
}

/// Every implemented stored-content container encoder. Single source of truth
/// for both the DTO's `encodable` flag and the encode dispatch, so a format
/// cannot be advertised without an encoder behind it.
const CONTAINER_ENCODERS: &[StoredContainerEncoder] = &[StoredContainerEncoder {
    name: "daniao_amx",
    build_image: daniao_store::build_image_container,
    build_text: daniao_store::build_text_container,
    build_animation: daniao_store::build_animation_container,
    // The raw "DNMX" `.eff` uploads as file kind 0, where the AMX microapp
    // is the spec's file_type 3.
    animation_file_type: 0,
    animation_path: daniao_animation_path,
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
    max_write: Option<usize>,
    program: &StoredProgram<'_>,
    sequence: u16,
) -> Result<StoredUploadPlan, ProtocolError> {
    encode_stored_image_in(CONTAINER_ENCODERS, spec, max_write, program, sequence)
}

/// [`encode_stored_image`] against an explicit encoder registry, so a test
/// can prove the container comes from the format the spec names.
fn encode_stored_image_in(
    registry: &[StoredContainerEncoder],
    spec: &DeviceSpec,
    max_write: Option<usize>,
    program: &StoredProgram<'_>,
    sequence: u16,
) -> Result<StoredUploadPlan, ProtocolError> {
    let (feature, encoder) = require_stored_feature(registry, spec)?;
    let container = (encoder.build_image)(program)?;
    let file_type = feature.file_type.unwrap_or(3);
    assemble_plan(
        spec,
        feature,
        &container,
        program.cid,
        file_type,
        None,
        sequence,
        max_write,
    )
}

/// Store a scrolling-text marquee ("DN" AMX text layer, same `file_type` as an
/// image microapp).
pub fn encode_stored_text(
    spec: &DeviceSpec,
    max_write: Option<usize>,
    program: &daniao_store::StoredText<'_>,
    sequence: u16,
) -> Result<StoredUploadPlan, ProtocolError> {
    let (feature, encoder) = require_stored_feature(CONTAINER_ENCODERS, spec)?;
    let container = (encoder.build_text)(program)?;
    let file_type = feature.file_type.unwrap_or(3);
    assemble_plan(
        spec,
        feature,
        &container,
        program.cid,
        file_type,
        None,
        sequence,
        max_write,
    )
}

/// Store a multi-frame animation (raw "DNMX" `.eff`).
///
/// The file kind and path come from the container encoder (Daniao's `.eff`
/// is file kind 0 at `<cid>.eff`) — a platform fact tied to that container
/// kind, not the spec's default `file_type` (the AMX microapp's 3). Both are
/// played back the same way (by cid).
pub fn encode_stored_animation(
    spec: &DeviceSpec,
    max_write: Option<usize>,
    anim: &daniao_store::StoredAnimation<'_>,
    sequence: u16,
) -> Result<StoredUploadPlan, ProtocolError> {
    let (feature, encoder) = require_stored_feature(CONTAINER_ENCODERS, spec)?;
    let container = (encoder.build_animation)(anim)?;
    let path = (encoder.animation_path)(anim.cid);
    assemble_plan(
        spec,
        feature,
        &container,
        anim.cid,
        encoder.animation_file_type,
        Some(&path),
        sequence,
        max_write,
    )
}

/// Validate that `spec` declares a `stored_upload` feature whose
/// `container_format` `registry` implements, returning the feature and the
/// encoder that builds its containers.
fn require_stored_feature<'s, 'r>(
    registry: &'r [StoredContainerEncoder],
    spec: &'s DeviceSpec,
) -> Result<(&'s Feature, &'r StoredContainerEncoder), ProtocolError> {
    let feature = stored_feature(spec).ok_or_else(|| ProtocolError::ImageUploadUnsupported {
        reason: "spec declares no stored_upload feature".to_string(),
    })?;
    let format = feature.container_format.as_deref().ok_or_else(|| {
        ProtocolError::ImageUploadUnsupported {
            reason: "stored_upload feature names no container_format".to_string(),
        }
    })?;
    let encoder = registry.iter().find(|e| e.name == format).ok_or_else(|| {
        ProtocolError::ImageUploadUnsupported {
            reason: format!("no container encoder registered for '{format}' in this build"),
        }
    })?;
    Ok((feature, encoder))
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
    max_write: Option<usize>,
) -> Result<StoredUploadPlan, ProtocolError> {
    let spec_frame = feature
        .frame_size
        .map(|n| n as usize)
        .unwrap_or(daniao_upload::DEFAULT_FRAME_SIZE);
    // The spec's frame size is what the vendor app sends over a link it has
    // negotiated a 512-byte MTU on. Each DATA packet is the frame plus the
    // 8-byte header, and flutter_blue_plus refuses a write longer than
    // MTU - 3 outright — so on any link with MTU < 511 (every iPhone that has
    // not finished negotiating, most Android stacks by default) every save
    // failed on the first DATA packet. `max_write` is the usable bytes per
    // write the caller measured on the live link; the frame shrinks to fit.
    let frame_size = match max_write {
        Some(budget) => spec_frame.min(budget.saturating_sub(daniao_upload::HEADER_LEN).max(1)),
        None => spec_frame,
    };
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

    // `max_write` shrank the DATA frames above. The START packet (the header
    // plus the upload_request protobuf) and the play write are single,
    // unsplittable packets the frame size does not touch, and on the 20-byte
    // budget Dart falls back to when the MTU read fails — every iPhone that
    // has not finished negotiating — the very first write already exceeded
    // it. The save then died at the first write with the plugin's error, or
    // sat through the "unconfirmed" timeout. Refused here instead, with the
    // one thing the user can do.
    if let Some(budget) = max_write {
        let over = transfer
            .writes
            .first()
            .filter(|w| w.bytes.len() > budget)
            .map(|w| ("the upload's START packet", w.bytes.len()))
            .or_else(|| {
                play_write
                    .as_ref()
                    .filter(|w| w.bytes.len() > budget)
                    .map(|w| ("the play command", w.bytes.len()))
            });
        if let Some((what, len)) = over {
            return Err(ProtocolError::ImageUploadUnsupported {
                reason: format!(
                    "{what} is {len} bytes and this link accepts writes of at most \
                     {budget}: the MTU has not been negotiated. Reconnect to the \
                     device and try again"
                ),
            });
        }
    }

    Ok(StoredUploadPlan {
        service_uuid,
        upload_writes: transfer.writes,
        play_write,
        response_characteristic_uuid: feature.response_characteristic.clone(),
        cid,
    })
}

/// Encode the play-by-id command and frame it for its characteristic, so it
/// is honoured (the controller ignores unframed command writes).
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
    let params = HashMap::from([
        ("effect_id".to_string(), cid as f64),
        ("slot".to_string(), 0.0),
    ]);
    build_framed_command(spec, command_name, params, HashMap::new(), sequence)
}

/// One playlist entry: a stored effect's id (cid) and its device slot.
pub struct PlaylistItem {
    pub cid: u32,
    pub slot: u32,
}

/// Encode the M_BOOKMARK_SAVE write that populates a bookmark/playlist with a
/// set of stored effects (each frame of a multi-frame animation is one stored
/// type-3 microapp). This is ONLY the save — the vendor's full sequence is
/// `bookmark_clear` -> `bookmark_enable` -> this -> `play_next`; the caller
/// sends the clear/enable/play around it (see the FFI wrappers). An earlier
/// version also emitted M_SET_MODE_LOOP (0x09CB), which the vendor NEVER sends
/// and which did not scope playback — that write is gone. `sequence` seeds the
/// write's rolling serial.
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
    let service =
        service_for_characteristic(spec, &set_pl.characteristic_uuid).ok_or_else(|| {
            ProtocolError::ImageUploadUnsupported {
                reason: "the set_playlist characteristic belongs to no service".to_string(),
            }
        })?;
    Ok((service, vec![set_pl]))
}

/// A `SimpleMessage {i1: value}` protobuf payload — `08 <varint>`. The shape a
/// handful of DDP commands carry (play speed, autorun mode, remove-by-cid).
fn simple_message_i1(value: u32) -> Vec<u8> {
    let mut payload = vec![0x08];
    write_varint(&mut payload, value as u64);
    payload
}

/// Frame a command whose only payload is `SimpleMessage {i1: value}`, resolving
/// its service. Shared by the play-speed / autorun / remove-app encoders.
fn encode_simple_i1_command(
    spec: &DeviceSpec,
    command: &str,
    value: u32,
    sequence: u16,
) -> Result<(String, EncodedWrite), ProtocolError> {
    let write = build_framed_command(
        spec,
        command,
        HashMap::new(),
        HashMap::from([("payload".to_string(), simple_message_i1(value))]),
        sequence,
    )?;
    let service =
        service_for_characteristic(spec, &write.characteristic_uuid).ok_or_else(|| {
            ProtocolError::ImageUploadUnsupported {
                reason: format!("the {command} characteristic belongs to no service"),
            }
        })?;
    Ok((service, write))
}

/// Encode M_SET_PLAY_SPEED — the global speed at which the device advances
/// effects/the playlist. SimpleMessage `{i1: speed}` (the vendor's slider,
/// default 100). Used to pace a multi-frame animation's cycle.
pub fn encode_play_speed(
    spec: &DeviceSpec,
    speed: u32,
    sequence: u16,
) -> Result<(String, EncodedWrite), ProtocolError> {
    encode_simple_i1_command(spec, "set_play_speed", speed, sequence)
}

/// Encode M_SET_AUTORUN_MODE — the real play/loop-mode control. `mode` is
/// `fixed(0) | repeat(1) | random(2)`. Sending `fixed(0)` after playing a
/// stored design makes the device HOLD that one effect across disconnect
/// instead of autorunning/randomly cycling every stored effect.
pub fn encode_autorun_mode(
    spec: &DeviceSpec,
    mode: u32,
    sequence: u16,
) -> Result<(String, EncodedWrite), ProtocolError> {
    encode_simple_i1_command(spec, "set_autorun_mode", mode, sequence)
}

/// Encode M_BOOKMARK_ENABLE — ACTIVATE bookmark/playlist `list_id` so the device
/// plays only its items. SimpleMessage `{i1: listId}`. Without this the device
/// keeps autorunning its whole stored set, so `play_next` cycles every effect
/// rather than the list (the decompiled app sends this on playlist select).
pub fn encode_bookmark_enable(
    spec: &DeviceSpec,
    list_id: u32,
    sequence: u16,
) -> Result<(String, EncodedWrite), ProtocolError> {
    encode_simple_i1_command(spec, "bookmark_enable", list_id, sequence)
}

/// Encode M_BOOKMARK_CLEAR — empty bookmark/playlist `list_id`. SimpleMessage
/// `{i1: listId}`. Sent before `set_playlist` so a re-save replaces the list
/// rather than accumulating stale items across saves.
pub fn encode_bookmark_clear(
    spec: &DeviceSpec,
    list_id: u32,
    sequence: u16,
) -> Result<(String, EncodedWrite), ProtocolError> {
    encode_simple_i1_command(spec, "bookmark_clear", list_id, sequence)
}

/// Encode M_REMOVE_APP — delete ONE stored user design (DIY micro-app) by its
/// cid. SimpleMessage `{i1: cid}` (the vendor sends only the cid, not the slot).
pub fn encode_remove_app(
    spec: &DeviceSpec,
    cid: u32,
    sequence: u16,
) -> Result<(String, EncodedWrite), ProtocolError> {
    encode_simple_i1_command(spec, "remove_app", cid, sequence)
}

/// Encode M_REMOVE_ALL_APPS — clear all stored micro-apps in one command
/// (header only). Best-effort (the vendor app deletes one-by-one instead).
pub fn encode_remove_all_apps(
    spec: &DeviceSpec,
    sequence: u16,
) -> Result<(String, EncodedWrite), ProtocolError> {
    let write = build_framed_command(
        spec,
        "remove_all_apps",
        HashMap::new(),
        HashMap::new(),
        sequence,
    )?;
    let service =
        service_for_characteristic(spec, &write.characteristic_uuid).ok_or_else(|| {
            ProtocolError::ImageUploadUnsupported {
                reason: "the remove_all_apps characteristic belongs to no service".to_string(),
            }
        })?;
    Ok((service, write))
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
/// optional `bytes` payload — then frame it for the characteristic that
/// declares it. `sequence` drives both the DNX `sn` (overriding the
/// template's `auto: sequence`, which the codec would fill with 0) and the
/// fragment serial, so a repeat command is a distinct packet on both layers.
///
/// Framing goes through [`image_upload::frame_command`], the one reader of
/// the `framing` block: it applies the DECLARED scheme, refuses one this
/// build does not implement or a malformed `channel_tag`, and passes an
/// unframed characteristic through. This path used to call the Daniao
/// fragmenter directly and parse `channel_tag` by hand, so a command on an
/// unframed (or differently framed) characteristic still went out with a
/// Daniao header, and the two readers once disagreed about the tag.
fn build_framed_command(
    spec: &DeviceSpec,
    command_name: &str,
    mut params: HashMap<String, f64>,
    bytes_params: HashMap<String, Vec<u8>>,
    sequence: u16,
) -> Result<EncodedWrite, ProtocolError> {
    let characteristic = command_characteristic(spec, command_name).ok_or_else(|| {
        ProtocolError::CommandNotFound {
            uuid: "<any>".to_string(),
            command: command_name.to_string(),
        }
    })?;
    let command = characteristic
        .commands
        .as_ref()
        .and_then(|c| c.get(command_name))
        .ok_or_else(|| ProtocolError::CommandNotFound {
            uuid: characteristic.uuid.clone(),
            command: command_name.to_string(),
        })?;
    params.insert("sn".to_string(), sequence as f64);
    let dnx = encode_command_with_bytes(command, &params, &bytes_params)?;
    // The fragment serial is one byte on the wire; the u16 counter's low
    // byte is what the Daniao header always carried.
    let bytes = image_upload::frame_command(characteristic, dnx, sequence as u8)?;
    Ok(EncodedWrite {
        characteristic_uuid: characteristic.uuid.clone(),
        bytes,
    })
}

/// The characteristic declaring `command_name`, found by which one declares
/// it rather than by a hardcoded UUID, so a command can live on whichever
/// channel the spec puts it.
fn command_characteristic<'a>(
    spec: &'a DeviceSpec,
    command_name: &str,
) -> Option<&'a Characteristic> {
    spec.services
        .iter()
        .flat_map(|service| &service.characteristics)
        .find(|characteristic| {
            characteristic
                .commands
                .as_ref()
                .is_some_and(|c| c.contains_key(command_name))
        })
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
          bookmark_enable:
            description: "Enable a bookmark/playlist."
            template: [0xF0, 0x04, "{sn}", "{len}", 0x0A, 0x3F, "{cid}", "{osn}", 0x00, "{ts}", 0x00, 0x00, 0x00, 0x00, "{payload}"]
            parameters:
              sn: { type: "uint16", endianness: "big", auto: "sequence" }
              len: { type: "uint16", endianness: "big", auto: "packet_length" }
              cid: { type: "uint32", endianness: "big", default: 0 }
              osn: { type: "uint16", endianness: "big", default: 1 }
              ts: { type: "uint8", default: 0 }
              payload: { type: "bytes" }
          bookmark_clear:
            description: "Clear a bookmark/playlist."
            template: [0xF0, 0x04, "{sn}", "{len}", 0x0A, 0x41, "{cid}", "{osn}", 0x00, "{ts}", 0x00, 0x00, 0x00, 0x00, "{payload}"]
            parameters:
              sn: { type: "uint16", endianness: "big", auto: "sequence" }
              len: { type: "uint16", endianness: "big", auto: "packet_length" }
              cid: { type: "uint32", endianness: "big", default: 0 }
              osn: { type: "uint16", endianness: "big", default: 1 }
              ts: { type: "uint8", default: 0 }
              payload: { type: "bytes" }
          set_autorun_mode:
            description: "Set play/loop mode."
            template: [0xF0, 0x04, "{sn}", "{len}", 0x09, 0xD0, "{cid}", "{osn}", 0x00, "{ts}", 0x00, 0x00, 0x00, 0x00, "{payload}"]
            parameters:
              sn: { type: "uint16", endianness: "big", auto: "sequence" }
              len: { type: "uint16", endianness: "big", auto: "packet_length" }
              cid: { type: "uint32", endianness: "big", default: 0 }
              osn: { type: "uint16", endianness: "big", default: 1 }
              ts: { type: "uint8", default: 0 }
              payload: { type: "bytes" }
          remove_app:
            description: "Delete a stored design by cid."
            template: [0xF0, 0x04, "{sn}", "{len}", 0x0B, 0x5D, "{cid}", "{osn}", 0x00, "{ts}", 0x00, 0x00, 0x00, 0x00, "{payload}"]
            parameters:
              sn: { type: "uint16", endianness: "big", auto: "sequence" }
              len: { type: "uint16", endianness: "big", auto: "packet_length" }
              cid: { type: "uint32", endianness: "big", default: 0 }
              osn: { type: "uint16", endianness: "big", default: 1 }
              ts: { type: "uint8", default: 0 }
              payload: { type: "bytes" }
          remove_all_apps:
            description: "Clear all stored designs."
            template: [0xF0, 0x04, "{sn}", "{len}", 0x0B, 0x80, "{cid}", "{osn}", 0x00, "{ts}", 0x00, 0x00, 0x00, 0x00]
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

    /// A second container format with nothing in common with Daniao AMX.
    fn marker_image(_: &StoredProgram<'_>) -> Result<Vec<u8>, ProtocolError> {
        Ok(b"NOT-AN-AMX-CONTAINER".to_vec())
    }
    fn refuse_text(_: &StoredText<'_>) -> Result<Vec<u8>, ProtocolError> {
        Err(ProtocolError::EmptyCommand)
    }
    fn refuse_animation(_: &StoredAnimation<'_>) -> Result<Vec<u8>, ProtocolError> {
        Err(ProtocolError::EmptyCommand)
    }
    const TWO_FORMATS: &[StoredContainerEncoder] = &[
        CONTAINER_ENCODERS[0],
        StoredContainerEncoder {
            name: "other_fmt",
            build_image: marker_image,
            build_text: refuse_text,
            build_animation: refuse_animation,
            animation_file_type: 9,
            animation_path: daniao_animation_path,
        },
    ];

    /// The container comes from the encoder the spec's `container_format`
    /// resolves to. The registry lookup used to be an existence check only,
    /// and the image path called Daniao's AMX builder regardless — so a
    /// second registered format would have put AMX bytes on its wire.
    #[test]
    fn the_container_comes_from_the_resolved_format() {
        let rgb = red_2x2();
        let other = parse_device_spec(&SPEC.replace(r#""daniao_amx""#, r#""other_fmt""#)).unwrap();
        let plan = encode_stored_image_in(TWO_FORMATS, &other, None, &program(&rgb), 0).unwrap();
        let stream: Vec<u8> = plan
            .upload_writes
            .iter()
            .flat_map(|w| w.bytes.iter().copied())
            .collect();
        assert!(
            stream
                .windows(b"NOT-AN-AMX-CONTAINER".len())
                .any(|w| w == b"NOT-AN-AMX-CONTAINER"),
            "the other format's container must be what is uploaded"
        );
        // And the Daniao spec still gets exactly the AMX container.
        let daniao = encode_stored_image_in(TWO_FORMATS, &spec(), None, &program(&rgb), 0).unwrap();
        let shipped = encode_stored_image(&spec(), None, &program(&rgb), 0).unwrap();
        assert_eq!(
            daniao
                .upload_writes
                .iter()
                .map(|w| &w.bytes)
                .collect::<Vec<_>>(),
            shipped
                .upload_writes
                .iter()
                .map(|w| &w.bytes)
                .collect::<Vec<_>>()
        );
    }

    #[test]
    fn plan_has_uploader_writes_targeting_the_uploader_characteristic() {
        let rgb = red_2x2();
        let plan = encode_stored_image(&spec(), None, &program(&rgb), 0).unwrap();
        assert!(!plan.upload_writes.is_empty());
        assert!(plan
            .upload_writes
            .iter()
            .all(|w| w.characteristic_uuid == "27923001-2072-1925-3022-077119514e44"));
        assert_eq!(plan.service_uuid, "00000074-1972-1925-3022-077119514e44");
        assert_eq!(plan.cid, 79009);
    }

    #[test]
    fn data_packets_shrink_to_the_write_budget() {
        // A 2x2 picture is well under one spec frame (500 bytes + 8 header),
        // so without a budget the whole container rides in one DATA write.
        // On a link whose usable write is 64 bytes every write has to fit,
        // header included; the spec's frame size only ever caps it.
        let rgb = red_2x2();
        let unbounded = encode_stored_image(&spec(), None, &program(&rgb), 0).unwrap();
        let bounded = encode_stored_image(&spec(), Some(64), &program(&rgb), 0).unwrap();
        assert!(bounded.upload_writes.len() > unbounded.upload_writes.len());
        assert!(bounded.upload_writes.iter().all(|w| w.bytes.len() <= 64));
        // A budget larger than the spec frame changes nothing.
        let roomy = encode_stored_image(&spec(), Some(4096), &program(&rgb), 0).unwrap();
        assert_eq!(roomy.upload_writes.len(), unbounded.upload_writes.len());
        // An absurd budget is a typed refusal, never a panic and never a plan
        // whose first write the link cannot carry: the START packet is a
        // single unsplittable packet, and a budget below it used to produce
        // DATA frames of a few bytes behind a START the plugin would refuse
        // on the first write.
        let Err(tiny) = encode_stored_image(&spec(), Some(3), &program(&rgb), 0) else {
            panic!("a 3-byte budget cannot carry the START packet");
        };
        assert!(
            matches!(tiny, ProtocolError::ImageUploadUnsupported { ref reason } if reason.contains("START packet")),
            "{tiny:?}"
        );
    }

    #[test]
    fn plan_names_the_response_characteristic_from_the_spec() {
        let rgb = red_2x2();
        let plan = encode_stored_image(&spec(), None, &program(&rgb), 0).unwrap();
        assert_eq!(
            plan.response_characteristic_uuid.as_deref(),
            Some("01010074-1972-1925-3022-077119514e44"),
            "the caller needs to know where to await the upload completion"
        );
    }

    #[test]
    fn stored_play_replays_by_cid_without_an_upload() {
        let rgb = red_2x2();
        let plan = encode_stored_image(&spec(), None, &program(&rgb), 0).unwrap();
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
            PlaylistItem {
                cid: 14221,
                slot: 8,
            },
            PlaylistItem {
                cid: 14220,
                slot: 7,
            },
            PlaylistItem {
                cid: 14219,
                slot: 6,
            },
            PlaylistItem {
                cid: 14218,
                slot: 5,
            },
        ];
        let payload = build_playlist_payload(&items);
        let hex: String = payload.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(
            hex,
            "0800100422070800108d6f180822070800108c6f180722070800108b6f180622070800108a6f1805"
        );
    }

    #[test]
    fn set_playlist_is_one_bookmark_save_write_no_mode_loop() {
        let (service, writes) = encode_set_playlist(
            &spec(),
            &[
                PlaylistItem {
                    cid: 900001,
                    slot: 0,
                },
                PlaylistItem {
                    cid: 900002,
                    slot: 0,
                },
            ],
            5,
        )
        .unwrap();
        assert_eq!(service, "00000074-1972-1925-3022-077119514e44");
        // ONLY the bookmark_save — the bogus M_SET_MODE_LOOP (0x09CB) the vendor
        // never sends is gone; clear/enable/play are separate writes now.
        assert_eq!(writes.len(), 1, "just M_BOOKMARK_SAVE");
        let w = &writes[0];
        assert_eq!(w.bytes[0], 5, "fragment serial carries the sequence");
        assert_eq!(
            w.characteristic_uuid,
            "01020074-1972-1925-3022-077119514e44"
        );
        assert_eq!(w.bytes[4], 0xF0, "DNX flag after the 4-byte frag header");
        // set_playlist mt = 0A 42 (M_BOOKMARK_SAVE) at whole-packet offset 10.
        assert_eq!(&w.bytes[10..12], &[0x0A, 0x42]);
    }

    #[test]
    fn bookmark_enable_and_clear_are_simple_i1_on_the_command_channel() {
        // bookmark_enable {i1: listId} -> mt 0A 3F, payload 08 <listId>
        let (service, en) = encode_bookmark_enable(&spec(), 0, 7).unwrap();
        assert_eq!(service, "00000074-1972-1925-3022-077119514e44");
        assert_eq!(en.bytes[0], 7, "fragment serial carries the sequence");
        assert_eq!(&en.bytes[10..12], &[0x0A, 0x3F], "mt = M_BOOKMARK_ENABLE");
        assert_eq!(
            &en.bytes[en.bytes.len() - 2..],
            &[0x08, 0x00],
            "i1=0 payload"
        );
        // bookmark_clear {i1: listId} -> mt 0A 41
        let (_s, cl) = encode_bookmark_clear(&spec(), 0, 8).unwrap();
        assert_eq!(&cl.bytes[10..12], &[0x0A, 0x41], "mt = M_BOOKMARK_CLEAR");
        assert_eq!(
            &cl.bytes[cl.bytes.len() - 2..],
            &[0x08, 0x00],
            "i1=0 payload"
        );
    }

    /// `framing.channel_tag` was read as `.as_u64().unwrap_or(0) as u8`, so
    /// every malformed spelling — a value past a byte, a negative, a word —
    /// silently became 0, the Daniao COMMAND channel. A bulk write framed for
    /// the command channel is a write the device drops with no error anywhere.
    /// Framing now goes through `image_upload::frame_command`, whose typed
    /// `Option<u8>` has always refused these.
    #[test]
    fn a_channel_tag_that_is_not_a_byte_is_refused_not_truncated_to_zero() {
        for hostile in ["256", "-1", "\"bulk\""] {
            let yaml = SPEC.replace(
                r#"framing: { scheme: "daniao_fragment", channel_tag: 0 }"#,
                &format!(r#"framing: {{ scheme: "daniao_fragment", channel_tag: {hostile} }}"#),
            );
            let spec = parse_device_spec(&yaml).expect("fixture parses");
            let error = encode_bookmark_enable(&spec, 0, 7)
                .expect_err("a malformed channel tag must not frame as channel 0");
            assert!(
                matches!(&error, ProtocolError::InvalidFraming { .. }),
                "{hostile}: {error}"
            );
            // The reason reaches the UI; a joined source line once left a
            // run of indentation spaces in the middle of it.
            assert!(!error.to_string().contains("  "), "{error:?}");
        }
    }

    /// An UNSTATED tag is still 0 — that is the scheme's own default and the
    /// BIN characteristic in this fixture relies on it.
    #[test]
    fn an_unstated_channel_tag_is_still_zero() {
        let yaml = SPEC.replace(
            r#"framing: { scheme: "daniao_fragment", channel_tag: 0 }"#,
            r#"framing: { scheme: "daniao_fragment" }"#,
        );
        let spec = parse_device_spec(&yaml).expect("fixture parses");
        let (_service, write) = encode_bookmark_enable(&spec, 0, 7).expect("encodes");
        assert_eq!(write.bytes[3], 0, "the fragment header's tag byte");
    }

    /// A command on a characteristic with no `framing` block went out with a
    /// Daniao fragment header anyway: this path called the fragmenter
    /// directly and never read `framing.scheme`, while the generic BLE path
    /// passes the same spec's write through unframed.
    #[test]
    fn a_command_on_an_unframed_characteristic_is_not_fragment_framed() {
        let yaml = SPEC.replace(
            r#"        framing: { scheme: "daniao_fragment", channel_tag: 0 }
"#,
            "",
        );
        assert_ne!(yaml, SPEC, "the fixture's framing line was removed");
        let spec = parse_device_spec(&yaml).expect("fixture parses");
        let (_service, write) = encode_bookmark_enable(&spec, 0, 7).expect("encodes");
        assert_eq!(
            write.bytes[0], 0xF0,
            "the DNX flag leads; no fragment header"
        );
    }

    /// A scheme this build does not implement is refused, never framed as
    /// Daniao: the old path ignored `framing.scheme` entirely.
    #[test]
    fn a_command_on_an_unimplemented_scheme_is_refused() {
        let yaml = SPEC.replace(
            r#"framing: { scheme: "daniao_fragment", channel_tag: 0 }"#,
            r#"framing: { scheme: "some_other_fragment", channel_tag: 0 }"#,
        );
        let spec = parse_device_spec(&yaml).expect("fixture parses");
        let error = encode_bookmark_enable(&spec, 0, 7)
            .expect_err("an unimplemented scheme must not be framed as Daniao");
        assert!(
            matches!(&error, ProtocolError::InvalidFraming { .. }),
            "{error}"
        );
    }

    #[test]
    fn autorun_mode_encodes_fixed() {
        // set_autorun_mode {i1: 0} (fixed): F0 04 | sn | len | 09 D0 | header | 08 00
        let (service, w) = encode_autorun_mode(&spec(), 0, 3).unwrap();
        assert_eq!(service, "00000074-1972-1925-3022-077119514e44");
        assert_eq!(w.bytes[0], 3, "fragment serial carries the sequence");
        assert_eq!(w.bytes[4], 0xF0);
        assert_eq!(&w.bytes[10..12], &[0x09, 0xD0], "mt = M_SET_AUTORUN_MODE");
        // payload {i1:0} = 08 00 at the tail.
        assert_eq!(&w.bytes[w.bytes.len() - 2..], &[0x08, 0x00]);
    }

    #[test]
    fn remove_app_encodes_cid_only() {
        // remove_app {i1: cid}: mt 0B 5D, payload 08 <cid varint>. cid 79009 = a1 e9 04.
        let (_, w) = encode_remove_app(&spec(), 79009, 4).unwrap();
        assert_eq!(&w.bytes[10..12], &[0x0B, 0x5D], "mt = M_REMOVE_APP");
        assert_eq!(
            &w.bytes[w.bytes.len() - 4..],
            &[0x08, 0xA1, 0xE9, 0x04],
            "payload SimpleMessage {{i1: cid}} — cid only, no slot"
        );
    }

    #[test]
    fn remove_all_apps_is_header_only() {
        let (_, w) = encode_remove_all_apps(&spec(), 5).unwrap();
        assert_eq!(&w.bytes[10..12], &[0x0B, 0x80], "mt = M_REMOVE_ALL_APPS");
        // header-only: 4-byte frag + 20-byte DNX = 24, no payload.
        assert_eq!(w.bytes.len(), 24);
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
        let plan = encode_stored_image(&spec(), None, &program(&rgb), 0).unwrap();
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
            None,
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
            None,
            &StoredAnimation {
                name: "a",
                cid: 900011,
                width: 2,
                height: 2,
                frames: &frames,
                timestamp: 0,
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
        assert!(encode_stored_image(&bare, None, &program(&rgb), 0).is_err());
    }
}

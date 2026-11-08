// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! LOY SPACE / popled.cn LED panels — `protocol_handler: "popled_json"`.
//!
//! The specs describe the vendor app's view: JSON commands such as
//! `{"cmd":{"light":{"type":0,"value_fix":N}}}`, which its native library
//! turns into binary TLV. The JSON never crosses the link. What the panel
//! hears, confirmed against a real backpack (`YS525C…`, 64x64, firmware
//! V2.8.8) on 2026-11-08:
//!
//! ```text
//! aa 55 ff ff | len u16le | seq u16le | body | checksum u16le
//!   len      = 2 (seq) + body + 2 (checksum)
//!   checksum = additive sum of every preceding byte
//!   body     = c1 02 <TLVs>        a write
//!              c1 03 <type> 00 ... a query, one empty TLV per field wanted
//! reply body = 81 82 <status>      a write's acknowledgement; 0 is success
//!              81 83 <TLVs>        a query's answer
//! ```
//!
//! Each frame goes to FFF2 without response and is answered on FFF1. The
//! panel echoes `seq` but does not judge it: repeating one is accepted.
//!
//! Three things the bench settled that the catalogue words differently, all
//! recorded in `SPECS_TO_FIX.md`: the upload's chunk count is little-endian,
//! a BLE write carries no outer length prefix, and power takes an explicit
//! state rather than toggling.
//!
//! # Where the commands come from
//!
//! A spec's `encoding: "json"` commands can state the app's JSON and nothing
//! else, so [`bind_commands`] gives the ones whose wire form is known real
//! templates when the spec is parsed, and marks the characteristic as framed
//! by [`FRAME_SCHEME`]. From there they are ordinary commands: the same
//! encoder, the same entity binding, the same "can this be sent" gates. The
//! commands no capture has pinned down (rotation, `rt_draw`, `game`, `pwd`)
//! stay `encoding: "json"` and so stay honestly unsendable.
//!
//! # Uploading
//!
//! The panel is a GIF player with sixty persistent program slots: a program
//! is a verbatim GIF89a, streamed in 960-byte chunks, one acknowledged frame
//! at a time. Nothing here talks to a canvas, so an upload survives power
//! loss, and a multi-frame GIF animates with no connection held.

use super::image_upload::{declared_max_chunk_size, validate_rgb_canvas, MIN_PAYLOAD_PER_WRITE};
use super::{EncodedFrame, EncodedWrite, ReplyWait};
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, CharacteristicProperty, Command, DeviceSpec};

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "popled_json";

/// The `framing.scheme` [`bind_commands`] states on a popled write
/// characteristic. Not a name any spec writes: the catalogue's `framing`
/// there says only `length_prefix` and `max_chunk_size`.
pub const FRAME_SCHEME: &str = crate::codec::types::POPLED_FRAME_SCHEME;

const FRAME_MAGIC: [u8; 4] = [0xAA, 0x55, 0xFF, 0xFF];

/// Magic, length and sequence ahead of a frame's body.
pub const FRAME_HEADER_LEN: usize = 8;

/// Bytes of GIF per upload chunk, and of the chunk-size field the panel is
/// told (`c0 03` on the wire).
const RESOURCE_CHUNK: usize = 960;

/// Largest single BLE write when a characteristic declares no
/// `framing.max_chunk_size`: the vendor app's initial write size.
const DEFAULT_WRITE_CHUNK: usize = 180;

/// The slot this app's uploads occupy: the last of the panel's sixty, which
/// the vendor app fills from the other end. An upload therefore replaces the
/// previous upload from here and leaves the owner's own programs alone.
const PROGRAM_SLOT: u8 = 59;

/// How long the panel gets to acknowledge one frame. A chunk is stored to
/// flash before it answers; a measured chunk took well under a second.
const ACK_TIMEOUT_MS: u32 = 5_000;

/// Gap between BLE writes of one frame, from the vendor's own send path:
/// write-without-response has no back-pressure of its own, and the panel
/// drops the tail of what it cannot absorb.
const INTER_WRITE_DELAY_MS: u32 = 5;

/// Query TLV naming the device-information record (`0a`) and panel-parameter
/// record (`1b`) in a reply; see [`decode_panel_size`].
const TLV_DEVICE_INFO: u8 = 0x0A;
const TLV_PANEL: u8 = 0x1B;
const BODY_ANSWER: [u8; 2] = [0x81, 0x83];

/// Every known wire form, by the spec's command name. YAML, so the
/// `parameters` and `template` here read exactly as a spec's would and go
/// through the same deserializer.
const WIRE_COMMANDS: &[(&str, &str)] = &[
    (
        "set_brightness",
        r#"
description: ""
template: [0xC1, 0x02, 0x06, 0x02, 0x00, "{brightness}"]
parameters:
  brightness: { type: "uint8", min: 1, max: 15, default: 15 }
"#,
    ),
    (
        "power_toggle",
        r#"
description: ""
template: [0xC1, 0x02, 0x04, 0x02, 0x00, "{state}"]
parameters:
  state: { type: "uint8", min: 0, max: 1, default: 1 }
"#,
    ),
    (
        "get_device_info",
        r#"
description: ""
value: [0xC1, 0x03, 0x0A, 0x00, 0x1B, 0x00, 0x04, 0x00, 0x06, 0x00]
"#,
    ),
    (
        "get_power_state",
        r#"
description: ""
value: [0xC1, 0x03, 0x04, 0x00]
"#,
    ),
    (
        "get_brightness",
        r#"
description: ""
value: [0xC1, 0x03, 0x06, 0x00]
"#,
    ),
    (
        "delete_all_programs",
        r#"
description: ""
value: [0xC1, 0x02, 0x08, 0x02, 0x00, 0xFF]
"#,
    ),
];

/// Give a popled spec's JSON commands their wire form. Runs at parse time so
/// that every later consumer sees ordinary, sendable commands; a spec naming
/// any other handler is untouched.
pub fn bind_commands(spec: &mut DeviceSpec) {
    if spec.protocol_handler.as_deref() != Some(HANDLER_NAME) {
        return;
    }
    // The vendored features differ in how they state size (nothing, a bound,
    // `device_reported`), and all three are the same fact: every panel in
    // this family answers with its size, and the answer is the only one
    // that holds across the 16x16 leg bag and the 64x64 backpack.
    for feature in &mut spec.features {
        if feature.feature_type == "image_upload" {
            feature.resolution_source = Some("device_reported".to_string());
        }
    }
    for service in &mut spec.services {
        for characteristic in &mut service.characteristics {
            let Some(commands) = characteristic.commands.as_mut() else {
                continue;
            };
            let mut bound = false;
            for (name, command) in commands.iter_mut() {
                if command.encoding.as_deref() != Some("json") {
                    continue;
                }
                let Some((_, wire)) = WIRE_COMMANDS.iter().find(|(n, _)| n == name) else {
                    continue;
                };
                let Ok(parsed) = serde_yaml::from_str::<Command>(wire) else {
                    debug_assert!(false, "unparseable wire command {name}");
                    continue;
                };
                command.value = parsed.value;
                command.template = parsed.template;
                command.parameters = parsed.parameters;
                command.encoding = None;
                command.payload = None;
                bound = true;
            }
            if bound {
                let mut framing = serde_yaml::Mapping::new();
                framing.insert("scheme".into(), FRAME_SCHEME.into());
                if let Some(size) = declared_max_chunk_size(characteristic) {
                    framing.insert("max_chunk_size".into(), (size as u64).into());
                }
                characteristic.framing = Some(serde_yaml::Value::Mapping(framing));
            }
        }
    }
}

/// One complete frame around `body`.
pub fn frame(seq: u16, body: &[u8]) -> Vec<u8> {
    let declared = (body.len() + 4) as u16;
    let mut out = Vec::with_capacity(FRAME_HEADER_LEN + body.len() + 2);
    out.extend_from_slice(&FRAME_MAGIC);
    out.extend_from_slice(&declared.to_le_bytes());
    out.extend_from_slice(&seq.to_le_bytes());
    out.extend_from_slice(body);
    let sum = out.iter().fold(0u16, |acc, b| acc.wrapping_add(*b as u16));
    out.extend_from_slice(&sum.to_le_bytes());
    out
}

/// [`FRAME_SCHEME`] as a [`super::image_upload::FragmentScheme`]: one packet
/// is one frame. The panel's own serial is 16 bits, but it does not judge it,
/// so the 8 bits a command's `sn` carries are as good as any.
pub fn fragment_packet(request: super::image_upload::FragmentRequest<'_>) -> Vec<Vec<u8>> {
    vec![frame(request.serial as u16, request.packet)]
}

/// The characteristics a popled upload needs: where frames go, and where
/// their acknowledgements come back.
fn resolve_channels(
    spec: &DeviceSpec,
) -> Result<(&Characteristic, &Characteristic), ProtocolError> {
    for service in &spec.services {
        let write = service
            .characteristics
            .iter()
            .find(|c| crate::codec::types::framing_scheme_name(c).as_deref() == Some(FRAME_SCHEME));
        let notify = service
            .characteristics
            .iter()
            .find(|c| c.properties.contains(&CharacteristicProperty::Notify));
        if let (Some(write), Some(notify)) = (write, notify) {
            return Ok((write, notify));
        }
    }
    Err(ProtocolError::ImageUploadUnsupported {
        reason: "the spec declares no popled write and notify characteristic pair".to_string(),
    })
}

/// A GIF89a of one still image.
pub fn encode_gif(rgb: &[u8], width: u32, height: u32) -> Result<Vec<u8>, ProtocolError> {
    encode_animated_gif(&[rgb], width, height, 0)
}

/// A looping GIF89a of `frames`, each shown for `delay_ms` (a still when there
/// is only one). Colours are quantized per frame: the format holds 256 in a
/// palette, and a design with few colours comes through exactly.
pub fn encode_animated_gif(
    frames: &[&[u8]],
    width: u32,
    height: u32,
    delay_ms: u32,
) -> Result<Vec<u8>, ProtocolError> {
    let invalid = |reason: String| ProtocolError::ImageDimensionsInvalid { reason };
    let (w, h) = match (u16::try_from(width), u16::try_from(height)) {
        (Ok(w), Ok(h)) => (w, h),
        _ => return Err(invalid(format!("{width}x{height} is too large for a GIF"))),
    };
    let mut out = Vec::new();
    {
        let mut encoder = gif::Encoder::new(&mut out, w, h, &[])
            .map_err(|e| invalid(format!("could not start the GIF: {e}")))?;
        if frames.len() > 1 {
            encoder
                .set_repeat(gif::Repeat::Infinite)
                .map_err(|e| invalid(format!("could not loop the GIF: {e}")))?;
        }
        for rgb in frames {
            if rgb.len() != w as usize * h as usize * 3 {
                return Err(invalid(format!(
                    "a {width}x{height} frame needs {} bytes, not {}",
                    w as usize * h as usize * 3,
                    rgb.len()
                )));
            }
            let mut frame = gif::Frame::from_rgb_speed(w, h, rgb, 10);
            // GIF counts in hundredths of a second, and a 16-bit count of them.
            frame.delay = (delay_ms / 10).min(u16::MAX as u32) as u16;
            encoder
                .write_frame(&frame)
                .map_err(|e| invalid(format!("could not encode the GIF: {e}")))?;
        }
    }
    Ok(out)
}

/// The frame bodies that store `gif` in [`PROGRAM_SLOT`] and start playing it.
fn upload_bodies(gif: &[u8]) -> Vec<Vec<u8>> {
    let slot = PROGRAM_SLOT;
    // What a resource TLV starts with: which program, region 0, item 0.
    let resource: Vec<u8> = [
        &[0xC1, 0x02, 0x09, 0x01, 0x01][..],
        &[0x0C, 0x01, slot],
        &[0x0D, 0x01, 0x00],
        &[0x0E, 0x01, 0x00],
    ]
    .concat();

    // Wake the panel: an upload to a panel that is switched off plays to
    // nobody, and a caller asking for an image to be shown means it.
    let mut bodies = vec![vec![0xC1, 0x02, 0x04, 0x02, 0x00, 0x01]];
    // Clear the slot, which is also what readies the panel for the upload.
    bodies.push(vec![0xC1, 0x02, 0x08, 0x02, 0x00, slot]);
    // Announce the resource: type "GIF", then the constant the vendor sends.
    bodies.push(
        [
            &resource[..],
            &[0x14, 0x03, 0x01, 0x0D, 0x03],
            &[0x11, 0x04, 0x00, 0x01, 0x00, 0x0A],
        ]
        .concat(),
    );

    let chunks: Vec<&[u8]> = gif.chunks(RESOURCE_CHUNK).collect();
    let count = chunks.len() as u16;
    for (index, chunk) in chunks.iter().enumerate() {
        let mut body = resource.clone();
        // [count][index][chunk size] — all three little-endian.
        body.extend_from_slice(&[0x12, 0x07]);
        body.extend_from_slice(&count.to_le_bytes());
        body.extend_from_slice(&(index as u16).to_le_bytes());
        body.extend_from_slice(&(RESOURCE_CHUNK as u16).to_le_bytes());
        body.push(0x00);
        // The data TLV. 0x82 is the TLV layer's "16-bit length follows".
        body.extend_from_slice(&[0x13, 0x82]);
        body.extend_from_slice(&(chunk.len() as u16).to_le_bytes());
        body.extend_from_slice(chunk);
        bodies.push(body);
    }

    // Commit: the program's id, then a 20-byte asset id for the vendor app's
    // gallery, which the firmware does not check.
    let mut commit = vec![0xC1, 0x02, 0x35, 0x19, 0x01, slot, 0x00, 0x00, 0x00];
    commit.extend_from_slice(&[0u8; 20]);
    bodies.push(commit);

    // Select. An upload does not change what is playing by itself. The body
    // is the slot and then the sixty slot numbers, which is what the panel
    // sends back when asked for its program list.
    let mut select = vec![0xC1, 0x02, 0x36, 0x3E, 0x01, slot];
    select.extend(0u8..60);
    bodies.push(select);
    bodies
}

/// The writes and acknowledgements that put `gif` on the panel.
fn upload_plan(
    spec: &DeviceSpec,
    gif: &[u8],
    frame_index: u32,
    max_payload_per_write: usize,
) -> Result<EncodedFrame, ProtocolError> {
    if max_payload_per_write < MIN_PAYLOAD_PER_WRITE {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "max_payload_per_write {max_payload_per_write} is below the BLE minimum of \
                 {MIN_PAYLOAD_PER_WRITE}"
            ),
        });
    }
    let (write, notify) = resolve_channels(spec)?;
    let write_size =
        max_payload_per_write.min(declared_max_chunk_size(write).unwrap_or(DEFAULT_WRITE_CHUNK));

    let mut plan = EncodedFrame {
        inter_write_delay_ms: INTER_WRITE_DELAY_MS,
        ..EncodedFrame::default()
    };
    let bodies = upload_bodies(gif);
    plan.packets = bodies.len() as u32;
    for (i, body) in bodies.iter().enumerate() {
        let seq = (frame_index as usize + i + 1) as u16;
        for part in frame(seq, body).chunks(write_size) {
            plan.writes.push(EncodedWrite {
                characteristic_uuid: write.uuid.clone(),
                bytes: part.to_vec(),
            });
        }
        // The panel's acknowledgement for this frame, from its length field
        // on: some panels answer with `aa 55 7e 7c` where others say
        // `aa 55 ff ff`, and the rest is the same either way.
        let [seq_lo, seq_hi] = seq.to_le_bytes();
        let ack = |status: u8| vec![0x07, 0x00, seq_lo, seq_hi, 0x81, 0x82, status];
        plan.reply_waits.push(ReplyWait {
            after_write: plan.writes.len() - 1,
            characteristic_uuid: notify.uuid.clone(),
            expect_prefix: ack(0),
            error_prefixes: (1..=0x0F).map(ack).collect(),
            timeout_ms: ACK_TIMEOUT_MS,
        });
    }
    Ok(plan)
}

/// [`super::FrameEncoder`] for popled panels: one image, uploaded and shown.
pub fn encode_image(
    spec: &DeviceSpec,
    rgb: &[u8],
    width: u32,
    height: u32,
    frame_index: u32,
    max_payload_per_write: usize,
) -> Result<EncodedFrame, ProtocolError> {
    validate_rgb_canvas(spec, rgb, width, height)?;
    let gif = encode_gif(rgb, width, height)?;
    upload_plan(spec, &gif, frame_index, max_payload_per_write)
}

/// A looping animation of `frames`, which the panel plays by itself once this
/// plan has run — the link can then be dropped.
pub fn encode_animation(
    spec: &DeviceSpec,
    frames: &[&[u8]],
    width: u32,
    height: u32,
    delay_ms: u32,
    max_payload_per_write: usize,
) -> Result<EncodedFrame, ProtocolError> {
    for rgb in frames {
        validate_rgb_canvas(spec, rgb, width, height)?;
    }
    let gif = encode_animated_gif(frames, width, height, delay_ms)?;
    upload_plan(spec, &gif, 0, max_payload_per_write)
}

/// Where and what to ask a panel for its size.
pub struct PanelProbe<'a> {
    pub write: &'a Characteristic,
    pub notify: &'a Characteristic,
    pub bytes: Vec<u8>,
}

/// The query that makes a panel state its size, for [`decode_panel_size`].
pub fn panel_probe(spec: &DeviceSpec) -> Result<PanelProbe<'_>, ProtocolError> {
    let (write, notify) = resolve_channels(spec)?;
    Ok(PanelProbe {
        write,
        notify,
        bytes: frame(1, &[0xC1, 0x03, TLV_DEVICE_INFO, 0x00, TLV_PANEL, 0x00]),
    })
}

/// Read a panel's width and height out of the notifications that followed
/// [`panel_probe`]. Reassembled by the frame's own length, since a reply can
/// outlast a notification; `None` when no complete frame states a usable size.
pub fn decode_panel_size(notifications: &[Vec<u8>]) -> Option<(u32, u32)> {
    let bytes: Vec<u8> = notifications.concat();
    let mut at = 0;
    while at + FRAME_HEADER_LEN <= bytes.len() {
        // The second half of the magic varies by panel, so only `aa 55` is
        // the anchor, and the checksum is what rules out a false one.
        if bytes[at..at + 2] != FRAME_MAGIC[..2] {
            at += 1;
            continue;
        }
        let declared = u16::from_le_bytes([bytes[at + 4], bytes[at + 5]]) as usize;
        let end = at + 6 + declared;
        if declared < 4 || end > bytes.len() {
            at += 1;
            continue;
        }
        let sum = bytes[at..end - 2]
            .iter()
            .fold(0u16, |acc, b| acc.wrapping_add(*b as u16));
        if sum.to_le_bytes() != bytes[end - 2..end] {
            at += 1;
            continue;
        }
        let body = &bytes[at + FRAME_HEADER_LEN..end - 2];
        if let Some(size) = panel_size_in_body(body) {
            return Some(size);
        }
        at = end;
    }
    None
}

fn panel_size_in_body(body: &[u8]) -> Option<(u32, u32)> {
    let mut rest = body.strip_prefix(&BODY_ANSWER[..])?;
    while let Some((&tag, after)) = rest.split_first() {
        let (&first, after) = after.split_first()?;
        // The TLV layer's length form: one byte below 0x80, otherwise 0x81
        // plus one byte or 0x82 plus a little-endian u16.
        let (length, after) = match first {
            0x81 => {
                let (&l, a) = after.split_first()?;
                (l as usize, a)
            }
            0x82 => {
                if after.len() < 2 {
                    return None;
                }
                (
                    u16::from_le_bytes([after[0], after[1]]) as usize,
                    &after[2..],
                )
            }
            n => (n as usize, after),
        };
        if after.len() < length {
            return None;
        }
        let (value, next) = after.split_at(length);
        if tag == TLV_PANEL && value.len() >= 4 {
            // Big-endian, unlike nearly everything else on this link.
            let width = u16::from_be_bytes([value[0], value[1]]) as u32;
            let height = u16::from_be_bytes([value[2], value[3]]) as u32;
            return (width > 0 && height > 0).then_some((width, height));
        }
        rest = next;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    const SPEC: &str = r#"
device:
  name: "Test panel"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
  category: "display"
protocol_handler: "popled_json"
features:
  - type: "image_upload"
    format: "gif"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Panel"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Notify"
        properties: ["notify"]
      - uuid: "0000fff2-0000-1000-8000-00805f9b34fb"
        name: "Write"
        properties: ["write_without_response"]
        framing:
          length_prefix: false
          max_chunk_size: 180
        commands:
          set_brightness:
            description: "Set brightness"
            encoding: "json"
            payload:
              key: "cmd.light.value_fix"
              value_type: "int"
          set_rotation:
            description: "Set rotation"
            encoding: "json"
            payload:
              key: "cmd.rotate"
              value_type: "int"
entities:
  - platform: "light"
    name: "LED Screen"
    features: ["brightness"]
    commands:
      set_brightness: "set_brightness"
"#;

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC).expect("test spec parses")
    }

    fn hex(s: &str) -> Vec<u8> {
        s.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect()
    }

    fn sum_is_right(frame: &[u8]) -> bool {
        let (rest, sum) = frame.split_at(frame.len() - 2);
        rest.iter()
            .fold(0u16, |acc, b| acc.wrapping_add(*b as u16))
            .to_le_bytes()
            == sum
    }

    /// Bytes sent to, and accepted by, a real backpack.
    #[test]
    fn a_frame_matches_what_the_panel_accepted() {
        assert_eq!(
            frame(1, &hex("c1 03 0a 00 1b 00 04 00 06 00")),
            hex("aa 55 ff ff 0e 00 01 00 c1 03 0a 00 1b 00 04 00 06 00 ff 03"),
        );
        assert_eq!(
            frame(1, &hex("c1 02 06 02 00 0f")),
            hex("aa 55 ff ff 0a 00 01 00 c1 02 06 02 00 0f e2 03"),
        );
    }

    #[test]
    fn a_json_command_with_a_known_wire_form_becomes_sendable() {
        let spec = spec();
        let char = &spec.services[0].characteristics[1];
        let command = &char.commands.as_ref().unwrap()["set_brightness"];
        assert_eq!(
            crate::codec::types::unsupported_write_kind(char, command),
            None
        );
        let bytes = crate::codec::types::encode_command(
            command,
            &[("brightness".to_string(), 15.0)].into_iter().collect(),
        )
        .unwrap();
        let framed = super::super::image_upload::frame_command(char, bytes, 1).unwrap();
        assert_eq!(
            framed,
            hex("aa 55 ff ff 0a 00 01 00 c1 02 06 02 00 0f e2 03")
        );
    }

    #[test]
    fn a_json_command_with_no_known_wire_form_stays_refused() {
        let spec = spec();
        let char = &spec.services[0].characteristics[1];
        let command = &char.commands.as_ref().unwrap()["set_rotation"];
        assert_eq!(
            crate::codec::types::unsupported_write_kind(char, command).as_deref(),
            Some("json"),
        );
    }

    #[test]
    fn another_handlers_framing_is_left_alone() {
        let yaml = SPEC.replace("popled_json", "someone_else");
        let spec = parse_device_spec(&yaml).unwrap();
        let char = &spec.services[0].characteristics[1];
        assert!(char.commands.as_ref().unwrap()["set_brightness"]
            .template
            .is_none());
        assert!(crate::codec::types::framing_scheme_name(char).is_none());
    }

    #[test]
    fn the_declared_write_size_survives_binding() {
        let spec = spec();
        assert_eq!(
            declared_max_chunk_size(&spec.services[0].characteristics[1]),
            Some(180),
        );
    }

    #[test]
    fn the_panel_size_is_the_panels_to_state() {
        let spec = spec();
        assert_eq!(
            spec.features[0].resolution_source.as_deref(),
            Some("device_reported"),
        );
    }

    fn solid(width: u32, height: u32) -> Vec<u8> {
        [0xE4u8, 0x03, 0x03].repeat((width * height) as usize)
    }

    /// Reassemble a plan's writes back into its frames, by the frames' own
    /// lengths: the shape the panel sees.
    fn frames_of(plan: &EncodedFrame) -> Vec<Vec<u8>> {
        let bytes: Vec<u8> = plan.writes.iter().flat_map(|w| w.bytes.clone()).collect();
        let mut frames = Vec::new();
        let mut at = 0;
        while at < bytes.len() {
            let declared = u16::from_le_bytes([bytes[at + 4], bytes[at + 5]]) as usize;
            frames.push(bytes[at..at + 6 + declared].to_vec());
            at += 6 + declared;
        }
        frames
    }

    #[test]
    fn a_small_image_is_one_chunk_between_its_preamble_and_commit() {
        let plan = encode_image(&spec(), &solid(8, 8), 8, 8, 0, 244).unwrap();
        let frames = frames_of(&plan);
        assert_eq!(
            frames.len(),
            6,
            "power, clear, announce, chunk, commit, select"
        );
        assert!(frames.iter().all(|f| sum_is_right(f)));
        let body = |frame: &'_ [u8]| frame[8..frame.len() - 2].to_vec();
        assert_eq!(body(&frames[0]), hex("c1 02 04 02 00 01"));
        assert_eq!(body(&frames[1]), hex("c1 02 08 02 00 3b"));
        assert_eq!(
            body(&frames[2]),
            hex("c1 02 09 01 01 0c 01 3b 0d 01 00 0e 01 00 14 03 01 0d 03 11 04 00 01 00 0a"),
        );
        // The commit is exactly what the panel acknowledged with status 0;
        // one byte more and it answers 3.
        let mut commit = hex("c1 02 35 19 01 3b 00 00 00");
        commit.extend_from_slice(&[0; 20]);
        assert_eq!(body(&frames[4]), commit);
        assert_eq!(frames[5][8..14], hex("c1 02 36 3e 01 3b")[..]);
        assert_eq!(frames[5].len(), 76);
    }

    #[test]
    fn the_chunk_count_is_little_endian_and_the_gif_comes_through_verbatim() {
        // A deliberately incompressible picture, so the GIF spans chunks.
        let mut noise = Vec::new();
        let mut state = 0x2545_F491u32;
        for _ in 0..64 * 64 * 3 {
            state ^= state << 13;
            state ^= state >> 17;
            state ^= state << 5;
            noise.push(state as u8);
        }
        let gif = encode_gif(&noise, 64, 64).unwrap();
        let count = gif.len().div_ceil(RESOURCE_CHUNK);
        assert!(count > 1, "needs more than one chunk, had {}", gif.len());

        let plan = encode_image(&spec(), &noise, 64, 64, 0, 244).unwrap();
        let frames = frames_of(&plan);
        assert_eq!(frames.len(), 3 + count + 2);
        let mut rebuilt = Vec::new();
        for (index, frame) in frames[3..3 + count].iter().enumerate() {
            // aa55ffff len seq | c1 02 09 01 01 | 0c.. 0d.. 0e.. | 12 07
            let tlv = &frame[8 + 5 + 9..];
            assert_eq!(tlv[..2], [0x12, 0x07]);
            assert_eq!(tlv[2..4], (count as u16).to_le_bytes());
            assert_eq!(tlv[4..6], (index as u16).to_le_bytes());
            assert_eq!(tlv[6..8], [0xC0, 0x03]);
            let length = u16::from_le_bytes([tlv[11], tlv[12]]) as usize;
            assert_eq!(tlv[9..11], [0x13, 0x82]);
            rebuilt.extend_from_slice(&tlv[13..13 + length]);
        }
        assert_eq!(rebuilt, gif);
    }

    #[test]
    fn every_frame_waits_for_its_own_acknowledgement() {
        let plan = encode_image(&spec(), &solid(8, 8), 8, 8, 0, 20).unwrap();
        let frames = frames_of(&plan);
        assert_eq!(plan.reply_waits.len(), frames.len());
        assert!(plan.writes.iter().all(|w| w.bytes.len() <= 20));
        let mut sent = 0;
        for (frame, wait) in frames.iter().zip(&plan.reply_waits) {
            sent += frame.len();
            let through: usize = plan.writes[..=wait.after_write]
                .iter()
                .map(|w| w.bytes.len())
                .sum();
            assert_eq!(through, sent, "the wait sits after the frame's last write");
            assert_eq!(wait.expect_prefix[2..4], frame[6..8], "echoes the sequence");
            assert_eq!(wait.expect_prefix[4..], [0x81, 0x82, 0x00]);
            assert_eq!(
                wait.characteristic_uuid,
                "0000fff1-0000-1000-8000-00805f9b34fb"
            );
            assert!(wait.error_prefixes.contains(&{
                let mut refused = wait.expect_prefix.clone();
                *refused.last_mut().unwrap() = 3;
                refused
            }));
        }
    }

    #[test]
    fn writes_respect_the_declared_chunk_size_on_a_big_mtu() {
        let plan = encode_image(&spec(), &solid(8, 8), 8, 8, 0, 512).unwrap();
        assert!(plan.writes.iter().all(|w| w.bytes.len() <= 180));
    }

    #[test]
    fn an_animation_is_one_looping_gif() {
        let first = solid(8, 8);
        let second = [0x00u8, 0x4D, 0xFF].repeat(64);
        let gif = encode_animated_gif(&[&first, &second], 8, 8, 4_000).unwrap();
        let mut decoder = gif::DecodeOptions::new();
        decoder.set_color_output(gif::ColorOutput::RGBA);
        let mut reader = decoder.read_info(&gif[..]).unwrap();
        assert_eq!(reader.repeat(), gif::Repeat::Infinite);
        let one = reader.read_next_frame().unwrap().unwrap();
        assert_eq!(one.delay, 400);
        let two = reader.read_next_frame().unwrap().unwrap();
        assert_eq!(two.delay, 400);
        assert_eq!(two.buffer[..3], [0x00, 0x4D, 0xFF]);
        assert!(reader.read_next_frame().unwrap().is_none());
    }

    #[test]
    fn a_frame_of_the_wrong_size_is_refused() {
        let wrong = [0u8; 9];
        assert!(encode_animated_gif(&[&wrong], 8, 8, 0).is_err());
    }

    /// The panel's actual reply to the query, whole.
    const REAL_REPLY: &str = "aa 55 ff ff 91 00 01 00 81 83 0a 63 35 32 35 43 31 31 30 33 34 30 \
        2c 45 58 59 43 2d 41 23 43 58 42 33 42 52 49 37 42 54 56 4f 49 43 45 33 2c 56 32 2e 38 \
        2e 38 23 56 30 31 2c 73 65 72 76 65 72 2c 74 63 2c 32 32 31 30 30 34 33 31 33 39 34 36 \
        33 37 33 34 2c 70 77 64 2c 72 65 6d 6f 74 65 2c 46 4f 4e 54 3a 65 6e 5f 55 53 30 34 2c \
        48 53 1b 1c 00 40 00 40 00 07 00 03 08 10 00 00 01 00 ff 01 00 01 02 03 04 05 06 07 08 \
        09 0a 0b 04 02 00 01 06 02 00 07 e4 21";

    #[test]
    fn the_size_is_read_from_a_real_reply_even_split_across_notifications() {
        let reply = hex(REAL_REPLY);
        assert_eq!(
            decode_panel_size(std::slice::from_ref(&reply)),
            Some((64, 64))
        );
        let split: Vec<Vec<u8>> = reply.chunks(20).map(<[u8]>::to_vec).collect();
        assert_eq!(decode_panel_size(&split), Some((64, 64)));
    }

    #[test]
    fn noise_and_a_bad_checksum_state_no_size() {
        let mut reply = hex(REAL_REPLY);
        *reply.last_mut().unwrap() ^= 0xFF;
        assert_eq!(decode_panel_size(&[reply]), None);
        assert_eq!(
            decode_panel_size(&[hex("aa 55 ff ff 07 00 01 00 81 82 00 08 04")]),
            None
        );
        assert_eq!(decode_panel_size(&[vec![0xAA, 0x55]]), None);
        assert_eq!(decode_panel_size(&[]), None);
    }

    #[test]
    fn a_stated_size_of_zero_is_not_a_size() {
        let reply = frame(1, &hex("81 83 1b 04 00 00 00 40"));
        assert_eq!(decode_panel_size(&[reply]), None);
    }

    #[test]
    fn the_probe_asks_for_the_panel_record() {
        let spec = spec();
        let probe = panel_probe(&spec).unwrap();
        assert_eq!(probe.write.uuid, "0000fff2-0000-1000-8000-00805f9b34fb");
        assert_eq!(probe.notify.uuid, "0000fff1-0000-1000-8000-00805f9b34fb");
        assert_eq!(
            probe.bytes[8..probe.bytes.len() - 2],
            hex("c1 03 0a 00 1b 00")[..]
        );
        assert!(sum_is_right(&probe.bytes));
    }
}

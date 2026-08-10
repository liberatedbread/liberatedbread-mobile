// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The device-independent half of pushing an image to an LED display.
//!
//! # Where the line is
//!
//! Seven devices in the catalogue declare an `image_upload` feature, across
//! six `protocol_handler`s and five pixel formats (`rgb888`, `rgb565`, `gif`,
//! `1bit-bitmap`, and Daniao's palette+RLE). They differ in two places and
//! agree everywhere else, so this module is the everywhere-else:
//!
//! ```text
//!   resolve channels ──▶ open session ──▶ encode canvas ──▶ fragment ──▶ writes
//!   [spec: framing]      [spec:           [PIXEL CODEC]     [FRAGMENT     [spec:
//!                         session_open]                      SCHEME]       uuids]
//! ```
//!
//! Everything on the outside is data a spec already states: which
//! characteristic is the command channel and which is bulk (`framing.scheme`
//! plus `channel_tag`), which commands open a session and in what order
//! (`session_open`), how big a chunk may get (`framing.max_chunk_size`), how
//! big a canvas may be (`max_width`/`max_height`), and which buffer tag this
//! flow writes under (the feature's `channel_tag`). None of it needs code.
//!
//! The two inside boxes are algorithms, and they stay in Rust deliberately. A
//! pixel codec is "traverse column-major, emit `(index << 4) | run` and spill
//! to `0xFF` extension bytes past 127" — expressing that in YAML means
//! inventing a bytecode, which would be untypeable, untestable, and would make
//! a downloadable spec pack executable. So a spec *names* an algorithm and
//! this module runs it, exactly as `framing.scheme` and `protocol_handler`
//! already work.
//!
//! # Adding a device
//!
//! Write the spec. If its pixel encoding matches one already registered, that
//! is the whole job — no Rust at all. If it is genuinely new, add a
//! [`PixelCodec`] (and a [`FragmentScheme`] only if its packet framing is also
//! new) and register it below. What you must NOT need to add is another copy
//! of the pipeline, which is what this module exists to stop.

use super::{EncodedFrame, EncodedWrite};
use crate::codec::types::encode_command;
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, CharacteristicProperty, DeviceSpec, Feature};
use serde::Deserialize;
use std::collections::HashMap;

/// Turns one logical packet into the BLE writes that carry it.
///
/// Fragmentation is per-platform: `daniao_fragment` prefixes a 4-byte
/// `[serial][total][remaining][tag]` header, and a scheme with no
/// fragmentation at all is simply one write per packet. The `tag` is the
/// scheme's channel byte where it has one.
pub type FragmentScheme = fn(FragmentRequest<'_>) -> Vec<Vec<u8>>;

/// Inputs a [`FragmentScheme`] needs to split one packet.
pub struct FragmentRequest<'a> {
    pub packet: &'a [u8],
    /// Sequence number this packet occupies. Schemes that carry no serial
    /// ignore it; the pipeline still advances it so callers can size frames.
    pub serial: u32,
    /// Channel/buffer tag byte, where the scheme has one.
    pub tag: u8,
    /// Usable bytes per BLE write AFTER the scheme's own header.
    pub capacity: usize,
}

/// Turns a canvas into the ordered packet payloads that draw it.
///
/// `budget` is the largest packet the caller may emit — already the smaller of
/// the channel's declared `max_chunk_size` and what one BLE write carries, so
/// a codec never has to know about MTUs.
pub type PixelCodec = fn(
    rgb: &[u8],
    width: usize,
    height: usize,
    budget: usize,
) -> Result<Vec<Vec<u8>>, ProtocolError>;

/// A named framing scheme, keyed by the spec's `framing.scheme`.
pub struct RegisteredScheme {
    pub name: &'static str,
    /// Bytes the scheme's own header consumes out of each BLE write.
    pub header_len: usize,
    pub fragment: FragmentScheme,
}

/// A named pixel encoder, keyed by a spec's `protocol_handler`.
pub struct RegisteredCodec {
    pub handler: &'static str,
    pub encode: PixelCodec,
    /// Largest canvas dimension the codec's own wire format can address, where
    /// it has one. Daniao's chunk start coordinates are `u8`, so it can place
    /// a chunk anywhere in a canvas up to 256 across — a separate limit from
    /// whatever a panel says it holds, and the tighter of the two binds.
    pub max_dimension: Option<u32>,
}

const SCHEMES: &[RegisteredScheme] = &[RegisteredScheme {
    name: super::daniao::FRAGMENT_SCHEME,
    header_len: super::daniao::FRAG_HEADER_LEN,
    fragment: super::daniao::fragment_packet,
}];

const CODECS: &[RegisteredCodec] = &[RegisteredCodec {
    handler: super::daniao::HANDLER_NAME,
    encode: super::daniao::encode_tutu_restore_chunks,
    max_dimension: Some(256),
}];

/// What a handler did before the spec could say it.
///
/// Every field here is a compatibility path, not a policy: each was once a
/// constant in a handler, and each applies only when the spec states nothing.
/// A spec pack written before these keys existed keeps encoding byte-for-byte
/// what it used to.
pub struct HandlerDefaults {
    /// `protocol_handler` name, which selects the pixel codec.
    pub handler: &'static str,
    /// Openers to send when the spec declares no `session_open` at all. An
    /// empty DECLARED list is a statement and overrides this; an absent key
    /// is not.
    pub session_open: &'static [&'static str],
    /// Buffer tag for the bulk channel when neither the channel nor the
    /// feature names one.
    pub bulk_tag: u8,
    /// Chunk ceiling when the bulk channel declares no `max_chunk_size`.
    pub chunk_limit: usize,
}

/// The BLE 4.0 minimum ATT payload (MTU 23 - 3). Not a device fact — no link
/// carries less — so it is the one dimension the spec has no say in.
const MIN_PAYLOAD_PER_WRITE: usize = 20;

/// The `framing` block of a characteristic, read on demand: the shared
/// `Characteristic` type keeps it untyped because most devices have none.
#[derive(Debug, Deserialize)]
struct Framing {
    scheme: Option<String>,
    channel_tag: Option<u8>,
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

/// The `image_upload` feature, if the spec declares one.
pub fn image_feature(spec: &DeviceSpec) -> Option<&Feature> {
    spec.features
        .iter()
        .find(|f| f.feature_type == "image_upload")
}

/// A characteristic using `scheme_name`, picked by channel: the command
/// channel is `channel_tag: 0`, and the bulk channel is the one that is not.
///
/// The bulk channel is identified by *not* being channel 0 rather than by
/// omitting a tag: omitting one is a statement about the channel (its tag
/// varies per transfer), not an identifier. Its tag for THIS flow comes from
/// the feature, which is the layer that knows which buffer an upload writes.
fn resolve_channel<'a>(
    spec: &'a DeviceSpec,
    scheme_name: &str,
    flow_tag: u8,
    want_command_channel: bool,
) -> Option<(&'a Characteristic, u8)> {
    for service in &spec.services {
        for c in &service.characteristics {
            if !is_writable(c) {
                continue;
            }
            let Some(f) = framing_of(c) else { continue };
            if f.scheme.as_deref() != Some(scheme_name) {
                continue;
            }
            match (want_command_channel, f.channel_tag) {
                (true, Some(0)) => return Some((c, 0)),
                (false, Some(tag)) if tag != 0 => return Some((c, tag)),
                (false, None) => return Some((c, flow_tag)),
                _ => {}
            }
        }
    }
    None
}

/// Encode one RGB888 frame into the ordered BLE writes that display it.
///
/// The pipeline is the same for every device; what differs is resolved from
/// `spec`. `frame_index` sequences consecutive frames (wire serials derive
/// from it) and `max_payload_per_write` is the usable bytes per BLE write
/// (negotiated ATT MTU - 3; 20 when unknown).
///
/// `session_open_default` is what a handler used to hardcode, applied only
/// when the spec states nothing — a spec pack written before `session_open`
/// existed still works. An EMPTY declared list is a statement ("no preamble")
/// and is honoured as one.
pub fn encode_frame(
    spec: &DeviceSpec,
    rgb: &[u8],
    width: u32,
    height: u32,
    frame_index: u32,
    max_payload_per_write: usize,
    defaults: &HandlerDefaults,
) -> Result<EncodedFrame, ProtocolError> {
    encode_frame_with(
        SCHEMES,
        CODECS,
        spec,
        rgb,
        width,
        height,
        frame_index,
        max_payload_per_write,
        defaults,
    )
}

/// [`encode_frame`] against explicit registries.
///
/// The registries are a parameter so a test can run this pipeline on
/// algorithms that share nothing with any shipped device. That is the only way
/// to tell a pipeline that is device-independent from one that merely happens
/// to agree with its single caller: every value it reads from the SmartDawn
/// spec is also a value the SmartDawn code once hardcoded.
#[allow(clippy::too_many_arguments)]
pub fn encode_frame_with(
    schemes: &[RegisteredScheme],
    codecs: &[RegisteredCodec],
    spec: &DeviceSpec,
    rgb: &[u8],
    width: u32,
    height: u32,
    frame_index: u32,
    max_payload_per_write: usize,
    defaults: &HandlerDefaults,
) -> Result<EncodedFrame, ProtocolError> {
    let handler = defaults.handler;
    let invalid = |reason: String| ProtocolError::ImageDimensionsInvalid { reason };

    let expected = (width as usize)
        .checked_mul(height as usize)
        .and_then(|px| px.checked_mul(3))
        .ok_or_else(|| invalid(format!("{width}x{height} overflows the pixel buffer size")))?;
    if expected == 0 {
        return Err(invalid(format!("{width}x{height} has no pixels")));
    }
    if rgb.len() != expected {
        return Err(invalid(format!(
            "expected {expected} bytes of RGB888 for {width}x{height}, got {}",
            rgb.len()
        )));
    }

    let feature = image_feature(spec);
    let registered = codecs
        .iter()
        .find(|c| c.handler == handler)
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: format!("no pixel codec registered for protocol_handler '{handler}'"),
        })?;

    // The canvas ceiling is whichever is tighter: what the panel says it can
    // hold, or what the codec's own wire format can address. Both are real
    // limits and neither implies the other.
    let declared_max = feature.and_then(|f| match (f.max_width, f.max_height) {
        (Some(w), Some(h)) => Some((w, h)),
        _ => None,
    });
    if let Some((max_w, max_h)) = declared_max {
        if width > max_w || height > max_h {
            return Err(invalid(format!(
                "{width}x{height} exceeds the {max_w}x{max_h} the spec declares"
            )));
        }
    }
    if let Some(limit) = registered.max_dimension {
        if width > limit || height > limit {
            return Err(invalid(format!(
                "{width}x{height} exceeds {limit} in a dimension, which is what this \
                 codec's chunk coordinates can address"
            )));
        }
    }

    if max_payload_per_write < MIN_PAYLOAD_PER_WRITE {
        return Err(invalid(format!(
            "max_payload_per_write {max_payload_per_write} is below the BLE minimum of \
             {MIN_PAYLOAD_PER_WRITE}"
        )));
    }

    // Which framing scheme this device uses is the spec's to say; a handler
    // that had one scheme hardcoded could not be pointed at a sibling.
    let scheme_name = spec
        .services
        .iter()
        .flat_map(|s| &s.characteristics)
        .filter(|c| is_writable(c))
        .find_map(|c| framing_of(c).and_then(|f| f.scheme))
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: "spec declares no framing.scheme on any writable characteristic".to_string(),
        })?;
    let scheme = schemes
        .iter()
        .find(|s| s.name == scheme_name)
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: format!("framing scheme '{scheme_name}' is declared but not implemented"),
        })?;

    let flow_tag = feature
        .and_then(|f| f.channel_tag)
        .unwrap_or(defaults.bulk_tag);
    let (command_char, command_tag) = resolve_channel(spec, &scheme_name, flow_tag, true)
        .ok_or_else(|| ProtocolError::ImageUploadUnsupported {
            reason: format!("spec has no {scheme_name} command characteristic (channel_tag: 0)"),
        })?;
    let (bulk_char, bulk_tag) =
        resolve_channel(spec, &scheme_name, flow_tag, false).ok_or_else(|| {
            ProtocolError::ImageUploadUnsupported {
                reason: format!("spec has no {scheme_name} bulk characteristic"),
            }
        })?;

    let capacity = max_payload_per_write - scheme.header_len;

    // The chunk ceiling is the bulk channel's own declaration where it makes
    // one: a property of that channel's encoder, not of this pipeline.
    let chunk_limit = framing_of(bulk_char)
        .and_then(|f| f.max_chunk_size)
        .filter(|n| *n > 0)
        .unwrap_or(defaults.chunk_limit);
    let chunks = (registered.encode)(
        rgb,
        width as usize,
        height as usize,
        chunk_limit.min(capacity),
    )?;

    // A device that does not reassemble fragments needs every chunk to fit one
    // write. Codecs honour the budget they were given, so a chunk over it is a
    // codec bug rather than an MTU problem — say so with the number.
    if let Some(biggest) = chunks.iter().map(Vec::len).max() {
        if biggest > capacity {
            return Err(invalid(format!(
                "a chunk is {biggest} B but only {capacity} B fit in one BLE write — raise \
                 the ATT MTU (need >= {} bytes) before pushing images",
                biggest + scheme.header_len + 3
            )));
        }
    }

    let mut serial = frame_index;
    let mut writes = Vec::new();
    let mut push = |packet: &[u8], uuid: &str, tag: u8, serial: &mut u32| {
        let parts = (scheme.fragment)(FragmentRequest {
            packet,
            serial: *serial,
            tag,
            capacity,
        });
        *serial = serial.wrapping_add(1);
        for bytes in parts {
            writes.push(EncodedWrite {
                characteristic_uuid: uuid.to_string(),
                bytes,
            });
        }
    };

    if frame_index == 0 {
        // An absent `session_open` is "unspecified", so the pre-key default
        // applies. An empty one is a statement — this device opens no session
        // — and must not be turned back into the default.
        let declared = feature.and_then(|f| f.session_open.as_ref());
        let session_open: Vec<&str> = match declared {
            Some(names) => names.iter().map(String::as_str).collect(),
            None => defaults.session_open.to_vec(),
        };
        if !session_open.is_empty() {
            let commands =
                command_char
                    .commands
                    .as_ref()
                    .ok_or_else(|| ProtocolError::NoCommands {
                        uuid: command_char.uuid.clone(),
                    })?;
            for name in session_open {
                let command = commands
                    .get(name)
                    .ok_or_else(|| ProtocolError::CommandNotFound {
                        uuid: command_char.uuid.clone(),
                        command: name.to_string(),
                    })?;
                // A spec may declare an `auto: sequence` field; reuse the
                // fragment serial this packet is about to consume so two
                // session-open packets stay distinguishable to firmware that
                // de-duplicates by serial.
                let params = HashMap::from([("sn".to_string(), serial as f64)]);
                let packet = encode_command(command, &params)?;
                push(&packet, &command_char.uuid, command_tag, &mut serial);
            }
        }
    }

    for chunk in &chunks {
        push(chunk, &bulk_char.uuid, bulk_tag, &mut serial);
    }

    let packets = serial.wrapping_sub(frame_index);
    // Fragment serials are a byte on every scheme here, so a frame needing
    // more than 256 would reuse one mid-frame and corrupt reassembly.
    if packets > 256 {
        return Err(invalid(format!(
            "frame needs {packets} logical packets; the u8 fragment serial allows at most 256 \
             per frame — reduce the image's distinct-run count or size"
        )));
    }
    Ok(EncodedFrame { writes, packets })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A framing scheme with nothing in common with `daniao_fragment`: no
    /// header at all, one write per packet, and a different name.
    fn one_write_per_packet(req: FragmentRequest<'_>) -> Vec<Vec<u8>> {
        vec![req.packet.to_vec()]
    }

    /// A pixel codec with nothing in common with TUTU: no palette, no runs —
    /// the raw canvas, split to the budget.
    fn raw_chunks(
        rgb: &[u8],
        _width: usize,
        _height: usize,
        budget: usize,
    ) -> Result<Vec<Vec<u8>>, ProtocolError> {
        Ok(rgb.chunks(budget).map(<[u8]>::to_vec).collect())
    }

    const TEST_SCHEMES: &[RegisteredScheme] = &[RegisteredScheme {
        name: "flat_write",
        header_len: 0,
        fragment: one_write_per_packet,
    }];

    const TEST_CODECS: &[RegisteredCodec] = &[RegisteredCodec {
        handler: "test_panel",
        encode: raw_chunks,
        max_dimension: None,
    }];

    /// A made-up device: a different framing scheme, a different codec, a
    /// different opener, different UUIDs, and no vendor in common with
    /// SmartDawn.
    const PANEL_YAML: &str = r#"
device:
  name: "Test Panel"
  manufacturer: "Nobody"
  manufacturer_status: "abandoned"
  protocol: "ble"
  category: "display"
  identification:
    local_name_prefix: "PANEL_"
protocol_handler: "test_panel"
features:
  - type: "image_upload"
    format: "rgb888"
    max_width: 64
    max_height: 64
    session_open: ["wake"]
    channel_tag: 0x09
services:
  - uuid: "0000ab00-0000-1000-8000-00805f9b34fb"
    name: "Panel"
    characteristics:
      - uuid: "0000ab01-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
        framing: { scheme: "flat_write", channel_tag: 0 }
        commands:
          wake:
            description: "wake the panel"
            value: [0xDE, 0xAD]
      - uuid: "0000ab02-0000-1000-8000-00805f9b34fb"
        name: "Pixels"
        properties: ["write"]
        framing: { scheme: "flat_write", max_chunk_size: 12 }
"#;

    fn panel() -> crate::spec::types::DeviceSpec {
        parse_device_spec(PANEL_YAML).expect("test panel spec should parse")
    }

    const TEST_DEFAULTS: HandlerDefaults = HandlerDefaults {
        handler: "test_panel",
        // No pre-key default: this device never had a hardcoded opener, so
        // everything the pipeline does here comes from the spec.
        session_open: &[],
        bulk_tag: 0,
        chunk_limit: 200,
    };

    fn encode(spec: &crate::spec::types::DeviceSpec, w: u32, h: u32, frame: u32) -> EncodedFrame {
        encode_frame_with(
            TEST_SCHEMES,
            TEST_CODECS,
            spec,
            &vec![0x7Fu8; (w * h * 3) as usize],
            w,
            h,
            frame,
            509,
            &TEST_DEFAULTS,
        )
        .expect("the panel should encode")
    }

    /// The pipeline drives a device that shares no code with SmartDawn.
    ///
    /// If any part of it were still Daniao-shaped — the opener names, the
    /// 4-byte fragment header, the TUTU chunk format, the buffer tag — this
    /// would fail rather than pass, because none of those appear here.
    #[test]
    fn the_pipeline_drives_a_device_with_a_different_scheme_and_codec() {
        let frame = encode(&panel(), 4, 4, 0);

        // Session open: the spec's `wake`, on the command channel, as its own
        // packet — with no framing header, because this scheme has none.
        assert_eq!(
            frame.writes[0].characteristic_uuid,
            "0000ab01-0000-1000-8000-00805f9b34fb"
        );
        assert_eq!(frame.writes[0].bytes, vec![0xDE, 0xAD]);

        // Pixels: 4x4x3 = 48 bytes, cut to the channel's declared 12-byte
        // ceiling, on the bulk channel.
        let pixels = &frame.writes[1..];
        assert_eq!(pixels.len(), 4);
        for w in pixels {
            assert_eq!(
                w.characteristic_uuid,
                "0000ab02-0000-1000-8000-00805f9b34fb"
            );
            assert_eq!(w.bytes.len(), 12);
        }
        assert_eq!(frame.packets, 5);
    }

    /// Later frames skip the preamble here too — that rule is the pipeline's,
    /// not any one device's.
    #[test]
    fn only_the_first_frame_opens_a_session() {
        let frame = encode(&panel(), 4, 4, 1);
        assert!(frame
            .writes
            .iter()
            .all(|w| w.characteristic_uuid == "0000ab02-0000-1000-8000-00805f9b34fb"));
    }

    /// The canvas ceiling is the spec's, for a device that never had a
    /// hardcoded one.
    #[test]
    fn the_declared_canvas_ceiling_is_enforced() {
        let err = encode_frame_with(
            TEST_SCHEMES,
            TEST_CODECS,
            &panel(),
            &[0u8; 65 * 64 * 3],
            65,
            64,
            0,
            509,
            &TEST_DEFAULTS,
        )
        .unwrap_err();
        assert!(
            format!("{err:?}").contains("64x64"),
            "the error should quote the spec's declared bounds, got {err:?}"
        );
    }

    /// A spec naming a scheme or handler nobody implements says so, rather
    /// than falling through to whichever one happens to be registered first.
    #[test]
    fn an_unimplemented_scheme_or_handler_is_named() {
        let err = encode_frame_with(
            TEST_SCHEMES,
            &[],
            &panel(),
            &[0u8; 4 * 4 * 3],
            4,
            4,
            0,
            509,
            &TEST_DEFAULTS,
        )
        .unwrap_err();
        assert!(format!("{err:?}").contains("test_panel"));

        let err = encode_frame_with(
            &[],
            TEST_CODECS,
            &panel(),
            &[0u8; 4 * 4 * 3],
            4,
            4,
            0,
            509,
            &TEST_DEFAULTS,
        )
        .unwrap_err();
        assert!(format!("{err:?}").contains("flat_write"));
    }
}

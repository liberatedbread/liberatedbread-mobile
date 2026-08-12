// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Drive a LIFX light over its binary LAN protocol, from the spec and a little
//! hardcoded wire knowledge the spec cannot carry.
//!
//! LIFX is the first device whose control surface is neither GATT nor
//! text-over-TCP: it speaks a binary protocol over **UDP unicast on port
//! 56700, unauthenticated**. Every message is a fixed 36-byte header followed
//! by a typed payload, all little-endian. This module is the counterpart to
//! [`crate::protocol::soap`] and [`crate::protocol::http`] one transport over:
//! it turns a control action into the bytes of a datagram and turns a returned
//! datagram back into a reading. It does the same job the BLE codec does for a
//! characteristic write — build bytes, decode bytes — for a protocol the
//! generic template engine cannot express (a per-device 6-byte `target` MAC, a
//! `u16` with the protocol number and flag bits packed together, HSBK colour,
//! and reply framing).
//!
//! What deliberately does NOT live here is I/O. This crate owns no UDP socket
//! and wants none: the caller (Dart's `LifxControlClient`) owns the socket and
//! the sequence counter, sends the bytes this builds, and hands the reply bytes
//! back to be decoded — exactly as the SOAP path hands back name→value pairs.
//!
//! ## Why the constants are hardcoded
//!
//! The spec's `lifx_lan_protocol` block lists message-type *numbers*, but the
//! wire layout — field offsets, the protocol/flag `u16` packing, HSBK widths,
//! little-endianness, the 36-byte reply header — is not in the YAML and cannot
//! be; the block itself points at `LIFX/public-protocol` (`protocol.yml`) as
//! the machine-readable source. Since the layout must be hardcoded regardless,
//! the type numbers belong beside it as one coherent, testable unit, exactly as
//! [`crate::protocol::daniao`] hardcodes its frame format. The message-type
//! numbers are cross-checked against the vendored spec in
//! `tests/lifx_control.rs`, so a spec that renumbers a message fails the build.

use crate::error::ProtocolError;
use crate::spec::types::DeviceSpec;

/// The `protocol_handler` string a spec must declare to be driven from here.
pub const HANDLER_NAME: &str = "lifx_lan_udp";

/// The transport an action carries so the UI dispatches the send to the UDP
/// client rather than the SOAP or HTTP one — the LIFX counterpart of
/// [`crate::protocol::soap::TRANSPORT`].
pub const TRANSPORT: &str = "lifx";

/// The one UDP port every LIFX device listens on for the LAN protocol.
pub const PORT: u16 = 56700;

/// Every LIFX message begins with this fixed header, payload follows.
pub const HEADER_LEN: usize = 36;

/// Protocol number (bits 0..12 of the frame's second `u16`). Constant 1024.
const PROTOCOL: u16 = 1024;
/// `addressable` bit (bit 12): set on every message this client sends.
const ADDRESSABLE: u16 = 0x1000;
/// `tagged` bit (bit 13): set for a broadcast/discovery message whose target is
/// every device, clear when addressing one device by MAC.
const TAGGED: u16 = 0x2000;

/// Client id stamped into every request's `source` field ("LBRG" — Liberated
/// Bread). A device echoes it in replies, so a client can ignore datagrams
/// meant for some other controller on the LAN. Any non-zero value works.
const SOURCE: u32 = 0x4C42_5247;

/// LIFX message types. Numbers cross-checked against the vendored spec's
/// `lifx_lan_protocol.message_types` / `multizone_messages` in the integration
/// test, so a spec renumbering fails the build rather than silently disagreeing.
pub mod msg {
    // Device / discovery
    pub const GET_SERVICE: u16 = 2;
    pub const STATE_SERVICE: u16 = 3;
    // Light
    pub const GET: u16 = 101;
    pub const SET_COLOR: u16 = 102;
    pub const STATE: u16 = 107;
    pub const SET_POWER: u16 = 117; // LightSetPower (level + duration)
                                    // MultiZone
    pub const SET_COLOR_ZONES: u16 = 501;
    pub const GET_COLOR_ZONES: u16 = 502;
    pub const STATE_ZONE: u16 = 503;
    pub const STATE_MULTI_ZONE: u16 = 506;
    // SoftAP provisioning (the legacy access-point family the setup block
    // documents; dropped from the current protocol.yml but still spoken by
    // original-generation firmware over the setup AP).
    pub const GET_ACCESS_POINTS: u16 = 0x130; // 304
    pub const SET_ACCESS_POINT: u16 = 0x131; // 305
    pub const STATE_ACCESS_POINT: u16 = 0x132; // 306
}

/// The `SECURITY_PROTOCOL` byte to try when the target network never appeared in
/// a scan (a hidden SSID, or a device that scanned nothing): home networks
/// overwhelmingly run WPA2-AES.
pub const SECURITY_WPA2_AES: u8 = 5;

/// The `interface` byte selecting the device's station radio — the one that
/// joins the home network — on a `SetAccessPoint`.
const INTERFACE_STATION: u8 = 2;

/// LIFX's colour model: hue, saturation and brightness each span the full
/// `u16` range; kelvin (1500..=9000) is the white point, meaningful when
/// saturation is 0. Sending a saturated colour sets hue/saturation/brightness;
/// sending a white sets saturation 0 and a kelvin.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Hsbk {
    pub hue: u16,
    pub saturation: u16,
    pub brightness: u16,
    pub kelvin: u16,
}

/// Lowest and highest kelvin the LIFX white range accepts.
pub const KELVIN_MIN: u16 = 1500;
pub const KELVIN_MAX: u16 = 9000;
/// The white point used when a colour is picked as RGB rather than a
/// temperature — irrelevant while saturation is non-zero, but a device stores
/// it, so a sane middle value keeps a later desaturate from snapping to 1500K.
pub const KELVIN_DEFAULT: u16 = 3500;

/// The `ApplicationRequest` byte on a `SetColorZones`: apply this write to the
/// strip immediately rather than buffering it for a later `APPLY`.
pub const APPLY: u8 = 1;

// ── header ───────────────────────────────────────────────────────────────

/// Build the 36-byte LIFX header for `payload_len` bytes of `msg_type`.
///
/// `tagged` selects broadcast (`0x3400`) vs addressed (`0x1400`); `target` is
/// the device MAC (all-zero addresses every device, which unicast firmware
/// accepts); `res_required` asks the device to answer with its matching
/// `State…` message; `sequence` lets the caller correlate that answer.
#[allow(clippy::too_many_arguments)]
fn header(
    msg_type: u16,
    payload_len: usize,
    tagged: bool,
    target: [u8; 6],
    res_required: bool,
    ack_required: bool,
    sequence: u8,
) -> [u8; HEADER_LEN] {
    let mut h = [0u8; HEADER_LEN];
    let size = (HEADER_LEN + payload_len) as u16;
    h[0..2].copy_from_slice(&size.to_le_bytes());
    let mut proto = PROTOCOL | ADDRESSABLE;
    if tagged {
        proto |= TAGGED;
    }
    h[2..4].copy_from_slice(&proto.to_le_bytes());
    h[4..8].copy_from_slice(&SOURCE.to_le_bytes());
    // target: 6-byte MAC in the low bytes, 2 trailing zero bytes (8..14, 14..16
    // stay zero). 16..22 reserved.
    h[8..14].copy_from_slice(&target);
    let mut flags = 0u8;
    if res_required {
        flags |= 0x01;
    }
    if ack_required {
        flags |= 0x02;
    }
    h[22] = flags;
    h[23] = sequence;
    // 24..32 reserved timestamp (0). Message type at 32.
    h[32..34].copy_from_slice(&msg_type.to_le_bytes());
    // 34..36 reserved.
    h
}

/// The 8 wire bytes of an HSBK colour, each channel little-endian.
fn hsbk_bytes(c: &Hsbk) -> [u8; 8] {
    let mut b = [0u8; 8];
    b[0..2].copy_from_slice(&c.hue.to_le_bytes());
    b[2..4].copy_from_slice(&c.saturation.to_le_bytes());
    b[4..6].copy_from_slice(&c.brightness.to_le_bytes());
    b[6..8].copy_from_slice(&c.kelvin.to_le_bytes());
    b
}

/// Read an HSBK colour out of `bytes[at..at+8]`. Caller has already checked the
/// slice is long enough.
fn read_hsbk(bytes: &[u8], at: usize) -> Hsbk {
    let u16le = |o: usize| u16::from_le_bytes([bytes[o], bytes[o + 1]]);
    Hsbk {
        hue: u16le(at),
        saturation: u16le(at + 2),
        brightness: u16le(at + 4),
        kelvin: u16le(at + 6),
    }
}

// ── colour conversion ────────────────────────────────────────────────────

/// An sRGB triple (0..=255 per channel) as the colour picker produces it,
/// converted to HSBK. Hue/saturation/brightness come from an HSV conversion;
/// `kelvin` is carried through for the white point (it has no visible effect
/// while saturation is non-zero).
pub fn rgb_to_hsbk(r: u8, g: u8, b: u8, kelvin: u16) -> Hsbk {
    let rf = f64::from(r) / 255.0;
    let gf = f64::from(g) / 255.0;
    let bf = f64::from(b) / 255.0;
    let max = rf.max(gf).max(bf);
    let min = rf.min(gf).min(bf);
    let delta = max - min;

    let mut hue_deg = if delta == 0.0 {
        0.0
    } else if max == rf {
        60.0 * (((gf - bf) / delta) % 6.0)
    } else if max == gf {
        60.0 * (((bf - rf) / delta) + 2.0)
    } else {
        60.0 * (((rf - gf) / delta) + 4.0)
    };
    if hue_deg < 0.0 {
        hue_deg += 360.0;
    }
    let saturation = if max == 0.0 { 0.0 } else { delta / max };

    Hsbk {
        hue: (hue_deg / 360.0 * f64::from(u16::MAX)).round() as u16,
        saturation: (saturation * f64::from(u16::MAX)).round() as u16,
        brightness: (max * f64::from(u16::MAX)).round() as u16,
        kelvin: kelvin.clamp(KELVIN_MIN, KELVIN_MAX),
    }
}

/// The inverse of [`rgb_to_hsbk`] for display: HSBK back to an sRGB triple.
/// Kelvin is ignored — it only tints pure whites, and approximating a colour
/// swatch is enough for the UI to show what the strip is doing.
pub fn hsbk_to_rgb(c: &Hsbk) -> (u8, u8, u8) {
    let h = f64::from(c.hue) / f64::from(u16::MAX) * 360.0;
    let s = f64::from(c.saturation) / f64::from(u16::MAX);
    let v = f64::from(c.brightness) / f64::from(u16::MAX);

    let chroma = v * s;
    let hp = h / 60.0;
    let x = chroma * (1.0 - ((hp % 2.0) - 1.0).abs());
    let (r1, g1, b1) = match hp as u32 {
        0 => (chroma, x, 0.0),
        1 => (x, chroma, 0.0),
        2 => (0.0, chroma, x),
        3 => (0.0, x, chroma),
        4 => (x, 0.0, chroma),
        _ => (chroma, 0.0, x),
    };
    let m = v - chroma;
    let to_byte = |c: f64| ((c + m) * 255.0).round().clamp(0.0, 255.0) as u8;
    (to_byte(r1), to_byte(g1), to_byte(b1))
}

// ── request builders ─────────────────────────────────────────────────────

/// A tagged broadcast `GetService` — the discovery probe. Every LIFX device on
/// the segment answers with a `StateService`.
pub fn get_service(sequence: u8) -> Vec<u8> {
    header(msg::GET_SERVICE, 0, true, [0; 6], true, false, sequence).to_vec()
}

/// `LightGet` (101) — ask a device for its current colour and power. Answered
/// by a `State` (107).
pub fn get_color(target: [u8; 6], sequence: u8) -> Vec<u8> {
    header(msg::GET, 0, false, target, true, false, sequence).to_vec()
}

/// `LightSetPower` (117): turn the light on or off over `duration_ms`.
/// Fire-and-forget — no reply requested.
pub fn set_power(target: [u8; 6], on: bool, duration_ms: u32, sequence: u8) -> Vec<u8> {
    let mut msg = header(msg::SET_POWER, 6, false, target, false, false, sequence).to_vec();
    let level: u16 = if on { u16::MAX } else { 0 };
    msg.extend_from_slice(&level.to_le_bytes());
    msg.extend_from_slice(&duration_ms.to_le_bytes());
    msg
}

/// `LightSetColor` (102): set the whole light to one HSBK colour over
/// `duration_ms`. Fire-and-forget.
pub fn set_color(target: [u8; 6], color: &Hsbk, duration_ms: u32, sequence: u8) -> Vec<u8> {
    let mut msg = header(msg::SET_COLOR, 13, false, target, false, false, sequence).to_vec();
    msg.push(0); // reserved
    msg.extend_from_slice(&hsbk_bytes(color));
    msg.extend_from_slice(&duration_ms.to_le_bytes());
    msg
}

/// `SetColorZones` (501): set zones `start..=end` of a multizone strip to one
/// HSBK colour and apply immediately. Fire-and-forget.
pub fn set_color_zones(
    target: [u8; 6],
    start: u8,
    end: u8,
    color: &Hsbk,
    duration_ms: u32,
    sequence: u8,
) -> Vec<u8> {
    let mut msg = header(
        msg::SET_COLOR_ZONES,
        15,
        false,
        target,
        false,
        false,
        sequence,
    )
    .to_vec();
    msg.push(start);
    msg.push(end);
    msg.extend_from_slice(&hsbk_bytes(color));
    msg.extend_from_slice(&duration_ms.to_le_bytes());
    msg.push(APPLY);
    msg
}

/// `GetColorZones` (502): ask for the colours of zones `start..=end`. Answered
/// by one `StateZone` (single zone) or one or more `StateMultiZone` messages.
pub fn get_color_zones(target: [u8; 6], start: u8, end: u8, sequence: u8) -> Vec<u8> {
    let mut msg = header(
        msg::GET_COLOR_ZONES,
        2,
        false,
        target,
        true,
        false,
        sequence,
    )
    .to_vec();
    msg.push(start);
    msg.push(end);
    msg
}

/// Write `src` into `out`, truncated or null-padded to exactly `width` bytes —
/// how the access-point messages carry their fixed-width UTF-8 strings.
fn push_fixed(out: &mut Vec<u8>, src: &[u8], width: usize) {
    let take = src.len().min(width);
    out.extend_from_slice(&src[..take]);
    out.extend(std::iter::repeat_n(0u8, width - take));
}

/// `GetAccessPoints` (0x130): ask an unprovisioned device on its own setup AP to
/// scan for networks. Sent tagged/broadcast — on the setup network the target is
/// unknown. Answered by one `StateAccessPoint` per visible network.
pub fn get_access_points(sequence: u8) -> Vec<u8> {
    header(
        msg::GET_ACCESS_POINTS,
        0,
        true,
        [0; 6],
        true,
        false,
        sequence,
    )
    .to_vec()
}

/// `SetAccessPoint` (0x131): hand the device its home-network credentials. The
/// 98-byte payload is `interface(1) ssid(32) password(64) security(1)`; strings
/// are UTF-8, null-padded to their fixed width. The passphrase rides in
/// plaintext — the legacy exchange has no credential encryption, and the setup
/// AP is the only transport protection — so a caller must not persist it.
pub fn set_access_point(ssid: &str, password: &str, security: u8, sequence: u8) -> Vec<u8> {
    let mut msg = header(
        msg::SET_ACCESS_POINT,
        98,
        true,
        [0; 6],
        false,
        false,
        sequence,
    )
    .to_vec();
    msg.push(INTERFACE_STATION);
    push_fixed(&mut msg, ssid.as_bytes(), 32);
    push_fixed(&mut msg, password.as_bytes(), 64);
    msg.push(security);
    msg
}

// ── reply decoders ───────────────────────────────────────────────────────

/// The framing fields of any received datagram: who it is from and which
/// request it answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplyHeader {
    pub source: u32,
    pub target: [u8; 6],
    pub sequence: u8,
    pub msg_type: u16,
}

fn need(bytes: &[u8], needed: usize) -> Result<(), ProtocolError> {
    if bytes.len() < needed {
        return Err(ProtocolError::BufferTooShort {
            needed,
            got: bytes.len(),
        });
    }
    Ok(())
}

/// Parse the 36-byte header off the front of a received datagram.
pub fn parse_header(bytes: &[u8]) -> Result<ReplyHeader, ProtocolError> {
    need(bytes, HEADER_LEN)?;
    let mut target = [0u8; 6];
    target.copy_from_slice(&bytes[8..14]);
    Ok(ReplyHeader {
        source: u32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]),
        target,
        sequence: bytes[23],
        msg_type: u16::from_le_bytes([bytes[32], bytes[33]]),
    })
}

/// A decoded `StateService` (3): which service this is (1 = UDP) and the port
/// it listens on. The device's IP is the datagram's source address, which the
/// socket layer already knows, so it is not carried here.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateService {
    pub mac: [u8; 6],
    pub service: u8,
    pub port: u32,
}

pub fn parse_state_service(bytes: &[u8]) -> Result<StateService, ProtocolError> {
    let head = parse_header(bytes)?;
    need(bytes, HEADER_LEN + 5)?;
    Ok(StateService {
        mac: head.target,
        service: bytes[HEADER_LEN],
        port: u32::from_le_bytes([
            bytes[HEADER_LEN + 1],
            bytes[HEADER_LEN + 2],
            bytes[HEADER_LEN + 3],
            bytes[HEADER_LEN + 4],
        ]),
    })
}

/// A decoded `State` (107): the light's current colour, power and label.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LightState {
    pub color: Hsbk,
    pub power_on: bool,
    pub label: String,
}

pub fn parse_state(bytes: &[u8]) -> Result<LightState, ProtocolError> {
    parse_header(bytes)?;
    // payload: color(8) reserved(2) power(2) label(32) reserved(8) = 52.
    // We read through the label, so require header + 44.
    need(bytes, HEADER_LEN + 44)?;
    let color = read_hsbk(bytes, HEADER_LEN);
    let power = u16::from_le_bytes([bytes[HEADER_LEN + 10], bytes[HEADER_LEN + 11]]);
    let label = decode_label(&bytes[HEADER_LEN + 12..HEADER_LEN + 44]);
    Ok(LightState {
        color,
        power_on: power != 0,
        label,
    })
}

/// A decoded multizone reply: the strip's zone count and the colours this
/// message carries, starting at `zone_index`. One `StateMultiZone` (506) holds
/// up to 8 zones; a longer strip sends several, keyed by `zone_index`. A single
/// `StateZone` (503) is normalised into the same shape (one colour).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MultiZone {
    pub zones_count: u8,
    pub zone_index: u8,
    pub colors: Vec<Hsbk>,
}

pub fn parse_state_multi_zone(bytes: &[u8]) -> Result<MultiZone, ProtocolError> {
    parse_header(bytes)?;
    need(bytes, HEADER_LEN + 2)?;
    let zones_count = bytes[HEADER_LEN];
    let zone_index = bytes[HEADER_LEN + 1];
    // Read as many whole HSBK colours as the payload actually carries, capped
    // at the 8 a StateMultiZone can hold — a short datagram yields fewer rather
    // than an error, and a device that padded to 8 yields 8.
    let available = (bytes.len() - (HEADER_LEN + 2)) / 8;
    let count = available.min(8);
    let colors = (0..count)
        .map(|i| read_hsbk(bytes, HEADER_LEN + 2 + i * 8))
        .collect();
    Ok(MultiZone {
        zones_count,
        zone_index,
        colors,
    })
}

pub fn parse_state_zone(bytes: &[u8]) -> Result<MultiZone, ProtocolError> {
    parse_header(bytes)?;
    need(bytes, HEADER_LEN + 10)?;
    Ok(MultiZone {
        zones_count: bytes[HEADER_LEN],
        zone_index: bytes[HEADER_LEN + 1],
        colors: vec![read_hsbk(bytes, HEADER_LEN + 2)],
    })
}

/// A decoded `StateAccessPoint` (0x132): one network an unprovisioned device can
/// see. The 38-byte payload is `interface(1) ssid(32) security(1) strength(2)
/// channel(2)`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccessPoint {
    pub ssid: String,
    pub security: u8,
    pub strength: i16,
    pub channel: u16,
}

pub fn parse_state_access_point(bytes: &[u8]) -> Result<AccessPoint, ProtocolError> {
    parse_header(bytes)?;
    need(bytes, HEADER_LEN + 38)?;
    // interface at payload offset 0 is ignored — the reply is always a station
    // scan result.
    Ok(AccessPoint {
        ssid: decode_label(&bytes[HEADER_LEN + 1..HEADER_LEN + 33]),
        security: bytes[HEADER_LEN + 33],
        strength: i16::from_le_bytes([bytes[HEADER_LEN + 34], bytes[HEADER_LEN + 35]]),
        channel: u16::from_le_bytes([bytes[HEADER_LEN + 36], bytes[HEADER_LEN + 37]]),
    })
}

/// A LIFX label is 32 UTF-8 bytes, null-padded. Cut at the first null and
/// decode lossily — a garbled label must not fail a whole reply.
fn decode_label(field: &[u8]) -> String {
    let end = field.iter().position(|&b| b == 0).unwrap_or(field.len());
    String::from_utf8_lossy(&field[..end]).into_owned()
}

/// A decoded reply, routed by the header's message type.
///
/// A single entry point for the socket layer: hand it whatever datagram came
/// back and it either decodes a message this client understands or reports the
/// type it skipped (an `Acknowledgement`, a `StatePower`, anything not asked
/// for). Dispatching here rather than in the caller keeps the type-number →
/// parser mapping in one place beside the parsers.
#[derive(Debug, Clone, PartialEq)]
pub enum Reply {
    Service(StateService),
    Light(LightState),
    Zones(MultiZone),
    AccessPoint(AccessPoint),
    /// A well-formed reply of a type this client does not decode.
    Other {
        msg_type: u16,
    },
}

/// Decode a received datagram by the message type in its header.
pub fn decode_reply(bytes: &[u8]) -> Result<Reply, ProtocolError> {
    let head = parse_header(bytes)?;
    Ok(match head.msg_type {
        msg::STATE_SERVICE => Reply::Service(parse_state_service(bytes)?),
        msg::STATE => Reply::Light(parse_state(bytes)?),
        msg::STATE_ZONE => Reply::Zones(parse_state_zone(bytes)?),
        msg::STATE_MULTI_ZONE => Reply::Zones(parse_state_multi_zone(bytes)?),
        msg::STATE_ACCESS_POINT => Reply::AccessPoint(parse_state_access_point(bytes)?),
        other => Reply::Other { msg_type: other },
    })
}

// ── entity synthesis ─────────────────────────────────────────────────────

/// One control a LIFX light exposes, in transport-neutral terms the FFI layer
/// turns into a `NetworkActionDto`. LIFX actions do not come from the spec's
/// `commands` block (it has none the generic renderer could execute); they are
/// synthesised from the entity's declared `features`, and their `command_name`
/// is the canonical action string [`render_command`] dispatches on.
#[derive(Debug, Clone, PartialEq)]
pub struct LifxControl {
    pub role: &'static str,
    pub command_name: &'static str,
    pub user_params: Vec<&'static str>,
    pub min: Option<f64>,
    pub max: Option<f64>,
}

/// A LIFX light entity resolved to its working controls.
#[derive(Debug, Clone, PartialEq)]
pub struct LifxEntity {
    pub name: String,
    pub controls: Vec<LifxControl>,
    /// Zones declared in the spec (`lifx_lan_protocol.zone_count`). A hint for
    /// the UI before a live `GetColorZones`; 1 for a single-zone bulb.
    pub zone_count: u32,
}

/// Whether a `light` entity's `features:` list contains a named capability.
/// Features are free-form YAML scalars in the spec, so match on the string.
fn has_feature(entity: &crate::spec::types::Entity, name: &str) -> bool {
    entity
        .features
        .iter()
        .filter_map(|f| f.as_str())
        .any(|f| f == name)
}

/// The controllable entities of a LIFX spec. Only `platform: light` entities
/// are driven; each resolves power plus whichever of colour, brightness and
/// colour-temperature its `features` declare. Brightness rides on `set_color`
/// (LIFX has no brightness-only message — it is the B of HSBK), so a strip that
/// declares `brightness` gets it as an extra `set_color` parameter, exactly the
/// way the BLE light card treats a colour command that carries brightness.
pub fn network_entities(spec: &DeviceSpec) -> Vec<LifxEntity> {
    let zone_count = spec
        .extensions
        .get("lifx_lan_protocol")
        .and_then(|b| b.get("zone_count"))
        .and_then(serde_yaml::Value::as_u64)
        .unwrap_or(1)
        .max(1) as u32;

    spec.entities
        .iter()
        .filter(|e| e.platform.as_deref() == Some("light"))
        .map(|entity| {
            let mut controls = vec![
                LifxControl {
                    role: "turn_on",
                    command_name: "turn_on",
                    user_params: vec![],
                    min: None,
                    max: None,
                },
                LifxControl {
                    role: "turn_off",
                    command_name: "turn_off",
                    user_params: vec![],
                    min: None,
                    max: None,
                },
            ];

            let wants_color = has_feature(entity, "color");
            let wants_brightness = has_feature(entity, "brightness");
            if wants_color {
                let mut params = vec!["red", "green", "blue"];
                if wants_brightness {
                    params.push("brightness");
                }
                controls.push(LifxControl {
                    role: "set_color",
                    command_name: "set_color",
                    user_params: params,
                    min: None,
                    max: None,
                });
            } else if wants_brightness {
                controls.push(LifxControl {
                    role: "set_brightness",
                    command_name: "set_brightness",
                    user_params: vec!["brightness"],
                    min: Some(0.0),
                    max: Some(255.0),
                });
            }

            if has_feature(entity, "color_temperature") {
                controls.push(LifxControl {
                    role: "set_color_temperature",
                    command_name: "set_color_temperature",
                    user_params: vec!["kelvin"],
                    min: Some(f64::from(KELVIN_MIN)),
                    max: Some(f64::from(KELVIN_MAX)),
                });
            }

            if zone_count > 1 {
                let mut params = vec!["zone", "red", "green", "blue"];
                if wants_brightness {
                    params.push("brightness");
                }
                controls.push(LifxControl {
                    role: "set_zone_color",
                    command_name: "set_zone_color",
                    user_params: params,
                    min: None,
                    max: None,
                });
            }

            LifxEntity {
                name: entity.name.clone(),
                controls,
                zone_count,
            }
        })
        .collect()
}

// ── action rendering ─────────────────────────────────────────────────────

/// Brightness comes off a 0..=255 UI slider; scale it to the `u16` LIFX wants.
fn scale_brightness(v: f64) -> u16 {
    (v.clamp(0.0, 255.0) / 255.0 * f64::from(u16::MAX)).round() as u16
}

/// Render one control action into datagram bytes.
///
/// `action` is the `command_name` from [`network_entities`]; `params` carries
/// the UI-owned values (`red`/`green`/`blue`/`brightness` 0..=255, `kelvin`
/// 1500..=9000, `zone` a zone index). `target` is the 6-byte device MAC
/// (all-zero addresses every device, accepted by unicast firmware); `sequence`
/// is the caller's counter, echoed in any reply.
pub fn render_command(
    action: &str,
    params: &std::collections::HashMap<String, f64>,
    target: [u8; 6],
    sequence: u8,
) -> Result<Vec<u8>, ProtocolError> {
    let get = |k: &str| params.get(k).copied();
    let rgb = || {
        (
            get("red").unwrap_or(0.0).clamp(0.0, 255.0) as u8,
            get("green").unwrap_or(0.0).clamp(0.0, 255.0) as u8,
            get("blue").unwrap_or(0.0).clamp(0.0, 255.0) as u8,
        )
    };
    // A colour picked as RGB carries its own brightness (the V of HSV); an
    // explicit brightness slider overrides it when present.
    let color_with_brightness = || {
        let (r, g, b) = rgb();
        let mut c = rgb_to_hsbk(r, g, b, KELVIN_DEFAULT);
        if let Some(br) = get("brightness") {
            c.brightness = scale_brightness(br);
        }
        c
    };

    match action {
        "turn_on" => Ok(set_power(target, true, 0, sequence)),
        "turn_off" => Ok(set_power(target, false, 0, sequence)),
        "set_color" => Ok(set_color(target, &color_with_brightness(), 0, sequence)),
        "set_brightness" => {
            // No colour picked: drive brightness as a neutral warm white so the
            // strip dims/brightens without lurching to a colour.
            let c = Hsbk {
                hue: 0,
                saturation: 0,
                brightness: scale_brightness(get("brightness").unwrap_or(255.0)),
                kelvin: KELVIN_DEFAULT,
            };
            Ok(set_color(target, &c, 0, sequence))
        }
        "set_color_temperature" => {
            let kelvin = get("kelvin")
                .unwrap_or(f64::from(KELVIN_DEFAULT))
                .clamp(f64::from(KELVIN_MIN), f64::from(KELVIN_MAX))
                as u16;
            let brightness = get("brightness").map_or(u16::MAX, scale_brightness);
            let c = Hsbk {
                hue: 0,
                saturation: 0,
                brightness,
                kelvin,
            };
            Ok(set_color(target, &c, 0, sequence))
        }
        "set_zone_color" => {
            let zone = get("zone").unwrap_or(0.0).clamp(0.0, 255.0) as u8;
            Ok(set_color_zones(
                target,
                zone,
                zone,
                &color_with_brightness(),
                0,
                sequence,
            ))
        }
        other => Err(ProtocolError::UnsupportedCommandEncoding(format!(
            "lifx action '{other}'"
        ))),
    }
}

/// Parse a `mac` string of the form `d0:73:d5:00:04:a3` into the 6-byte target.
/// An unparseable or absent MAC yields the all-zero target, which unicast
/// firmware still answers — discovery has simply not supplied one yet.
pub fn parse_mac(mac: &str) -> [u8; 6] {
    let mut out = [0u8; 6];
    for (i, part) in mac.split(':').take(6).enumerate() {
        out[i] = u8::from_str_radix(part.trim(), 16).unwrap_or(0);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const TARGET: [u8; 6] = [0xd0, 0x73, 0xd5, 0x00, 0x04, 0xa3];

    fn params(pairs: &[(&str, f64)]) -> HashMap<String, f64> {
        pairs.iter().map(|(k, v)| ((*k).to_string(), *v)).collect()
    }

    #[test]
    fn get_service_is_a_tagged_broadcast_with_no_payload() {
        let pkt = get_service(1);
        assert_eq!(pkt.len(), HEADER_LEN);
        // size = 36
        assert_eq!(&pkt[0..2], &[36, 0]);
        // protocol|addressable|tagged = 0x3400 -> LE 0x00, 0x34
        assert_eq!(&pkt[2..4], &[0x00, 0x34]);
        // source echoed as "LBRG" little-endian
        assert_eq!(&pkt[4..8], &SOURCE.to_le_bytes());
        // target all-zero (broadcast)
        assert_eq!(&pkt[8..16], &[0u8; 8]);
        // res_required set, sequence 1
        assert_eq!(pkt[22], 0x01);
        assert_eq!(pkt[23], 1);
        // type = 2
        assert_eq!(&pkt[32..34], &[2, 0]);
    }

    #[test]
    fn an_addressed_message_is_0x1400_and_carries_the_mac() {
        let pkt = get_color(TARGET, 7);
        assert_eq!(&pkt[2..4], &[0x00, 0x14]); // addressable, not tagged
        assert_eq!(&pkt[8..14], &TARGET);
        assert_eq!(&pkt[14..16], &[0, 0]); // MAC padding
        assert_eq!(pkt[23], 7);
        assert_eq!(&pkt[32..34], &[101, 0]);
    }

    #[test]
    fn set_power_on_is_full_level_with_duration() {
        let pkt = set_power(TARGET, true, 0x0102_0304, 3);
        assert_eq!(&pkt[0..2], &[42, 0]); // 36 + 6
        assert_eq!(&pkt[32..34], &[117, 0]);
        assert_eq!(&pkt[HEADER_LEN..HEADER_LEN + 2], &[0xff, 0xff]); // level 65535
        assert_eq!(
            &pkt[HEADER_LEN + 2..HEADER_LEN + 6],
            &[0x04, 0x03, 0x02, 0x01]
        );
        // off is level 0
        let off = set_power(TARGET, false, 0, 3);
        assert_eq!(&off[HEADER_LEN..HEADER_LEN + 2], &[0, 0]);
    }

    #[test]
    fn set_color_lays_hsbk_out_little_endian_after_a_reserved_byte() {
        let color = Hsbk {
            hue: 0x1122,
            saturation: 0x3344,
            brightness: 0x5566,
            kelvin: 3500,
        };
        let pkt = set_color(TARGET, &color, 1000, 9);
        assert_eq!(&pkt[0..2], &[49, 0]); // 36 + 13
        assert_eq!(&pkt[32..34], &[102, 0]);
        assert_eq!(pkt[HEADER_LEN], 0); // reserved
        assert_eq!(&pkt[HEADER_LEN + 1..HEADER_LEN + 3], &[0x22, 0x11]);
        assert_eq!(&pkt[HEADER_LEN + 3..HEADER_LEN + 5], &[0x44, 0x33]);
        assert_eq!(&pkt[HEADER_LEN + 5..HEADER_LEN + 7], &[0x66, 0x55]);
        assert_eq!(&pkt[HEADER_LEN + 7..HEADER_LEN + 9], &3500u16.to_le_bytes());
        assert_eq!(
            &pkt[HEADER_LEN + 9..HEADER_LEN + 13],
            &1000u32.to_le_bytes()
        );
    }

    #[test]
    fn set_color_zones_frames_start_end_and_apply() {
        let color = Hsbk {
            hue: 1,
            saturation: 2,
            brightness: 3,
            kelvin: 4,
        };
        let pkt = set_color_zones(TARGET, 2, 5, &color, 0, 4);
        assert_eq!(&pkt[0..2], &[51, 0]); // 36 + 15
        assert_eq!(&pkt[32..34], &[0xf5, 0x01]); // 501 LE
        assert_eq!(pkt[HEADER_LEN], 2);
        assert_eq!(pkt[HEADER_LEN + 1], 5);
        assert_eq!(pkt[HEADER_LEN + 14], APPLY);
    }

    #[test]
    fn rgb_primaries_map_to_the_expected_hsbk() {
        // Pure red: hue 0, full saturation and brightness.
        let red = rgb_to_hsbk(255, 0, 0, KELVIN_DEFAULT);
        assert_eq!(red.hue, 0);
        assert_eq!(red.saturation, u16::MAX);
        assert_eq!(red.brightness, u16::MAX);
        // White: no saturation, full brightness.
        let white = rgb_to_hsbk(255, 255, 255, KELVIN_DEFAULT);
        assert_eq!(white.saturation, 0);
        assert_eq!(white.brightness, u16::MAX);
        // Black: zero brightness.
        assert_eq!(rgb_to_hsbk(0, 0, 0, KELVIN_DEFAULT).brightness, 0);
    }

    #[test]
    fn rgb_round_trips_through_hsbk_within_a_step() {
        for (r, g, b) in [
            (255, 0, 0),
            (0, 255, 0),
            (0, 0, 255),
            (255, 128, 0),
            (10, 200, 90),
        ] {
            let (r2, g2, b2) = hsbk_to_rgb(&rgb_to_hsbk(r, g, b, KELVIN_DEFAULT));
            assert!((i32::from(r) - i32::from(r2)).abs() <= 1, "r {r}->{r2}");
            assert!((i32::from(g) - i32::from(g2)).abs() <= 1, "g {g}->{g2}");
            assert!((i32::from(b) - i32::from(b2)).abs() <= 1, "b {b}->{b2}");
        }
    }

    #[test]
    fn get_access_points_is_a_tagged_empty_request() {
        let pkt = get_access_points(2);
        assert_eq!(pkt.len(), HEADER_LEN);
        assert_eq!(&pkt[2..4], &[0x00, 0x34]); // tagged broadcast on the setup AP
        assert_eq!(&pkt[32..34], &0x130u16.to_le_bytes());
    }

    #[test]
    fn set_access_point_frames_credentials_null_padded() {
        let pkt = set_access_point("HomeNet", "s3cr3t", SECURITY_WPA2_AES, 4);
        assert_eq!(pkt.len(), HEADER_LEN + 98);
        assert_eq!(&pkt[0..2], &134u16.to_le_bytes());
        assert_eq!(&pkt[32..34], &0x131u16.to_le_bytes());
        assert_eq!(pkt[HEADER_LEN], INTERFACE_STATION);
        // ssid at payload offset 1, null-padded to 32.
        assert_eq!(&pkt[HEADER_LEN + 1..HEADER_LEN + 8], b"HomeNet");
        assert_eq!(pkt[HEADER_LEN + 8], 0);
        // password at payload offset 33.
        assert_eq!(&pkt[HEADER_LEN + 33..HEADER_LEN + 39], b"s3cr3t");
        assert_eq!(pkt[HEADER_LEN + 33 + 6], 0);
        // security byte last, at payload offset 97.
        assert_eq!(pkt[HEADER_LEN + 97], SECURITY_WPA2_AES);
    }

    #[test]
    fn a_string_longer_than_its_field_is_truncated_not_overrun() {
        let long = "x".repeat(50);
        let pkt = set_access_point(&long, &long, 5, 0);
        // Still exactly 98 payload bytes: the 50-char ssid is cut to 32.
        assert_eq!(pkt.len(), HEADER_LEN + 98);
        assert_eq!(&pkt[HEADER_LEN + 1..HEADER_LEN + 33], &[b'x'; 32]);
    }

    #[test]
    fn state_access_point_decodes_ssid_and_signal() {
        let mut pkt = header(msg::STATE_ACCESS_POINT, 38, false, TARGET, false, false, 0).to_vec();
        pkt.push(2); // interface
        let mut ssid = [0u8; 32];
        ssid[..7].copy_from_slice(b"HomeNet");
        pkt.extend_from_slice(&ssid);
        pkt.push(SECURITY_WPA2_AES);
        pkt.extend_from_slice(&(-40i16).to_le_bytes()); // strength
        pkt.extend_from_slice(&11u16.to_le_bytes()); // channel
        let ap = parse_state_access_point(&pkt).unwrap();
        assert_eq!(ap.ssid, "HomeNet");
        assert_eq!(ap.security, SECURITY_WPA2_AES);
        assert_eq!(ap.strength, -40);
        assert_eq!(ap.channel, 11);
        // and it routes through the dispatcher
        assert!(matches!(
            decode_reply(&pkt).unwrap(),
            Reply::AccessPoint(a) if a.ssid == "HomeNet"
        ));
    }

    #[test]
    fn state_service_decodes_mac_service_and_port() {
        let mut pkt = get_service(0); // reuse the header shape
                                      // Overwrite header target so the reply carries a MAC, set type 3.
        pkt[8..14].copy_from_slice(&TARGET);
        pkt[32..34].copy_from_slice(&msg::STATE_SERVICE.to_le_bytes());
        pkt.push(1); // service = UDP
        pkt.extend_from_slice(&56700u32.to_le_bytes());
        let state = parse_state_service(&pkt).unwrap();
        assert_eq!(state.mac, TARGET);
        assert_eq!(state.service, 1);
        assert_eq!(state.port, 56700);
    }

    #[test]
    fn light_state_decodes_color_power_and_label() {
        let color = Hsbk {
            hue: 100,
            saturation: 200,
            brightness: 300,
            kelvin: 4000,
        };
        let mut pkt = header(msg::STATE, 52, false, TARGET, false, false, 0).to_vec();
        pkt.extend_from_slice(&hsbk_bytes(&color)); // color
        pkt.extend_from_slice(&[0, 0]); // reserved
        pkt.extend_from_slice(&u16::MAX.to_le_bytes()); // power on
        let mut label = [0u8; 32];
        label[..6].copy_from_slice(b"LIFX Z");
        pkt.extend_from_slice(&label);
        pkt.extend_from_slice(&[0u8; 8]); // reserved
        let state = parse_state(&pkt).unwrap();
        assert_eq!(state.color, color);
        assert!(state.power_on);
        assert_eq!(state.label, "LIFX Z");
    }

    #[test]
    fn multi_zone_decodes_count_index_and_colours() {
        let mut pkt = header(msg::STATE_MULTI_ZONE, 66, false, TARGET, false, false, 0).to_vec();
        pkt.push(8); // zones_count
        pkt.push(0); // zone_index
        for i in 0..8u16 {
            pkt.extend_from_slice(&hsbk_bytes(&Hsbk {
                hue: i,
                saturation: i,
                brightness: i,
                kelvin: 3500,
            }));
        }
        let mz = parse_state_multi_zone(&pkt).unwrap();
        assert_eq!(mz.zones_count, 8);
        assert_eq!(mz.zone_index, 0);
        assert_eq!(mz.colors.len(), 8);
        assert_eq!(mz.colors[3].hue, 3);
    }

    #[test]
    fn a_single_state_zone_normalises_to_one_colour() {
        let color = Hsbk {
            hue: 500,
            saturation: 600,
            brightness: 700,
            kelvin: 3500,
        };
        let mut pkt = header(msg::STATE_ZONE, 10, false, TARGET, false, false, 0).to_vec();
        pkt.push(8); // zones_count
        pkt.push(2); // zone_index
        pkt.extend_from_slice(&hsbk_bytes(&color));
        let mz = parse_state_zone(&pkt).unwrap();
        assert_eq!(mz.zones_count, 8);
        assert_eq!(mz.zone_index, 2);
        assert_eq!(mz.colors, vec![color]);
    }

    #[test]
    fn a_short_buffer_is_an_error_not_a_panic() {
        assert!(matches!(
            parse_header(&[0u8; 10]),
            Err(ProtocolError::BufferTooShort {
                needed: 36,
                got: 10
            })
        ));
        assert!(matches!(
            parse_state_service(&[0u8; HEADER_LEN]),
            Err(ProtocolError::BufferTooShort { .. })
        ));
    }

    #[test]
    fn render_dispatches_each_action_to_its_message_type() {
        let on = render_command("turn_on", &params(&[]), TARGET, 1).unwrap();
        assert_eq!(&on[32..34], &[117, 0]);
        let color = render_command(
            "set_color",
            &params(&[("red", 255.0), ("green", 0.0), ("blue", 0.0)]),
            TARGET,
            2,
        )
        .unwrap();
        assert_eq!(&color[32..34], &[102, 0]);
        // red -> hue 0, full sat/bri
        assert_eq!(&color[HEADER_LEN + 1..HEADER_LEN + 3], &[0, 0]);
        assert_eq!(
            &color[HEADER_LEN + 3..HEADER_LEN + 5],
            &u16::MAX.to_le_bytes()
        );
        let zone = render_command(
            "set_zone_color",
            &params(&[("zone", 3.0), ("red", 0.0), ("green", 255.0), ("blue", 0.0)]),
            TARGET,
            3,
        )
        .unwrap();
        assert_eq!(&zone[32..34], &[0xf5, 0x01]); // 501
        assert_eq!(zone[HEADER_LEN], 3);
        assert_eq!(zone[HEADER_LEN + 1], 3);
        // an unknown action is declined, not guessed
        assert!(render_command("frobnicate", &params(&[]), TARGET, 0).is_err());
    }

    #[test]
    fn parse_mac_reads_a_colon_hex_string() {
        assert_eq!(parse_mac("d0:73:d5:00:04:a3"), TARGET);
        assert_eq!(parse_mac(""), [0; 6]);
    }

    #[test]
    fn decode_reply_routes_by_message_type() {
        // A StateService round-trips through the dispatcher.
        let mut svc = header(msg::STATE_SERVICE, 5, false, TARGET, false, false, 0).to_vec();
        svc.push(1);
        svc.extend_from_slice(&56700u32.to_le_bytes());
        assert!(matches!(decode_reply(&svc).unwrap(), Reply::Service(s) if s.port == 56700));

        // An acknowledgement (type 45) is reported, not an error.
        let ack = header(45, 0, false, TARGET, false, false, 0).to_vec();
        assert_eq!(decode_reply(&ack).unwrap(), Reply::Other { msg_type: 45 });
    }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The LOY SPACE / popled.cn panel over Wi-Fi: the same `aa 55` frame as the
//! BLE backpack ([`super::popled`]), carried in UDP datagrams to port 9090 on
//! the panel's own "YS…" access point (led-space.yaml,
//! `protocol_details.popled_wifi_protocol`).
//!
//! What the spec states, and this follows:
//!
//! ```text
//! datagram = len u16le | len bytes of popled frame
//! ```
//!
//! a frame longer than 180 bytes split across several such datagrams ~5 ms
//! apart; replies decoded through the same frame layer; the wire sequence
//! starting at 1 and rising by one per command.
//!
//! **None of this has been run against a panel.** The frame and its bodies
//! are the hardware-verified BLE ones; the outer length prefix is the spec's
//! word and nothing more. On BLE the same specs claimed an outer prefix that
//! the bench showed the panel does not want (SPECS_TO_FIX.md), so this one is
//! the first thing to check on hardware. Two details the spec leaves open are
//! settled here and marked where they are: whether the 180 counts the prefix
//! (it does not, here), and whether a reply carries the prefix (either is
//! accepted).
//!
//! Image upload is NOT what the spec describes. The spec's feature says
//! zlib-compressed BMP inside a `pkts_program` JSON whose TLV layout it never
//! gives, so that path cannot be built from it. What is sent instead is the
//! BLE backpack's hardware-proven GIF upload (same board family, same frame),
//! carried over UDP — untested over Wi-Fi.

use std::collections::{BTreeMap, HashMap};

use super::popled::{self, frame, frames_in, BODY_ACK, HANDLER_NAME};
use crate::error::ProtocolError;
use crate::spec::types::{Command, DeviceSpec, SpecCommand};

/// The transport the spec's device block declares. Bare `udp` already means
/// Rabbit Air and LimitlessLED downstream, so the resolver replaces it with
/// [`HANDLER_NAME`] on an action, the LimitlessLED precedent.
pub const TRANSPORT: &str = "udp";

/// The panel's control and discovery port (`identification.default_port`).
pub const PORT: u16 = 9090;

/// Bytes of frame per datagram (`writeFscNum` in the spec's words). The
/// 2-byte prefix comes on top: the spec does not say whether it counts.
pub const DATAGRAM_CHUNK: usize = 180;

/// The pause between the datagrams of one split frame (~5 ms in the spec).
pub const INTER_DATAGRAM_MS: u32 = 5;

/// The sequence number of the first frame a client sends (`sno_base`).
pub const FIRST_SEQ: u16 = 1;

/// `{"cmd":{"get":"dev_info"}}`: the device-information query, alone. The
/// body of the probe the spec prints, `aa 55 ff ff 08 00 01 00 c1 03 0a 00
/// d4 03`.
pub const DEV_INFO_QUERY: [u8; 4] = [0xC1, 0x03, 0x0A, 0x00];

/// The identity dialect a scan reads this panel's reply in: the reply is a
/// binary frame, so the generic readers cannot, and [`discovery_fields`] does.
pub const IDENTITY_DIALECT: &str = "popled";

/// The names [`discovery_fields`] reads into, which are the ones the spec's
/// `discovery.identity` names (`stable_keys: ["id_dev"]`, `display: "name"`).
pub const FIELD_ID: &str = "id_dev";
pub const FIELD_NAME: &str = "name";
pub const FIELD_MODEL: &str = "model";
pub const FIELD_VERSION: &str = "version";

/// One network command: its name, the BLE command it sends, and the value it
/// fixes, if any.
type NetworkCommand = (&'static str, &'static str, Option<(&'static str, f64)>);

/// The network commands this handler gives a Wi-Fi panel, and the BLE
/// characteristic command (with its fixed values) each one sends. The spec's
/// `power_toggle` states the power rather than toggling it (measured on the
/// backpack, SPECS_TO_FIX.md), so it serves as both turn_on and turn_off.
const NETWORK_COMMANDS: &[NetworkCommand] = &[
    ("set_brightness", "set_brightness", None),
    ("turn_on", "power_toggle", Some(("state", 1.0))),
    ("turn_off", "power_toggle", Some(("state", 0.0))),
];

/// Whether `spec` is a popled panel reached over Wi-Fi: the handler, and a
/// device block that says `transport: udp`. The BLE backpack and bag say
/// neither, and are left exactly as they were.
pub fn is_wifi_panel(spec: &DeviceSpec) -> bool {
    spec.protocol_handler.as_deref() == Some(HANDLER_NAME)
        && spec
            .device
            .extensions
            .get("transport")
            .and_then(|t| t.as_str())
            == Some(TRANSPORT)
}

/// The BLE characteristic command a Wi-Fi panel's network command sends.
fn characteristic_command<'a>(spec: &'a DeviceSpec, name: &str) -> Option<&'a Command> {
    spec.services
        .iter()
        .flat_map(|s| &s.characteristics)
        .filter_map(|c| c.commands.as_ref()?.get(name))
        // Bound by [`popled::bind_commands`]: a command still `encoding:
        // json` has no wire form, and stays off the network surface too.
        .find(|c| c.encoding.is_none() && (c.template.is_some() || c.value.is_some()))
}

/// Give a Wi-Fi panel's light a network surface. Runs at parse time, after
/// [`popled::bind_commands`] has given the characteristic commands their
/// wire form; any other spec is untouched.
///
/// The spec binds its light's brightness to a command it declares only on
/// the BLE characteristic, so the network resolver, which reads the
/// top-level `commands`, found nothing and the panel drew no controls. Each
/// bound command gets a top-level twin riding `udp`, and the light gains
/// `turn_on`/`turn_off` from `power_toggle` where it binds none.
pub fn bind_network_surface(spec: &mut DeviceSpec) {
    if !is_wifi_panel(spec) {
        return;
    }
    let mut added = Vec::new();
    for &(name, wire, fixed) in NETWORK_COMMANDS {
        if spec.commands.contains_key(name) {
            continue;
        }
        let Some(command) = characteristic_command(spec, wire) else {
            continue;
        };
        // The user's value, when the network command takes one, with the
        // bounds the wire command states and no default: a default would
        // make the value the control supplies a fixed one.
        let mut yaml = format!("transport: \"{TRANSPORT}\"\nparameters:\n");
        if fixed.is_none() {
            let params = command.parameters.as_ref();
            for (param, p) in params.into_iter().flat_map(|p| &p.params) {
                yaml.push_str(&format!("  {param}:\n    type: \"int\"\n"));
                if let Some(min) = p.min {
                    yaml.push_str(&format!("    min: {min}\n"));
                }
                if let Some(max) = p.max {
                    yaml.push_str(&format!("    max: {max}\n"));
                }
            }
        }
        if yaml.ends_with("parameters:\n") {
            yaml.push_str("  {}\n");
        }
        let Ok(parsed) = serde_yaml::from_str::<SpecCommand>(&yaml) else {
            debug_assert!(false, "unparseable network command {name}: {yaml}");
            continue;
        };
        spec.commands.insert(name.to_string(), parsed);
        added.push(name);
    }
    for entity in &mut spec.entities {
        if entity.platform.as_deref() != Some("light") {
            continue;
        }
        for role in ["turn_on", "turn_off"] {
            if added.contains(&role) && !entity.commands.contains_key(role) {
                entity.commands.insert(role.to_string(), role.into());
            }
        }
    }
}

/// The frame body a Wi-Fi panel's network command sends. `values` are the
/// action's user values as text, as every LAN renderer takes them.
pub fn render_command(
    spec: &DeviceSpec,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<Vec<u8>, ProtocolError> {
    if !is_wifi_panel(spec) {
        return Err(ProtocolError::UnsupportedCommandEncoding(format!(
            "{command_name}: not a Wi-Fi popled panel"
        )));
    }
    let (_, wire, fixed) = NETWORK_COMMANDS
        .iter()
        .find(|(name, ..)| *name == command_name)
        .ok_or_else(|| ProtocolError::CommandNotFound {
            uuid: String::new(),
            command: command_name.to_string(),
        })?;
    let command =
        characteristic_command(spec, wire).ok_or_else(|| ProtocolError::CommandNotFound {
            uuid: String::new(),
            command: wire.to_string(),
        })?;
    let mut params = HashMap::new();
    match fixed {
        Some((name, value)) => {
            params.insert(name.to_string(), *value);
        }
        None => {
            for (name, raw) in values {
                let value = raw.trim().parse::<f64>().map_err(|_| {
                    ProtocolError::ParameterValueInvalid {
                        name: name.clone(),
                        value: raw.clone(),
                        reason: "not a number".to_string(),
                    }
                })?;
                params.insert(name.clone(), value);
            }
        }
    }
    crate::codec::types::encode_command(command, &params)
}

/// The datagrams that carry one frame: the frame split into
/// [`DATAGRAM_CHUNK`]-byte pieces, each behind its own u16-LE length.
pub fn datagrams(frame: &[u8]) -> Vec<Vec<u8>> {
    frame
        .chunks(DATAGRAM_CHUNK)
        .map(|piece| {
            let mut datagram = Vec::with_capacity(piece.len() + 2);
            datagram.extend_from_slice(&(piece.len() as u16).to_le_bytes());
            datagram.extend_from_slice(piece);
            datagram
        })
        .collect()
}

/// [`datagrams`] of the frame around `body` with sequence `seq`.
pub fn command_datagrams(seq: u16, body: &[u8]) -> Vec<Vec<u8>> {
    datagrams(&frame(seq, body))
}

/// The discovery probe: the dev_info query in the first frame a client
/// sends, in its datagram.
pub fn discovery_probe() -> Vec<u8> {
    command_datagrams(FIRST_SEQ, &DEV_INFO_QUERY).concat()
}

/// One datagram's frame bytes. The spec says a datagram is a length and that
/// many bytes, and it is read that way when it is; a datagram that does not
/// carry the prefix is taken whole, since the BLE panel's own replies do not
/// and the spec gives no capture of a Wi-Fi one.
fn unwrap_datagram(datagram: &[u8]) -> &[u8] {
    match datagram {
        [lo, hi, rest @ ..] if u16::from_le_bytes([*lo, *hi]) as usize == rest.len() => rest,
        _ => datagram,
    }
}

/// What one reply frame says.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reply {
    pub seq: u16,
    /// A write's acknowledgement status (`81 82 <status>`), 0 being success.
    pub ack_status: Option<u8>,
    /// Whether the body is a query's answer (`81 83 ...`).
    pub answer: bool,
    /// The panel's size, when the answer states it.
    pub size: Option<(u32, u32)>,
    /// The device-information record's fields, when the answer has one.
    pub fields: BTreeMap<String, String>,
}

/// Every complete frame in `datagrams`, in order. Garbage, a bad checksum, or
/// a frame whose tail never came reads as nothing rather than as an error.
pub fn read_replies(datagrams: &[Vec<u8>]) -> Vec<Reply> {
    let bytes: Vec<u8> = datagrams
        .iter()
        .flat_map(|d| unwrap_datagram(d))
        .copied()
        .collect();
    frames_in(&bytes)
        .into_iter()
        .map(|(seq, body)| Reply {
            seq,
            ack_status: body
                .strip_prefix(&BODY_ACK[..])
                .and_then(|s| s.first().copied()),
            answer: popled::answer_tlvs(&body).is_some(),
            size: popled::decode_panel_size(&[frame(seq, &body)]),
            fields: info_fields(&body),
        })
        .collect()
}

/// The device-information record as named fields. The spec names the reply
/// `{id_dev, model, version, cid, ...}`; the bench's BLE answer is one
/// comma-separated record leading with exactly those three. It carries no
/// separate name, so the display name is the panel's id.
fn info_fields(body: &[u8]) -> BTreeMap<String, String> {
    let Some(text) = popled::device_info_text(body) else {
        return BTreeMap::new();
    };
    let mut parts = text.split(',').map(str::trim);
    let mut out = BTreeMap::new();
    for key in [FIELD_ID, FIELD_MODEL, FIELD_VERSION] {
        match parts.next() {
            Some(value) if !value.is_empty() => {
                out.insert(key.to_string(), value.to_string());
            }
            _ => {}
        }
    }
    if let Some(id) = out.get(FIELD_ID).cloned() {
        out.insert(FIELD_NAME.to_string(), id);
    }
    out
}

/// The identity a discovery reply carries, or `None` when the datagram is not
/// a panel's answer naming its id: a stray packet on 9090 must not become a
/// row.
pub fn discovery_fields(datagram: &[u8]) -> Option<BTreeMap<String, String>> {
    read_replies(&[datagram.to_vec()])
        .into_iter()
        .map(|r| r.fields)
        .find(|f| f.contains_key(FIELD_ID))
}

/// The frame bodies that store and show `frames` (one still, or a looping
/// animation of each `delay_ms`) on a Wi-Fi panel: the BLE backpack's GIF
/// upload into its program slot, each body to be sent in its own frame and
/// acknowledged. Differs from the spec's own `zlib-bmp`, and untested over
/// Wi-Fi; see the module docs.
pub fn upload_bodies(
    spec: &DeviceSpec,
    frames: &[&[u8]],
    width: u32,
    height: u32,
    delay_ms: u32,
) -> Result<Vec<Vec<u8>>, ProtocolError> {
    if !is_wifi_panel(spec) {
        return Err(ProtocolError::ImageUploadUnsupported {
            reason: "not a Wi-Fi popled panel".to_string(),
        });
    }
    if frames.is_empty() {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: "no frames to upload".to_string(),
        });
    }
    for rgb in frames {
        super::image_upload::validate_rgb_canvas(spec, rgb, width, height)?;
    }
    let gif = popled::encode_animated_gif(frames, width, height, delay_ms)?;
    Ok(popled::upload_bodies(&gif))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn hex(s: &str) -> Vec<u8> {
        s.split_whitespace()
            .map(|b| u8::from_str_radix(b, 16).unwrap())
            .collect()
    }

    const SPEC: &str = r#"
device:
  name: "Wi-Fi panel"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "display"
  transport: "udp"
protocol_handler: "popled_json"
features:
  - type: "image_upload"
    format: "zlib-bmp"
    max_width: 64
    max_height: 64
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
        commands:
          power_toggle:
            description: "power"
            encoding: "json"
            payload: { key: "cmd.power.type", value_type: "int" }
          set_brightness:
            description: "brightness"
            encoding: "json"
            payload: { key: "cmd.light.value_fix", value_type: "int" }
entities:
  - platform: "light"
    name: "LED Screen"
    features: ["brightness"]
    commands:
      set_brightness: "set_brightness"
"#;

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC).unwrap()
    }

    /// The probe the spec prints in its softap method, byte for byte, from
    /// the frame builder; then the datagram the spec's framing puts it in.
    #[test]
    fn the_probe_is_the_specs_bytes_behind_its_length() {
        let printed = hex("aa 55 ff ff 08 00 01 00 c1 03 0a 00 d4 03");
        assert_eq!(frame(FIRST_SEQ, &DEV_INFO_QUERY), printed);
        let mut datagram = vec![0x0E, 0x00];
        datagram.extend_from_slice(&printed);
        assert_eq!(discovery_probe(), datagram);
    }

    #[test]
    fn a_long_frame_splits_into_prefixed_180_byte_datagrams() {
        let body = vec![0x5A; 400];
        let whole = frame(7, &body);
        let parts = command_datagrams(7, &body);
        assert_eq!(whole.len(), 410);
        assert_eq!(
            parts.iter().map(Vec::len).collect::<Vec<_>>(),
            [182, 182, 52]
        );
        for part in &parts {
            let declared = u16::from_le_bytes([part[0], part[1]]) as usize;
            assert_eq!(declared, part.len() - 2);
            assert!(declared <= DATAGRAM_CHUNK);
        }
        let rebuilt: Vec<u8> = parts.iter().flat_map(|p| p[2..].to_vec()).collect();
        assert_eq!(rebuilt, whole);
    }

    #[test]
    fn a_frame_of_exactly_one_chunk_is_one_datagram() {
        // 170 bytes of body make a 180-byte frame.
        let parts = command_datagrams(1, &[0u8; 170]);
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0][..2], [180, 0]);
    }

    #[test]
    fn replies_decode_with_or_without_the_prefix_and_split_across_datagrams() {
        let ack = frame(3, &[0x81, 0x82, 0x00]);
        let replies = read_replies(&datagrams(&ack));
        assert_eq!(replies.len(), 1);
        assert_eq!(replies[0].seq, 3);
        assert_eq!(replies[0].ack_status, Some(0));
        assert!(!replies[0].answer);

        let bare = read_replies(std::slice::from_ref(&ack));
        assert_eq!(bare[0].ack_status, Some(0));

        let refused = read_replies(&datagrams(&frame(4, &[0x81, 0x82, 0x03])));
        assert_eq!(refused[0].ack_status, Some(3));

        // A long answer split the way the spec splits a send.
        let answer = frame(
            1,
            &[
                [0x81, 0x83, 0x1B, 0x04, 0x00, 0x40, 0x00, 0x20].as_slice(),
                &[0xEE; 300],
            ]
            .concat(),
        );
        let replies = read_replies(&datagrams(&answer));
        assert_eq!(replies.len(), 1);
        assert_eq!(replies[0].size, Some((64, 32)));
    }

    #[test]
    fn garbage_and_a_bad_checksum_read_as_nothing() {
        assert!(read_replies(&[b"hello".to_vec()]).is_empty());
        assert!(read_replies(&[vec![]]).is_empty());
        let mut bad = frame(1, &[0x81, 0x82, 0x00]);
        *bad.last_mut().unwrap() ^= 1;
        assert!(read_replies(&[bad]).is_empty());
        assert!(discovery_fields(&[0x0E, 0x00, 0xAA, 0x55]).is_none());
    }

    #[test]
    fn a_dev_info_answer_names_the_panel() {
        let mut body = vec![0x81, 0x83, 0x0A];
        let text = b"525C110340,EXYC-A#CXB3BRI7BTVOICE3,V2.8.8#V01,server";
        body.push(text.len() as u8);
        body.extend_from_slice(text);
        let fields = discovery_fields(&datagrams(&frame(1, &body)).concat()).unwrap();
        assert_eq!(fields[FIELD_ID], "525C110340");
        assert_eq!(fields[FIELD_NAME], "525C110340");
        assert_eq!(fields[FIELD_MODEL], "EXYC-A#CXB3BRI7BTVOICE3");
        assert_eq!(fields[FIELD_VERSION], "V2.8.8#V01");
        // An acknowledgement is a panel, but names nothing.
        assert!(discovery_fields(&datagrams(&frame(1, &[0x81, 0x82, 0])).concat()).is_none());
    }

    #[test]
    fn the_wifi_panel_gains_a_network_light() {
        let spec = spec();
        let brightness = &spec.commands["set_brightness"];
        assert_eq!(brightness.transport.as_deref(), Some("udp"));
        assert_eq!(brightness.user_params(), ["brightness"]);
        assert_eq!(brightness.parameters["brightness"].min, Some(1.0));
        assert_eq!(brightness.parameters["brightness"].max, Some(15.0));
        assert!(spec.commands["turn_on"].user_params().is_empty());
        let light = &spec.entities[0];
        assert_eq!(light.command_for_role("turn_on"), Some("turn_on"));
        assert_eq!(light.command_for_role("turn_off"), Some("turn_off"));
    }

    #[test]
    fn a_ble_panel_is_left_alone() {
        let ble = parse_device_spec(&SPEC.replace("  transport: \"udp\"\n", "")).unwrap();
        assert!(ble.commands.is_empty());
        assert!(ble.entities[0].command_for_role("turn_on").is_none());
    }

    #[test]
    fn network_commands_render_the_bench_bodies() {
        let spec = spec();
        let values = |pairs: &[(&str, &str)]| {
            pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect::<BTreeMap<_, _>>()
        };
        assert_eq!(
            render_command(&spec, "set_brightness", &values(&[("brightness", "15")])).unwrap(),
            hex("c1 02 06 02 00 0f")
        );
        assert_eq!(
            render_command(&spec, "turn_on", &values(&[])).unwrap(),
            hex("c1 02 04 02 00 01")
        );
        assert_eq!(
            render_command(&spec, "turn_off", &values(&[])).unwrap(),
            hex("c1 02 04 02 00 00")
        );
        assert!(render_command(&spec, "set_brightness", &values(&[("brightness", "99")])).is_err());
        assert!(render_command(&spec, "set_rotation", &values(&[])).is_err());
    }

    #[test]
    fn an_upload_is_the_ble_gif_upload() {
        let spec = spec();
        let rgb = [0x10u8, 0x20, 0x30].repeat(64);
        let bodies = upload_bodies(&spec, &[&rgb], 8, 8, 0).unwrap();
        let gif = popled::encode_gif(&rgb, 8, 8).unwrap();
        assert_eq!(bodies, popled::upload_bodies(&gif));
        assert_eq!(bodies[0], hex("c1 02 04 02 00 01"), "wakes the panel first");
        assert!(upload_bodies(&spec, &[&rgb], 65, 1, 0).is_err());
        assert!(upload_bodies(&spec, &[], 8, 8, 0).is_err());
    }
}

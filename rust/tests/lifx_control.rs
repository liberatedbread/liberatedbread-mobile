// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end control test for a device driven over binary UDP: the LIFX Z
//! multizone strip, from its spec.
//!
//! The unit tests in `protocol::lifx` exercise the wire format against
//! hand-built vectors. This one runs the whole path against the catalogue's
//! real file, because the claim being tested is about that file: a consumer
//! holding it and a strip should be able to draw the right controls
//! (`network_entities_for_device`), send the right datagram
//! (`render_lifx_command`) and read the answer back
//! (`parse_lifx_state_service`), without knowing anything LIFX-specific.
//!
//! It also guards the one place the spec and the code MUST agree: the message
//! type numbers. The wire layout is hardcoded in `protocol::lifx` (it cannot
//! live in YAML), but the type numbers are published in the spec's
//! `lifx_lan_protocol` block, so this asserts the two match — a spec that
//! renumbers a message fails the build.
//!
//! The fixture is a verbatim copy of the upstream spec, like every other file
//! under `tests/specs/`, and is ahead of `vendor/protocol-specs` until the next
//! subtree pull.

use std::collections::HashMap;

use liberated_bread_core::api::device_api::{
    network_entities_for_device, parse_lifx_state_service, render_lifx_command,
};
use liberated_bread_core::protocol::lifx::{self, msg, Hsbk};
use liberated_bread_core::spec::parser::parse_device_spec;

const LIFX: &str = include_str!("specs/lifx-z.yaml");
const TARGET_MAC: &str = "d0:73:d5:aa:bb:cc";
const TARGET: [u8; 6] = [0xd0, 0x73, 0xd5, 0xaa, 0xbb, 0xcc];

fn params(pairs: &[(&str, f64)]) -> HashMap<String, f64> {
    pairs.iter().map(|(k, v)| ((*k).to_string(), *v)).collect()
}

#[test]
fn the_spec_declares_the_controls_a_client_draws() {
    let entities =
        network_entities_for_device(LIFX.to_string(), vec![]).expect("LIFX entities resolve");
    assert_eq!(entities.len(), 1, "one light entity");
    let light = &entities[0];
    assert_eq!(light.name, "LIFX Z Multizone Strip");
    assert_eq!(light.platform.as_deref(), Some("light"));

    let role = |r: &str| light.actions.iter().find(|a| a.role == r);
    // Power, colour, colour temperature and — because the strip declares eight
    // zones — per-zone colour all resolve, each on the lifx transport.
    for r in [
        "turn_on",
        "turn_off",
        "set_color",
        "set_color_temperature",
        "set_zone_color",
    ] {
        let action = role(r).unwrap_or_else(|| panic!("action {r} resolved"));
        assert_eq!(action.transport, "lifx", "{r} is a lifx action");
    }
    // The spec's features include brightness, so set_color carries it.
    assert!(role("set_color")
        .unwrap()
        .user_params
        .contains(&"brightness".to_string()));
    // Colour temperature is bounded to the LIFX white range.
    let ct = role("set_color_temperature").unwrap();
    assert_eq!(ct.min, Some(1500.0));
    assert_eq!(ct.max, Some(9000.0));
}

#[test]
fn set_color_renders_the_exact_datagram() {
    let bytes = render_lifx_command(
        "set_color".to_string(),
        params(&[("red", 255.0), ("green", 0.0), ("blue", 0.0)]),
        TARGET_MAC.to_string(),
        7,
    )
    .expect("set_color renders");
    // Same datagram the codec builds directly for pure red at full brightness.
    let expected = lifx::set_color(
        TARGET,
        &Hsbk {
            hue: 0,
            saturation: u16::MAX,
            brightness: u16::MAX,
            kelvin: lifx::KELVIN_DEFAULT,
        },
        0,
        7,
    );
    assert_eq!(bytes, expected);
    // And it really is a LightSetColor (102) addressed to the strip's MAC.
    assert_eq!(&bytes[32..34], &msg::SET_COLOR.to_le_bytes());
    assert_eq!(&bytes[8..14], &TARGET);
}

#[test]
fn turn_on_renders_light_set_power() {
    let bytes = render_lifx_command(
        "turn_on".to_string(),
        params(&[]),
        TARGET_MAC.to_string(),
        1,
    )
    .expect("turn_on renders");
    assert_eq!(&bytes[32..34], &msg::SET_POWER.to_le_bytes());
    assert_eq!(
        &bytes[lifx::HEADER_LEN..lifx::HEADER_LEN + 2],
        &[0xff, 0xff]
    );
}

#[test]
fn state_service_reply_decodes_to_mac_and_port() {
    // Build a StateService the way a device answers a discovery probe.
    let mut reply = lifx::get_service(0);
    reply[8..14].copy_from_slice(&TARGET);
    reply[32..34].copy_from_slice(&msg::STATE_SERVICE.to_le_bytes());
    reply.push(1); // service = UDP
    reply.extend_from_slice(&56700u32.to_le_bytes());

    let dto = parse_lifx_state_service(reply).expect("state service decodes");
    assert_eq!(dto.mac, TARGET_MAC);
    assert_eq!(dto.service, 1);
    assert_eq!(dto.port, 56700);
}

/// The wire layout is hardcoded, but the message-type numbers are the spec's to
/// publish. If a future spec renumbers one, this fails rather than letting the
/// code and the documentation silently disagree.
#[test]
fn message_type_constants_match_the_spec() {
    let spec = parse_device_spec(LIFX).expect("spec parses");
    let block = spec
        .extensions
        .get("lifx_lan_protocol")
        .expect("spec has a lifx_lan_protocol block");

    let types = block.get("message_types").expect("message_types present");
    let want = |key: &str| -> u16 {
        types
            .get(key)
            .and_then(serde_yaml::Value::as_u64)
            .unwrap_or_else(|| panic!("message_types.{key} present")) as u16
    };
    assert_eq!(want("get_service"), msg::GET_SERVICE);
    assert_eq!(want("state_service"), msg::STATE_SERVICE);
    assert_eq!(want("get"), msg::GET);
    assert_eq!(want("set_color"), msg::SET_COLOR);
    assert_eq!(want("state"), msg::STATE);
    assert_eq!(want("set_power"), msg::SET_POWER);

    let mz = block.get("multizone_messages").expect("multizone present");
    let want_mz = |key: &str| -> u16 {
        mz.get(key)
            .and_then(serde_yaml::Value::as_u64)
            .unwrap_or_else(|| panic!("multizone_messages.{key} present")) as u16
    };
    assert_eq!(want_mz("set_color_zones"), msg::SET_COLOR_ZONES);
    assert_eq!(want_mz("get_color_zones"), msg::GET_COLOR_ZONES);
    assert_eq!(want_mz("state_zone"), msg::STATE_ZONE);
    assert_eq!(want_mz("state_multi_zone"), msg::STATE_MULTI_ZONE);
}

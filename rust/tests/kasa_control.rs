// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end control test for the vendored TP-Link Kasa spec.
//!
//! Loads `tplink-kasa-smart-plug.yaml` through the same FFI the app calls,
//! resolves the outlet's switch entity to its on/off actions, renders each to
//! the JSON the device expects, and drives that JSON through the cipher and
//! the TCP framing — diffing against the bytes the spec publishes. The sibling
//! of `roku_control.rs` (HTTP) and `network_control.rs` (SOAP) for the third
//! transport, holding the vendored spec honest against real byte output rather
//! than against a hand-written fixture.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use liberated_bread_core::api::device_api::{
    kasa_decode_datagram, kasa_decode_frame, kasa_encode_frame, kasa_encrypt_datagram,
    network_entities_for_device, render_network_kasa_command, render_network_kasa_state_request,
};

fn spec_yaml() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests/specs/tplink-kasa-smart-plug.yaml");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[test]
fn the_outlet_resolves_an_on_off_switch_over_tcp_json() {
    let entities = network_entities_for_device(spec_yaml(), vec![]).expect("spec resolves");
    let outlet = entities
        .iter()
        .find(|e| e.name == "Outlet")
        .expect("the plug declares an Outlet switch");

    assert_eq!(outlet.platform.as_deref(), Some("switch"));
    assert_eq!(outlet.device_class.as_deref(), Some("outlet"));
    assert_eq!(outlet.state_command, "get_sysinfo");
    assert_eq!(outlet.value_field.as_deref(), Some("relay_state"));

    let roles: Vec<&str> = outlet.actions.iter().map(|a| a.role.as_str()).collect();
    assert_eq!(roles, vec!["turn_on", "turn_off"]);
    // Every action rides the Kasa transport — the screen dispatches on this.
    for action in &outlet.actions {
        assert_eq!(action.transport, "tcp-json");
        assert!(
            action.user_params.is_empty(),
            "on/off take no caller input"
        );
    }
}

#[test]
fn on_off_render_the_documented_json() {
    let yaml = spec_yaml();
    let entities = network_entities_for_device(yaml.clone(), vec![]).unwrap();
    let outlet = entities.iter().find(|e| e.name == "Outlet").unwrap();

    let command_for = |role: &str| {
        outlet
            .actions
            .iter()
            .find(|a| a.role == role)
            .unwrap_or_else(|| panic!("no {role} action"))
            .command_name
            .clone()
    };

    let on = render_network_kasa_command(yaml.clone(), command_for("turn_on"), HashMap::new())
        .expect("turn_on renders");
    assert_eq!(on.json, r#"{"system":{"set_relay_state":{"state":1}}}"#);

    let off = render_network_kasa_command(yaml, command_for("turn_off"), HashMap::new())
        .expect("turn_off renders");
    assert_eq!(off.json, r#"{"system":{"set_relay_state":{"state":0}}}"#);
}

#[test]
fn the_state_poll_renders_get_sysinfo() {
    let yaml = spec_yaml();
    let entities = network_entities_for_device(yaml.clone(), vec![]).unwrap();
    let outlet = entities.iter().find(|e| e.name == "Outlet").unwrap();

    let poll = render_network_kasa_state_request(yaml, outlet.state_command.clone())
        .expect("the state poll renders");
    assert_eq!(poll.json, r#"{"system":{"get_sysinfo":null}}"#);
}

#[test]
fn a_rendered_command_frames_onto_the_tcp_wire_and_back() {
    let yaml = spec_yaml();
    let entities = network_entities_for_device(yaml.clone(), vec![]).unwrap();
    let outlet = entities.iter().find(|e| e.name == "Outlet").unwrap();
    let on = &outlet.actions.iter().find(|a| a.role == "turn_on").unwrap().command_name;

    let request = render_network_kasa_command(yaml, on.clone(), HashMap::new()).unwrap();
    let frame = kasa_encode_frame(request.json.clone());

    // 4-byte big-endian length prefix, then the encrypted payload.
    let declared = u32::from_be_bytes(frame[..4].try_into().unwrap()) as usize;
    assert_eq!(declared, frame.len() - 4);
    // Round-trips through the codec's own decode.
    assert_eq!(kasa_decode_frame(frame).unwrap(), request.json);
}

#[test]
fn the_discovery_datagram_is_the_canonical_encrypted_get_sysinfo() {
    let yaml = spec_yaml();
    let poll = render_network_kasa_state_request(yaml, "get_sysinfo".to_string()).unwrap();
    let datagram = kasa_encrypt_datagram(poll.json.clone());

    // The published softScheck / python-kasa discovery datagram — no length
    // prefix, since UDP frames the whole payload itself.
    assert_eq!(
        hex(&datagram),
        "d0f281f88bff9af7d5ef94b6d1b4c09fec95e68fe187e8caf09eeb87eb96eb"
    );
    assert_eq!(kasa_decode_datagram(datagram).unwrap(), poll.json);
}

#[test]
fn a_sysinfo_reply_decodes_to_the_switch_state() {
    // The app flattens get_sysinfo's JSON in Dart and hands the pairs to
    // read_network_entity; this pins the Rust half of that — that a reply,
    // once decrypted and flattened, carries the field the switch reads.
    use liberated_bread_core::api::device_api::read_network_entity;

    let yaml = spec_yaml();
    // A realistic reply, framed and encrypted exactly as the device sends it,
    // then decoded back through the codec — proving the full receive path.
    let reply_json = r#"{"system":{"get_sysinfo":{"relay_state":1,"alias":"Desk Lamp","model":"HS100(US)"}}}"#;
    let frame = kasa_encode_frame(reply_json.to_string());
    let decoded = kasa_decode_frame(frame).unwrap();
    assert_eq!(decoded, reply_json);

    // The Dart-side flatten, transcribed: pull the sysinfo scalars out.
    let mut returned = HashMap::new();
    returned.insert("relay_state".to_string(), "1".to_string());

    let reading = read_network_entity(yaml, "Outlet".to_string(), returned)
        .expect("decode succeeds")
        .expect("the reply carries the switch's value");
    assert_eq!(reading.is_on, Some(true));
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end control test for the Roku remote, driven entirely from its spec.
//!
//! The unit tests in `protocol::http` exercise the rules against a miniature
//! fixture. This one runs them against the catalogue's real file, because the
//! claim being tested is about that file: a consumer holding it and a Roku on
//! the LAN should draw a full remote and send the exact keypresses the ECP
//! document publishes, without knowing anything about Roku.
//!
//! Two properties matter beyond mechanics:
//!
//!   * a `button` is stateless BY DESIGN — it must resolve with no
//!     `state_command`, because the alternative is spec authors inventing
//!     fake state bindings for keys that have none; and
//!   * the spec's app-parity claim: every key the official Roku app's remote
//!     sends is here, spelled exactly as the wire wants it.
//!
//! The fixture is a verbatim copy of the upstream spec, like every other file
//! under `tests/specs/`. It is ahead of `vendor/protocol-specs` until the next
//! subtree pull, which is deliberate: this crate's support for the vocabulary
//! lands before the catalogue that uses it ships.

use std::collections::BTreeMap;

use liberated_bread_core::protocol::http;
use liberated_bread_core::spec::bindings::{network_entities, resolve_network_actions};
use liberated_bread_core::spec::parser::parse_device_spec;
use liberated_bread_core::spec::types::DeviceSpec;

const ROKU: &str = include_str!("specs/roku-ecp.yaml");

fn spec() -> DeviceSpec {
    parse_device_spec(ROKU).expect("the Roku spec parses")
}

fn no_values() -> BTreeMap<String, String> {
    BTreeMap::new()
}

/// Every key the official Roku app's remote sends, as (button name, key).
/// The expectation is written against the ECP document's spelling so a spec
/// that drifts fails here rather than on a television.
const REMOTE: &[(&str, &str)] = &[
    ("Power On", "PowerOn"),
    ("Power Off", "PowerOff"),
    ("Back", "Back"),
    ("Home", "Home"),
    ("Up", "Up"),
    ("Left", "Left"),
    ("OK", "Select"),
    ("Right", "Right"),
    ("Down", "Down"),
    ("Replay", "InstantReplay"),
    ("Options", "Info"),
    ("Rewind", "Rev"),
    ("Play/Pause", "Play"),
    ("Fast Forward", "Fwd"),
    ("Volume Down", "VolumeDown"),
    ("Mute", "VolumeMute"),
    ("Volume Up", "VolumeUp"),
    ("Channel Up", "ChannelUp"),
    ("Channel Down", "ChannelDown"),
    ("Search", "Search"),
    ("Find Remote", "FindRemote"),
    ("HDMI 1", "InputHDMI1"),
    ("HDMI 2", "InputHDMI2"),
    ("HDMI 3", "InputHDMI3"),
    ("HDMI 4", "InputHDMI4"),
    ("AV", "InputAV1"),
    ("Antenna", "InputTuner"),
];

#[test]
fn the_spec_declares_the_whole_remote() {
    let spec = spec();
    let buttons: Vec<_> = network_entities(&spec)
        .into_iter()
        .filter(|e| e.platform.as_deref() == Some("button"))
        .collect();

    // Every expected button, in the spec's own remote-layout order.
    let names: Vec<&str> = buttons.iter().map(|e| e.name.as_str()).collect();
    let expected: Vec<&str> = REMOTE.iter().map(|(name, _)| *name).collect();
    assert_eq!(
        names, expected,
        "the buttons and their layout order are the spec's remote"
    );
}

#[test]
fn buttons_resolve_stateless_with_one_press_each() {
    let spec = spec();
    for entity in network_entities(&spec) {
        if entity.platform.as_deref() != Some("button") {
            continue;
        }
        assert!(
            entity.state_command.is_none(),
            "{}: a button has no state to poll",
            entity.name
        );
        let actions = resolve_network_actions(&spec, entity);
        assert_eq!(actions.len(), 1, "{}: exactly one action", entity.name);
        let action = &actions[0];
        assert_eq!(action.role, "press");
        assert!(
            action.user_params.is_empty() && action.read_back.is_empty(),
            "{}: a press is sendable from nothing",
            entity.name
        );
        assert_eq!(action.command.transport.as_deref(), Some("http"));
    }
}

#[test]
fn every_button_renders_the_documented_keypress() {
    let spec = spec();
    for (name, key) in REMOTE {
        let entity = network_entities(&spec)
            .into_iter()
            .find(|e| e.name == *name)
            .unwrap_or_else(|| panic!("no button named {name:?}"));
        let action = &resolve_network_actions(&spec, entity)[0];
        let request = http::render_request(&spec, action.command_name, &no_values())
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, format!("/keypress/{key}"));
        assert!(
            request.body.is_empty(),
            "{name}: ECP commands carry no body"
        );
    }
}

#[test]
fn the_soap_renderer_declines_what_is_not_its_transport() {
    // The same command through the SOAP path must fail loudly, not render a
    // hollow envelope: the action's `transport` is what a caller dispatches
    // on, and this is what happens to one that dispatches wrong.
    let spec = spec();
    let err =
        liberated_bread_core::protocol::soap::render_request(&spec, "press_home", &no_values())
            .unwrap_err();
    assert!(err.to_string().contains("http"), "unexpected error: {err}");
}

#[test]
fn the_sensors_stay_off_the_network_surface_for_now() {
    // The spec documents two XML state surfaces with `state_topic`, which
    // this crate does not consume yet. They must not leak into the resolved
    // entity list as though they could update.
    let spec = spec();
    let names: Vec<_> = network_entities(&spec)
        .into_iter()
        .map(|e| e.name.as_str())
        .collect();
    assert!(!names.contains(&"Active App"));
    assert!(!names.contains(&"Media Player"));
}

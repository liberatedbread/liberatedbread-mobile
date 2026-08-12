// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end control test for the Panasonic Viera remote, driven entirely
//! from its spec — the SOAP counterpart of `roku_control.rs`.
//!
//! Of the TV protocols the catalogue documents, pre-2019 Vieras are the one
//! this crate can already speak: plain UPnP SOAP, no auth, no encryption.
//! The claim under test is that a consumer holding the spec and a Viera on
//! the LAN draws a full remote and sends the exact X_SendKey envelopes the
//! NRC service documents — including that the description path comes from
//! the device (`/nrc/ddd.xml`), which is the Dart side's problem, not this
//! crate's.
//!
//! The fixture is a verbatim copy of the upstream spec, like every other file
//! under `tests/specs/`. It is ahead of `vendor/protocol-specs` until the
//! next subtree pull, which is deliberate: this crate's support for the
//! vocabulary lands before the catalogue that uses it ships.

use std::collections::BTreeMap;

use liberated_bread_core::protocol::soap;
use liberated_bread_core::spec::bindings::{network_entities, resolve_network_actions};
use liberated_bread_core::spec::parser::parse_device_spec;
use liberated_bread_core::spec::types::DeviceSpec;

const VIERA: &str = include_str!("specs/panasonic-viera.yaml");

fn spec() -> DeviceSpec {
    parse_device_spec(VIERA).expect("the Panasonic Viera spec parses")
}

fn no_values() -> BTreeMap<String, String> {
    BTreeMap::new()
}

/// A sample of the remote, as (button name, NRC key). The full vocabulary is
/// the spec's; these pin the wire spelling of each group — power, nav,
/// D-pad, volume, and the input keys Home Assistant's table carries.
const KEYS: &[(&str, &str)] = &[
    ("Power", "NRC_POWER-ONOFF"),
    ("Home", "NRC_HOME-ONOFF"),
    ("Menu", "NRC_MENU-ONOFF"),
    ("Up", "NRC_UP-ONOFF"),
    ("Down", "NRC_DOWN-ONOFF"),
    ("Left", "NRC_LEFT-ONOFF"),
    ("Right", "NRC_RIGHT-ONOFF"),
];

#[test]
fn buttons_resolve_stateless_with_one_press_each() {
    let spec = spec();
    let mut count = 0;
    for entity in network_entities(&spec) {
        if entity.platform.as_deref() != Some("button") {
            continue;
        }
        count += 1;
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
        assert_eq!(action.command.transport.as_deref(), Some("soap"));
    }
    assert!(count >= 30, "a Viera remote is ~50 keys, resolved {count}");
}

#[test]
fn every_sampled_button_renders_the_documented_key_event() {
    let spec = spec();
    for (name, key) in KEYS {
        let entity = network_entities(&spec)
            .into_iter()
            .find(|e| e.name == *name)
            .unwrap_or_else(|| panic!("no button named {name:?}"));
        let action = &resolve_network_actions(&spec, entity)[0];
        let request = soap::render_request(&spec, action.command_name, &no_values())
            .unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(
            request.service, "urn:panasonic-com:service:p00NetworkControl:1",
            "{name}: the NRC service URN is how the control URL resolves"
        );
        assert_eq!(request.action, "X_SendKey");
        assert!(
            request
                .body
                .contains(&format!("<X_KeyEvent>{key}</X_KeyEvent>")),
            "{name}: the envelope carries its key — got:\n{}",
            request.body
        );
        // The SOAPACTION the wire wants: service URN, hash, action, in quotes.
        assert_eq!(
            request.soap_action,
            "\"urn:panasonic-com:service:p00NetworkControl:1#X_SendKey\""
        );
    }
}

#[test]
fn the_http_renderer_declines_what_is_not_its_transport() {
    let spec = spec();
    let err =
        liberated_bread_core::protocol::http::render_request(&spec, "press_home", &no_values())
            .unwrap_err();
    assert!(err.to_string().contains("soap"), "unexpected error: {err}");
}

#[test]
fn the_remote_resolves_from_the_devices_own_search_target() {
    // Discovery hears urn:panasonic-com:device:p00RemoteController:1; the
    // resolved surface must be the full remote, not nothing.
    let entities = liberated_bread_core::api::device_api::network_entities_for_device(
        VIERA.to_string(),
        vec!["urn:panasonic-com:device:p00RemoteController:1".to_string()],
    )
    .expect("the spec resolves");
    let buttons = entities
        .iter()
        .filter(|e| e.platform.as_deref() == Some("button"))
        .count();
    assert!(
        buttons >= 30,
        "expected a full remote, got {buttons} buttons"
    );
}

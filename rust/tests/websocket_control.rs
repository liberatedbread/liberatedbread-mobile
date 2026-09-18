// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The two WebSocket TVs, driven from the catalogue's real files.
//!
//! The unit tests in `protocol::websocket` exercise the rules against a
//! miniature fixture. This file exercises the CATALOGUE: Samsung publishes the
//! exact frame it expects for 38 of its commands (`example_body`), and nothing
//! had ever diffed the renderer against one — unlike Hue, Roomba and Wemo,
//! whose published bodies are checked on every run. A spec whose frame shape
//! drifts, or a renderer that stops producing it, fails here.
//!
//! LG publishes no per-command `example_body`; it publishes one frame in
//! `protocol_details.remote_common.request_format.example`, and that one is
//! diffed too. The rest of its 32 commands are asserted to render at all, on
//! the channel the spec assigns them — LG is the two-socket device, and a
//! button rendered onto the JSON socket is a button that silently does
//! nothing.
//!
//! These read the vendored subtree rather than a copy under `tests/specs/`,
//! because the claim is about the files the app actually bundles.

use std::collections::BTreeMap;
use std::path::PathBuf;

use liberated_bread_core::protocol::websocket::{self, Frame};
use liberated_bread_core::spec::parser::parse_device_spec;
use liberated_bread_core::spec::types::{DeviceSpec, SpecCommand};

/// The bundled spec catalogue, derived from this crate's manifest dir so the
/// test is location-independent — the same derivation `vendored_assets.rs`
/// makes.
fn vendored(file: &str) -> String {
    let path: PathBuf = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("the rust crate has a parent repo dir")
        .join("vendor/protocol-specs/device-specs/devices")
        .join(file);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{} should be bundled: {e}", path.display()))
}

fn samsung() -> DeviceSpec {
    parse_device_spec(&vendored("samsung-tizen-tv.yaml")).expect("the Samsung spec parses")
}

fn lg() -> DeviceSpec {
    parse_device_spec(&vendored("lg-webos.yaml")).expect("the LG spec parses")
}

/// A value for every parameter a command declares, shaped by its declared
/// type. The point of these tests is the FRAME, not the values, so anything
/// that survives type validation will do — but it has to survive it, which is
/// itself worth asserting: a spec that declares a parameter the renderer
/// cannot type is a command that can never be sent.
fn values_for(command: &SpecCommand) -> BTreeMap<String, String> {
    command
        .parameters
        .iter()
        .map(|(name, parameter)| {
            let value = match parameter.value_type.as_deref() {
                Some("integer" | "int8" | "int16" | "int32" | "int64") => "7",
                Some("uint8" | "uint16" | "uint24" | "uint32" | "uint64" | "varint") => "7",
                Some("number" | "float" | "double") => "7.5",
                Some("boolean" | "bool") => "true",
                _ => "x",
            };
            (name.clone(), value.to_string())
        })
        .collect()
}

fn render(spec: &DeviceSpec, name: &str, request_id: i64) -> Frame {
    let command = spec
        .commands
        .get(name)
        .unwrap_or_else(|| panic!("the spec declares no command {name:?}"));
    websocket::render_command(spec, name, command, &values_for(command), request_id)
        .unwrap_or_else(|e| panic!("{name} should render: {e}"))
}

/// Every Samsung command that publishes an `example_body` must render to
/// exactly that frame. Thirty-eight of them do, and none of them had ever been
/// compared with what the renderer emits.
#[test]
fn every_samsung_example_body_is_what_the_renderer_emits() {
    let spec = samsung();
    let mut checked = 0;
    for (name, command) in &spec.commands {
        let Some(published) = command.example_body.as_deref() else {
            continue;
        };
        let frame = render(&spec, name, 1);
        assert_eq!(
            frame.channel, "remote",
            "{name} rides the set's single control socket"
        );
        assert_eq!(
            frame.text, published,
            "{name}: the rendered frame is not the one the spec publishes"
        );
        checked += 1;
    }
    assert_eq!(
        checked, 38,
        "the Samsung spec should publish 38 example frames; it published {checked}"
    );
}

/// Samsung declares one REST command in the same `commands:` block as its
/// WebSocket keys. Before the renderer checked the transport it came back as a
/// frame carrying `{"method": "Launch App"}`, which the TV has no method for —
/// a button that appears to work and does nothing.
#[test]
fn the_samsung_rest_command_is_not_rendered_as_a_frame() {
    let spec = samsung();
    let command = spec.commands.get("launch_app").expect("declared");
    let error = websocket::render_command(&spec, "launch_app", command, &values_for(command), 1)
        .expect_err("an http command must not render as a websocket frame");
    let message = error.to_string();
    assert!(message.contains("http"), "{message}");
}

/// LG publishes one example frame, in its `request_format` prose. Diff it —
/// the id is a number, the payload an object, and the uri the command's own
/// action, all three of which are things a renderer can get subtly wrong.
#[test]
fn the_lg_published_request_frame_is_what_the_renderer_emits() {
    let frame = render(&lg(), "volume_up", 12);
    assert_eq!(frame.channel, "ssap");
    let rendered: serde_json::Value = serde_json::from_str(&frame.text).expect("valid JSON");
    let published: serde_json::Value = serde_json::from_str(
        r#"{"id": 12, "type": "request", "uri": "ssap://audio/volumeUp", "payload": {}}"#,
    )
    .expect("the spec's published example is valid JSON");
    assert_eq!(rendered, published);
}

/// Every LG command renders, on the channel the spec assigns it. The d-pad
/// rides a SECOND socket the TV hands out at runtime and speaks plain text,
/// not JSON; a button rendered onto the ssap socket is accepted and ignored,
/// which is the failure that looks like broken hardware.
#[test]
fn every_lg_command_renders_on_the_channel_the_spec_assigns_it() {
    let spec = lg();
    let mut json = 0;
    let mut text = 0;
    for name in spec.commands.keys() {
        let command = &spec.commands[name];
        let frame = render(&spec, name, 3);
        match command.channel.as_deref() {
            Some(channel) => {
                assert_eq!(frame.channel, channel, "{name}");
                // The pointer channel is line-structured text, not JSON.
                assert!(
                    frame.text.starts_with("type:button\nname:"),
                    "{name}: {:?}",
                    frame.text
                );
                assert!(frame.text.ends_with("\n\n"), "{name}: {:?}", frame.text);
                text += 1;
            }
            None => {
                assert_eq!(frame.channel, "ssap", "{name} takes the default channel");
                let value: serde_json::Value =
                    serde_json::from_str(&frame.text).expect("valid JSON");
                assert_eq!(value["id"], serde_json::json!(3), "{name}");
                assert_eq!(value["type"], "request", "{name}");
                assert_eq!(
                    value["uri"],
                    serde_json::Value::String(
                        command.action.clone().expect("every command has an action")
                    ),
                    "{name}"
                );
                assert!(value["payload"].is_object(), "{name}");
                json += 1;
            }
        }
    }
    assert_eq!(json + text, 32, "the LG spec should declare 32 commands");
    assert_eq!(text, 9, "nine of them ride the pointer socket");
}

/// Both specs declare a surface a client can actually open: a port, a scheme,
/// and — for LG — the TLS fallback its late firmware requires.
#[test]
fn both_specs_publish_a_connectable_surface() {
    let samsung = websocket::surface(&samsung()).expect("Samsung declares a websocket block");
    assert_eq!(samsung.connect.port, 8002);
    assert_eq!(samsung.connect.scheme, "wss");
    assert!(samsung.channels.iter().any(|c| c.is_default));

    let lg = websocket::surface(&lg()).expect("LG declares a websocket block");
    assert_eq!(lg.connect.port, 3000);
    let fallback = lg.fallback.expect("LG declares the TLS fallback");
    assert_eq!(fallback.port, 3001);
    assert_eq!(fallback.scheme, "wss");
    // The pointer socket's address is not in the spec — it is whatever the TV
    // answers with, which is why the channel names the command that asks.
    let pointer = lg
        .channels
        .iter()
        .find(|c| c.name == "pointer")
        .expect("declared");
    assert!(pointer.obtained_by.is_some());
    assert!(pointer.address_path.is_some());
}

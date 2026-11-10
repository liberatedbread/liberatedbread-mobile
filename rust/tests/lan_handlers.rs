// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The vendored Yeelight, LimitlessLED and SenseME specs through the same FFI
//! the app calls: what each surfaces, what the actions route on, how a device
//! that answered a probe finds its way back to its spec. The byte-level checks
//! against the specs' literal frames are unit tests beside each codec.
//!
//! None of this has been run against hardware.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use liberated_bread_core::api::device_api::{
    load_device_spec, match_network_device, network_entities_for_device, read_network_entity_roles,
    render_network_limitlessled_command, render_network_yeelight_command,
    render_network_yeelight_state_request, yeelight_decode_reply, yeelight_encode_line,
    NetworkDeviceDto, NetworkEntityDto, SpecIdentityDto,
};

fn spec_yaml(file: &str) -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../vendor/protocol-specs/device-specs/devices")
        .join(file);
    fs::read_to_string(path).expect("the spec is vendored")
}

fn identity(file: &str) -> SpecIdentityDto {
    SpecIdentityDto::from(&load_device_spec(spec_yaml(file)).expect("the spec loads"))
}

fn only_light(file: &str) -> NetworkEntityDto {
    let surface = network_entities_for_device(spec_yaml(file), vec![]).expect("a surface");
    assert_eq!(surface.entities.len(), 1, "{file}: one light");
    surface.entities.into_iter().next().unwrap()
}

fn roles(entity: &NetworkEntityDto) -> Vec<&str> {
    entity.actions.iter().map(|a| a.role.as_str()).collect()
}

fn answered(token: &str) -> NetworkDeviceDto {
    NetworkDeviceDto {
        name: String::new(),
        hostname: None,
        service_types: vec![],
        ssdp_targets: vec![],
        answered_lan_protocols: vec![token.to_string()],
        port: None,
        txt: HashMap::new(),
        mac: None,
    }
}

#[test]
fn the_cube_lamp_surfaces_its_controls_on_its_own_transport() {
    let light = only_light("yeelight-cube-lamp.yaml");
    assert_eq!(light.state_command, "get_prop");
    assert_eq!(light.transport.as_deref(), Some("yeelight_lan"));
    for role in [
        "turn_on",
        "turn_off",
        "toggle",
        "set_brightness",
        "set_color",
        "set_color_temperature",
        "set_segments",
    ] {
        assert!(roles(&light).contains(&role), "{role}: {:?}", roles(&light));
    }
    assert!(
        light.actions.iter().all(|a| a.transport == "yeelight_lan"),
        "tcp-json on an action means Kasa's cipher downstream"
    );
    let colour = light
        .actions
        .iter()
        .find(|a| a.role == "set_color")
        .unwrap();
    assert_eq!(colour.user_params, vec!["rgb"]);
    assert_eq!(colour.max, Some(16_777_215.0));
}

#[test]
fn the_spec_the_handler_is_not_declared_on_stays_dark() {
    // yeelight-wifi.yaml describes the same protocol and names no handler
    // (SPECS_TO_FIX.md S-29), so nothing here may guess that it applies.
    let surface = network_entities_for_device(spec_yaml("yeelight-wifi.yaml"), vec![]).unwrap();
    assert!(surface.entities.is_empty());
    assert!(!surface.hidden_names.is_empty());
}

/// The whole round trip the screen's poll runs, against the reply SPECS_TO_FIX
/// S-29 quotes.
#[test]
fn a_cube_state_poll_reads_through_the_entitys_mapping_names() {
    let request = render_network_yeelight_state_request(
        spec_yaml("yeelight-cube-lamp.yaml"),
        "get_prop".into(),
    )
    .unwrap();
    assert_eq!(
        yeelight_encode_line(request.json.clone()),
        b"{\"id\":1,\"method\":\"get_prop\",\"params\":[\"power\",\"bright\",\"ct\",\"rgb\",\"hue\",\"sat\",\"color_mode\",\"name\"]}\r\n"
    );
    let reply = yeelight_decode_reply(
        request.json,
        r#"{"id":1,"result":["on","100","4000","16711680","359","100","2","Desk"]}"#.into(),
    );
    assert!(reply.answers_request);
    // What the entity's state_mapping names.
    assert_eq!(reply.fields["power"], "on");
    assert_eq!(reply.fields["bright"], "100");
    assert_eq!(reply.fields["ct"], "4000");
    assert_eq!(reply.fields["rgb"], "16711680");

    // And through the entity's mapping, which is the point of the zip.
    let roles = read_network_entity_roles(
        spec_yaml("yeelight-cube-lamp.yaml"),
        "Cube Lamp".into(),
        reply.fields,
    )
    .unwrap();
    let role = |name: &str| roles.iter().find(|r| r.role == name).map(|r| &r.reading);
    assert_eq!(role("is_on").and_then(|r| r.is_on), Some(true));
    assert_eq!(role("brightness").and_then(|r| r.number), Some(100.0));
    assert_eq!(role("color_temp").and_then(|r| r.number), Some(4000.0));
}

#[test]
fn the_cube_renderer_answers_only_for_its_own_handler() {
    let rendered = render_network_yeelight_command(
        spec_yaml("yeelight-cube-lamp.yaml"),
        "set_rgb".into(),
        HashMap::from([("rgb".to_string(), "255".to_string())]),
    )
    .unwrap();
    assert_eq!(
        rendered.json,
        r#"{"id":1,"method":"set_rgb","params":[255,"smooth",500]}"#
    );
    assert!(render_network_yeelight_command(
        spec_yaml("tplink-kasa-smart-plug.yaml"),
        "turn_on".into(),
        HashMap::new(),
    )
    .is_err());
}

#[test]
fn the_bridge_surfaces_a_write_only_light() {
    let light = only_light("limitlessled-milight-bridge.yaml");
    assert_eq!(
        light.state_command, "",
        "the protocol reports nothing, so there is nothing to poll"
    );
    assert_eq!(light.transport.as_deref(), Some("limitlessled_legacy_8899"));
    assert_eq!(
        roles(&light),
        vec!["turn_on", "turn_off", "set_brightness", "set_color"]
    );
    assert!(light
        .actions
        .iter()
        .all(|a| a.transport == "limitlessled_legacy_8899"));
    let brightness = light
        .actions
        .iter()
        .find(|a| a.role == "set_brightness")
        .unwrap();
    assert_eq!((brightness.min, brightness.max), (Some(2.0), Some(27.0)));
    let colour = light
        .actions
        .iter()
        .find(|a| a.role == "set_color")
        .unwrap();
    assert_eq!(colour.user_params, vec!["hue"]);
    assert_eq!(colour.max, Some(255.0));
}

#[test]
fn a_bridge_send_crosses_the_ffi_as_its_timed_sequence() {
    let frames = render_network_limitlessled_command(
        spec_yaml("limitlessled-milight-bridge.yaml"),
        "set_color".into(),
        HashMap::from([
            ("hue".to_string(), "176".to_string()),
            ("zone".to_string(), "1".to_string()),
        ]),
    )
    .unwrap();
    assert_eq!(frames[0].bytes, vec![0x45, 0x00, 0x55]);
    assert_eq!(frames[0].delay_after_ms, 100);
    assert_eq!(frames[1].bytes, vec![0x40, 0xB0, 0x55]);
    assert_eq!(frames.len(), 6);
    assert_eq!(frames[5].delay_after_ms, 0);
}

/// SPECS_TO_FIX S-21: the bridge declares a probe and no `lan_protocols`, so
/// its handler's name stands in. Without this it is an unidentified host.
#[test]
fn a_bridge_that_answered_its_probe_finds_its_spec() {
    let bridge = identity("limitlessled-milight-bridge.yaml");
    assert_eq!(bridge.lan_protocols, vec!["limitlessled_legacy_8899"]);
    let matches = match_network_device(vec![bridge], answered("limitlessled_legacy_8899"));
    assert_eq!(matches.len(), 1);
    assert!(matches[0].device_name.contains("LimitlessLED"));
}

#[test]
fn the_token_fallback_never_replaces_a_declared_one() {
    assert_eq!(
        identity("yeelight-cube-lamp.yaml").lan_protocols,
        vec!["yeelight-ssdp"]
    );
    assert_eq!(
        identity("big-ass-fans-senseme.yaml").lan_protocols,
        vec!["senseme"]
    );
}

#[test]
fn a_fan_that_answered_its_probe_finds_its_spec() {
    let matches = match_network_device(
        vec![identity("big-ass-fans-senseme.yaml")],
        answered("senseme"),
    );
    assert_eq!(matches.len(), 1);
}

/// Both Yeelight specs declare the token and only the cube lamp names a
/// handler. The token cannot tell them apart, so catalogue order decides, and
/// the card draws rows only for a unit whose `support` header lists them.
#[test]
fn a_yeelight_that_answered_its_probe_is_offered_the_cube_spec_first() {
    let matches = match_network_device(
        vec![
            identity("yeelight-cube-lamp.yaml"),
            identity("yeelight-wifi.yaml"),
        ],
        answered("yeelight-ssdp"),
    );
    let names: Vec<&str> = matches.iter().map(|m| m.device_name.as_str()).collect();
    assert!(
        names.first().is_some_and(|n| n.contains("Cube")),
        "{names:?}"
    );
}

/// The Philips purifier's controls resolve on the handler's own transport,
/// for the controls its spec binds and nothing else: `sync` and `get_status`
/// are session plumbing, and the compact Mode stays a reading as the spec
/// says it must.
#[test]
fn the_philips_purifier_surfaces_its_controls_on_its_own_transport() {
    let surface =
        network_entities_for_device(spec_yaml("philips-air-coap.yaml"), vec![]).expect("a surface");
    let actions: Vec<(&str, &str, &str)> = surface
        .entities
        .iter()
        .flat_map(|e| {
            e.actions.iter().map(move |a| {
                (
                    e.name.as_str(),
                    a.command_name.as_str(),
                    a.transport.as_str(),
                )
            })
        })
        .collect();
    assert!(!actions.is_empty(), "the purifier resolves no controls");
    for (entity, command, transport) in &actions {
        assert_eq!(*transport, "philips_air_coap", "{entity}: {command}");
        assert!(
            !matches!(*command, "sync" | "get_status"),
            "{entity} resolved session plumbing {command}"
        );
        assert_ne!(*command, "compact_set_mode_pair");
    }
    for command in ["power_on", "power_off", "set_mode", "set_fan_speed"] {
        assert!(
            actions.iter().any(|(_, c, _)| *c == command),
            "{command}: {actions:?}"
        );
    }
    let pm25 = surface
        .entities
        .iter()
        .find(|e| e.name == "PM2.5")
        .expect("PM2.5 is a reading");
    assert_eq!(pm25.state_command, "get_status");
}

/// `coap` is the IKEA gateway's DTLS surface too, and none of that is this
/// handler's: nothing there resolves a control.
#[test]
fn coap_resolves_only_for_the_philips_handler() {
    let surface = network_entities_for_device(spec_yaml("ikea-tradfri-gateway.yaml"), vec![])
        .expect("a surface");
    for entity in &surface.entities {
        for action in &entity.actions {
            assert!(
                !matches!(action.transport.as_str(), "coap" | "philips_air_coap"),
                "{}: {}",
                entity.name,
                action.command_name
            );
        }
    }
}

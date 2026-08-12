// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end control test for a hub: the Philips Hue Bridge, driven entirely
//! from its spec.
//!
//! The unit tests in `protocol::http` exercise the rules against miniature
//! fixtures. This one runs them against the catalogue's real file, because
//! the claim being tested is about that file: a consumer holding it and a
//! bridge should be able to pair, enumerate the lights behind it, draw the
//! right controls, send the right request and read the answer back, without
//! knowing anything about Hue.
//!
//! Three of these assertions are about traps the spec documents, and they are
//! the reason this file is worth its length:
//!
//!   * an unpaired client must FAIL at the missing `credential:username`, not
//!     improvise a request the bridge answers with error 1;
//!   * `bri` renders as a JSON number in 1–254 with `"on": true` riding
//!     along, because a bare or quoted `bri` is rejected by the device; and
//!   * a write's reply is an acknowledgement, so state comes from re-reading
//!     the one `Lights` call that enumerates every child at once.
//!
//! The fixture is a verbatim copy of the upstream spec, like every other file
//! under `tests/specs/`. It is ahead of `vendor/protocol-specs` until the
//! next subtree pull, which is deliberate: this crate's support for the
//! vocabulary lands before the catalogue that uses it ships.

use std::collections::BTreeMap;

use liberated_bread_core::error::ProtocolError;
use liberated_bread_core::protocol::http::{self, Instance, SourceScheme};
use liberated_bread_core::protocol::soap::EntityReading;
use liberated_bread_core::spec::bindings::{network_entities, resolve_network_actions};
use liberated_bread_core::spec::parser::parse_device_spec;
use liberated_bread_core::spec::types::{DeviceSpec, Entity};

const HUE: &str = include_str!("specs/hue-bridge.yaml");

fn spec() -> DeviceSpec {
    parse_device_spec(HUE).expect("the Hue spec parses")
}

fn light_entity(spec: &DeviceSpec) -> &Entity {
    spec.entities
        .iter()
        .find(|e| e.name == "Hue Light")
        .expect("the spec declares the Hue Light entity")
}

fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
        .collect()
}

/// The response example the named endpoint publishes.
fn endpoint_example(spec: &DeviceSpec, name: &str) -> String {
    spec.http_endpoint(name)
        .and_then(|e| e.get("response_body"))
        .and_then(|r| r.get("example"))
        .and_then(|x| x.as_str())
        .unwrap_or_else(|| panic!("the {name} endpoint publishes a response example"))
        .to_string()
}

#[test]
fn the_spec_declares_one_network_entity_and_it_is_instanced() {
    let spec = spec();
    let entities = network_entities(&spec);
    // The sensor entity is deliberately declarative (state_topic only), so
    // the network path sees exactly the light template.
    assert_eq!(
        entities.iter().map(|e| e.name.as_str()).collect::<Vec<_>>(),
        vec!["Hue Light"]
    );
    let instances = entities[0]
        .instances
        .as_ref()
        .expect("the light entity declares instances");
    assert_eq!(instances.keyed_by, "id");
    assert_eq!(instances.label_path.as_deref(), Some("name"));
}

#[test]
fn the_light_resolves_the_full_light_role_set_over_http() {
    let spec = spec();
    let actions = resolve_network_actions(&spec, light_entity(&spec));

    let roles: Vec<&str> = actions.iter().map(|a| a.role).collect();
    assert_eq!(roles, vec!["turn_on", "turn_off", "set_brightness"]);
    assert!(
        actions
            .iter()
            .all(|a| a.command.transport.as_deref() == Some(http::TRANSPORT)),
        "every hue action rides the http transport"
    );

    // The toggles own no value; the slider owns exactly bri, with the
    // device's own bounds — 1..254, not the 0..255 a UI would guess.
    let slider = &actions[2];
    assert_eq!(slider.user_params, vec!["bri"]);
    assert_eq!((slider.min, slider.max), (Some(1.0), Some(254.0)));
    assert!(actions[0].user_params.is_empty());
    assert!(actions[1].user_params.is_empty());

    // Every action leans on the credential and the child id, and says so in
    // schemes this crate knows how to fetch.
    for action in &actions {
        let schemes: Vec<SourceScheme<'_>> = action
            .read_back
            .iter()
            .filter_map(|(_, source)| http::parse_source(source))
            .collect();
        assert!(
            schemes.contains(&SourceScheme::Credential("username")),
            "{}: does not name the pairing credential",
            action.role
        );
        assert!(
            schemes.contains(&SourceScheme::Instance("id")),
            "{}: does not name the child id",
            action.role
        );
    }
}

#[test]
fn every_command_with_an_example_renders_it_byte_for_byte() {
    let spec = spec();
    let paired = values(&[
        ("username", "testuser"),
        ("id", "1"),
        ("bri", "200"),
        ("devicetype", "opengreeniot#hub"),
    ]);
    let mut diffed = 0;
    for (name, command) in &spec.commands {
        let Some(published) = command.example_body.as_deref() else {
            continue;
        };
        let request = http::render_command(name, command, &paired)
            .unwrap_or_else(|e| panic!("{name} renders: {e}"));
        // The spec publishes the exact bytes; the renderer must reproduce
        // them. This is the assertion that fails when a spec edit breaks the
        // wire format — the only place it can be caught without hardware.
        assert_eq!(
            request.body.trim(),
            published.trim(),
            "{name}: rendered body differs from the published example"
        );
        diffed += 1;
    }
    assert_eq!(diffed, 4, "the spec publishes four example bodies");
}

#[test]
fn light_writes_address_the_credentialed_child_path() {
    let spec = spec();
    let action = resolve_network_actions(&spec, light_entity(&spec))
        .into_iter()
        .find(|a| a.role == "set_brightness")
        .expect("the light resolves a brightness slider");

    let request = http::render_command(
        action.command_name,
        action.command,
        &values(&[("username", "testuser"), ("id", "2"), ("bri", "128")]),
    )
    .expect("set_brightness renders");

    assert_eq!(request.method, "PUT");
    assert_eq!(request.path, "/api/testuser/lights/2/state");
    // Typed substitution: the integer goes on the wire unquoted, with the
    // on:true the spec says must ride along.
    assert_eq!(request.body, r#"{"on":true,"bri":128}"#);
}

#[test]
fn an_unpaired_send_fails_at_the_missing_credential() {
    let spec = spec();
    let err = http::render_request(&spec, "light_turn_on", &values(&[("id", "1")]))
        .expect_err("rendering without the credential must fail");
    assert!(
        matches!(&err, ProtocolError::ParameterMissing(name) if name == "light_turn_on.username"),
        "unexpected error: {err}"
    );
}

#[test]
fn a_credential_cannot_escape_its_path_segment() {
    // A garbage credential is neutralized by percent-encoding, not rejected:
    // every substituted path value is data, so a `/` in it becomes `%2F` and
    // cannot open a new path segment. A legitimate Hue username is URL-safe,
    // so this encoding never fires for a real one.
    let spec = spec();
    let request = http::render_request(
        &spec,
        "light_turn_on",
        &values(&[("username", "u/../../admin"), ("id", "1")]),
    )
    .expect("a garbage credential renders to a safe, dead path");
    assert_eq!(request.path, "/api/u%2F..%2F..%2Fadmin/lights/1/state");
    assert!(
        !request.path.contains("/admin/"),
        "the value cannot add a segment"
    );
}

#[test]
fn pairing_renders_the_request_the_spec_publishes() {
    let spec = spec();
    let request = http::render_request(
        &spec,
        "create_user",
        &values(&[("devicetype", "opengreeniot#hub")]),
    )
    .expect("create_user renders");
    assert_eq!(request.method, "POST");
    assert_eq!(request.path, "/api");
    assert_eq!(
        request.body.trim(),
        spec.commands["create_user"]
            .example_body
            .as_deref()
            .unwrap()
            .trim()
    );
}

#[test]
fn the_state_read_is_the_one_enumerating_get() {
    let spec = spec();
    let entity = light_entity(&spec);
    let state_command = entity.state_command.as_deref().expect("state_command");

    let request =
        http::render_state_request(&spec, state_command, &values(&[("username", "testuser")]))
            .expect("the state read renders");
    assert_eq!(request.method, "GET");
    assert_eq!(request.path, "/api/testuser/lights");
    assert!(request.body.is_empty(), "a GET carries no body");

    // Unpaired, the read fails the same visible way a write does.
    assert!(http::render_state_request(&spec, state_command, &values(&[])).is_err());
}

#[test]
fn the_published_lights_reply_enumerates_and_reads_every_child() {
    let spec = spec();
    let entity = light_entity(&spec);
    let reply = endpoint_example(&spec, "Lights");

    let children = http::list_instances(entity, &reply).expect("children enumerate");
    assert_eq!(
        children,
        vec![
            Instance {
                id: "1".into(),
                label: "Kitchen counter".into()
            },
            Instance {
                id: "2".into(),
                label: "Hallway".into()
            },
        ]
    );

    // Child 1: a color light that is on at full brightness.
    let readings = http::read_instance_entity(entity, &reply, "1").unwrap();
    assert_eq!(readings.get("is_on"), Some(&EntityReading::OnOff(true)));
    assert_eq!(
        readings.get("brightness"),
        Some(&EntityReading::Number(254.0))
    );

    // Child 2: off, holding brightness 77 for when it comes back.
    let readings = http::read_instance_entity(entity, &reply, "2").unwrap();
    assert_eq!(readings.get("is_on"), Some(&EntityReading::OnOff(false)));
    assert_eq!(
        readings.get("brightness"),
        Some(&EntityReading::Number(77.0))
    );

    // A light that vanished between enumeration and read is unknown, not off.
    assert!(http::read_instance_entity(entity, &reply, "9")
        .unwrap()
        .is_empty());
}

#[test]
fn the_write_acknowledgement_is_not_mistakable_for_state() {
    // The Set Light State reply is a v1 envelope (an ARRAY), and the reader
    // refuses non-object replies by design — which is exactly what forces
    // the read-back the spec mandates.
    let spec = spec();
    let ack = endpoint_example(&spec, "Set Light State");
    let err = http::list_instances(light_entity(&spec), &ack)
        .expect_err("an acknowledgement must not enumerate as children");
    assert!(matches!(err, ProtocolError::InvalidStateReply(_)), "{err}");
}

#[test]
fn the_ffi_surface_round_trips_the_whole_flow() {
    // What Dart actually calls, end to end: resolve the entity, render the
    // state read, enumerate the children, read one, render a write. The
    // DTO layer must carry everything the client needs — transport to route
    // the screen, credential and instance params to fill — because Dart
    // never parses a `source` string itself.
    use std::collections::HashMap;

    use liberated_bread_core::api::device_api as api;

    let entities = api::network_entities_for_device(HUE.to_string(), vec![]).unwrap();
    assert_eq!(entities.len(), 1);
    let light = &entities[0];
    assert_eq!(light.transport.as_deref(), Some("http"));
    assert!(light.is_instanced);

    let on = light
        .actions
        .iter()
        .find(|a| a.role == "turn_on")
        .expect("turn_on resolves");
    assert_eq!(on.transport, "http");
    assert_eq!(
        on.credentials
            .iter()
            .map(|c| (c.param.as_str(), c.name.as_str()))
            .collect::<Vec<_>>(),
        vec![("username", "username")]
    );
    assert_eq!(
        on.instance_params
            .iter()
            .map(|c| (c.param.as_str(), c.name.as_str()))
            .collect::<Vec<_>>(),
        vec![("id", "id")]
    );
    // The state: scheme surface stays clean — hue's sources are not
    // read-backs, and mixing them up would send Dart fetching state that
    // does not exist.
    assert!(on.read_back.is_empty());

    let paired = HashMap::from([("username".to_string(), "testuser".to_string())]);
    let state = api::render_network_http_state_request(
        HUE.to_string(),
        light.state_command.clone(),
        paired,
    )
    .unwrap();
    assert_eq!(state.method, "GET");
    assert_eq!(state.path, "/api/testuser/lights");
    assert!(state.body.is_empty());

    let reply = endpoint_example(&spec(), "Lights");
    let children =
        api::list_network_instances(HUE.to_string(), light.name.clone(), reply.clone()).unwrap();
    assert_eq!(
        children
            .iter()
            .map(|c| (c.id.as_str(), c.label.as_str()))
            .collect::<Vec<_>>(),
        vec![("1", "Kitchen counter"), ("2", "Hallway")]
    );

    let readings =
        api::read_network_instance(HUE.to_string(), light.name.clone(), reply, "2".to_string())
            .unwrap();
    let is_on = readings.iter().find(|r| r.role == "is_on").unwrap();
    assert_eq!(is_on.reading.is_on, Some(false));
    let brightness = readings.iter().find(|r| r.role == "brightness").unwrap();
    assert_eq!(brightness.reading.number, Some(77.0));

    let request = api::render_network_http_command(
        HUE.to_string(),
        on.command_name.clone(),
        HashMap::from([
            ("username".to_string(), "testuser".to_string()),
            ("id".to_string(), "2".to_string()),
        ]),
    )
    .unwrap();
    assert_eq!(request.method, "PUT");
    assert_eq!(request.path, "/api/testuser/lights/2/state");
    assert_eq!(request.body, r#"{"on":true}"#);
}

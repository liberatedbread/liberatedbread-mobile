// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end state test for the vendored Enphase Envoy spec.
//!
//! The Envoy is the first NON-hub device whose state poll is plain HTTP: the
//! sensor entities' `state_command` names a `commands` entry
//! (`get_production_v1`), not an `http_endpoints` name the way the Hue hub's
//! does. This drives the whole path from the spec file alone — the entities
//! resolve, the poll renders to the documented GET, and a reply, once the app
//! has flattened it, decodes to the readings.
//!
//! The fixture is a verbatim copy of the upstream spec, like every other file
//! under `tests/specs/`. It is ahead of `vendor/protocol-specs` until the
//! next subtree pull, which is deliberate: this crate's support for the
//! vocabulary lands before the catalogue that uses it ships.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use liberated_bread_core::api::device_api::{
    network_entities_for_device, read_network_entity, render_network_http_state_request,
};

fn spec_yaml() -> String {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/specs/enphase-envoy.yaml");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

#[test]
fn the_sensors_resolve_as_http_state_readings() {
    let entities = network_entities_for_device(spec_yaml(), vec![]).expect("spec resolves");

    assert_eq!(entities.len(), 3, "three sensors, nothing else on screen");
    for (name, field, unit) in [
        ("Solar Production", "wattsNow", "W"),
        ("Lifetime Energy", "wattHoursLifetime", "Wh"),
        ("Today's Energy", "wattHoursToday", "Wh"),
    ] {
        let sensor = entities
            .iter()
            .find(|e| e.name == name)
            .unwrap_or_else(|| panic!("the spec declares a {name} sensor"));
        assert_eq!(sensor.platform.as_deref(), Some("sensor"), "{name}");
        assert_eq!(sensor.state_command, "get_production_v1", "{name}");
        // The flat reply key — /api/v1/production's values sit at the top
        // level, which is exactly why the spec binds THIS endpoint.
        assert_eq!(sensor.value_field.as_deref(), Some(field), "{name}");
        assert_eq!(sensor.unit.as_deref(), Some(unit), "{name}");
        assert!(sensor.actions.is_empty(), "{name}: read-only telemetry");
        // No action to answer for the transport, so it comes from the state
        // command's own declaration — the signal the screen routes the
        // poll on.
        assert_eq!(sensor.transport.as_deref(), Some("http"), "{name}");
    }
}

#[test]
fn the_state_poll_renders_the_production_get() {
    let request = render_network_http_state_request(
        spec_yaml(),
        "get_production_v1".to_string(),
        HashMap::new(),
    )
    .expect("the state poll renders");
    assert_eq!(
        (request.method.as_str(), request.path.as_str()),
        ("GET", "/api/v1/production")
    );
    assert!(request.body.is_empty());
}

#[test]
fn a_production_reply_decodes_to_the_sensor_readings() {
    let yaml = spec_yaml();
    // The app flattens the reply's JSON in Dart (jsonStateFields) and hands
    // the pairs to read_network_entity; this pins the Rust half — that the
    // flat keys, so flattened, carry the values the sensors read.
    let returned: HashMap<String, String> = [
        ("wattsNow", "2532"),
        ("wattHoursToday", "18320"),
        ("wattHoursSevenDays", "120440"),
        ("wattHoursLifetime", "10324050"),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect();

    for (entity, number, raw) in [
        ("Solar Production", 2532.0, "2532"),
        ("Today's Energy", 18320.0, "18320"),
        ("Lifetime Energy", 10324050.0, "10324050"),
    ] {
        let reading = read_network_entity(yaml.clone(), entity.to_string(), returned.clone())
            .expect("decode succeeds")
            .unwrap_or_else(|| panic!("the reply carries {entity}'s value"));
        assert_eq!(reading.number, Some(number), "{entity}");
        assert_eq!(reading.raw, raw, "{entity}");
    }
}

#[test]
fn a_reply_without_a_value_reads_as_unknown_not_zero() {
    // The watt-hours fields are absent on unmonitored gateways; unknown is
    // the honest reading, never a fabricated zero.
    let returned: HashMap<String, String> = [("wattsNow".to_string(), "2532".to_string())]
        .into_iter()
        .collect();
    assert!(
        read_network_entity(spec_yaml(), "Lifetime Energy".to_string(), returned)
            .expect("decode succeeds")
            .is_none()
    );
}

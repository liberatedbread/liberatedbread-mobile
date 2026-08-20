// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end control test for the Rabbit Air purifier spec.
//!
//! Loads `rabbit-air-purifier.yaml` through the same FFI the app calls,
//! resolves the entities to their actions, renders each to the envelope
//! plaintext the device expects — diffed against the spec's own
//! `example_exchange` plaintexts — and drives it through the AES-128-CBC
//! datagram crypto. The sibling of `kasa_control.rs` for the fourth transport,
//! holding the spec honest against real byte output rather than against a
//! hand-written fixture.

use std::collections::HashMap;
use std::fs;
use std::path::PathBuf;

use liberated_bread_core::api::device_api::{
    network_entities_for_device, rabbit_air_decrypt_datagram, rabbit_air_encrypt_datagram,
    rabbit_air_time_sync_offset, read_network_entity, render_network_rabbit_air_command,
    render_network_rabbit_air_state_request,
};

/// The spec's documented example key — a documentation value, not a real
/// device credential.
const KEY_HEX: &str = "0123456789abcdeffedcba9876543210";

fn spec_yaml() -> String {
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/specs/rabbit-air-purifier.yaml");
    fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
}

#[test]
fn the_entities_resolve_over_udp() {
    let entities = network_entities_for_device(spec_yaml(), vec![]).expect("spec resolves");

    // The control surface the spec decomposes: a power switch, a mode select,
    // a fan-speed number, three sensors, and two more switches.
    let power = entities
        .iter()
        .find(|e| e.name == "Power")
        .expect("the spec declares a Power switch");
    assert_eq!(power.platform.as_deref(), Some("switch"));
    assert_eq!(power.state_command, "get_state");
    assert_eq!(power.value_field.as_deref(), Some("power"));
    let roles: Vec<&str> = power.actions.iter().map(|a| a.role.as_str()).collect();
    assert_eq!(roles, vec!["turn_on", "turn_off"]);
    // Every action rides the udp transport — the screen dispatches on this.
    for entity in &entities {
        for action in &entity.actions {
            assert_eq!(action.transport, "udp", "{}: {}", entity.name, action.role);
        }
    }

    let mode = entities
        .iter()
        .find(|e| e.name == "Mode")
        .expect("the spec declares a Mode select");
    assert_eq!(mode.platform.as_deref(), Some("select"));
    let options: Vec<(&str, &str)> = mode
        .options
        .iter()
        .map(|o| (o.raw.as_str(), o.label.as_str()))
        .collect();
    assert_eq!(options, [("0", "Auto"), ("1", "Pollen"), ("2", "Manual")]);

    let speed = entities
        .iter()
        .find(|e| e.name == "Fan Speed")
        .expect("the spec declares a Fan Speed number");
    assert_eq!(speed.platform.as_deref(), Some("number"));
    assert_eq!(speed.setpoint_min, Some(1.0));
    assert_eq!(speed.setpoint_max, Some(5.0));

    // The pure readings: no actions, transport inherited from the state
    // command's own declaration so the screen routes the poll.
    for (name, field, unit) in [
        ("Air Quality", "quality", None),
        ("Filter Life", "filter_life", Some("min")),
        ("Wi-Fi RSSI", "rssi", Some("dBm")),
    ] {
        let sensor = entities
            .iter()
            .find(|e| e.name == name)
            .unwrap_or_else(|| panic!("the spec declares a {name} sensor"));
        assert_eq!(sensor.platform.as_deref(), Some("sensor"), "{name}");
        assert_eq!(sensor.state_command, "get_state", "{name}");
        assert_eq!(sensor.value_field.as_deref(), Some(field), "{name}");
        assert_eq!(sensor.unit.as_deref(), unit, "{name}");
        assert!(sensor.actions.is_empty(), "{name}: a pure reading");
        assert_eq!(sensor.transport.as_deref(), Some("udp"), "{name}");
    }
}

#[test]
fn rendered_envelopes_match_the_spec_example_exchange() {
    let yaml = spec_yaml();

    // body '{"cmd":9}' + runtime id/ts is exactly the example's
    // time_sync_request_plaintext, in the pinned field order.
    let sync = render_network_rabbit_air_state_request(
        yaml.clone(),
        "time_sync".to_string(),
        1234567,
        1700000000,
    )
    .expect("time_sync renders");
    assert_eq!(sync.json, r#"{"id":1234567,"cmd":9,"ts":1700000000}"#);
    assert_eq!(sync.request_id, 1234567);

    // state_get_request_plaintext.
    let poll = render_network_rabbit_air_state_request(
        yaml.clone(),
        "get_state".to_string(),
        1234568,
        1700000123,
    )
    .expect("get_state renders");
    assert_eq!(poll.json, r#"{"id":1234568,"cmd":4,"ts":1700000123}"#);

    // state_set_power_on_plaintext — `data` last.
    let on = render_network_rabbit_air_command(
        yaml.clone(),
        "turn_on".to_string(),
        HashMap::new(),
        1234569,
        1700000124,
    )
    .expect("turn_on renders");
    assert_eq!(
        on.json,
        r#"{"id":1234569,"cmd":4,"ts":1700000124,"data":{"power":true}}"#
    );

    // And the write commands that take a caller value: {param} substitutes
    // into the body's data, matching the spec's example_body spellings.
    let manual = render_network_rabbit_air_command(
        yaml.clone(),
        "set_mode".to_string(),
        HashMap::from([("mode".to_string(), "2".to_string())]),
        1,
        100,
    )
    .unwrap();
    assert_eq!(
        manual.json,
        r#"{"id":1,"cmd":4,"ts":100,"data":{"mode":2}}"#
    );

    let speed = render_network_rabbit_air_command(
        yaml,
        "set_speed".to_string(),
        HashMap::from([("speed".to_string(), "3".to_string())]),
        2,
        100,
    )
    .unwrap();
    assert_eq!(
        speed.json,
        r#"{"id":2,"cmd":4,"ts":100,"data":{"mode":2,"speed":3}}"#
    );
}

#[test]
fn a_rendered_command_encrypts_onto_the_wire_and_back() {
    let request = render_network_rabbit_air_command(
        spec_yaml(),
        "turn_off".to_string(),
        HashMap::new(),
        77,
        1700000125,
    )
    .unwrap();
    let datagram =
        rabbit_air_encrypt_datagram(KEY_HEX.to_string(), request.json.clone()).expect("encrypts");

    // ciphertext || IV: a block multiple, longer than the plaintext.
    assert_eq!(datagram.len() % 16, 0);
    assert!(datagram.len() > request.json.len());
    // A fresh random IV per message: two sends of one command differ.
    let again = rabbit_air_encrypt_datagram(KEY_HEX.to_string(), request.json.clone()).unwrap();
    assert_ne!(datagram, again);

    let decoded = rabbit_air_decrypt_datagram(KEY_HEX.to_string(), datagram).expect("decrypts");
    assert_eq!(decoded, request.json);
}

#[test]
fn a_wrong_key_or_garbage_datagram_is_rejected_not_misread() {
    let request =
        render_network_rabbit_air_state_request(spec_yaml(), "get_state".to_string(), 1, 100)
            .unwrap();
    let datagram = rabbit_air_encrypt_datagram(KEY_HEX.to_string(), request.json).unwrap();

    let other_key = "fedcba98765432100123456789abcdef";
    assert!(rabbit_air_decrypt_datagram(other_key.to_string(), datagram.clone()).is_err());
    assert!(rabbit_air_decrypt_datagram(KEY_HEX.to_string(), vec![0u8; 24]).is_err());
    assert!(rabbit_air_decrypt_datagram(KEY_HEX.to_string(), vec![]).is_err());
    // A malformed key string fails at the edge, on either call.
    assert!(rabbit_air_encrypt_datagram("not-a-key".to_string(), "{}".to_string()).is_err());
    assert!(rabbit_air_decrypt_datagram("not-a-key".to_string(), datagram).is_err());
}

#[test]
fn the_time_sync_reply_teaches_the_clock_offset() {
    // The spec's example time_sync_response_plaintext, answered 123 s ahead
    // of the local clock.
    let reply = r#"{"id":1234567,"data":{"ts":1700000123}}"#;
    assert_eq!(
        rabbit_air_time_sync_offset(reply.to_string(), 1700000000).unwrap(),
        123
    );
    assert!(rabbit_air_time_sync_offset(r#"{"id":1,"error":1}"#.to_string(), 0).is_err());
    assert!(rabbit_air_time_sync_offset(r#"{"id":1}"#.to_string(), 0).is_err());
}

#[test]
fn a_state_reply_decodes_to_the_entity_readings() {
    let yaml = spec_yaml();
    // A realistic cmd-4 reply, encrypted exactly as the device sends it, then
    // decrypted back through the codec — proving the full receive path.
    let reply_json = r#"{"id":1234568,"data":{"power":true,"mode":2,"speed":3,"quality":2,"ionizer":false,"lock":false,"filter_life":4320,"rssi":-55,"model":1}}"#;
    let datagram =
        rabbit_air_encrypt_datagram(KEY_HEX.to_string(), reply_json.to_string()).unwrap();
    assert_eq!(
        rabbit_air_decrypt_datagram(KEY_HEX.to_string(), datagram).unwrap(),
        reply_json
    );

    // The Dart-side flatten (rabbitAirStateFields), transcribed: the reply's
    // `data` object flattened to bare name→value pairs — the state_mapping
    // paths are rooted at that object, so `power` names reply data.power.
    let returned: HashMap<String, String> = [
        ("power", "true"),
        ("mode", "2"),
        ("speed", "3"),
        ("quality", "2"),
        ("ionizer", "false"),
        ("lock", "false"),
        ("filter_life", "4320"),
        ("rssi", "-55"),
        ("model", "1"),
    ]
    .iter()
    .map(|(k, v)| (k.to_string(), v.to_string()))
    .collect();

    let power = read_network_entity(yaml.clone(), "Power".to_string(), returned.clone())
        .expect("decode succeeds")
        .expect("the reply carries the switch's value");
    assert_eq!(power.is_on, Some(true), "a JSON boolean IS the on/off");

    let ionizer = read_network_entity(yaml.clone(), "Ionizer".to_string(), returned.clone())
        .unwrap()
        .unwrap();
    assert_eq!(ionizer.is_on, Some(false));

    let mode = read_network_entity(yaml.clone(), "Mode".to_string(), returned.clone())
        .unwrap()
        .unwrap();
    assert_eq!(mode.label.as_deref(), Some("Manual"));
    assert_eq!(mode.raw, "2");

    let speed = read_network_entity(yaml.clone(), "Fan Speed".to_string(), returned.clone())
        .unwrap()
        .unwrap();
    assert_eq!(speed.number, Some(3.0));

    let quality = read_network_entity(yaml.clone(), "Air Quality".to_string(), returned.clone())
        .unwrap()
        .unwrap();
    assert_eq!(quality.label.as_deref(), Some("Medium"));

    for (name, number, raw) in [
        ("Filter Life", 4320.0, "4320"),
        ("Wi-Fi RSSI", -55.0, "-55"),
    ] {
        let reading = read_network_entity(yaml.clone(), name.to_string(), returned.clone())
            .unwrap()
            .unwrap_or_else(|| panic!("the reply carries {name}'s value"));
        assert_eq!(reading.number, Some(number), "{name}");
        assert_eq!(reading.raw, raw, "{name}");
    }
}

#[test]
fn a_reply_missing_a_value_reads_as_unknown_not_zero() {
    // Reply fields are all optional in practice (the vendor TypedDict is
    // total=False): a unit that did not report filter life must read as
    // unknown, never as a fabricated 0 minutes.
    let returned: HashMap<String, String> = [("power".to_string(), "true".to_string())]
        .into_iter()
        .collect();
    assert!(
        read_network_entity(spec_yaml(), "Filter Life".to_string(), returned)
            .expect("decode succeeds")
            .is_none()
    );
}

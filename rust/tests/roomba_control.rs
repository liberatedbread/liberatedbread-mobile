// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end control test for the vendored iRobot Roomba spec.
//!
//! Loads `irobot-roomba.yaml` through the same FFI the app calls, resolves its
//! entities to the buttons and readings a control screen draws, renders each
//! command to the JSON the robot expects — diffing against the `example_body`
//! the spec publishes — and drives a whole MQTT session's worth of packets
//! through the codec. The sibling of `kasa_control.rs` (raw-socket JSON),
//! `roku_control.rs` (HTTP) and `network_control.rs` (SOAP) for the fourth
//! transport.
//!
//! The protocol is koalazak/dorita980's work (MIT); this holds our
//! transcription of it honest against real byte output rather than against a
//! hand-written fixture.
//!
//! The fixture is a verbatim copy of the upstream spec, like every other file
//! under `tests/specs/`, and is ahead of `vendor/protocol-specs` until the next
//! subtree pull.

use liberated_bread_core::api::device_api::{
    network_entities_for_device, render_network_roomba_command, roomba_connect_packet,
    roomba_disconnect_packet, roomba_parse_announcement, roomba_parse_incoming,
    roomba_parse_password_reply, roomba_password_probe, roomba_publish_packet, roomba_state_fields,
    roomba_subscribe_packet, RoombaIncomingDto,
};

const ROOMBA: &str = include_str!("specs/irobot-roomba.yaml");

/// The epoch every `example_body` in the spec is rendered at.
const EXAMPLE_EPOCH: i64 = 1_755_129_600;

fn entities() -> Vec<liberated_bread_core::api::device_api::NetworkEntityDto> {
    network_entities_for_device(ROOMBA.to_string(), vec![]).expect("the spec resolves")
}

// ── The control surface ──────────────────────────────────────────────────────

#[test]
fn the_spec_resolves_the_mission_buttons_and_the_readings() {
    let entities = entities();
    let names: Vec<&str> = entities.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(
        names,
        vec![
            "Clean",
            "Pause",
            "Stop",
            "Dock",
            "Locate",
            "Battery",
            "Mission Phase",
            "Bin Full",
        ],
        "the whole control surface, in the spec's declared order"
    );
}

/// Every entity routes onto the MQTT client. This is the field the app's
/// device screen dispatches on, so a spec change that broke it would silently
/// send Roomba commands through the SOAP path.
#[test]
fn every_entity_rides_the_mqtt_transport() {
    for entity in entities() {
        assert_eq!(
            entity.transport.as_deref(),
            Some("mqtt"),
            "{} routed to the wrong client",
            entity.name
        );
    }
}

#[test]
fn the_buttons_bind_one_press_role_each() {
    let expected = [
        ("Clean", "clean"),
        ("Pause", "pause"),
        ("Stop", "stop"),
        ("Dock", "dock"),
        ("Locate", "find"),
    ];
    let entities = entities();
    for (name, command) in expected {
        let entity = entities
            .iter()
            .find(|e| e.name == name)
            .unwrap_or_else(|| panic!("{name} is missing"));
        assert_eq!(entity.platform.as_deref(), Some("button"));
        assert_eq!(entity.actions.len(), 1, "{name} binds one action");
        assert_eq!(entity.actions[0].role, "press");
        assert_eq!(entity.actions[0].command_name, command);
        // A button is stateless; the mission's real state is the phase sensor.
        assert!(entity.state_command.is_empty(), "{name} bound state");
        // Nothing for the UI to fill in — the timestamp is the client's own.
        assert!(entity.actions[0].user_params.is_empty(), "{name}");
    }
}

/// For this transport `state_command` carries the TOPIC and `value_field` the
/// dotted path into its payload. Pinned because those are overloaded meanings
/// and a reader of the DTO would not guess them.
#[test]
fn the_readings_name_their_topic_and_their_path() {
    let entities = entities();
    let expected = [
        ("Battery", "delta", "state.reported.batPct", Some("%")),
        (
            "Mission Phase",
            "delta",
            "state.reported.cleanMissionStatus.phase",
            None,
        ),
        ("Bin Full", "delta", "state.reported.bin.full", None),
    ];
    for (name, topic, path, unit) in expected {
        let entity = entities
            .iter()
            .find(|e| e.name == name)
            .unwrap_or_else(|| panic!("{name} is missing"));
        assert_eq!(entity.state_command, topic, "{name}");
        assert_eq!(entity.value_field.as_deref(), Some(path), "{name}");
        assert_eq!(entity.unit.as_deref(), unit, "{name}");
        assert!(
            entity.actions.is_empty(),
            "{name} is a reading, not a control"
        );
    }
}

// ── Commands render the spec's own examples ──────────────────────────────────

/// The strongest check in this file: for every command the spec publishes an
/// `example_body`, and the renderer must reproduce it byte for byte. A spec
/// change that breaks rendering fails here rather than against a robot.
#[test]
fn every_command_renders_the_example_body_the_spec_publishes() {
    let spec: serde_yaml::Value = serde_yaml::from_str(ROOMBA).expect("the fixture parses");
    let commands = spec["commands"]
        .as_mapping()
        .expect("the spec declares commands");
    assert!(!commands.is_empty());

    for (name, command) in commands {
        let name = name.as_str().expect("command names are strings");
        let expected = command["example_body"]
            .as_str()
            .unwrap_or_else(|| panic!("{name} publishes no example_body"));

        let rendered =
            render_network_roomba_command(ROOMBA.to_string(), name.to_string(), EXAMPLE_EPOCH)
                .unwrap_or_else(|e| panic!("rendering {name}: {e}"));

        assert_eq!(rendered.topic, "cmd", "{name} publishes to the wrong topic");
        assert_eq!(
            rendered.payload, expected,
            "{name} does not render its example"
        );
    }
}

/// A quoted timestamp is a payload the robot will not read, and the failure is
/// silent. The renderer takes each argument's declared type, so this stays a
/// JSON number at every clock value.
#[test]
fn the_timestamp_is_always_a_json_number() {
    for epoch in [0i64, 1, 1_755_129_600, 4_102_444_800] {
        let rendered =
            render_network_roomba_command(ROOMBA.to_string(), "clean".to_string(), epoch)
                .expect("renders");
        assert!(
            rendered.payload.contains(&format!(r#""time":{epoch}"#)),
            "{}",
            rendered.payload
        );
    }
}

#[test]
fn an_undeclared_command_is_refused_rather_than_improvised() {
    let error = render_network_roomba_command(
        ROOMBA.to_string(),
        "self_destruct".to_string(),
        EXAMPLE_EPOCH,
    )
    .expect_err("an unknown command must not render");
    assert!(error.to_string().contains("self_destruct"), "{error}");
}

// ── Discovery ────────────────────────────────────────────────────────────────

/// The spec publishes an example announcement; parsing it must yield the
/// identity the spec says it carries. An example that does not decode is a
/// test vector that lies.
#[test]
fn the_specs_own_discovery_example_parses_to_its_blid() {
    let spec: serde_yaml::Value = serde_yaml::from_str(ROOMBA).expect("the fixture parses");
    let example = spec["irobot_lan_protocol"]["discovery"]["response"]["example"]
        .as_str()
        .expect("the spec publishes a discovery example");

    let found = roomba_parse_announcement(example.as_bytes().to_vec())
        .expect("parses")
        .expect("the example is a robot");

    assert_eq!(found.blid, "3193C60472324700");
    assert_eq!(found.robotname, "Dorita");
    assert_eq!(found.proto, "mqtt");
}

/// The probe is a broadcast: it reaches printers, TVs and whatever else is
/// listening. A scan must ignore those rather than report them or fail.
#[test]
fn a_non_robot_reply_is_ignored_not_an_error() {
    let found = roomba_parse_announcement(br#"{"hostname":"printer-4f2a"}"#.to_vec())
        .expect("must not error");
    assert!(found.is_none());
}

// ── The password handshake ───────────────────────────────────────────────────

#[test]
fn the_password_probe_matches_the_specs_published_bytes() {
    let spec: serde_yaml::Value = serde_yaml::from_str(ROOMBA).expect("the fixture parses");
    let published = spec["irobot_lan_protocol"]["password_disclosure"]["request"]["payload_hex"]
        .as_str()
        .expect("the spec publishes the probe");

    let probe = roomba_password_probe();
    let hex: String = probe.iter().map(|b| format!("{b:02x}")).collect();
    assert_eq!(hex, published);
}

/// The spec records three published clients slicing the same reply at three
/// different offsets and states one rule that satisfies all of them. The rule
/// is a `hypothesis`, so this reads the offsets out of the spec rather than
/// restating them: if the spec learns a fourth, this test starts covering it.
#[test]
fn the_extraction_rule_holds_at_every_offset_the_spec_records() {
    let spec: serde_yaml::Value = serde_yaml::from_str(ROOMBA).expect("the fixture parses");
    let observed = spec["irobot_lan_protocol"]["password_disclosure"]["response"]
        ["observed_offsets"]
        .as_sequence()
        .expect("the spec records the offsets it is reconciling");
    assert!(!observed.is_empty());

    let password = ":1:1486937829:gktkDoYpWaDxCfGh";
    for entry in observed {
        let offset = entry["offset"].as_u64().expect("an offset") as usize;
        let gap = offset - 2;
        let mut reply = vec![0xf0, (password.len() + gap) as u8];
        reply.extend((1..=gap).map(|i| (i % 0x20) as u8));
        reply.extend_from_slice(password.as_bytes());

        assert_eq!(
            roomba_parse_password_reply(reply).expect("extracts"),
            password,
            "the rule failed on a reply framed at offset {offset}"
        );
    }
}

/// Two failures that look alike on the wire and must not read alike to a user:
/// one says hold the button again, the other says stop trying.
#[test]
fn the_two_handshake_failures_say_different_things() {
    let not_disclosing = roomba_parse_password_reply(vec![0xf0, 0x05, 0x00])
        .expect_err("a short reply is a failure");
    assert!(
        not_disclosing.to_string().contains("disclosure mode"),
        "{not_disclosing}"
    );

    let spec: serde_yaml::Value = serde_yaml::from_str(ROOMBA).expect("the fixture parses");
    let unsupported_hex = spec["irobot_lan_protocol"]["password_disclosure"]["response"]
        ["unsupported_reply_hex"]
        .as_str()
        .expect("the spec publishes the unsupported reply");
    let unsupported: Vec<u8> = (0..unsupported_hex.len())
        .step_by(2)
        .map(|i| u8::from_str_radix(&unsupported_hex[i..i + 2], 16).expect("hex"))
        .collect();

    let cannot = roomba_parse_password_reply(unsupported).expect_err("not a password");
    assert!(cannot.to_string().contains("account"), "{cannot}");
}

// ── A whole session ──────────────────────────────────────────────────────────

/// Connect, subscribe, publish a command, take a state push, disconnect —
/// with the robot's replies interleaved and split across reads the way TLS
/// actually delivers them.
#[test]
fn a_full_session_encodes_and_parses() {
    let blid = "3193C60472324700";
    let password = ":1:1486937829:gktkDoYpWaDxCfGh";

    let connect = roomba_connect_packet(blid.to_string(), password.to_string());
    assert_eq!(connect[0], 0x10, "CONNECT");

    let subscribe = roomba_subscribe_packet("#".to_string(), 1);
    assert_eq!(subscribe[0], 0x82, "SUBSCRIBE");

    let command =
        render_network_roomba_command(ROOMBA.to_string(), "clean".to_string(), EXAMPLE_EPOCH)
            .expect("renders");
    let publish = roomba_publish_packet(command.topic.clone(), command.payload.clone());
    assert_eq!(publish[0], 0x30, "PUBLISH at QoS 0");

    assert_eq!(roomba_disconnect_packet(), vec![0xE0, 0x00]);

    // What the robot sends back, as one stream.
    let state = r#"{"state":{"reported":{"batPct":94,"bin":{"full":false,"present":true},"cleanMissionStatus":{"phase":"run","cycle":"clean"},"name":"Dorita"}}}"#;
    let mut stream = vec![0x20, 0x02, 0x00, 0x00]; // CONNACK, accepted
    stream.extend([0x90, 0x03, 0x00, 0x01, 0x00]); // SUBACK for packet id 1
    stream.extend(roomba_publish_packet(
        "delta".to_string(),
        state.to_string(),
    ));

    // Delivered a byte at a time — the worst case a TLS stream can produce.
    let mut buffer: Vec<u8> = Vec::new();
    let mut received: Vec<RoombaIncomingDto> = Vec::new();
    for byte in &stream {
        buffer.push(*byte);
        let parsed = roomba_parse_incoming(buffer.clone()).expect("parses");
        received.extend(parsed.packets);
        buffer.drain(..parsed.consumed as usize);
    }
    assert!(buffer.is_empty(), "the whole stream was consumed");

    let kinds: Vec<&str> = received.iter().map(|p| p.kind.as_str()).collect();
    assert_eq!(kinds, vec!["connack", "suback", "publish"]);
    assert_eq!(received[0].code, 0, "the broker accepted the credentials");
    assert_eq!(received[1].code, 1, "SUBACK echoes the packet id");
    assert_eq!(received[2].topic, "delta");

    // And the payload decodes into exactly the paths the entities bind to.
    let fields = roomba_state_fields(received[2].payload.clone());
    for entity in entities() {
        let Some(path) = entity.value_field else {
            continue;
        };
        assert!(
            fields.contains_key(&path),
            "{} binds {path}, which this state push does not carry",
            entity.name
        );
    }
    assert_eq!(fields["state.reported.batPct"], "94");
    assert_eq!(fields["state.reported.cleanMissionStatus.phase"], "run");
    // false -> "0", so the binary_sensor's `on_when: nonzero` reads it.
    assert_eq!(fields["state.reported.bin.full"], "0");
}

/// A wrong password is refusal code 4, and it must be distinguishable from an
/// unreachable robot — otherwise the user re-checks their network instead of
/// re-running the handshake.
#[test]
fn a_refused_connection_carries_its_reason() {
    let parsed = roomba_parse_incoming(vec![0x20, 0x02, 0x00, 0x04]).expect("parses");
    assert_eq!(parsed.packets[0].kind, "connack");
    assert_eq!(parsed.packets[0].code, 4);
}

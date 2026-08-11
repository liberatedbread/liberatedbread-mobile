// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end control test for a device with no GATT: the Wemo smart plug and
//! the Crock-Pot Smart Slow Cooker, driven entirely from their spec.
//!
//! The unit tests in `protocol::soap` exercise the rules against a miniature
//! fixture. This one runs them against the catalogue's real file, because the
//! claim being tested is about that file: a consumer holding it and a device
//! should be able to draw the right controls, send the right request and read
//! the answer back, without knowing anything about Wemo.
//!
//! Two of these assertions are not about mechanics at all but about a trap the
//! spec documents, and they are the reason this file is worth its length:
//!
//!   * the Crock-Pot's on/off state is NOT `BinaryState` (the device answers 0
//!     there whatever it is doing), and
//!   * `SetCrockpotState` carries mode and cook time together, so a control
//!     changing one must send the other back or it clears the timer.
//!
//! The fixture is a verbatim copy of the upstream spec, like every other file
//! under `tests/specs/`. It is ahead of `vendor/protocol-specs` until the next
//! subtree pull, which is deliberate: this crate's support for the vocabulary
//! lands before the catalogue that uses it ships.

use std::collections::BTreeMap;

use liberated_bread_core::protocol::soap::{self, EntityReading};
use liberated_bread_core::spec::bindings::{network_entities, resolve_network_actions};
use liberated_bread_core::spec::parser::parse_device_spec;
use liberated_bread_core::spec::types::{DeviceSpec, Entity};

const WEMO: &str = include_str!("specs/wemo-devices.yaml");

fn spec() -> DeviceSpec {
    parse_device_spec(WEMO).expect("the Wemo spec parses")
}

fn entity<'a>(spec: &'a DeviceSpec, name: &str) -> &'a Entity {
    spec.entities
        .iter()
        .find(|e| e.name == name)
        .unwrap_or_else(|| panic!("the spec declares no entity named {name:?}"))
}

fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
        .collect()
}

/// The state values the spec's own published `GetCrockpotState` example
/// returns: low, four hours set, fifteen minutes elapsed.
fn crockpot_state() -> BTreeMap<String, String> {
    values(&[("mode", "51"), ("time", "240"), ("cookedTime", "15")])
}

#[test]
fn the_spec_declares_the_controls_a_client_draws() {
    let spec = spec();
    let names: Vec<&str> = network_entities(&spec)
        .iter()
        .map(|e| e.name.as_str())
        .collect();
    assert_eq!(
        names,
        vec![
            "Plug",
            "Slow Cooker",
            "Cook Mode",
            "Cook Time",
            "Cooked Time"
        ]
    );
}

#[test]
fn the_plug_resolves_both_halves_of_a_toggle() {
    let spec = spec();
    let actions = resolve_network_actions(&spec, entity(&spec, "Plug"));

    let roles: Vec<&str> = actions.iter().map(|a| a.role).collect();
    assert_eq!(roles, vec!["turn_on", "turn_off"]);
    // Nothing to fill in and nothing to read first: a plug toggle is one tap.
    assert!(actions.iter().all(|a| a.user_params.is_empty()));
    assert!(actions.iter().all(|a| a.read_back.is_empty()));
}

#[test]
fn turning_the_plug_on_renders_the_request_the_spec_publishes() {
    let spec = spec();
    let action = resolve_network_actions(&spec, entity(&spec, "Plug"))
        .into_iter()
        .find(|a| a.role == "turn_on")
        .expect("the plug resolves a turn_on");

    let request = soap::render_command(&spec, action.command_name, action.command, &values(&[]))
        .expect("turn_on renders");

    assert_eq!(
        request.soap_action,
        "\"urn:Belkin:service:basicevent:1#SetBinaryState\""
    );
    // The spec publishes the exact bytes; the renderer must reproduce them.
    // This is the assertion that fails when a spec edit breaks the wire
    // format, which is the only place it can be caught without hardware.
    let published = action
        .command
        .example_body
        .as_deref()
        .expect("plug_turn_on publishes an example body");
    assert_eq!(request.body.trim(), published.trim());
}

#[test]
fn the_cooker_resolves_a_switch_a_mode_picker_and_a_timer() {
    let spec = spec();

    let switch = resolve_network_actions(&spec, entity(&spec, "Slow Cooker"));
    assert_eq!(
        switch.iter().map(|a| a.role).collect::<Vec<_>>(),
        vec!["turn_on", "turn_off"]
    );

    let select = resolve_network_actions(&spec, entity(&spec, "Cook Mode"));
    assert_eq!(
        select.iter().map(|a| a.role).collect::<Vec<_>>(),
        vec!["select_option"],
        "a heat-level picker is a select, and nothing in the app spoke that \
         role before this device"
    );
    assert_eq!(select[0].user_params, vec!["mode"]);

    let number = resolve_network_actions(&spec, entity(&spec, "Cook Time"));
    assert_eq!(
        number.iter().map(|a| a.role).collect::<Vec<_>>(),
        vec!["set_value"]
    );
    assert_eq!(number[0].user_params, vec!["time"]);
    assert_eq!(number[0].min, Some(0.0));
    // No max: the spec deliberately states none, and a control must not
    // invent a ceiling the appliance never agreed to.
    assert_eq!(number[0].max, None);

    // A reading with no way to set it resolves no actions at all.
    assert!(resolve_network_actions(&spec, entity(&spec, "Cooked Time")).is_empty());
}

#[test]
fn every_cooker_write_says_what_it_must_read_back_first() {
    let spec = spec();
    for (entity_name, role, expected) in [
        (
            "Cook Mode",
            "select_option",
            ("time", "state:GetCrockpotState.time"),
        ),
        (
            "Cook Time",
            "set_value",
            ("mode", "state:GetCrockpotState.mode"),
        ),
        (
            "Slow Cooker",
            "turn_on",
            ("time", "state:GetCrockpotState.time"),
        ),
    ] {
        let action = resolve_network_actions(&spec, entity(&spec, entity_name))
            .into_iter()
            .find(|a| a.role == role)
            .unwrap_or_else(|| panic!("{entity_name} resolves no {role}"));
        assert_eq!(
            action.read_back,
            vec![expected],
            "{entity_name}/{role} does not surface the value it must read back \
             — a client that does not know to fetch it will clear the setting \
             the user did not touch"
        );
    }

    // Off is the exception, and it is the one that must work from cold: it
    // takes no cook time with it, so there is nothing to read first.
    let off = resolve_network_actions(&spec, entity(&spec, "Slow Cooker"))
        .into_iter()
        .find(|a| a.role == "turn_off")
        .expect("the cooker resolves a turn_off");
    assert!(off.read_back.is_empty());
    assert!(off.user_params.is_empty());
}

#[test]
fn setting_a_cook_mode_renders_the_request_the_spec_publishes() {
    let spec = spec();
    let action = resolve_network_actions(&spec, entity(&spec, "Cook Mode"))
        .into_iter()
        .next()
        .expect("the cooker resolves a mode picker");

    // What a picker sends after reading the current cook time back: low, with
    // the four hours already on the clock handed straight back to the device.
    let request = soap::render_command(
        &spec,
        action.command_name,
        action.command,
        &values(&[("mode", "51"), ("time", "240")]),
    )
    .expect("set_cook_mode renders");

    let published = action
        .command
        .example_body
        .as_deref()
        .expect("set_cook_mode publishes an example body");
    assert_eq!(request.body.trim(), published.trim());
}

#[test]
fn a_mode_picker_that_cannot_read_the_time_back_still_sends_a_valid_request() {
    let spec = spec();
    let action = resolve_network_actions(&spec, entity(&spec, "Cook Mode"))
        .into_iter()
        .next()
        .unwrap();

    // The spec defaults `time` precisely so this is possible. It is the
    // fallback, not the intent — but a control that cannot send at all is
    // worse than one that sends the documented default.
    let request = soap::render_command(
        &spec,
        action.command_name,
        action.command,
        &values(&[("mode", "50")]),
    )
    .expect("set_cook_mode renders without a read-back");
    assert!(request.body.contains("<mode>50</mode>"));
    assert!(request.body.contains("<time>0</time>"));
}

#[test]
fn one_state_response_drives_every_cooker_control() {
    let spec = spec();
    let returned = crockpot_state();

    assert_eq!(
        soap::read_entity(&spec, entity(&spec, "Slow Cooker"), &returned),
        Some(EntityReading::OnOff(true))
    );
    assert_eq!(
        soap::read_entity(&spec, entity(&spec, "Cook Mode"), &returned),
        Some(EntityReading::Option {
            raw: "51".to_string(),
            label: "low".to_string()
        })
    );
    assert_eq!(
        soap::read_entity(&spec, entity(&spec, "Cook Time"), &returned),
        Some(EntityReading::Number(240.0))
    );
    assert_eq!(
        soap::read_entity(&spec, entity(&spec, "Cooked Time"), &returned),
        Some(EntityReading::Number(15.0))
    );
}

#[test]
fn the_cooker_reads_its_state_from_mode_and_never_from_binary_state() {
    let spec = spec();
    let cooker = entity(&spec, "Slow Cooker");

    // The documented trap: GetBinaryState answers 0 on this device whatever it
    // is doing. Binding it — which is what every other Wemo switch does — gives
    // a cooker that reads as permanently off, and nothing in the response says
    // so. Pin the binding rather than trusting a future editor to remember.
    assert_eq!(cooker.state_command.as_deref(), Some("GetCrockpotState"));
    assert_eq!(cooker.value_field(), Some("mode"));

    // And the reading a naive binding would produce, so the difference is
    // visible here rather than only in a user's kitchen.
    let lying = values(&[("BinaryState", "0"), ("mode", "51")]);
    assert_eq!(
        soap::read_entity(&spec, cooker, &lying),
        Some(EntityReading::OnOff(true)),
        "the cooker is on: it is set to Low"
    );
}

#[test]
fn the_plug_reads_on_through_the_long_pipe_delimited_form() {
    let spec = spec();
    let plug = entity(&spec, "Plug");

    // The short form every plug answers with.
    assert_eq!(
        soap::read_entity(&spec, plug, &values(&[("BinaryState", "1")])),
        Some(EntityReading::OnOff(true))
    );
    // The long form some firmware answers with, whose leading 8 means "on,
    // load idling". Read whole it is not a number; read as a plain state it is
    // not 1. Both failures show a live plug as off.
    assert_eq!(
        soap::read_entity(
            &spec,
            plug,
            &values(&[(
                "BinaryState",
                "8|1492338954|0|922|14195|1209600|0|940670|15213709|227088884"
            )])
        ),
        Some(EntityReading::OnOff(true))
    );
    assert_eq!(
        soap::read_entity(&spec, plug, &values(&[("BinaryState", "0")])),
        Some(EntityReading::OnOff(false))
    );
}

#[test]
fn the_other_wemo_families_declare_no_controls_yet() {
    let spec = spec();
    // The spec scopes its entities to the plugs and the cooker on purpose: a
    // declared entity is a promise the control works. This asserts the scoping
    // survives, so nobody widens `variants` without widening the evidence.
    let scoped: Vec<Vec<String>> = network_entities(&spec)
        .iter()
        .map(|e| {
            e.extensions
                .get("variants")
                .and_then(|v| v.as_sequence())
                .map(|seq| {
                    seq.iter()
                        .filter_map(|v| v.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default()
        })
        .collect();
    assert!(
        scoped.iter().all(|variants| !variants.is_empty()),
        "every declared entity must say which models it applies to"
    );
    assert!(scoped
        .iter()
        .flatten()
        .all(|variant| { variant.contains("Plug") || variant.contains("Crock-Pot") }));
}

// ── The FFI surface, over the same file ─────────────────────────────────────
//
// What Dart actually calls. Tested here rather than only through the internal
// modules because the FFI layer adds two things of its own — variant scoping
// by SSDP target, and the parsing of `source:` strings into structured
// read-back entries — and both have a wrong-answer failure mode, not a crash.

use liberated_bread_core::api::device_api::{
    network_entities_for_device, read_network_entity, render_network_command,
    render_network_state_request, NetworkReadingKind,
};
use std::collections::HashMap;

fn targets(list: &[&str]) -> Vec<String> {
    list.iter().map(|t| (*t).to_string()).collect()
}

#[test]
fn a_crockpot_gets_cooker_controls_and_a_plug_does_not() {
    // The device's own SSDP answers are what narrow a family spec to a model.
    let cooker = network_entities_for_device(
        WEMO.to_string(),
        targets(&[
            "urn:Belkin:service:basicevent:1",
            "urn:Belkin:device:crockpot:1",
        ]),
    )
    .unwrap();
    let names: Vec<&str> = cooker.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(
        names,
        vec!["Slow Cooker", "Cook Mode", "Cook Time", "Cooked Time"]
    );

    // A Mini answers controllee:1 — it must get the plug switch and nothing
    // of the cooker's. This is the assertion that fails if variant scoping
    // ever loosens, and the failure it prevents is a Cook Mode picker on a
    // power strip.
    let plug = network_entities_for_device(
        WEMO.to_string(),
        targets(&[
            "urn:Belkin:service:basicevent:1",
            "urn:Belkin:device:controllee:1",
        ]),
    )
    .unwrap();
    let names: Vec<&str> = plug.iter().map(|e| e.name.as_str()).collect();
    assert_eq!(names, vec!["Plug"]);

    // Unidentifiable model: no controls, not a stranger's controls.
    let unknown =
        network_entities_for_device(WEMO.to_string(), targets(&["upnp:rootdevice"])).unwrap();
    assert!(unknown.is_empty());
}

#[test]
fn the_dto_carries_structured_read_back_not_source_strings() {
    let cooker =
        network_entities_for_device(WEMO.to_string(), targets(&["urn:Belkin:device:crockpot:1"]))
            .unwrap();
    let mode = cooker.iter().find(|e| e.name == "Cook Mode").unwrap();

    assert_eq!(mode.platform.as_deref(), Some("select"));
    let labels: Vec<&str> = mode.options.iter().map(|o| o.label.as_str()).collect();
    assert_eq!(labels, vec!["off", "warm", "low", "high"]);

    let action = &mode.actions[0];
    assert_eq!(action.role, "select_option");
    assert_eq!(action.user_params, vec!["mode"]);
    // "state:GetCrockpotState.time" arrives parsed, so Dart never learns the
    // string format — the FFI is where it stops being a spelling.
    assert_eq!(action.read_back.len(), 1);
    assert_eq!(action.read_back[0].param, "time");
    assert_eq!(action.read_back[0].command, "GetCrockpotState");
    assert_eq!(action.read_back[0].field, "time");
}

#[test]
fn a_state_request_renders_from_the_endpoint_catalogue() {
    let request =
        render_network_state_request(WEMO.to_string(), "GetCrockpotState".to_string()).unwrap();
    assert_eq!(request.service, "urn:Belkin:service:basicevent:1");
    assert_eq!(
        request.soap_action,
        "\"urn:Belkin:service:basicevent:1#GetCrockpotState\""
    );
    assert_eq!(request.path.as_deref(), Some("/upnp/control/basicevent1"));
    assert!(request
        .body
        .contains("<u:GetCrockpotState xmlns:u=\"urn:Belkin:service:basicevent:1\">"));
    // Argument-less: the action element is empty, with no stray blank line.
    assert!(!request.body.contains("\n\n"));
}

#[test]
fn the_ffi_round_trip_reads_what_it_would_send_about() {
    let request = render_network_command(
        WEMO.to_string(),
        "set_cook_mode".to_string(),
        HashMap::from([
            ("mode".to_string(), "51".to_string()),
            ("time".to_string(), "240".to_string()),
        ]),
    )
    .unwrap();
    assert!(request.body.contains("<mode>51</mode>"));

    let reading = read_network_entity(
        WEMO.to_string(),
        "Cook Mode".to_string(),
        HashMap::from([("mode".to_string(), "51".to_string())]),
    )
    .unwrap()
    .expect("the reply carries the mode");
    assert_eq!(reading.kind, NetworkReadingKind::Option);
    assert_eq!(reading.label.as_deref(), Some("low"));
    assert_eq!(reading.raw, "51");

    // A mode the table does not know is UNKNOWN, with the raw value kept for
    // display — never the first option's label.
    let unknown = read_network_entity(
        WEMO.to_string(),
        "Cook Mode".to_string(),
        HashMap::from([("mode".to_string(), "99".to_string())]),
    )
    .unwrap()
    .unwrap();
    assert_eq!(unknown.kind, NetworkReadingKind::UnknownOption);
    assert_eq!(unknown.raw, "99");

    // And a reply that never mentioned the value reads as nothing at all.
    let absent =
        read_network_entity(WEMO.to_string(), "Cook Mode".to_string(), HashMap::new()).unwrap();
    assert!(absent.is_none());
}

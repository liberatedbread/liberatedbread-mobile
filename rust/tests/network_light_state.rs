// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! A Wi-Fi light's live state, read from the vendored specs through the API
//! the device screen calls.
//!
//! A light declares no `value`: its `state_mapping` names roles — `is_on`,
//! `brightness`, sometimes `color_temperature` — beside the power rule that
//! reads `is_on`. `read_network_entity` reads `value` alone, so for every
//! such light it answered None and the card never learned whether the bulb
//! was on. These hold the role read to the real catalogue entries, fed the
//! flattened replies the app's own flatteners produce.

use std::collections::HashMap;

use liberated_bread_core::api::device_api::{
    read_network_entity, read_network_entity_roles, NetworkReadingKind, NetworkRoleReadingDto,
};

const KASA: &str =
    include_str!("../../vendor/protocol-specs/device-specs/devices/tplink-kasa-smart-plug.yaml");
const ELGATO: &str =
    include_str!("../../vendor/protocol-specs/device-specs/devices/elgato-key-light.yaml");
const RATGDO: &str = include_str!("../../vendor/protocol-specs/device-specs/devices/ratgdo.yaml");

fn returned(pairs: &[(&str, &str)]) -> HashMap<String, String> {
    pairs
        .iter()
        .map(|(k, v)| (k.to_string(), v.to_string()))
        .collect()
}

fn role<'a>(readings: &'a [NetworkRoleReadingDto], name: &str) -> &'a NetworkRoleReadingDto {
    readings
        .iter()
        .find(|r| r.role == name)
        .unwrap_or_else(|| panic!("no {name} reading in {readings:?}"))
}

#[test]
fn a_kasa_bulb_reads_on_and_brightness() {
    // kasaStateFields lifts get_sysinfo flat, so light_state's members
    // arrive as dotted keys.
    let reply = returned(&[
        ("alias", "Reading Lamp"),
        ("light_state.on_off", "1"),
        ("light_state.brightness", "60"),
    ]);
    // The single-value read has nothing to say about a light — which is
    // why the screen needs the role read below.
    assert!(
        read_network_entity(KASA.into(), "Bulb".into(), reply.clone())
            .unwrap()
            .is_none()
    );

    let readings = read_network_entity_roles(KASA.into(), "Bulb".into(), reply).unwrap();
    let on = role(&readings, "is_on");
    assert_eq!(on.reading.kind, NetworkReadingKind::OnOff);
    assert_eq!(on.reading.is_on, Some(true));
    // `on_when: nonzero` sits beside `brightness` in the mapping and is
    // the power role's rule alone: 60 is a level, not "on".
    let brightness = role(&readings, "brightness");
    assert_eq!(brightness.reading.kind, NetworkReadingKind::Number);
    assert_eq!(brightness.reading.number, Some(60.0));

    let off = read_network_entity_roles(
        KASA.into(),
        "Bulb".into(),
        returned(&[("light_state.on_off", "0"), ("light_state.brightness", "1")]),
    )
    .unwrap();
    assert_eq!(role(&off, "is_on").reading.is_on, Some(false));
    assert_eq!(role(&off, "brightness").reading.number, Some(1.0));
}

#[test]
fn an_elgato_key_light_reads_on_brightness_and_colour_temperature() {
    // The flatteners keep an array whole, as its JSON text, under its own
    // path (R-043) — so `lights[0].on` is never a key, and the read walks
    // into the array the reply carried.
    let reply = returned(&[
        ("numberOfLights", "1"),
        ("lights", r#"[{"on":1,"brightness":40,"temperature":213}]"#),
    ]);
    let readings = read_network_entity_roles(ELGATO.into(), "Key Light".into(), reply).unwrap();
    assert_eq!(role(&readings, "is_on").reading.is_on, Some(true));
    assert_eq!(role(&readings, "brightness").reading.number, Some(40.0));
    // Mireds, as the reply and the set_color_temperature action both state.
    assert_eq!(
        role(&readings, "color_temperature").reading.number,
        Some(213.0)
    );

    let off = read_network_entity_roles(
        ELGATO.into(),
        "Key Light".into(),
        returned(&[("lights", r#"[{"on":0,"brightness":3,"temperature":344}]"#)]),
    )
    .unwrap();
    assert_eq!(role(&off, "is_on").reading.is_on, Some(false));
    assert_eq!(role(&off, "brightness").reading.number, Some(3.0));
}

#[test]
fn a_ratgdo_garage_light_compares_its_string_on_value() {
    // ESPHome answers "ON"/"OFF"; the spec's `on_value: "ON"` is text.
    for (state, on) in [("ON", true), ("OFF", false)] {
        let readings = read_network_entity_roles(
            RATGDO.into(),
            "Garage Light".into(),
            returned(&[("id", "light-light"), ("state", state)]),
        )
        .unwrap();
        assert_eq!(role(&readings, "is_on").reading.is_on, Some(on), "{state}");
    }
}

#[test]
fn a_reply_without_the_roles_reads_as_nothing() {
    // Unknown, never a fabricated "off" or a zero brightness.
    let readings = read_network_entity_roles(
        KASA.into(),
        "Bulb".into(),
        returned(&[("relay_state", "1"), ("lights", "not json")]),
    )
    .unwrap();
    assert!(readings.is_empty(), "{readings:?}");
    let readings = read_network_entity_roles(
        ELGATO.into(),
        "Key Light".into(),
        returned(&[("lights", "[]")]),
    )
    .unwrap();
    assert!(readings.is_empty(), "{readings:?}");
}

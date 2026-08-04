// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Tolerance test: the parser must accept every real protocol-docs device spec
//! without error, including WiFi specs with no BLE services, Home-Assistant
//! `entities` metadata, and vendor-specific extension blocks (admore's
//! protobuf/state_machine/version_fields, encryption/framing declarations,
//! `int32` parameters, etc.). These blocks are parsed-and-ignored for now — the
//! point of this test is that a valid spec loads rather than being rejected by
//! `deny_unknown_fields`.
//!
//! The fixtures under `tests/specs/` are verbatim copies of the upstream
//! protocol-docs specs, vendored so the test does not depend on a sibling repo
//! being checked out (e.g. in CI).

use liberated_bread_core::spec::parser::parse_device_spec;

/// Every real spec paired with its vendored fixture contents.
const SPECS: &[(&str, &str)] = &[
    ("example-bulb", include_str!("specs/example-bulb.yaml")),
    (
        "admore-light-bar",
        include_str!("specs/admore-light-bar.yaml"),
    ),
    ("chef-iq-sense", include_str!("specs/chef-iq-sense.yaml")),
    (
        "frigidaire-window-ac",
        include_str!("specs/frigidaire-window-ac.yaml"),
    ),
    (
        "frigidaire-portable-ac",
        include_str!("specs/frigidaire-portable-ac.yaml"),
    ),
];

#[test]
fn all_real_specs_parse_ok() {
    for (name, yaml) in SPECS {
        parse_device_spec(yaml)
            .unwrap_or_else(|e| panic!("real spec `{name}` should parse, but failed: {e}"));
    }
}

#[test]
fn wifi_spec_parses_with_no_ble_services() {
    // Frigidaire specs are WiFi: they carry `mqtt_topics` and no `services`.
    let spec = parse_device_spec(include_str!("specs/frigidaire-window-ac.yaml"))
        .expect("wifi spec should parse");
    assert!(
        spec.services.is_empty(),
        "wifi spec should have no BLE services"
    );
    assert!(
        spec.extensions.contains_key("mqtt_topics"),
        "mqtt_topics should be preserved in the extensions bag"
    );
    // `entities` is no longer swept into the extensions bag: it is now a typed
    // field, because it is what lets the app render named readings instead of a
    // GATT browser. The tolerance guarantee it used to stand for — unknown
    // top-level blocks survive parsing — is still covered by `mqtt_topics`
    // above.
    assert!(
        !spec.extensions.contains_key("entities"),
        "entities should be parsed into its typed field, not the extensions bag"
    );
    assert!(
        !spec.entities.is_empty(),
        "the WiFi spec declares entities, which should parse into DeviceSpec::entities"
    );
}

#[test]
fn ble_spec_still_exposes_characteristics() {
    // The tolerance changes must not stop the parser from surfacing the fields
    // that actually drive BLE reads/writes.
    let spec =
        parse_device_spec(include_str!("specs/example-bulb.yaml")).expect("bulb spec should parse");
    assert_eq!(spec.services.len(), 2);
    let (_svc, ch) = spec
        .find_characteristic("0000fff1-0000-1000-8000-00805f9b34fb")
        .expect("command characteristic should be found");
    assert!(ch.commands.as_ref().unwrap().contains_key("set_brightness"));
}

#[test]
fn admore_int32_and_bespoke_blocks_parse() {
    // admore uses `manufacturer_status: active`, `type: int32` parameters with
    // `allowed`/`labels`, service- and characteristic-level `notes`,
    // command-level `setting_id`, and bespoke `protobuf`/`state_machine`/
    // `version_fields` blocks nested under `device:`. None may break parsing.
    let spec = parse_device_spec(include_str!("specs/admore-light-bar.yaml"))
        .expect("admore spec should parse");
    assert!(spec.device.protobuf.is_some());
    assert!(spec.device.state_machine.is_some());
    assert!(spec.device.version_fields.is_some());
    // An int32 parameter with an `allowed`/`labels` enumeration must parse.
    let (_svc, ch) = spec
        .find_characteristic("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
        .expect("NUS RX characteristic should be found");
    let cmd = &ch.commands.as_ref().unwrap()["set_tail_brightness"];
    let value = &cmd.parameters.as_ref().unwrap().params["value"];
    assert_eq!(value.value_type.to_string(), "int32");
    assert!(value.allowed.is_some());
    assert!(value.labels.is_some());
    assert_eq!(cmd.setting_id.as_deref(), Some("LOS_TAIL_LIGHT_BRIGHTNESS"));
}

#[test]
fn entities_resolve_only_when_the_characteristic_exists() {
    // The bulb declares a Battery sensor bound to 0x2A19, which the spec also
    // declares as a characteristic — so it resolves and can carry a reading.
    let spec =
        parse_device_spec(include_str!("specs/example-bulb.yaml")).expect("bulb spec should parse");

    let resolved = spec.resolved_entities();
    assert!(
        resolved
            .iter()
            .any(|(entity, _)| entity.name == "Battery"),
        "the Battery entity binds to a declared characteristic and should resolve"
    );

    // Every resolved entity must name a characteristic that genuinely exists;
    // that invariant is what lets the UI trust the list it is given.
    for (entity, _) in &resolved {
        let uuid = entity
            .state_characteristic
            .as_deref()
            .expect("a resolved entity always has a state_characteristic");
        assert!(
            spec.find_characteristic(uuid).is_some(),
            "resolved entity `{}` points at unknown characteristic {uuid}",
            entity.name
        );
    }
}

#[test]
fn entity_value_field_comes_from_state_mapping() {
    let spec =
        parse_device_spec(include_str!("specs/example-bulb.yaml")).expect("bulb spec should parse");

    let battery = spec
        .entities
        .iter()
        .find(|e| e.name == "Battery")
        .expect("bulb spec declares a Battery entity");

    // `state_mapping.value` picks which decoded field is the reading; without
    // it the UI would have to guess when a format block decodes several fields.
    assert_eq!(battery.value_field(), Some("battery_percent"));
}

#[test]
fn entities_dangling_characteristic_is_dropped() {
    // A hand-written spec can bind an entity to a UUID it never declares. Such
    // an entity can never produce a reading, so it must not reach the UI.
    let yaml = r#"
device:
  name: "Ghost Sensor"
  manufacturer: "Nobody"
  manufacturer_status: "abandoned"
  protocol: "ble"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control Service"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
entities:
  - platform: "sensor"
    name: "Nowhere Temperature"
    device_class: "temperature"
    unit: "C"
    state_characteristic: "0000dead-0000-1000-8000-00805f9b34fb"
"#;

    let spec = parse_device_spec(yaml).expect("spec should parse");
    assert_eq!(spec.entities.len(), 1, "the entity should still parse");
    assert!(
        spec.resolved_entities().is_empty(),
        "an entity bound to an undeclared characteristic must not resolve"
    );
}

#[test]
fn entity_scale_comes_from_state_mapping() {
    // Fixed-point reporting is common: Ember's mug sends centidegrees, so the
    // spec carries `scale: 0.01` and a raw 5320 renders as 53.20 °C. The
    // multiplier must come from the spec, otherwise every such device needs a
    // hardcoded conversion in the app.
    let yaml = r#"
device:
  name: "Scaled Thermometer"
  manufacturer: "Someone"
  manufacturer_status: "abandoned"
  protocol: "ble"
services:
  - uuid: "fc543622-236c-4c94-8fa9-944a3e5353fa"
    name: "Mug Service"
    characteristics:
      - uuid: "fc540002-236c-4c94-8fa9-944a3e5353fa"
        name: "Current Temperature"
        properties: ["read"]
        format:
          - offset: 0
            length: 2
            name: "current_temp_raw"
            type: "uint16"
entities:
  - platform: "sensor"
    name: "Current Temperature"
    device_class: "temperature"
    unit: "C"
    state_characteristic: "fc540002-236c-4c94-8fa9-944a3e5353fa"
    state_mapping:
      value: "current_temp_raw"
      scale: 0.01
"#;

    let spec = parse_device_spec(yaml).expect("spec should parse");
    let entity = &spec.entities[0];
    assert_eq!(entity.value_field(), Some("current_temp_raw"));
    assert_eq!(entity.value_scale(), Some(0.01));

    // An entity with no declared scale must report none, so the caller shows
    // the decoder's own display string rather than silently multiplying by 1.
    let unscaled = parse_device_spec(include_str!("specs/example-bulb.yaml"))
        .expect("bulb spec should parse");
    let battery = unscaled
        .entities
        .iter()
        .find(|e| e.name == "Battery")
        .expect("bulb declares a Battery entity");
    assert_eq!(battery.value_scale(), None);
}

#[test]
fn format_field_scale_and_unit_parse() {
    // The Bluetooth SIG temperature characteristic (0x2A6E) is a signed 16-bit
    // value in hundredths of a degree, and upstream specs declare that on the
    // format field rather than on the entity: `airthings-wave-family` and
    // `xiaomi-miflora` both do. Dropping these keys made the reading wrong by
    // two orders of magnitude, which looks like a working app reporting 2350 °C.
    let yaml = r#"
device:
  name: "SIG Thermometer"
  manufacturer: "Someone"
  manufacturer_status: "unsupported"
  protocol: "ble"
services:
  - uuid: "0000181a-0000-1000-8000-00805f9b34fb"
    name: "Environmental Sensing"
    characteristics:
      - uuid: "00002a6e-0000-1000-8000-00805f9b34fb"
        name: "Temperature"
        properties: ["read", "notify"]
        format:
          - offset: 0
            length: 2
            name: "temperature"
            type: "int16"
            scale: 0.01
            unit: "°C"
      - uuid: "00002a19-0000-1000-8000-00805f9b34fb"
        name: "Battery Level"
        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: "battery_percent"
            type: "uint8"
            unit: "%"
"#;

    let spec = parse_device_spec(yaml).expect("spec should parse");
    let (_, temp) = spec
        .find_characteristic("00002a6e-0000-1000-8000-00805f9b34fb")
        .expect("temperature characteristic");
    let field = &temp.format.as_ref().expect("format block")[0];
    assert_eq!(field.scale, Some(0.01));
    assert_eq!(field.unit.as_deref(), Some("°C"));

    // A field with a unit but no scale must not invent one: the raw value is
    // already the physical quantity.
    let (_, battery) = spec
        .find_characteristic("00002a19-0000-1000-8000-00805f9b34fb")
        .expect("battery characteristic");
    let field = &battery.format.as_ref().expect("format block")[0];
    assert_eq!(field.scale, None);
    assert_eq!(field.unit.as_deref(), Some("%"));
}

#[test]
fn vendored_airthings_declares_format_scale() {
    // Guards the real catalogue, not just a hand-written fixture: if upstream
    // moves Airthings' scale onto the entity instead, this test says so rather
    // than the app quietly showing raw counts.
    let spec = parse_device_spec(include_str!("specs/airthings-wave-family.yaml"))
        .expect("airthings spec should parse");
    let (_, temp) = spec
        .find_decodable_characteristic("00002a6e-0000-1000-8000-00805f9b34fb")
        .expect("airthings declares the SIG temperature characteristic");
    let field = &temp.format.as_ref().expect("format block")[0];
    assert_eq!(field.scale, Some(0.01));
}

#[test]
fn duplicate_characteristic_resolves_to_the_one_with_a_format() {
    // airthings-wave-family declares 0x2A6E and 0x2A6F twice: once as a bare
    // stub under an earlier service, and once with the byte layout. Whichever
    // the app picks decides whether the reading works at all, so pick the one
    // that can actually decode.
    let spec = parse_device_spec(include_str!("specs/airthings-wave-family.yaml"))
        .expect("airthings spec should parse");

    for uuid in [
        "00002a6e-0000-1000-8000-00805f9b34fb",
        "00002a6f-0000-1000-8000-00805f9b34fb",
    ] {
        let (_, first) = spec.find_characteristic(uuid).expect("declared");
        assert!(
            first.format.is_none(),
            "fixture assumption: the first declaration of {uuid} is the stub"
        );

        let (_, decodable) = spec.find_decodable_characteristic(uuid).expect("declared");
        assert!(
            decodable.format.is_some(),
            "a duplicate declaration must not hide the one carrying `format:`"
        );
    }

    // Every entity that names a duplicated characteristic must now resolve to a
    // decodable one, which is what makes the reading render.
    let resolved = spec.resolved_entities();
    assert_eq!(resolved.len(), 6, "airthings declares six sensor entities");
    assert!(
        resolved.iter().all(|(_, c)| c.format.is_some()),
        "every resolved entity should bind to a characteristic with a format block"
    );
}

#[test]
fn undeclared_characteristic_still_returns_none() {
    // The fallback in `find_characteristic_where` must not turn a miss into a
    // hit: a UUID nobody declares has to stay unresolvable.
    let spec = parse_device_spec(include_str!("specs/example-bulb.yaml")).expect("bulb parses");
    assert!(spec
        .find_decodable_characteristic("0000dead-0000-1000-8000-00805f9b34fb")
        .is_none());
    assert!(spec
        .find_writable_characteristic("0000dead-0000-1000-8000-00805f9b34fb")
        .is_none());
}

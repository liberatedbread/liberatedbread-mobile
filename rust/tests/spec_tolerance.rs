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
    // The catalogue's largest file, and the one that exercises the top-level
    // `commands` block and SOAP-bound entities. `airthings-wave-family` keeps a
    // BLE-flavoured catalogue under the same key, so the two together are what
    // holds the block tolerant of both shapes.
    ("wemo-devices", include_str!("specs/wemo-devices.yaml")),
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

/// The UI greys out commands the raw-byte encoder cannot serve, keyed off
/// `CommandDto::is_encodable` / `unsupported_encoding`. The admore spec's
/// commands are protobuf `setting_id` commands (no `value`/`template`), so
/// every one of them must surface as non-encodable with the exact
/// "protobuf setting_id" kind — that string is the UI's grey-out signal, and
/// a wrong verdict here means a control that either vanishes or fails on tap.
#[test]
fn admore_setting_id_commands_surface_as_unencodable_in_dto() {
    use liberated_bread_core::api::device_api::load_device_spec;

    let yaml = include_str!("specs/admore-light-bar.yaml");
    // Cross-reference the raw spec (which knows each command's setting_id)
    // against the DTO (which carries only the encodability verdict).
    let spec = parse_device_spec(yaml).expect("admore spec should parse");
    let dto = load_device_spec(yaml.to_string()).expect("admore DTO should build");

    let mut checked = 0;
    for svc in &spec.services {
        for ch in &svc.characteristics {
            let Some(commands) = &ch.commands else {
                continue;
            };
            let dto_char = dto
                .services
                .iter()
                .find(|s| s.uuid == svc.uuid)
                .and_then(|s| s.characteristics.iter().find(|c| c.uuid == ch.uuid))
                .expect("every spec characteristic appears in the DTO");
            for (name, cmd) in commands {
                let is_pure_setting_id = cmd.setting_id.is_some()
                    && cmd.value.is_none()
                    && cmd.template.is_none()
                    && cmd.encoding.is_none();
                if !is_pure_setting_id {
                    continue;
                }
                let dto_cmd = dto_char
                    .commands
                    .iter()
                    .find(|c| &c.name == name)
                    .unwrap_or_else(|| panic!("command `{name}` missing from DTO"));
                assert!(
                    !dto_cmd.is_encodable,
                    "`{name}`: setting_id commands are not raw-byte encodable"
                );
                assert_eq!(
                    dto_cmd.unsupported_encoding.as_deref(),
                    Some("protobuf setting_id"),
                    "`{name}`: wrong unsupported_encoding kind"
                );
                checked += 1;
            }
        }
    }
    assert!(
        checked >= 20,
        "the admore fixture should exercise many setting_id commands, found only {checked}"
    );
}

/// The DTO boundary must carry the enumerated `allowed`/`labels` pairs the
/// spec declares — the UI renders them as a dropdown instead of a free
/// slider, so dropping them (the old `ParameterDto` shape) silently turned
/// "six discrete device presets" into "any int32". Exact values, straight
/// from the vendored fixture.
#[test]
fn admore_allowed_and_labels_surface_in_dto() {
    use liberated_bread_core::api::device_api::load_device_spec;

    let yaml = include_str!("specs/admore-light-bar.yaml");
    let dto = load_device_spec(yaml.to_string()).expect("admore DTO should build");
    let param = dto
        .services
        .iter()
        .flat_map(|s| &s.characteristics)
        .find(|c| c.uuid == "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
        .expect("NUS RX characteristic should be in the DTO")
        .commands
        .iter()
        .find(|c| c.name == "set_tail_brightness")
        .expect("set_tail_brightness should be in the DTO")
        .parameters
        .iter()
        .find(|p| p.name == "value")
        .expect("set_tail_brightness declares a `value` parameter");

    assert_eq!(param.value_type, "int32");
    assert_eq!(
        param.allowed.as_deref(),
        Some(&[0, 200, 400, 1000, 1500, 2000][..]),
        "allowed values must survive the DTO conversion verbatim"
    );
    let labels: Vec<&str> = param
        .labels
        .as_ref()
        .expect("labels must survive alongside allowed")
        .iter()
        .map(String::as_str)
        .collect();
    assert_eq!(
        labels,
        ["OFF", "1", "2", "3", "4", "5"],
        "labels must pair 1:1 (by index) with allowed"
    );
}

/// `labels` pair with `allowed` 1:1 by index; mismatched lengths cannot be
/// paired truthfully. The conversion decision (documented on
/// `From<(&str, &Parameter)> for ParameterDto`): keep `allowed` — it is what
/// the device accepts — and drop `labels` entirely rather than panic or
/// mispair. Labels without any `allowed` are dropped for the same reason.
/// The parser itself still preserves both blocks (tolerance), so this also
/// pins that the drop happens exactly at the DTO boundary.
#[test]
fn mismatched_labels_are_dropped_at_dto_boundary_but_allowed_kept() {
    use liberated_bread_core::api::device_api::load_device_spec;

    const MISMATCH_YAML: &str = r#"
device:
  name: "Mismatch"
  manufacturer: "Test"
  manufacturer_status: "abandoned"
  protocol: "ble"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
        commands:
          set_mode:
            description: "One label short of its allowed values"
            template: [0x01, "{mode}"]
            parameters:
              mode:
                type: "uint8"
                allowed: [1, 2, 3]
                labels: ["Slow", "Fast"]
          set_speed:
            description: "Labels with no allowed at all"
            template: [0x02, "{speed}"]
            parameters:
              speed:
                type: "uint8"
                labels: ["A", "B"]
"#;

    // The parser is tolerant: both blocks are preserved as declared.
    let spec = parse_device_spec(MISMATCH_YAML).expect("mismatched labels must still parse");
    let commands = spec.services[0].characteristics[0]
        .commands
        .as_ref()
        .unwrap();
    let raw_mode = &commands["set_mode"].parameters.as_ref().unwrap().params["mode"];
    assert_eq!(raw_mode.allowed.as_ref().map(Vec::len), Some(3));
    assert_eq!(raw_mode.labels.as_ref().map(Vec::len), Some(2));

    // The DTO boundary is where the unpairable labels get dropped.
    let dto = load_device_spec(MISMATCH_YAML.to_string()).expect("DTO should build");
    let dto_commands = &dto.services[0].characteristics[0].commands;
    let mode = dto_commands
        .iter()
        .find(|c| c.name == "set_mode")
        .unwrap()
        .parameters
        .iter()
        .find(|p| p.name == "mode")
        .unwrap();
    assert_eq!(
        mode.allowed.as_deref(),
        Some(&[1, 2, 3][..]),
        "allowed survives even when its labels are unusable"
    );
    assert_eq!(
        mode.labels, None,
        "length-mismatched labels are dropped, not zipped short or padded"
    );

    let speed = dto_commands
        .iter()
        .find(|c| c.name == "set_speed")
        .unwrap()
        .parameters
        .iter()
        .find(|p| p.name == "speed")
        .unwrap();
    assert_eq!(speed.allowed, None);
    assert_eq!(
        speed.labels, None,
        "labels with no allowed values have nothing to pair with"
    );
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
        resolved.iter().any(|(entity, _)| entity.name == "Battery"),
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
    let unscaled =
        parse_device_spec(include_str!("specs/example-bulb.yaml")).expect("bulb spec should parse");
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

#[test]
fn hotwired_climate_entity_resolves_a_sendable_action() {
    // The entity exists to set the heat level and had nothing to send: its
    // write characteristic carries an 8-byte frame, so there is no bare value
    // to write, and the command that builds the frame lived in a top-level
    // block no consumer reads. Both are fixed upstream; this pins that the
    // action now resolves and that the level is the one parameter the UI
    // supplies (status is spec-defaulted to ON).
    let yaml = std::fs::read_to_string(
        std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
            .parent()
            .unwrap()
            .join("vendor/protocol-specs/device-specs/devices/hotwired-heated-gear.yaml"),
    )
    .expect("hotwired spec should be readable");
    let spec = parse_device_spec(&yaml).expect("hotwired spec should parse");
    let entity = spec
        .entities
        .iter()
        .find(|e| e.name == "Heat Level")
        .expect("the climate entity");
    let actions = liberated_bread_core::spec::bindings::resolve_entity_actions(&spec, entity);
    let set = actions
        .iter()
        .find(|a| a.role == "set_value")
        .expect("the heat level must resolve a set_value action");
    assert_eq!(set.command_name, Some("set_heat"));
    assert_eq!(set.user_params, vec!["level"]);
    assert_eq!((set.min, set.max), (Some(0), Some(10)));
}

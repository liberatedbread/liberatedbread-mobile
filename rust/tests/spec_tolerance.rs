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
    assert!(
        spec.extensions.contains_key("entities"),
        "entities should be preserved in the extensions bag"
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

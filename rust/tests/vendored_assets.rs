// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end consumption test: every bundled device spec in the Flutter app's
//! `assets/device_specs/` must parse via the real `parse_device_spec()`.
//!
//! The specs are read from the app's real asset directory at test time (the
//! same files `rootBundle` ships to the device), so this test fails loudly if a
//! bundled fallback spec cannot be parsed.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use liberated_bread_core::spec::parser::parse_device_spec;

/// Absolute path to `<repo>/assets/device_specs`, derived from this crate's
/// manifest dir (`<repo>/rust`) so the test is location-independent.
fn assets_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust crate should have a parent repo dir")
        .join("assets/device_specs")
}

/// Every `*.yaml` under `assets/device_specs/`.
fn vendored_yaml_paths() -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = fs::read_dir(assets_dir())
        .expect("assets/device_specs should exist")
        .map(|e| e.expect("readable dir entry").path())
        .filter(|p| {
            p.extension()
                .is_some_and(|ext| ext == "yaml" || ext == "yml")
        })
        .collect();
    paths.sort();
    paths
}

#[test]
fn every_vendored_spec_parses_ok() {
    let paths = vendored_yaml_paths();
    // The catalogue is vendored wholesale from protocol-specs by
    // `scripts/sync_device_specs.sh`, so this asserts a floor rather than an
    // exact list: pinning filenames would mean editing this test every time a
    // device is added upstream, which is exactly the data-only refresh the
    // manifest exists to enable.
    assert!(
        paths.len() > 1,
        "expected the vendored catalogue, found {} spec(s) — did the sync script run?",
        paths.len()
    );

    // Collect every failure rather than panicking on the first: with a 70-spec
    // catalogue, failing one at a time turns a single vendor refresh into a
    // long sequence of one-error test runs.
    // Specs that fail for a genuine authoring error upstream, not parser
    // strictness. Listed rather than silently skipped so the bug stays visible;
    // remove the entry once the spec is fixed upstream. The Dart loader skips
    // unparseable specs at runtime, so a listed spec means one missing device,
    // not a broken app.
    //
    // seeblue-motorcycle-led: the `direct_brake_feature` command's template
    // references `{message_length}`, which the command never declares. The
    // write would fail at send time with a missing parameter, so rejecting it
    // at parse time is right — the spec should declare it or drop the
    // reference.
    //
    // fardriver-controller: declares `min` on a `bytes` parameter. Byte-string
    // parameters have no numeric range, so the bound is meaningless and the
    // validator is right to reject it — the spec should drop `min` or change
    // the type.
    const KNOWN_BAD: &[&str] = &["fardriver-controller.yaml", "seeblue-motorcycle-led.yaml"];

    let mut failures = Vec::new();
    for path in &paths {
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        let yaml = fs::read_to_string(path).expect("spec file should be readable");
        match parse_device_spec(&yaml) {
            Ok(_) => assert!(
                !KNOWN_BAD.contains(&name.as_str()),
                "`{name}` is listed as known-bad but now parses — remove it from KNOWN_BAD"
            ),
            Err(e) => {
                if !KNOWN_BAD.contains(&name.as_str()) {
                    failures.push(format!("  {name}: {e}"));
                }
            }
        }
    }

    assert!(
        failures.is_empty(),
        "{} of {} vendored spec(s) failed to parse:\n{}",
        failures.len(),
        paths.len(),
        failures.join("\n")
    );
}

#[test]
fn manifest_and_spec_files_agree() {
    // The Dart loader is manifest-driven: it loads exactly the files listed in
    // manifest.json. An entry with no file behind it means a device silently
    // missing at runtime, and a file with no entry means a spec that is shipped
    // but never loaded. Both are invisible without this check — the sync script
    // writes both sides, so they can only drift by hand-editing.
    let manifest_path = assets_dir().join("manifest.json");
    let raw = fs::read_to_string(&manifest_path).expect("manifest.json should exist");

    // Pull `"file": "<name>"` out without taking a JSON dependency for a test.
    let listed: Vec<String> = raw
        .split("\"file\"")
        .skip(1)
        .filter_map(|chunk| {
            let start = chunk.find('"')? + 1;
            let rest = &chunk[start..];
            let end = rest.find('"')?;
            Some(rest[..end].to_owned())
        })
        .collect();
    assert!(
        !listed.is_empty(),
        "manifest.json should list spec files via a `file` key"
    );

    let on_disk: Vec<String> = vendored_yaml_paths()
        .iter()
        .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
        .collect();

    for file in &listed {
        assert!(
            on_disk.contains(file),
            "manifest lists `{file}` but it is not vendored — the loader would skip it"
        );
    }
    for file in &on_disk {
        assert!(
            listed.contains(file),
            "`{file}` is vendored but absent from the manifest — it would never load"
        );
    }
}

/// The shipped asset and the vendored test fixture are the same document by
/// construction: `tests/specs/` holds verbatim upstream copies, and the asset
/// is what the app actually loads at runtime. Pin semantic identity — both
/// files must parse to the same YAML value. Comments and header lines are
/// invisible to `serde_yaml::Value`, so the two may keep different headers,
/// but any structural drift (a block present in one and missing in the
/// other, as happened with `entities:`) fails loudly.
#[test]
fn shipped_example_bulb_matches_test_fixture_semantically() {
    let asset_path = assets_dir().join("example-bulb.yaml");
    let asset = fs::read_to_string(&asset_path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", asset_path.display()));
    let fixture = include_str!("specs/example-bulb.yaml");

    let asset_value: serde_yaml::Value =
        serde_yaml::from_str(&asset).expect("asset should be valid YAML");
    let fixture_value: serde_yaml::Value =
        serde_yaml::from_str(fixture).expect("fixture should be valid YAML");
    assert_eq!(
        asset_value, fixture_value,
        "assets/device_specs/example-bulb.yaml and rust/tests/specs/example-bulb.yaml \
         must stay semantically identical — update both together"
    );
}

/// The loader must stay manifest-driven.
///
/// This replaces an earlier check that `device_spec_provider.dart` list every
/// asset by name. That list was the reason only the example bulb ever shipped:
/// each new device needed a Dart edit, so vendoring the catalogue would have
/// meant hand-maintaining 70+ entries in lockstep with the sync script. The
/// invariant it protected — nothing shipped-but-unloaded, nothing listed-but-
/// missing — is now enforced against `manifest.json` by
/// `manifest_and_spec_files_agree`, which is the list the loader actually
/// reads. What is left to guard here is a regression back to a hardcoded list.
#[test]
fn dart_loader_does_not_hardcode_spec_filenames() {
    let dart_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust crate should have a parent repo dir")
        .join("lib/providers/device_spec_provider.dart");
    let dart_src = fs::read_to_string(&dart_path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", dart_path.display()));

    const PREFIX: &str = "assets/device_specs/";
    let mut hardcoded = BTreeSet::new();
    for (idx, _) in dart_src.match_indices(PREFIX) {
        let rest = &dart_src[idx + PREFIX.len()..];
        if let Some(end) = rest.find(['\'', '"']) {
            let name = &rest[..end];
            if name.ends_with(".yaml") || name.ends_with(".yml") {
                hardcoded.insert(name.to_string());
            }
        }
    }

    // The example bulb is the one permitted literal: it is the fallback used
    // when the manifest is missing or unreadable, so mock mode still works
    // after a broken vendor step.
    hardcoded.remove("example-bulb.yaml");
    assert!(
        hardcoded.is_empty(),
        "device_spec_provider.dart names spec files directly ({hardcoded:?}); \
         adding a device must stay a spec refresh, not a Dart edit"
    );
}

/// The control bindings the flagship devices resolve from the real catalogue,
/// end-to-end through the DTO path the app consumes.
///
/// Each case pins behaviour a card depends on: govee's plug is command-only
/// (no state characteristic at all) and must still cross the FFI; elk-bledom
/// gets brightness and color but must NOT get a power toggle (its on/off
/// command's `cmd` byte is un-defaulted and the spec itself calls it
/// ambiguous); switchbot's prefixed commands resolve through the suffix
/// fallback; ember's LED packs brightness into its color command.
#[test]
fn vendored_specs_resolve_expected_control_actions() {
    use liberated_bread_core::api::device_api::load_device_spec;

    let load = |file: &str| {
        let path = assets_dir().join(file);
        let yaml =
            fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
        load_device_spec(yaml).unwrap_or_else(|e| panic!("{file} should load: {e}"))
    };

    let roles = |dto: &liberated_bread_core::api::device_api::EntityDto| -> Vec<String> {
        dto.actions.iter().map(|a| a.role.clone()).collect()
    };

    // govee-h5080: a stateless switch riding on payload.bytes commands.
    let govee = load("govee-h5080-plug.yaml");
    let plug = govee
        .entities
        .iter()
        .find(|e| e.name == "Plug Outlet")
        .expect("the plug's command-only switch entity must cross the FFI");
    assert_eq!(plug.state_characteristic, None);
    assert_eq!(roles(plug), vec!["turn_on", "turn_off"]);

    // elk-bledom: brightness (bounded 0..100 by the spec) and color resolve;
    // power must not.
    let elk = load("elk-bledom-led-strip.yaml");
    let strip = elk
        .entities
        .iter()
        .find(|e| e.name == "LED Strip")
        .expect("elk-bledom declares an LED Strip light");
    assert_eq!(roles(strip), vec!["set_brightness", "set_color"]);
    let brightness = &strip.actions[0];
    assert_eq!(brightness.command_name, Some("set_brightness".to_string()));
    assert_eq!((brightness.min, brightness.max), (Some(0.0), Some(100.0)));
    assert_eq!(
        strip.actions[1].command_name,
        Some("set_rgb_color".to_string())
    );

    // switchbot: no role map; bot_* names resolve via the suffix fallback,
    // and press resolves alongside the toggle pair.
    let switchbot = load("switchbot-ble.yaml");
    let bot = switchbot
        .entities
        .iter()
        .find(|e| e.name == "Bot Press")
        .expect("switchbot declares a Bot Press switch");
    assert_eq!(roles(bot), vec!["turn_on", "turn_off", "press"]);
    assert_eq!(bot.actions[0].command_name, Some("bot_turn_on".to_string()));
    assert_eq!(bot.actions[2].command_name, Some("bot_press".to_string()));

    // ember: the LED's color command carries brightness as a user param, and
    // the state mapping names the decoded color fields.
    let ember = load("ember-mug.yaml");
    let led = ember
        .entities
        .iter()
        .find(|e| e.name == "LED")
        .expect("ember declares an LED light");
    assert_eq!(roles(led), vec!["set_color"]);
    assert_eq!(
        led.actions[0].user_params,
        vec!["red", "green", "blue", "brightness"]
    );
    assert_eq!(led.color_red_field.as_deref(), Some("red"));
    assert_eq!(led.brightness_field.as_deref(), Some("brightness"));

    // ember's temperature-control switch: no sendable commands (the role map
    // is prose), but it still crosses on the strength of its state binding,
    // with the on_when: nonzero rule intact.
    let temp_control = ember
        .entities
        .iter()
        .find(|e| e.name == "Temperature Control")
        .expect("ember declares a Temperature Control switch");
    assert!(temp_control.actions.is_empty());
    assert!(temp_control.on_when_nonzero);
    assert!(temp_control.state_characteristic.is_some());

    // ember's charging base: the binary_sensor on-mapping crosses intact.
    let charging = ember
        .entities
        .iter()
        .find(|e| e.name == "Charging Base")
        .expect("ember declares a Charging Base binary_sensor");
    assert_eq!(charging.on_value, Some(1));

    // example-bulb: the reference spec resolves the full role set, and its
    // light state mapping (is_on/brightness/color_rgb) crosses intact.
    let bulb = load("example-bulb.yaml");
    let light = bulb
        .entities
        .iter()
        .find(|e| e.name == "Bulb")
        .expect("example-bulb declares a Bulb light");
    assert_eq!(
        roles(light),
        vec!["turn_on", "turn_off", "set_brightness", "set_color"]
    );
    assert_eq!(light.is_on_field.as_deref(), Some("power_state"));
    assert_eq!(light.color_green_field.as_deref(), Some("green"));
}

/// Setpoint resolution against the real catalogue, end to end through the
/// encode path a card actually calls.
///
/// Gerbing is the worked example the whole `set_value` role exists for: no
/// commands anywhere in its spec, but each heat channel nominates a writable
/// characteristic with a single `uint8` percentage field, so a value the user
/// picks becomes one byte on the right characteristic. Ember is the honest
/// negative: its centi-°C target is split across two byte parameters whose
/// order lives only in prose, so it must resolve nothing rather than write a
/// wildly wrong temperature.
#[test]
fn vendored_specs_resolve_expected_setpoints() {
    use liberated_bread_core::api::device_api::{encode_entity_value, load_device_spec};

    let read = |file: &str| {
        let path = assets_dir().join(file);
        fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
    };

    // ── Gerbing: direct write, bounds in decoded units ─────────────────────
    let yaml = read("gerbing-thermogauge.yaml");
    let gerbing = load_device_spec(yaml.clone()).expect("gerbing should load");
    let heat = gerbing
        .entities
        .iter()
        .find(|e| e.name == "Heat Level 1")
        .expect("gerbing declares Heat Level 1");
    assert_eq!(
        heat.actions.len(),
        1,
        "the heat channel resolves exactly one setpoint action"
    );
    assert_eq!(heat.actions[0].role, "set_value");
    assert_eq!(
        heat.actions[0].command_name, None,
        "gerbing has no commands; this is a direct write"
    );
    assert_eq!(
        (heat.setpoint_min, heat.setpoint_max, heat.setpoint_step),
        (Some(0.0), Some(100.0), Some(1.0))
    );

    let write =
        encode_entity_value(yaml.clone(), "Heat Level 1".into(), 60.0).expect("60% should encode");
    assert_eq!(write.bytes, vec![60], "raw byte IS the percentage here");
    assert_eq!(
        write.characteristic_uuid,
        "90759319-1668-44da-9ef3-492d593bd1e5"
    );
    // The two channels are distinct characteristics; a card must not send
    // channel 2's value to channel 1.
    let write2 = encode_entity_value(yaml.clone(), "Heat Level 2".into(), 60.0)
        .expect("channel 2 should encode");
    assert_ne!(write.characteristic_uuid, write2.characteristic_uuid);

    // Out-of-range values fail loudly rather than wrapping to a byte.
    assert!(
        encode_entity_value(yaml, "Heat Level 1".into(), 300.0).is_err(),
        "300% must not silently wrap into a u8"
    );

    // ── Ember: the two-byte split must NOT be guessed at ───────────────────
    let yaml = read("ember-mug.yaml");
    let ember = load_device_spec(yaml.clone()).expect("ember should load");
    let target = ember
        .entities
        .iter()
        .find(|e| e.name == "Target Temperature")
        .expect("ember declares Target Temperature");
    assert!(
        target.actions.is_empty(),
        "temp_low/temp_high ordering is prose-only; resolving it would be a guess"
    );
    // The entity's own declared bounds still cross, so a read-only setpoint
    // still knows what range the device accepts.
    assert_eq!(
        (target.setpoint_min, target.setpoint_max),
        (Some(49.0), Some(63.0))
    );
    assert!(encode_entity_value(yaml, "Target Temperature".into(), 55.0).is_err());
}

/// The number-semantics vocabulary the subtree refresh brought in must reach
/// the decode path, or Gerbing's thermometer reads 85 degrees cold and
/// Ember's liquid state stays an opaque integer.
#[test]
fn vendored_specs_decode_with_offsets_and_value_tables() {
    use liberated_bread_core::api::device_api::decode_value;

    let read = |file: &str| {
        let path = assets_dir().join(file);
        fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
    };

    // Gerbing channel 1: value = raw * 0.5 + 85 (°F). Raw 100 is 135 °F.
    let decoded = decode_value(
        Some(read("gerbing-thermogauge.yaml")),
        None,
        "ab06bd91-cc16-11e4-8830-0800200c9a66".into(),
        vec![100],
    )
    .expect("temperature should decode");
    let temp = &decoded[0];
    assert_eq!(temp.uint_value, Some(100), "decoding stays lossless");
    assert_eq!(temp.scale, Some(0.5));
    assert_eq!(
        temp.value_offset,
        Some(85.0),
        "without the offset this reading is 85 degrees wrong"
    );

    // Ember liquid state 5 is "heating", not 5.
    let decoded = decode_value(
        Some(read("ember-mug.yaml")),
        None,
        "fc540008-236c-4c94-8fa9-944a3e5353fa".into(),
        vec![5],
    )
    .expect("liquid state should decode");
    assert_eq!(decoded[0].value_label.as_deref(), Some("heating"));
}

/// A characteristic that encrypts or frames its payloads must resolve no
/// control actions, however sendable the command itself looks.
///
/// The encoding gate asks whether a *command* can be encoded; these specs put
/// the obstacle one level up, on the characteristic. shining-mask wraps every
/// write in AES-128-ECB and coolledx length-prefixes, escapes and delimits
/// its frames — neither transform is implemented here, so a slider built on
/// them would write plaintext or unwrapped bytes the device silently drops.
/// Rendering a control that cannot work is worse than rendering none.
///
/// In each spec below the only command-bearing characteristic is the one
/// carrying the transform, so nothing in the spec should resolve an action.
/// An entity left with neither actions nor readable state is dropped from the
/// DTO entirely, so "absent" is as good an answer as "present with none".
#[test]
fn characteristics_needing_unimplemented_transforms_resolve_no_actions() {
    use liberated_bread_core::api::device_api::load_device_spec;

    let cases = [
        ("shining-mask.yaml", "AES-128-ECB"),
        ("shining-glasses.yaml", "AES-128-ECB"),
        ("magic-display.yaml", "AES-128-ECB"),
        ("coolledx-led-sign.yaml", "length-prefix framing"),
        ("autobaba-led-backpack.yaml", "framing"),
        ("nyan-bt-image-controller.yaml", "framing"),
        ("pax-vape.yaml", "OFB encryption"),
    ];

    for (file, transform) in cases {
        let path = assets_dir().join(file);
        let yaml =
            fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
        let dto = load_device_spec(yaml).unwrap_or_else(|e| panic!("{file} should load: {e}"));
        for entity in &dto.entities {
            assert!(
                entity.actions.is_empty(),
                "{file}: '{}' resolved {:?}, but its writes need {transform}, \
                 which this crate does not implement",
                entity.name,
                entity.actions.iter().map(|a| &a.role).collect::<Vec<_>>()
            );
        }
    }
}

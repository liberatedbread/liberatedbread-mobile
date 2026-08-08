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
    assert_eq!(brightness.command_name, "set_brightness");
    assert_eq!((brightness.min, brightness.max), (Some(0.0), Some(100.0)));
    assert_eq!(strip.actions[1].command_name, "set_rgb_color");

    // switchbot: no role map; bot_* names resolve via the suffix fallback,
    // and press resolves alongside the toggle pair.
    let switchbot = load("switchbot-ble.yaml");
    let bot = switchbot
        .entities
        .iter()
        .find(|e| e.name == "Bot Press")
        .expect("switchbot declares a Bot Press switch");
    assert_eq!(roles(bot), vec!["turn_on", "turn_off", "press"]);
    assert_eq!(bot.actions[0].command_name, "bot_turn_on");
    assert_eq!(bot.actions[2].command_name, "bot_press");

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

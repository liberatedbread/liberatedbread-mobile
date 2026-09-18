// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end consumption test: every bundled device spec must parse via the
//! real `parse_device_spec()`.
//!
//! The specs are read from the vendored protocol-specs subtree at test time —
//! the same files `pubspec.yaml` bundles and `rootBundle` ships to the device,
//! since there is no copy under `assets/` — so this test fails loudly if a
//! bundled spec cannot be parsed.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use liberated_bread_core::spec::parser::parse_device_spec;
use liberated_bread_core::spec::types::LocateKind;

/// The bundled spec directories, derived from this crate's manifest dir
/// (`<repo>/rust`) so the test is location-independent.
///
/// Two of them, because that is how upstream is laid out and the app bundles it
/// verbatim: `devices/` is the real catalogue and `examples/` holds the bulb
/// that mock mode and the widget tests depend on. `pubspec.yaml` lists both.
/// The repo root: one level above this crate. Every path in this file hangs
/// off it, so derive it once.
fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust crate should have a parent repo dir")
        .to_path_buf()
}

fn assets_dirs() -> Vec<PathBuf> {
    let repo = repo_root();
    ["devices", "examples"]
        .iter()
        .map(|d| repo.join("vendor/protocol-specs/device-specs").join(d))
        .collect()
}

/// The bundled path of one spec by filename.
///
/// The catalogue is split across `devices/` and `examples/`, so a caller that
/// knows only the filename cannot join a single directory any more. Panics
/// rather than returning an Option: every caller here names a spec that is
/// supposed to ship, and "the file moved" is exactly what these tests exist to
/// notice.
fn spec_path(file: &str) -> PathBuf {
    assets_dirs()
        .into_iter()
        .map(|dir| dir.join(file))
        .find(|p| p.exists())
        .unwrap_or_else(|| panic!("{file} should be bundled under device-specs/"))
}

/// Every `*.yaml` the app bundles.
fn vendored_yaml_paths() -> Vec<PathBuf> {
    let mut paths: Vec<PathBuf> = assets_dirs()
        .into_iter()
        .flat_map(|dir| {
            fs::read_dir(&dir)
                .unwrap_or_else(|e| panic!("{} should exist: {e}", dir.display()))
                .map(|e| e.expect("readable dir entry").path())
        })
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
    // The list is empty, and the two entries it used to hold are why it is
    // worth keeping empty rather than deleting. Both were real authoring
    // errors, both cost their whole spec, and both were a key saying something
    // the schema did not define — seeblue spelled its transport envelope into
    // nine command templates as placeholders no command declared, and
    // fardriver bounded a `bytes` parameter with `min`/`max`, which mean a
    // numeric range that a run of octets does not have. Upstream fixed both
    // (`framing.scheme: seeblue_envelope` owns the envelope bytes now, and
    // `bytes` parameters use `min_length`/`max_length`) and now enforces both
    // rules in `scripts/test_device_specs.py`, so a spec cannot arrive here
    // broken the same way again.
    const KNOWN_BAD: &[&str] = &[];

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
    // The Dart loader is index-driven: it loads exactly the files listed in the
    // subtree's own index.json. An entry with no file behind it means a device
    // silently missing at runtime, and a file with no entry means a spec that is
    // shipped but never loaded. Both are invisible without this check.
    //
    // Since the app dropped its copy under assets/ and bundles the subtree
    // directly, both sides of this comparison come from upstream — so they now
    // drift only when upstream itself is inconsistent, which is exactly the case
    // a consumer cannot see.
    //
    // Upstream builds index.json in CI and commits it on main *after* the spec
    // merge, so any upstream tree that is not a published main commit — the
    // window right after a merge, or any spec branch — carries an index that
    // predates its own specs. A refresh landing there vendors an inconsistent
    // pair and fails here. Both fixes are in the refresh script, neither is an
    // edit to the subtree: refresh again once upstream's index commit exists,
    // or build the index from the vendored specs with
    // `./scripts/update-specs.sh --rebuild-index`.
    let manifest_path = repo_root().join("vendor/protocol-specs/device-specs/index.json");
    let raw = fs::read_to_string(&manifest_path).expect("index.json should exist");

    // Pull `"path": "<repo-relative path>"` out without taking a JSON
    // dependency for a test, then reduce to basenames to compare with the files
    // on disk.
    let listed: Vec<String> = raw
        .split("\"path\"")
        .skip(1)
        .filter_map(|chunk| {
            let start = chunk.find('"')? + 1;
            let rest = &chunk[start..];
            let end = rest.find('"')?;
            Some(rest[..end].rsplit('/').next()?.to_owned())
        })
        .collect();
    assert!(
        !listed.is_empty(),
        "index.json should list spec files via a `path` key"
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
            "`{file}` is vendored but absent from the manifest — it would never \
             load. Upstream's index is published by CI after a spec merges, so \
             a branch or a just-merged main has one that predates its specs: \
             re-run ./scripts/update-specs.sh, or build the index from these \
             specs with ./scripts/update-specs.sh --rebuild-index"
        );
    }
}

/// The vendored milight spec's `night_mode` is the catalogue's one multi-frame
/// command. Pin that the sequence arrives as structured `frames` (two of them,
/// with the 100 ms delay), so a spec refresh that regresses it to the old
/// opaque prose — the shape nothing can ever execute — fails here instead of
/// shipping documentation where data was.
#[test]
fn the_vendored_milight_night_mode_carries_structured_frames() {
    let raw = fs::read_to_string(
        repo_root()
            .join("vendor/protocol-specs/device-specs/devices/limitlessled-milight-bridge.yaml"),
    )
    .expect("the milight spec should be vendored");
    let spec = parse_device_spec(&raw).expect("the vendored milight spec should parse");
    let frames = &spec.commands["night_mode"].frames;
    assert_eq!(frames.len(), 2, "OFF, then OFF|0x80");
    assert_eq!(
        frames[0].delay_after_ms,
        Some(100),
        "the pause between the two frames is part of the protocol"
    );
    assert!(
        frames[1].delay_after_ms.is_none(),
        "nothing follows the last frame"
    );
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
    let asset_path =
        repo_root().join("vendor/protocol-specs/device-specs/examples/example-bulb.yaml");
    let asset = fs::read_to_string(&asset_path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", asset_path.display()));
    let fixture = include_str!("specs/example-bulb.yaml");

    let asset_value: serde_yaml::Value =
        serde_yaml::from_str(&asset).expect("asset should be valid YAML");
    let fixture_value: serde_yaml::Value =
        serde_yaml::from_str(fixture).expect("fixture should be valid YAML");
    assert_eq!(
        asset_value, fixture_value,
        "the bundled example-bulb.yaml and rust/tests/specs/example-bulb.yaml \
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
/// missing — is now enforced against the subtree's `index.json` by
/// `manifest_and_spec_files_agree`, which is the list the loader actually
/// reads. What is left to guard here is a regression back to a hardcoded list.
#[test]
fn dart_loader_does_not_hardcode_spec_filenames() {
    let dart_path = repo_root().join("lib/providers/device_spec_provider.dart");
    let dart_src = fs::read_to_string(&dart_path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", dart_path.display()));

    const PREFIX: &str = "device-specs/";
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
    // when the index is missing or unreadable, so mock mode still works after a
    // broken vendoring. Matched in the repo-relative form the loader now uses,
    // since paths come straight from upstream's index.json.
    hardcoded.remove("examples/example-bulb.yaml");
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
        let path = spec_path(file);
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

    // elk-bledom: the full role set since the spec grew constant on/off
    // frames (the parameterized set_light_on_off's command byte is
    // app-version-dependent and stays unbindable); brightness keeps its
    // spec-declared 0..100 bound.
    let elk = load("elk-bledom-led-strip.yaml");
    let strip = elk
        .entities
        .iter()
        .find(|e| e.name == "LED Strip")
        .expect("elk-bledom declares an LED Strip light");
    assert_eq!(
        roles(strip),
        vec!["turn_on", "turn_off", "set_brightness", "set_color"]
    );
    let brightness = strip
        .actions
        .iter()
        .find(|a| a.role == "set_brightness")
        .expect("the brightness slider resolves");
    assert_eq!(brightness.command_name, Some("set_brightness".to_string()));
    assert_eq!((brightness.min, brightness.max), (Some(0.0), Some(100.0)));
    let color = strip
        .actions
        .iter()
        .find(|a| a.role == "set_color")
        .expect("the color picker resolves");
    assert_eq!(color.command_name, Some("set_rgb_color".to_string()));

    // switchbot: the spec now binds the bot_* commands explicitly (the
    // suffix fallback found the same ones before), and press resolves
    // alongside the toggle pair.
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

    // ember's temperature-control switch: turn_off now binds the confirmed
    // 0x0000 target-temp write (the prose turn_on — "restore previous
    // setpoint" — is client-side statefulness and stays unresolvable), and
    // the state binding with its on_when: nonzero rule is intact.
    let temp_control = ember
        .entities
        .iter()
        .find(|e| e.name == "Temperature Control")
        .expect("ember declares a Temperature Control switch");
    assert_eq!(roles(temp_control), vec!["turn_off"]);
    assert_eq!(
        temp_control.actions[0].command_name.as_deref(),
        Some("set_target_temp_off")
    );
    assert!(temp_control.on_when_nonzero);
    assert!(temp_control.state_characteristic.is_some());

    // ember's charging base: the binary_sensor on-mapping crosses intact.
    let charging = ember
        .entities
        .iter()
        .find(|e| e.name == "Charging Base")
        .expect("ember declares a Charging Base binary_sensor");
    assert_eq!(charging.on_value, Some(1));

    // kingsmith: the treadmill's transport verbs finally live in the entity
    // layer — Start/Stop buttons keyed for the treadmill card, and a Target
    // Speed number in decoded km/h. WiLink's Start binds the vendor frame.
    let pad = load("kingsmith-walkingpad.yaml");
    let start = pad
        .entities
        .iter()
        .find(|e| e.key.as_deref() == Some("start"))
        .expect("kingsmith declares a keyed Start button");
    assert_eq!(start.platform.as_deref(), Some("button"));
    assert!(start
        .actions
        .iter()
        .any(|a| a.role == "press" && a.command_name.as_deref() == Some("start_belt")));
    let speed = pad
        .entities
        .iter()
        .find(|e| e.key.as_deref() == Some("speed") && e.setpoint_max == Some(6.0))
        .expect("the WiLink Target Speed declares its decoded 0-6 km/h clamp");
    assert!(speed.actions.iter().any(|a| a.role == "set_value"));

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
        let path = spec_path(file);
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
        let path = spec_path(file);
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

/// A `string`/`bytes` format field's `length` is a ceiling, and the catalogue
/// says so in as many words: ember-mug's `Mug Name` is `length: 16` with the
/// note "reads five bytes, EMBER ... an upper bound and not a length", and
/// xiaomi-miflora's 0x1a02 "returns variable-length data" with the firmware
/// string at offset 2 of a reply the hardware sends seven bytes long. Both
/// used to decode to `BufferTooShort`, and on the MiFlora that took the
/// battery beside the string down too — the spec's only battery source.
#[test]
fn vendored_variable_length_fields_decode_from_short_replies() {
    use liberated_bread_core::api::device_api::decode_value;

    let read = |file: &str| {
        let path = spec_path(file);
        fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
    };

    let decoded = decode_value(
        Some(read("ember-mug.yaml")),
        None,
        "fc540001-236c-4c94-8fa9-944a3e5353fa".into(),
        b"EMBER".to_vec(),
    )
    .expect("a five-byte name against a sixteen-byte ceiling decodes");
    assert_eq!(decoded[0].string_value.as_deref(), Some("EMBER"));

    let decoded = decode_value(
        Some(read("xiaomi-miflora.yaml")),
        None,
        "00001a02-0000-1000-8000-00805f9b34fb".into(),
        vec![0x63, 0x27, b'3', b'.', b'2', b'.', b'2'],
    )
    .expect("the seven-byte reply the hardware sends decodes");
    let field = |name: &str| {
        decoded
            .iter()
            .find(|d| d.name == name)
            .unwrap_or_else(|| panic!("{name} must be decoded"))
    };
    assert_eq!(field("battery").uint_value, Some(99));
    assert_eq!(
        field("firmware_version").string_value.as_deref(),
        Some("3.2.2")
    );
}

/// xkglow-chrome's `set_rgb_color` declares a fixed `value` AND a
/// parameterised `template`. The template must be the command: the raw
/// browser's zone/red/green/blue controls reach the wire, and the DTO does
/// not call the command fixed while still listing parameters for it.
#[test]
fn the_vendored_xkglow_set_rgb_color_honours_its_parameters() {
    use liberated_bread_core::api::device_api::{encode_command, load_device_spec};
    use std::collections::HashMap;

    let yaml = fs::read_to_string(spec_path("xkglow-chrome.yaml")).expect("spec reads");
    const ZONE_COMMAND: &str = "458a7133-0009-4e37-a4a4-5d8492586977";

    let params = HashMap::from([
        ("zone".to_string(), 3.0),
        ("red".to_string(), 0.0),
        ("green".to_string(), 128.0),
        ("blue".to_string(), 255.0),
    ]);
    let bytes = encode_command(
        Some(yaml.clone()),
        None,
        ZONE_COMMAND.into(),
        "set_rgb_color".into(),
        params,
    )
    .expect("set_rgb_color encodes from its template");
    assert_eq!(
        bytes,
        vec![0x00, 0x03, 0x04, 0x00, 0x80, 0xFF],
        "the caller's zone and colour must reach the wire, not the fixed red"
    );

    let dto = load_device_spec(yaml).expect("xkglow-chrome loads");
    let command = dto
        .services
        .iter()
        .flat_map(|s| &s.characteristics)
        .filter(|c| c.uuid.eq_ignore_ascii_case(ZONE_COMMAND))
        .flat_map(|c| &c.commands)
        .find(|c| c.name == "set_rgb_color")
        .expect("set_rgb_color is on the zone command characteristic");
    assert!(
        !command.is_fixed,
        "a command whose parameters the encoder honours must not be called fixed"
    );
    assert!(command.is_encodable);
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
        let path = spec_path(file);
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

/// The real vendored SmartDawn spec must encode a doodle image frame end to
/// end. This is the regression guard the hand-written daniao unit tests could
/// not be: a stripped test spec once hid that the shipped `doodle_start`
/// template ended in an unencodable `{payload}` param, which broke every image
/// send on real hardware while the unit tests stayed green.
#[test]
fn smartdawn_spec_encodes_a_doodle_frame() {
    use liberated_bread_core::api::device_api::encode_image_frame;

    let yaml = fs::read_to_string(spec_path("smartdawn-smart-lights.yaml"))
        .expect("smartdawn spec should be readable");
    // 20x20 two-colour canvas at frame 0: opens the session (ui_end_sync +
    // doodle_start, both resolved FROM the spec's command templates) then
    // streams a TUTU_RESTORE chunk.
    let mut rgb = vec![0u8; 20 * 20 * 3];
    for i in (0..rgb.len()).step_by(3) {
        rgb[i] = 0x10; // one non-black colour so there are two palette entries
    }
    let plan = encode_image_frame(yaml, 20, 20, rgb, 0, 509)
        .expect("the real smartdawn spec must encode a doodle frame");
    assert!(
        plan.writes.len() >= 3,
        "frame 0 = ui_end_sync + doodle_start + >=1 chunk"
    );
    // The session-open writes go to the DDP command characteristic.
    assert_eq!(
        plan.writes[0].characteristic_uuid,
        "01020074-1972-1925-3022-077119514e44"
    );
}

/// The shipped SmartDawn spec, not the stripped fixture, states its own
/// upload choreography.
///
/// The handler reads `session_open`, the feature's `channel_tag` and the bulk
/// channel's `max_chunk_size`, and falls back to what it used to hardcode when
/// a spec is silent — which means a vendored spec that stopped declaring them
/// would keep working and nothing would say so. This is the test that notices:
/// it asserts the real catalogue still carries the declarations, so the
/// fallbacks stay a compatibility path for older third-party packs rather than
/// quietly becoming the way SmartDawn works again.
#[test]
fn the_vendored_smartdawn_spec_declares_its_own_upload_flow() {
    let spec = parse_device_spec(
        &fs::read_to_string(spec_path("smartdawn-smart-lights.yaml"))
            .expect("smartdawn spec should be readable"),
    )
    .expect("smartdawn spec should parse");

    let feature = spec
        .features
        .iter()
        .find(|f| f.feature_type == "image_upload")
        .expect("smartdawn declares an image_upload feature");
    let session_open = feature
        .session_open
        .as_ref()
        .expect("smartdawn states its opener sequence rather than leaving it to a fallback");
    assert_eq!(
        session_open.as_slice(),
        ["ui_end_sync", "doodle_start"],
        "the opener pair verified on hardware — M_DEV_START blanks the canvas"
    );
    assert_eq!(
        feature.channel_tag,
        Some(0x04),
        "an image upload is a full-canvas redraw, so it writes under TUTU_RESTORE"
    );
    for name in session_open {
        assert!(
            spec.services
                .iter()
                .any(|s| s.characteristics.iter().any(|c| c
                    .commands
                    .as_ref()
                    .is_some_and(|m| m.contains_key(name.as_str())))),
            "session_open names {name:?}, which the spec's commands do not define"
        );
    }

    let bulk = spec
        .services
        .iter()
        .flat_map(|s| &s.characteristics)
        .find(|c| c.uuid.starts_with("02020074"))
        .expect("smartdawn declares the BIN bulk characteristic");
    let framing = bulk.framing.as_ref().expect("BIN declares framing");
    assert_eq!(
        framing.get("max_chunk_size").and_then(|v| v.as_u64()),
        Some(200),
        "the vendor encoder's chunk ceiling belongs in the spec, not the handler"
    );
}

/// The SmartDawn `light` entity resolves power and brightness, and encodes them
/// as FRAMED writes — the whole point of teaching the encodability gate that an
/// implemented `daniao_fragment` scheme is not a blocker. Before that, every
/// command on the DDP Write characteristic was dropped as an unimplemented
/// transform and the light tile had no controls at all.
#[test]
fn smartdawn_light_exposes_framed_power_and_brightness() {
    use liberated_bread_core::api::device_api::{encode_command, load_device_spec};

    let yaml = fs::read_to_string(spec_path("smartdawn-smart-lights.yaml"))
        .expect("smartdawn spec should be readable");

    let dto = load_device_spec(yaml.clone()).expect("smartdawn spec loads");
    let light = dto
        .entities
        .iter()
        .find(|e| e.platform.as_deref() == Some("light"))
        .expect("smartdawn declares a light entity");
    let roles: Vec<&str> = light.actions.iter().map(|a| a.role.as_str()).collect();
    for role in ["turn_on", "turn_off", "set_brightness"] {
        assert!(
            roles.contains(&role),
            "the light must resolve {role} now that daniao_fragment is honoured; got {roles:?}"
        );
    }

    // And the resolved power command encodes to a fragment-framed packet, not
    // raw template bytes the controller would ignore.
    let turn_on = light
        .actions
        .iter()
        .find(|a| a.role == "turn_on")
        .expect("resolved above");
    let bytes = encode_command(
        Some(yaml),
        Some(turn_on.service_uuid.clone()),
        turn_on.characteristic_uuid.clone(),
        turn_on
            .command_name
            .clone()
            .expect("power_on names a command"),
        std::collections::HashMap::new(),
    )
    .expect("power_on encodes now that the framing scheme is implemented");
    // 4-byte fragment header [serial, total, remaining, tag] then F0 04 …; the
    // power-on mt (09 D2) sits at DNX offset 6 -> whole-packet offset 10.
    assert_eq!(
        &bytes[0..4],
        &[0, 1, 0, 0],
        "fragment header wraps the command"
    );
    assert_eq!(bytes[4], 0xF0, "DNX flag follows the fragment header");
    assert_eq!(&bytes[10..12], &[0x09, 0xD2], "M_SET_POWERON");
}

/// The catalogue's own uses of the keys this app newly honours.
///
/// Each of these was carrying real information that reached nothing: the
/// endianness declarations were written into a key the BLE schema did not
/// define, Gerbing's icons and Hotwired's precision had no consumer, and the
/// two locator commands were found — when they were found — by matching on
/// their names. Pinning them against the vendored catalogue rather than a
/// fixture is the point: a hand-written fixture would keep passing after an
/// upstream refresh dropped the key.
#[test]
fn vendored_specs_exercise_the_newly_honoured_keys() {
    let read = |name: &str| {
        let path = spec_path(name);
        parse_device_spec(
            &fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("reading {}: {e}", path.display())),
        )
        .unwrap_or_else(|e| panic!("{name} should parse: {e:?}"))
    };

    // xiaomi-miflora states `endianness: little` on five fields. All little,
    // so the reading is the same either way — what matters is that the key
    // now parses into something the decoder consults rather than being
    // dropped on the floor.
    let miflora = read("xiaomi-miflora.yaml");
    let (_, realtime) = miflora
        .find_decodable_characteristic("00001a01-0000-1000-8000-00805f9b34fb")
        .expect("miflora declares the realtime sensor characteristic");
    let fields = realtime.format.as_ref().expect("format block");
    let stated: Vec<_> = fields.iter().filter(|f| f.endianness.is_some()).collect();
    assert!(
        !stated.is_empty(),
        "miflora should still declare endianness on its multi-byte fields"
    );
    for field in stated {
        assert!(
            !field.is_big_endian(),
            "{} is big-endian upstream now; the decoder handles it, but the \
             reading it produces has changed and wants checking",
            field.name
        );
    }

    // gerbing-thermogauge asks for an icon on its heat levels: `number`
    // entities with no device_class that implies a heater.
    let gerbing = read("gerbing-thermogauge.yaml");
    let iconed: Vec<_> = gerbing
        .entities
        .iter()
        .filter(|e| e.icon.is_some())
        .collect();
    assert!(
        !iconed.is_empty(),
        "gerbing should still declare entity icons"
    );
    assert!(
        iconed
            .iter()
            .all(|e| e.icon.as_deref() == Some("mdi:heat-wave")),
        "gerbing's icons changed upstream; check lib/core/entity_icon.dart \
         maps the new name"
    );

    // hotwired-heated-gear declares precision on its climate control.
    let hotwired = read("hotwired-heated-gear.yaml");
    assert!(
        hotwired.entities.iter().any(|e| e.precision.is_some()),
        "hotwired should still declare entity precision"
    );

    // The two commands upstream marks as locators. Both must stay FIXED:
    // a find button is one tap, so a command needing a user-supplied
    // parameter cannot be offered as one however it is labelled.
    for (file, uuid, command, kind) in [
        (
            "xiaomi-miflora.yaml",
            "00001a00-0000-1000-8000-00805f9b34fb",
            "blink_led",
            LocateKind::Flash,
        ),
        (
            "m6-fitness-band.yaml",
            "6e400002-b5a3-f393-e0a9-e50e24dcca9d",
            "find_me",
            LocateKind::Both,
        ),
    ] {
        let spec = read(file);
        let (_, characteristic) = spec
            .find_characteristic(uuid)
            .unwrap_or_else(|| panic!("{file} should declare {uuid}"));
        let cmd = &characteristic
            .commands
            .as_ref()
            .unwrap_or_else(|| panic!("{file}: {uuid} should carry commands"))[command];
        assert_eq!(
            cmd.locate_kind(),
            Some(kind),
            "{file}: {command} should still declare itself a {kind:?} locator"
        );
        assert!(
            cmd.value.is_some(),
            "{file}: {command} must stay a fixed command — a locator is one \
             tap, with no user to supply parameters"
        );
    }
}

/// Two specs this branch made parseable must not reach the UI as ordinary
/// sendable commands.
///
/// Both were unreachable before — the specs did not parse at all — so making
/// them load is exactly when the question arises. Neither can be encoded by
/// this crate today, and the failure mode differs: seeblue's templates are the
/// packet, with the SEEBlue envelope (header, length, sequence, protocol id,
/// checksum) belonging to the characteristic, so raw bytes reach the device as
/// a packet it will not answer. Fardriver's `data` is 1-26 raw octets, and the
/// FFI carries parameters as f64, so there is no value to send at all.
///
/// The rule is the same either way: a command the encoder cannot produce must
/// report itself unencodable rather than enabling a Send that fails — or worse,
/// one that succeeds into malformed bytes.
#[test]
fn specs_this_branch_unlocked_do_not_offer_commands_that_cannot_encode() {
    use liberated_bread_core::codec::types::unsupported_write_kind;

    let read = |name: &str| {
        parse_device_spec(&fs::read_to_string(spec_path(name)).expect("readable"))
            .unwrap_or_else(|e| panic!("{name} should parse: {e:?}"))
    };

    // Every seeblue command sits behind the envelope, so none is sendable raw.
    let seeblue = read("seeblue-motorcycle-led.yaml");
    let mut checked = 0;
    for service in &seeblue.services {
        for characteristic in &service.characteristics {
            let Some(commands) = characteristic.commands.as_ref() else {
                continue;
            };
            for (name, command) in commands {
                let reason = unsupported_write_kind(characteristic, command);
                assert!(
                    reason
                        .as_deref()
                        .is_some_and(|r| r.contains("seeblue_envelope")),
                    "seeblue {name} must be gated by its characteristic's framing, got {reason:?}"
                );
                checked += 1;
            }
        }
    }
    assert!(
        checked >= 30,
        "expected seeblue's full command set, saw {checked}"
    );

    // Fardriver's frame carries a raw byte payload the FFI cannot express.
    let fardriver = read("fardriver-controller.yaml");
    let (_, characteristic) = fardriver
        .find_writable_characteristic("0000ffe1-0000-1000-8000-00805f9b34fb")
        .or_else(|| {
            fardriver.services.iter().find_map(|s| {
                s.characteristics
                    .iter()
                    .find(|c| {
                        c.commands
                            .as_ref()
                            .is_some_and(|m| m.contains_key("write_parameter"))
                    })
                    .map(|c| (s, c))
            })
        })
        .expect("fardriver declares write_parameter somewhere");
    let command = &characteristic.commands.as_ref().unwrap()["write_parameter"];
    let reason = unsupported_write_kind(characteristic, command);
    assert!(
        reason.as_deref().is_some_and(|r| r.contains("data")),
        "write_parameter must name the byte parameter it cannot carry, got {reason:?}"
    );

    // The gate is not a blanket "nothing encodes": a plain templated command on
    // an unframed characteristic is still offered.
    let miflora = read("xiaomi-miflora.yaml");
    let (_, blink_char) = miflora
        .find_writable_characteristic("00001a00-0000-1000-8000-00805f9b34fb")
        .expect("miflora's mode-change characteristic");
    let blink = &blink_char.commands.as_ref().unwrap()["blink_led"];
    assert_eq!(unsupported_write_kind(blink_char, blink), None);
}

/// Six vendored specs declare an `initialization` handshake, and until this
/// branch every one of them was parsed to nowhere: `Service` had no field for
/// the per-service blocks, and the top-level ones sat in `extensions`.
///
/// Driven against the real files because the whole failure was that the
/// catalogue said something nothing read.
#[test]
fn the_vendored_handshakes_reach_the_connect_time_api() {
    use liberated_bread_core::api::device_api::spec_ble_handshake;

    let yaml = |file: &str| {
        fs::read_to_string(spec_path(file)).unwrap_or_else(|e| panic!("reading {file}: {e}"))
    };

    // SpotLED: three fixed writes to the command characteristic, in order,
    // addressed to the service that declares it.
    let spotled =
        spec_ble_handshake(yaml("spotled-led-panel.yaml")).expect("spotled's handshake resolves");
    assert_eq!(spotled.steps.len(), 3, "spotled declares three writes");
    assert!(
        spotled.steps.iter().all(|s| s.write.is_some()
            && s.service_uuid.as_deref() == Some("0000ff20-0000-1000-8000-00805f9b34fb")),
        "every spotled step is an addressed write, got {:?}",
        spotled.steps
    );
    assert_eq!(
        spotled.steps[0].write.as_deref(),
        Some(&[0x00, 0x00, 0x00, 0x01][..])
    );

    // SmartDawn: two subscriptions, opened before anything is sent.
    let smartdawn = spec_ble_handshake(yaml("smartdawn-smart-lights.yaml"))
        .expect("smartdawn's handshake resolves");
    assert_eq!(smartdawn.steps.len(), 2);
    assert!(smartdawn
        .steps
        .iter()
        .all(|s| s.subscribe && s.write.is_none()));

    // Hyperice declares its one step at the TOP level, upper-case, and the
    // service is resolved from the spec's own characteristic list.
    let hyperice = spec_ble_handshake(yaml("hyperice-hypervolt-plus.yaml"))
        .expect("hyperice's handshake resolves");
    assert_eq!(hyperice.steps.len(), 1);
    assert!(hyperice.steps[0].read);
    assert_eq!(
        hyperice.steps[0].service_uuid.as_deref(),
        Some("31cb4500-3c31-4e56-8c2b-e8f479d2b056")
    );

    // Schlage's session resumption is a fresh SPAKE2 exchange per connect,
    // stated in prose: reported, never executed.
    let schlage =
        spec_ble_handshake(yaml("schlage-smart-locks.yaml")).expect("schlage's handshake resolves");
    assert_eq!(schlage.steps.len(), 1, "only the RxData read is executable");
    assert_eq!(
        schlage.described.len(),
        4,
        "the four procedural steps must be reported, not dropped: {:?}",
        schlage.described
    );

    // And the overwhelming majority declares none, so a connect pays nothing.
    let bulb = spec_ble_handshake(yaml("example-bulb.yaml")).expect("the example bulb resolves");
    assert!(bulb.steps.is_empty() && bulb.described.is_empty());
}

/// The ratgdo fleet spans an ESPHome change in how a URL names an entity, so
/// its spec states two paths per action and two topics per reading. Both have
/// to reach the rendered request, or every board on firmware up to 2025.12
/// answers 404 to every tap and every state read.
///
/// Against the real vendored file, because the point is that the CATALOGUE's
/// pairs survive parsing and rendering — a spec edit upstream that drops a
/// `path_fallback`, or a parser that stops reading the key, has to fail here.
#[test]
fn the_vendored_ratgdo_renders_both_spellings_of_its_paths() {
    use liberated_bread_core::api::device_api::{
        render_network_http_command, render_network_http_state_request,
    };

    let yaml =
        || fs::read_to_string(spec_path("ratgdo.yaml")).expect("ratgdo.yaml should be readable");

    let open = render_network_http_command(yaml(), "door_open".into(), Default::default())
        .expect("ratgdo's door_open renders");
    assert_eq!(open.path, "/cover/Door/open");
    assert_eq!(
        open.path_fallback.as_deref(),
        Some("/cover/door/open"),
        "the legacy object_id spelling must ride along, or a pre-2026 board \
         404s on every Open"
    );

    // The state read takes the same pair, off the entity rather than the
    // command: `state_topic` here names a path on the board's own web server.
    let state = render_network_http_state_request(yaml(), "/cover/Door".into(), Default::default())
        .expect("ratgdo's cover state renders");
    assert_eq!(state.path, "/cover/Door");
    assert_eq!(state.path_fallback.as_deref(), Some("/cover/door"));

    // Every ratgdo command states its pair, percent-encoding and all.
    let lock = render_network_http_command(yaml(), "lock_remotes".into(), Default::default())
        .expect("ratgdo's lock_remotes renders");
    assert_eq!(lock.path, "/lock/Lock%20remotes/lock");
    assert_eq!(
        lock.path_fallback.as_deref(),
        Some("/lock/lock_remotes/lock")
    );

    // A spec that states one path gets ONE candidate — nothing may invent a
    // second, because a blind retry is a device that acts twice.
    let roku = fs::read_to_string(spec_path("roku-ecp.yaml")).expect("roku-ecp.yaml readable");
    let keypress = render_network_http_command(roku, "press_power_on".into(), Default::default())
        .expect("roku's power keypress renders");
    assert_eq!(keypress.path, "/keypress/PowerOn");
    assert_eq!(keypress.path_fallback, None);
}

/// The network control surface against the real catalogue: the ratgdo garage
/// door — one of the three `integration: supported` specs — resolves its
/// cover, and an `identify_only` spec resolves an EMPTY surface however many
/// entities it declares.
#[test]
fn vendored_specs_resolve_the_network_surface_honestly() {
    use liberated_bread_core::api::device_api::{
        network_capabilities, network_entities_for_device,
    };

    let yaml = |file: &str| {
        let path = spec_path(file);
        fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()))
    };

    // ratgdo: the stateless cover is admitted on its fixed motions and
    // resolves the full role set over plain HTTP POST.
    let surface = network_entities_for_device(yaml("ratgdo.yaml"), vec![])
        .expect("ratgdo resolves a surface");
    let door = surface
        .entities
        .iter()
        .find(|e| e.name == "Garage Door")
        .expect("ratgdo's Garage Door must be on the surface");
    let roles: Vec<&str> = door.actions.iter().map(|a| a.role.as_str()).collect();
    assert_eq!(
        roles,
        vec![
            "open_cover",
            "close_cover",
            "stop_cover",
            "set_cover_position"
        ]
    );
    assert!(door.actions.iter().all(|a| a.transport == "http"));

    // lutron-caseta declares descriptive entities with prose role bindings,
    // and is identify_only: the surface must be empty with every declared
    // entity counted hidden — a spec edit upstream cannot leak controls
    // past the handoff page.
    let lutron = network_entities_for_device(yaml("lutron-caseta-smart-bridge.yaml"), vec![])
        .expect("lutron resolves");
    assert!(lutron.entities.is_empty());
    assert!(
        !lutron.hidden_names.is_empty(),
        "lutron's declared entities must be counted, not vanished"
    );

    // roku: the ecp2 block's presence is the signed-session capability, and
    // control is definitionally on 8060.
    let roku = network_capabilities(yaml("roku-ecp.yaml")).expect("roku capabilities");
    assert_eq!(roku.signed_session.as_deref(), Some("ecp2"));
    assert_eq!(roku.default_port, Some(8060));
    assert_eq!(roku.default_scheme, None);
}

/// The catalogue's HTTP writes are mostly declared as a literal `body:` with
/// no `arguments:` — WLED, Valetudo, Bose SoundTouch, Divoom — and for a long
/// time the renderer never read that field: every one of those controls was
/// offered, and every press POSTed an empty body. This drives the real files.
#[test]
fn vendored_literal_http_bodies_render_filled_not_empty() {
    use liberated_bread_core::protocol::http;
    use liberated_bread_core::spec::parser::parse_device_spec;
    use std::collections::BTreeMap;

    let spec = |file: &str| {
        let path = spec_path(file);
        let yaml =
            fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
        parse_device_spec(&yaml).unwrap_or_else(|e| panic!("{file} parses: {e}"))
    };
    let values = |pairs: &[(&str, &str)]| -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect()
    };

    // WLED: a fixed JSON body, and a `uint8` placeholder in numeric position
    // that must render as a number.
    let wled = spec("wled-controller.yaml");
    let on = http::render_request(&wled, "turn_on", &values(&[])).expect("turn_on renders");
    assert_eq!(on.method, "POST");
    assert_eq!(on.path, "/json/state");
    assert_eq!(on.body, r#"{"on": true}"#);
    let bri = http::render_request(&wled, "set_brightness", &values(&[("brightness", "100")]))
        .expect("set_brightness renders");
    assert_eq!(bri.body, r#"{"bri": 100}"#);
    let fx = http::render_request(&wled, "set_effect", &values(&[("effect", "12")]))
        .expect("set_effect renders");
    assert_eq!(fx.body, r#"{"seg": [{"id": 0, "fx": 12}]}"#);

    // Valetudo: a fixed JSON body on a PUT.
    let valetudo = spec("valetudo.yaml");
    let start = http::render_request(&valetudo, "start", &values(&[])).expect("start renders");
    assert_eq!(start.body, r#"{"action":"start"}"#);

    // Bose SoundTouch: XML bodies, fixed and with an integer placeholder.
    let bose = spec("bose-soundtouch.yaml");
    let power = http::render_request(&bose, "power", &values(&[])).expect("power renders");
    assert_eq!(
        power.body,
        r#"<key state="press" sender="Gabbo">POWER</key>"#
    );
    let volume = http::render_request(&bose, "set_volume", &values(&[("level", "30")]))
        .expect("set_volume renders");
    assert_eq!(volume.body, "<volume>30</volume>");
}

/// The vendored iDotMatrix spec now reports its image uploads encodable.
///
/// This is the DTO the editor keys off: `encodable` must flip to true the
/// moment the registry carries `idotmatrix_image` — with the spec's own
/// declared bounds — and the encode path must actually produce a plan from
/// the REAL vendored spec, not just from the handler's test fixture (the
/// lesson of the smartdawn stripped-fixture regression above).
#[test]
fn vendored_idotmatrix_spec_is_encodable_with_its_declared_bounds() {
    use liberated_bread_core::api::device_api::{encode_image_frame, load_device_spec};

    let yaml = fs::read_to_string(spec_path("idotmatrix.yaml"))
        .expect("idotmatrix spec should be readable");
    let dto = load_device_spec(yaml.clone()).expect("idotmatrix spec loads");
    let img = dto
        .image_upload
        .expect("idotmatrix declares an image_upload feature");
    assert_eq!(img.handler.as_deref(), Some("idotmatrix_image"));
    assert!(img.encodable, "idotmatrix_image is implemented now");
    assert_eq!((img.max_width, img.max_height), (Some(64), Some(64)));
    assert_eq!(img.format.as_deref(), Some("png"));

    // And the real spec encodes: frame 0 = enter_diy_mode + the framed
    // upload, every write on the 0xFA02 Write Data characteristic, inside
    // the 0xFA02 service.
    let plan = encode_image_frame(yaml, 16, 16, vec![0x20; 16 * 16 * 3], 0, 509)
        .expect("the vendored idotmatrix spec must encode a framed image");
    assert_eq!(plan.service_uuid, "0000fa02-0000-1000-8000-00805f9b34fb");
    assert!(plan.writes.len() >= 2, "opener + at least one framed slice");
    assert!(plan
        .writes
        .iter()
        .all(|w| w.characteristic_uuid == "0000fa02-0000-1000-8000-00805f9b34fb"));
    assert_eq!(
        plan.writes[0].bytes,
        vec![0x05, 0x00, 0x04, 0x01, 0x01],
        "the DIY opener's bytes come from the spec's enter_diy_mode template"
    );
}

/// The vendored LED name badge spec now reports its image uploads encodable.
///
/// Same gate as the iDotMatrix test above: the DTO's `encodable` must flip
/// with the registry, carrying the spec's declared bounds (max_height only —
/// badge width is variable by design), and the REAL vendored spec must
/// encode: raw 16-byte chunks on the FEE1 Badge Data characteristic, opening
/// with the header magic the spec's own `write_badge_data` value declares.
#[test]
fn vendored_led_badge_spec_is_encodable_with_its_declared_bounds() {
    use liberated_bread_core::api::device_api::{encode_image_frame, load_device_spec};

    let yaml = fs::read_to_string(spec_path("bluetooth-led-name-badge.yaml"))
        .expect("badge spec should be readable");
    let dto = load_device_spec(yaml.clone()).expect("badge spec loads");
    let img = dto
        .image_upload
        .expect("the badge declares an image_upload feature");
    assert_eq!(img.handler.as_deref(), Some("ledbadge_bitmap"));
    assert!(img.encodable, "ledbadge_bitmap is implemented now");
    assert_eq!((img.max_width, img.max_height), (None, Some(16)));
    assert_eq!(img.format.as_deref(), Some("1bit-bitmap"));

    let plan = encode_image_frame(yaml, 44, 11, vec![0xFF; 44 * 11 * 3], 0, 509)
        .expect("the vendored badge spec must encode a bitmap transfer");
    assert_eq!(plan.service_uuid, "0000fee0-0000-1000-8000-00805f9b34fb");
    assert!(plan
        .writes
        .iter()
        .all(|w| w.characteristic_uuid == "0000fee1-0000-1000-8000-00805f9b34fb"));
    assert!(
        plan.writes.iter().all(|w| w.bytes.len() == 16),
        "the spec's framing.max_chunk_size drives the raw 16-byte chunks"
    );
    // 64-byte header (4 chunks) + 6 stripes x 11 rows = 66 bytes (5 chunks).
    assert_eq!(plan.writes.len(), 9);
    assert_eq!(&plan.writes[0].bytes[..4], b"wang");
}

/// The vendored cat printer spec now reports its image uploads encodable.
///
/// This one is also the gate on the parser's device-nested tolerance:
/// cat-printer.yaml declares `features` and `protocol_handler` under
/// `device:`, so until they were hoisted the spec loaded with no image
/// capability at all — a declared printer rendered as a device with no
/// pixel surface. The DTO must carry the handler and the 384-dot paper
/// bound, and the REAL spec must encode a job onto the 0xAE01 TX
/// characteristic of the identifying 0xAE30 service.
#[test]
fn vendored_cat_printer_spec_is_encodable_with_its_declared_bounds() {
    use liberated_bread_core::api::device_api::{encode_image_frame, load_device_spec};

    let yaml = fs::read_to_string(spec_path("cat-printer.yaml"))
        .expect("cat printer spec should be readable");
    let dto = load_device_spec(yaml.clone()).expect("cat printer spec loads");
    let img = dto
        .image_upload
        .expect("the cat printer declares an image_upload feature (under device:)");
    assert_eq!(img.handler.as_deref(), Some("cat_printer"));
    assert!(img.encodable, "cat_printer is implemented now");
    assert_eq!((img.max_width, img.max_height), (Some(384), Some(65535)));
    assert_eq!(img.format.as_deref(), Some("1bit-bitmap"));

    let plan = encode_image_frame(yaml, 384, 4, vec![0x00; 384 * 4 * 3], 0, 509)
        .expect("the vendored cat printer spec must encode a print job");
    assert_eq!(plan.service_uuid, "0000ae30-0000-1000-8000-00805f9b34fb");
    assert!(plan
        .writes
        .iter()
        .all(|w| w.characteristic_uuid == "0000ae01-0000-1000-8000-00805f9b34fb"));
    // The stream opens with the get_device_state frame the sequence starts
    // on, and its 12 fixed frames + 4 rows are the logical packet count.
    assert_eq!(
        &plan.writes[0].bytes[..9],
        &[0x51, 0x78, 0xA3, 0x00, 0x01, 0x00, 0x00, 0x00, 0xFF]
    );
    assert_eq!(plan.next_frame_index, 16);
}

/// The vendored Fichero / AiYin D11 spec now reports its image uploads
/// encodable.
///
/// Same gate as the cat printer above, and the same device-nested tolerance:
/// this spec declares `features` and `protocol_handler` under `device:` too.
/// The DTO must carry the handler and the 96-dot printhead bound, and the
/// REAL spec must encode a job onto the 0x2AF1 write characteristic of the
/// 0x18F0 service it identifies the printer by — never onto the vendor-app
/// 0xFF00 service, which carries a write characteristic of its own.
#[test]
fn vendored_fichero_d11_spec_is_encodable_with_its_declared_bounds() {
    use liberated_bread_core::api::device_api::{encode_image_frame, load_device_spec};

    let yaml = fs::read_to_string(spec_path("fichero-d11-printer.yaml"))
        .expect("fichero spec should be readable");
    let dto = load_device_spec(yaml.clone()).expect("fichero spec loads");
    let img = dto
        .image_upload
        .expect("the D11 declares an image_upload feature (under device:)");
    assert_eq!(img.handler.as_deref(), Some("fichero_d11"));
    assert!(img.encodable, "fichero_d11 is implemented now");
    assert_eq!((img.max_width, img.max_height), (Some(96), Some(65535)));
    assert_eq!(img.format.as_deref(), Some("1bit-bitmap"));

    let plan = encode_image_frame(yaml, 96, 4, vec![0x00; 96 * 4 * 3], 0, 509)
        .expect("the vendored D11 spec must encode a print job");
    assert_eq!(plan.service_uuid, "000018f0-0000-1000-8000-00805f9b34fb");
    assert!(plan
        .writes
        .iter()
        .all(|w| w.characteristic_uuid == "00002af1-0000-1000-8000-00805f9b34fb"));
    // The stream opens with the AiYin density opcode the documented sequence
    // starts on, and the seven steps are the logical packet count however
    // many BLE writes carry them.
    assert_eq!(
        &plan.writes[0].bytes[..9],
        &[0x10, 0xFF, 0x10, 0x00, 0x01, 0x10, 0xFF, 0x84, 0x00]
    );
    assert_eq!(plan.next_frame_index, 7);
    // 96 dots = 12 bytes/row, so the GS v 0 header states 0C 00 rows of 4.
    let stream: Vec<u8> = plan
        .writes
        .iter()
        .flat_map(|w| w.bytes.iter().copied())
        .collect();
    let at = stream
        .windows(3)
        .position(|w| w == [0x1D, 0x76, 0x30])
        .expect("the raster header is in the stream");
    assert_eq!(
        &stream[at..at + 8],
        &[0x1D, 0x76, 0x30, 0x00, 0x0C, 0x00, 0x04, 0x00]
    );
}

/// The vendored Magic Display spec now reports its image uploads encodable.
///
/// Same gate as the handlers above, with one extra thing worth pinning from
/// the REAL spec: this transfer is encrypted, so a regression that lost the
/// cipher would still produce a plausible-looking plan. The assertions below
/// decrypt the plan with the key the spec itself records, which fails both
/// ways — plaintext on the wire, or the wrong key.
#[test]
fn vendored_magic_display_spec_is_encodable_with_its_declared_bounds() {
    use aes::cipher::{BlockDecrypt, KeyInit};
    use liberated_bread_core::api::device_api::{encode_image_frame, load_device_spec};

    let yaml = fs::read_to_string(spec_path("magic-display.yaml"))
        .expect("magic display spec should be readable");
    let dto = load_device_spec(yaml.clone()).expect("magic display spec loads");
    let img = dto
        .image_upload
        .expect("Magic Display declares an image_upload feature");
    assert_eq!(img.handler.as_deref(), Some("cdbwsoft_ecb"));
    assert!(img.encodable, "cdbwsoft_ecb is implemented now");
    assert_eq!((img.max_width, img.max_height), (Some(64), Some(16)));
    assert_eq!(img.format.as_deref(), Some("1bit-bitmap"));

    // A full 64x16 panel frame: DATS on WRITE1, nine bitmap blocks on
    // WRITE2, DATCP back on WRITE1 — every packet one 16-byte cipher block.
    let plan = encode_image_frame(yaml, 64, 16, vec![0xFF; 64 * 16 * 3], 0, 509)
        .expect("the vendored Magic Display spec must encode a bitmap transfer");
    assert_eq!(plan.service_uuid, "0000fee9-0000-1000-8000-00805f9b34fb");
    assert_eq!(plan.writes.len(), 11);
    assert!(plan.writes.iter().all(|w| w.bytes.len() == 16));
    let channels: Vec<&str> = plan
        .writes
        .iter()
        .map(|w| w.characteristic_uuid.as_str())
        .collect();
    assert_eq!(channels[0], "d44bc439-abfd-45a2-b575-925416129600");
    assert_eq!(*channels.last().unwrap(), channels[0]);
    assert!(channels[1..10]
        .iter()
        .all(|u| *u == "d44bc439-abfd-45a2-b575-92541612960a"));

    // The spec's own static key, decrypting the spec's own framing commands.
    let key: [u8; 16] = [
        0x34, 0x52, 0x2A, 0x5B, 0x7A, 0x6E, 0x49, 0x2C, 0x08, 0x09, 0x0A, 0x9D, 0x8D, 0x2A, 0x23,
        0xF8,
    ];
    let decrypt = |bytes: &[u8]| {
        let mut block = [0u8; 16];
        block.copy_from_slice(bytes);
        aes::Aes128::new(&key.into()).decrypt_block((&mut block).into());
        block
    };
    // DATS states 128 bytes big-endian: 64 columns x 2 bytes, the byte count
    // the vendored doc's display-type table gives for STYPE16X64.
    assert_eq!(
        decrypt(&plan.writes[0].bytes)[..9],
        [0x08, b'D', b'A', b'T', b'S', 0x00, 0x80, 0x00, 0x00]
    );
    assert_eq!(
        decrypt(&plan.writes[10].bytes)[..6],
        [0x05, b'D', b'A', b'T', b'C', b'P']
    );
    assert_eq!(plan.next_frame_index, 11);
}

/// The sibling on the same handler stays out of the editor.
///
/// `shining-glasses.yaml` declares `protocol_handler: cdbwsoft_ecb` but no
/// `image_upload` feature — and its DATS is a different shape (a 9-byte
/// frame with a second length pair and a type byte, then UNENCRYPTED indexed
/// frames with REOK per frame). Registering the handler must not hand the
/// glasses the Magic Display's bytes: with no feature declared there is no
/// pixel surface at all, and that is the state this pins.
#[test]
fn the_shining_glasses_sibling_declares_no_pixel_surface_to_encode() {
    use liberated_bread_core::api::device_api::load_device_spec;

    let yaml = fs::read_to_string(spec_path("shining-glasses.yaml"))
        .expect("shining glasses spec should be readable");
    let dto = load_device_spec(yaml).expect("shining glasses spec loads");
    assert!(
        dto.image_upload.is_none(),
        "the glasses declare no image_upload feature; their transfer framing \
         differs from the Magic Display's and is not implemented"
    );
}

/// The two places the schema puts an mDNS service type, held together.
///
/// `device.identification.mdns_service_type` and every
/// `device.discovery.methods[].mdns.service_type` state the same kind of fact,
/// and the matcher used to read only the first. Most of the catalogue writes
/// only the second: the scan's DNS-SD meta-query found those devices on the
/// wire, nothing matched them to a spec, and they listed as unrecognised hosts
/// with no controls — a Xiaomi on `_miio._udp`, a Parrot drone on
/// `_arsdk._udp`, a Caséta bridge on `_lutron._tcp`, sixteen more whose only
/// type is `_http._tcp`. A spec that follows the schema and writes its type
/// where the schema puts it got nothing for it.
///
/// This walks the raw YAML rather than the parsed spec deliberately. It is the
/// only assertion that can catch the two blocks drifting apart again, because
/// it re-derives what the FILES say and holds the DTO to exactly that — no
/// more (a type nobody declared would be a query on the wire for nothing) and
/// no less.
#[test]
fn every_vendored_spec_reports_the_mdns_types_from_both_blocks() {
    use liberated_bread_core::api::device_api::load_device_spec;
    use liberated_bread_core::spec::types::normalize_service_type;

    let stems = |types: Vec<&str>| -> BTreeSet<String> {
        types
            .into_iter()
            .map(normalize_service_type)
            .filter(|stem| !stem.is_empty())
            .collect()
    };

    let mut gained: Vec<String> = Vec::new();
    for path in vendored_yaml_paths() {
        let name = path
            .file_name()
            .map(|f| f.to_string_lossy().into_owned())
            .unwrap_or_default();
        let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("{name}: {e}"));
        let doc: serde_yaml::Value =
            serde_yaml::from_str(&text).unwrap_or_else(|e| panic!("{name}: {e}"));
        let Some(device) = doc.get("device") else {
            continue;
        };

        let from_identification: Vec<&str> = device
            .get("identification")
            .and_then(|i| i.get("mdns_service_type"))
            .and_then(|t| t.as_str())
            .into_iter()
            .collect();
        let from_discovery: Vec<&str> = device
            .get("discovery")
            .and_then(|d| d.get("methods"))
            .and_then(|m| m.as_sequence())
            .into_iter()
            .flatten()
            .filter(|method| method.get("type").and_then(|t| t.as_str()) == Some("mdns"))
            .filter_map(|method| method.get("mdns")?.get("service_type")?.as_str())
            .collect();

        let declared = stems(
            from_identification
                .iter()
                .chain(from_discovery.iter())
                .copied()
                .collect(),
        );
        let dto = load_device_spec(text).unwrap_or_else(|e| panic!("{name}: {e}"));
        let reported = stems(dto.mdns_service_types.iter().map(String::as_str).collect());
        assert_eq!(
            reported, declared,
            "{name} must report every mDNS type it declares, from either block"
        );

        if declared.len() > stems(from_identification).len() {
            gained.push(name);
        }
    }

    // A floor, not an exact list — the catalogue arrives by subtree pull and
    // grows. It is here so the assertion above cannot pass vacuously: an
    // implementation that read the identification block alone would still
    // satisfy `reported == declared` on every spec that names its type there,
    // and only this count notices that a third of the catalogue went missing.
    assert!(
        gained.len() >= 30,
        "the discovery block should be carrying the type for ~34 specs, got {}: {gained:?}",
        gained.len()
    );
}

/// The discovery matchers, against the real catalogue: a platform's service
/// type belongs to whichever spec the device's TXT records name, and to the
/// catch-all only when none of them does.
///
/// This is the bug the ESPHome spec was written for. `_esphomelib._tcp` is
/// the FIRMWARE's service type, so with ratgdo the only claimant every
/// ESPHome node on the LAN rendered as a garage-door opener — complete with
/// open/close controls pointing at entities the node does not have.
#[test]
fn vendored_specs_narrow_a_platform_service_type_by_its_txt_records() {
    use liberated_bread_core::api::device_api::{
        load_device_spec, match_network_device, NetworkDeviceDto, SpecIdentityDto,
    };
    use std::collections::HashMap;

    let identity = |file: &str| {
        let path = spec_path(file);
        let yaml =
            fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
        SpecIdentityDto::from(&load_device_spec(yaml).unwrap_or_else(|e| panic!("{file}: {e}")))
    };
    // Order matters not at all to the rule, but listing the product spec
    // first proves the catch-all is stepped aside from deliberately rather
    // than merely out-ranked.
    let catalogue = vec![identity("ratgdo.yaml"), identity("esphome-device.yaml")];

    let node = |project: &str| NetworkDeviceDto {
        name: "garage".into(),
        hostname: Some("garage.local".into()),
        service_types: vec!["_esphomelib._tcp.local.".into()],
        ssdp_targets: vec![],
        answered_lan_protocols: vec![],
        port: Some(6053),
        txt: HashMap::from([("project_name".to_string(), project.to_string())]),
        mac: None,
    };
    let named = |device: NetworkDeviceDto| -> Vec<String> {
        match_network_device(catalogue.clone(), device)
            .into_iter()
            .map(|m| m.device_name)
            .collect()
    };

    // A ratgdo board: its project_name carries the prefix ratgdo's spec
    // matches on, so the garage-door spec claims it and the catch-all stands
    // aside.
    let ratgdo = named(node("ratgdo.v25iboard_secplus2"));
    assert!(
        ratgdo.first().is_some_and(|name| name.contains("ratgdo")),
        "a ratgdo board must match its own spec first, got {ratgdo:?}"
    );

    // Any other ESPHome node: ratgdo's TXT condition fails, so it must not
    // claim the node at all — and the catch-all picks it up instead.
    let other = named(node("esphome.bedroom_sensor"));
    assert!(
        !other.iter().any(|name| name.contains("ratgdo")),
        "a non-ratgdo ESPHome node must not match the garage-door spec, got {other:?}"
    );
    assert!(
        !other.is_empty(),
        "the platform catch-all must still recognise the node"
    );

    // A node publishing no TXT records at all is the same case: unnarrowed,
    // so the product spec has no evidence and must not claim it.
    let mut bare = node("");
    bare.txt.clear();
    let bare = named(bare);
    assert!(
        !bare.iter().any(|name| name.contains("ratgdo")),
        "no TXT evidence is not evidence, got {bare:?}"
    );
}

/// The Rabbit Air purifier is the catalogue's one BLE-provisioned family, and
/// the adopt screen used to hard-code its card and its advertised name in Dart.
/// This pins the facts the screen now reads from the spec: that the profile
/// exists, that the name it scans for is the spec's, and that the spec's
/// `exact` rule is what decides the match — so a rename upstream moves the app
/// and a stray look-alike peripheral is never handed Wi-Fi credentials.
#[test]
fn the_vendored_rabbit_air_spec_drives_its_own_ble_adopt_card() {
    use liberated_bread_core::spec::setup::{ble_provisioning_profiles, NameMatch};

    let yamls: Vec<String> = vendored_yaml_paths()
        .iter()
        .map(|p| fs::read_to_string(p).expect("vendored spec reads"))
        .collect();
    let specs: Vec<_> = yamls
        .iter()
        .filter_map(|y| parse_device_spec(y).ok())
        .collect();
    let profiles = ble_provisioning_profiles(specs.iter());

    let rabbit = profiles
        .iter()
        .find(|p| p.spec_name.to_lowercase().contains("rabbit"))
        .unwrap_or_else(|| {
            panic!("the Rabbit Air spec should declare a ble_provisioning method, got {profiles:?}")
        });
    assert_eq!(rabbit.advertised_name, "RabbitAirSetup");
    assert_eq!(rabbit.name_match, NameMatch::Exact);
    assert!(rabbit.matches_name("RabbitAirSetup"));
    // A provisioned unit renames itself; it must fall through to the ordinary
    // control panel rather than back into the setup flow.
    assert!(!rabbit.matches_name("RabbitAir-Living Room"));
    assert!(
        rabbit.service_uuid.is_some() && rabbit.write_characteristic.is_some(),
        "the provisioning conversation needs its GATT addresses from the spec"
    );
}

/// The Hisense set is the catalogue's MQTT control surface, and the whole
/// point of the transport work is that its remote resolves without a line of
/// TV-specific code.
///
/// Pins the three things a consumer depends on: that the entities reach the
/// surface at all (a transport the resolver cannot send would hide every one
/// of them), that a key press renders to the topic and payload the spec
/// declares, and that the topic's client id comes from the caller rather than
/// being guessed. The last is the one that fails silently: a publish to a
/// topic still holding a literal `{client_id}` succeeds at the socket.
#[test]
fn the_vendored_hisense_spec_resolves_a_remote_over_mqtt() {
    use liberated_bread_core::api::device_api::{
        network_entities_for_device, render_network_mqtt_command,
    };

    let yaml = fs::read_to_string(spec_path("hisense-vidaa.yaml")).expect("spec reads");

    let surface =
        network_entities_for_device(yaml.clone(), vec![]).expect("hisense resolves a surface");
    let names: BTreeSet<&str> = surface.entities.iter().map(|e| e.name.as_str()).collect();
    for expected in ["Power Key", "Up", "Down", "Left", "Right", "OK"] {
        assert!(
            names.contains(expected),
            "{expected:?} should be on the surface, got {names:?}"
        );
    }
    // The remote's keys are what this set can actually be driven by. Its
    // `Power` SWITCH is a different entity and is deliberately not drawn: its
    // one binding is `toggle`, whose contract requires reading the state
    // first, and its `state_topic` carries no `state_mapping` saying which
    // field of that topic is the power state (the spec puts it in prose). A
    // switch that can neither be read nor operated is the dead control the
    // surface rule exists to keep off screen — the momentary key beside it
    // works, which is the honest surface for this set.
    assert!(
        !names.contains("Power"),
        "the toggle-only, mapping-less Power switch is not drivable, got {names:?}"
    );

    let values = std::collections::HashMap::from([(
        "client_id".to_string(),
        "56:b8:88:4e:f7:19$normal".to_string(),
    )]);
    let request = render_network_mqtt_command(yaml.clone(), "press_power".to_string(), values)
        .expect("a key press renders");
    assert_eq!(
        request.topic,
        "/remoteapp/tv/remote_service/56:b8:88:4e:f7:19$normal/actions/sendkey"
    );
    // The bare key name, not JSON: this spec's payload is a string.
    assert_eq!(request.payload, "KEY_POWER");

    // With no client id there is nothing to address, and rendering must say so
    // rather than publish a topic containing a brace.
    let unaddressed = render_network_mqtt_command(
        yaml,
        "press_power".to_string(),
        std::collections::HashMap::new(),
    );
    assert!(
        unaddressed.is_err(),
        "an unaddressed command must not render, got {unaddressed:?}"
    );
}

/// `state_topic` is a LOCATION, and a location is a binding only when the
/// reading there can be both reached and read.
///
/// Twenty specs declare the field and no two of them mean quite the same
/// thing by it, which is why this is resolved in one place
/// (`bindings::state_binding`) rather than re-derived per transport. The four
/// cases below are the whole rule:
///
/// - A Hisense set's `/remoteapp/mobile/broadcast/ui_service/state` opens with
///   a slash and is an MQTT TOPIC all the same, because the device speaks
///   MQTT. Shape must not be asked before transport.
/// - A WLED controller's `/json/state` is a path on its own HTTP API. It names
///   no command because there is none to name: the reading is a resource, and
///   reading a resource is a GET of it.
/// - The Dyson purifier is reachable and unreadable. Its spec records that the
///   STATE-SET key names were never recovered, so it declares no
///   `state_mapping` — nothing says which field at that topic is the reading,
///   and a card admitted on the topic alone is permanently blank.
/// - The Hue bridge is readable and unreachable: `/api/{username}/sensors/{id}`
///   wants a credential this app does not store and a child id nothing
///   enumerates.
///
/// The last two stay off the surface and are counted as hidden, which is what
/// the honesty rule asks for — an absent control over a dead one.
#[test]
fn a_state_topic_binds_only_where_it_can_be_reached_and_read() {
    use liberated_bread_core::api::device_api::{
        network_entities_for_device, render_network_http_state_request,
    };

    let entities = |file: &str| {
        let yaml = fs::read_to_string(spec_path(file)).expect("spec reads");
        network_entities_for_device(yaml, vec![])
            .unwrap_or_else(|e| panic!("{file} should resolve a surface: {e}"))
            .entities
    };
    let surfaced =
        |file: &str| -> BTreeSet<String> { entities(file).into_iter().map(|e| e.name).collect() };

    // A topic, because the device speaks MQTT — despite opening with a slash.
    //
    // Asserted on the TRANSPORT the DTO reports, not merely on the entity
    // reaching the surface. That is what routes the read, and it is the half
    // that fails silently: resolve this by shape before asking what the device
    // speaks and the select still draws, while the screen polls a television's
    // MQTT topic over HTTP and every read 404s.
    let input = entities("hisense-vidaa.yaml")
        .into_iter()
        .find(|e| e.name == "Input")
        .expect("a Hisense input select reads its state off a subscribed topic");
    assert_eq!(
        input.transport.as_deref(),
        Some("mqtt"),
        "the set's own transport decides what its state_topic means"
    );
    assert_eq!(
        input.state_command, "/remoteapp/mobile/broadcast/ui_service/state",
        "the topic itself rides the state binding's field"
    );

    // A path on the device's own HTTP API, which is the whole of its surface:
    // before this resolved, a WLED controller drew nothing at all.
    let wled = surfaced("wled-controller.yaml");
    assert!(
        wled.contains("WLED"),
        "a WLED light reads its state out of /json/state, got {wled:?}"
    );
    let yaml = fs::read_to_string(spec_path("wled-controller.yaml")).expect("spec reads");
    let request =
        render_network_http_state_request(yaml, "/json/state".to_string(), Default::default())
            .expect("a bare path renders as the GET it is");
    assert_eq!(
        (request.method.as_str(), request.path.as_str()),
        ("GET", "/json/state")
    );

    // Reachable, unreadable: no state_mapping, so nothing says what to take
    // out of what arrives.
    let dyson = surfaced("dyson-air-purifier.yaml");
    assert!(
        dyson.is_empty(),
        "a purifier whose state keys were never recovered has nothing to draw, got {dyson:?}"
    );

    // Readable, unreachable: the path wants a credential nothing stores.
    let hue = surfaced("hue-bridge.yaml");
    assert!(
        !hue.contains("Hue Sensor"),
        "hue's sensor path needs a credential this app has no store for, got {hue:?}"
    );
}

/// Every `state_topic` the catalogue declares either resolves to a binding
/// this crate can act on, or fails for one of the reasons below — and a NEW
/// reason fails this test rather than making an entity quietly vanish.
///
/// This is the drift guard this project keeps needing: a closed table in code
/// facing an open field in the schema, with no symptom when they disagree.
/// The field's own description is "MQTT topic or HTTP endpoint", which is
/// exactly the kind of open sentence a spec author will reasonably write a
/// `coap://` or an `mqtts://` into one day. When that happens the entity would
/// simply stop being drawn, on every device, with nothing said. So the
/// unreadable locations are enumerated by the SCHEME they carry, and an
/// unlisted scheme is a failure.
#[test]
fn every_state_topic_in_the_catalogue_resolves_or_is_a_known_backlog_item() {
    use liberated_bread_core::spec::bindings::state_binding;

    /// Location schemes no transport here can read, with what each would take.
    /// Not a wish-list — every entry is a real entity on a real spec that the
    /// surface is currently, deliberately, honest about not drawing.
    const UNREADABLE_SCHEMES: &[(&str, &str)] = &[
        (
            "udp",
            "a binary datagram exchange (LIFX, Mi-Light) — the reading is a decode, not a path",
        ),
        (
            "ssap",
            "an LG WebSocket request; the session exists, the read side is not wired",
        ),
        ("homekit", "HAP, which this app does not speak"),
        ("smartthings", "a hub's own cloud-adjacent API"),
        ("matter", "Matter, which this app does not speak"),
    ];

    /// Specs whose `state_topic` names a place on the VENDOR'S CLOUD rather
    /// than on the device. Listed per spec, not waved through by shape, so
    /// that a schemeless location on a spec that is not here still fails.
    ///
    /// Both Frigidaire units are the whole list, and their own `device.notes`
    /// are the evidence: a static-analysis pass over three versions of the
    /// Electrolux app found provisioning-only local paths and "no usable
    /// post-pairing LAN discovery/control path". The schema has a way to say
    /// this — `state_endpoint: "cloud"` — and these specs predate it; the
    /// placeholder is also spelled `device_id` here while every command
    /// parameter spells it `applianceId`, so nothing could fill it either way.
    const CLOUD_ONLY_STATE: &[(&str, &str)] = &[
        (
            "frigidaire-portable-ac.yaml",
            "Electrolux OCP cloud; no LAN control path exists",
        ),
        (
            "frigidaire-window-ac.yaml",
            "Electrolux OCP cloud; no LAN control path exists",
        ),
    ];

    let mut unresolved: Vec<String> = Vec::new();
    for path in vendored_yaml_paths() {
        let yaml = fs::read_to_string(&path).expect("spec reads");
        let Ok(spec) = parse_device_spec(&yaml) else {
            continue;
        };
        let file = path.file_name().unwrap().to_string_lossy().to_string();
        for entity in &spec.entities {
            let Some(topic) = entity.state_topic.as_deref() else {
                continue;
            };
            if state_binding(&spec, entity).is_some() {
                continue;
            }
            // A location with no `state_mapping` is unreadable by declaration,
            // and the spec saying so is the point — Dyson records that its
            // state keys were never recovered.
            if entity.state_mapping.is_empty() {
                continue;
            }
            if CLOUD_ONLY_STATE.iter().any(|(spec, _)| *spec == file) {
                continue;
            }
            // A scheme names a transport rather than a place on this device.
            if let Some(scheme) = topic.split("://").next().filter(|s| s.len() < topic.len()) {
                if UNREADABLE_SCHEMES.iter().any(|(known, _)| *known == scheme) {
                    continue;
                }
                unresolved.push(format!(
                    "{file}: {} — unknown location scheme '{scheme}://'",
                    entity.name
                ));
                continue;
            }
            unresolved.push(format!("{file}: {} — {topic}", entity.name));
        }
    }
    assert!(
        unresolved.is_empty(),
        "these state_topic locations resolve to no binding and match no known \
         backlog reason. Either wire the transport, or — if it is genuinely \
         out of reach — add its scheme to UNREADABLE_SCHEMES with what it \
         would take:\n  {}",
        unresolved.join("\n  ")
    );
}

/// A parameter name means one thing within a spec.
///
/// This is what makes `http::spec_wide_default` sound. A `{placeholder}` in a
/// bare `state_topic` has no owning command to read a default from — Philips's
/// `/{api_version}/powerstate` names a version the spec declares fifty-four
/// times, once per command, always as `6`. Resolving it by name across the
/// spec is reading the spec; it would be GUESSING if one name could mean two
/// things, and this is what keeps that from becoming true silently.
#[test]
fn a_parameter_name_means_one_thing_within_a_spec() {
    let mut conflicts: Vec<String> = Vec::new();
    for path in vendored_yaml_paths() {
        let yaml = fs::read_to_string(&path).expect("spec reads");
        let Ok(spec) = parse_device_spec(&yaml) else {
            continue;
        };
        let file = path.file_name().unwrap().to_string_lossy().to_string();
        let mut seen: std::collections::BTreeMap<&str, BTreeSet<String>> = Default::default();
        for command in spec.commands.values() {
            for (name, parameter) in &command.parameters {
                if let Some(default) = parameter.default.as_ref() {
                    seen.entry(name).or_default().insert(format!("{default:?}"));
                }
            }
        }
        for (name, defaults) in seen {
            if defaults.len() > 1 {
                conflicts.push(format!("{file}: {name} defaults to {defaults:?}"));
            }
        }
    }
    assert!(
        conflicts.is_empty(),
        "one parameter name, two declared defaults — a path placeholder can no \
         longer be resolved by name, and http::spec_wide_default has to become \
         a per-command question:\n  {}",
        conflicts.join("\n  ")
    );
}

/// A name is either a credential or the user's to set — never both within one
/// spec.
///
/// The sender merges the stored credentials under every render's values, so a
/// name that means "the whitelist username" on one command and "a value the
/// user picks" on another would have the store quietly answering for the user
/// on the second. Nothing in the catalogue does this today; the merge is only
/// safe while that holds, and this is what says so if it stops.
#[test]
fn a_credential_name_is_not_also_a_user_settable_parameter() {
    let mut conflicts: Vec<String> = Vec::new();
    for path in vendored_yaml_paths() {
        let yaml = fs::read_to_string(&path).expect("spec reads");
        let Ok(spec) = parse_device_spec(&yaml) else {
            continue;
        };
        let file = path.file_name().unwrap().to_string_lossy().to_string();
        let credentials: BTreeSet<&str> = spec
            .commands
            .values()
            .flat_map(|command| command.parameters.values())
            .filter_map(|parameter| parameter.source.as_deref())
            .filter_map(|source| source.strip_prefix("credential:"))
            .collect();
        for (command_name, command) in &spec.commands {
            // `user_params` is the resolver's own answer to "what does the UI
            // supply", so this asks the same question the send path asks.
            for name in command.user_params() {
                if credentials.contains(name) {
                    conflicts.push(format!("{file}: {command_name}.{name}"));
                }
            }
        }
    }
    assert!(
        conflicts.is_empty(),
        "these parameters are a stored credential on one command and the \
         user's to set on another, so the sender's credential merge would \
         answer for the user:\n  {}",
        conflicts.join("\n  ")
    );
}

/// Every credential the catalogue names is reachable — a client can either run
/// a declared flow to get it, or show a person a sentence saying where to find
/// it.
///
/// The drift this guards is a spec author adding `source: credential:token`
/// with no `description` and no `issues_credentials` entry. Nothing breaks
/// visibly: the commands resolve, the controls draw, and every press fails on
/// a value the app has no way to obtain and no words to ask for. The prompt is
/// built entirely from the spec — that is what makes it generic — so a
/// credential the spec does not describe is a prompt with a blank in it.
#[test]
fn every_credential_the_catalogue_names_can_be_obtained() {
    use liberated_bread_core::spec::credentials::required_credentials;

    /// Credentials this rule already caught, fixed UPSTREAM, and still
    /// present in the vendored copy because the subtree has not been
    /// refreshed since. Each entry disappears with the next
    /// `update-specs.sh`, and the guard fails again if one does not.
    ///
    /// This is not a permanent-exception list. An entry that survives a
    /// refresh means the upstream fix did not land, which is worth a failing
    /// test in its own right — so keep the list to what has genuinely been
    /// written upstream, and delete each line the moment vendoring makes it
    /// unnecessary.
    const FIXED_UPSTREAM_NOT_YET_VENDORED: &[(&str, &str, &str)] = &[];

    let mut unobtainable: Vec<String> = Vec::new();
    for path in vendored_yaml_paths() {
        let yaml = fs::read_to_string(&path).expect("spec reads");
        let Ok(spec) = parse_device_spec(&yaml) else {
            continue;
        };
        let file = path.file_name().unwrap().to_string_lossy().to_string();
        for requirement in required_credentials(&spec) {
            if !requirement.must_be_asked_for() {
                continue;
            }
            let described = requirement
                .description
                .as_deref()
                .is_some_and(|d| !d.trim().is_empty());
            if described {
                assert!(
                    !FIXED_UPSTREAM_NOT_YET_VENDORED
                        .iter()
                        .any(|(spec, name, _)| *spec == file && *name == requirement.name),
                    "{file}: {} is described now — the upstream fix has been \
                     vendored, so delete its FIXED_UPSTREAM_NOT_YET_VENDORED \
                     line",
                    requirement.name
                );
                continue;
            }
            if FIXED_UPSTREAM_NOT_YET_VENDORED
                .iter()
                .any(|(spec, name, _)| *spec == file && *name == requirement.name)
            {
                continue;
            }
            {
                unobtainable.push(format!(
                    "{file}: {} — needed by {:?}, issued by no declared flow, \
                     and described nowhere",
                    requirement.name, requirement.needed_by
                ));
            }
        }
    }
    assert!(
        unobtainable.is_empty(),
        "a client can neither obtain nor ask for these. Give the parameter a \
         `description` saying where a person finds the value, or declare the \
         setup method that issues it in `issues_credentials`:\n  {}",
        unobtainable.join("\n  ")
    );
}

/// A stored credential fills the parameter it is sourced into, even when the
/// two are spelled differently — which in most of the catalogue they are.
///
/// A client stores what `issues_credentials` NAMES, so the store is keyed by
/// the credential's name. A renderer fills by the PARAMETER's name. Three of
/// the five specs that use credentials spell those differently — Frigidaire's
/// `applianceId` from `credential:appliance_id`, Hisense's `client_id` from
/// `credential:mqtt_client_id` — so a renderer that only looked up the
/// parameter name failed on a value the app was holding, and reported a name
/// the person who typed it had never seen.
#[test]
fn a_stored_credential_fills_the_parameter_it_is_sourced_into() {
    use liberated_bread_core::api::device_api::{
        render_network_http_command, render_network_mqtt_command,
    };
    use std::collections::HashMap;

    // Frigidaire: parameter `applianceId`, credential `appliance_id`.
    let yaml = fs::read_to_string(spec_path("frigidaire-window-ac.yaml")).expect("spec reads");
    let stored = HashMap::from([("appliance_id".to_string(), "OCP-12345".to_string())]);
    let request = render_network_http_command(yaml, "turn_on".to_string(), stored)
        .expect("the stored credential fills applianceId");
    assert!(
        request.path.contains("OCP-12345"),
        "the appliance id belongs in the path, got {}",
        request.path
    );

    // Hisense: parameter `client_id`, credential `mqtt_client_id`. The topic
    // IS the address here, so a miss publishes nowhere useful.
    let yaml = fs::read_to_string(spec_path("hisense-vidaa.yaml")).expect("spec reads");
    let stored = HashMap::from([(
        "mqtt_client_id".to_string(),
        "56:b8:88:4e:f7:19$normal".to_string(),
    )]);
    let request = render_network_mqtt_command(yaml, "press_power".to_string(), stored)
        .expect("the stored credential fills client_id");
    assert_eq!(
        request.topic,
        "/remoteapp/tv/remote_service/56:b8:88:4e:f7:19$normal/actions/sendkey"
    );

    // And a bare state path, which has no owning command to read `source:`
    // off and resolves the same correspondence across the spec instead.
    let yaml = fs::read_to_string(spec_path("hue-bridge.yaml")).expect("spec reads");
    let stored = HashMap::from([("username".to_string(), "nUP9k2sQ".to_string())]);
    let request = liberated_bread_core::api::device_api::render_network_http_state_request(
        yaml,
        "/api/{username}/sensors".to_string(),
        stored,
    )
    .expect("a bare path fills from the store too");
    assert_eq!(request.path, "/api/nUP9k2sQ/sensors");
}

/// The two ends of the credential join, on the two vendored specs that make
/// it: a value a pairing flow mints, and a value only a person can supply.
///
/// The coupling is the NAME and nothing else — `issues_credentials` keys its
/// entries by the same spelling a `credential:<name>` parameter refers to —
/// which is what lets a client pair, store, and fill a later request with no
/// per-device table in between. This pins that the join actually happens over
/// the vendored files rather than only over a fixture.
#[test]
fn a_vendored_credential_joins_its_flow_to_its_consumers() {
    use liberated_bread_core::api::device_api::credentials_for_device;

    // Hue: the link-button flow issues `username`, and every later request
    // embeds it. Nothing should ask a person for it.
    let yaml = fs::read_to_string(spec_path("hue-bridge.yaml")).expect("spec reads");
    let hue = credentials_for_device(yaml).expect("hue resolves its credentials");
    let username = hue
        .iter()
        .find(|c| c.name == "username")
        .expect("the bridge names a username credential");
    let issued = username
        .issued_by
        .as_ref()
        .expect("the link-button flow issues it");
    assert_eq!(issued.method, "button_pairing");
    assert!(!username.needed_by.is_empty(), "requests embed it");
    assert!(
        !username.must_be_asked_for,
        "a pairing mints it; prompting teaches people to paste what a button \
         press was about to hand over"
    );

    // Bambu: the serial is read off the printer's own touchscreen, and no
    // setup method in the spec can mint it. This is the ask-for case, and the
    // spec's own sentence is what a client shows.
    let yaml = fs::read_to_string(spec_path("bambu-lab-lan.yaml")).expect("spec reads");
    let bambu = credentials_for_device(yaml).expect("bambu resolves its credentials");
    let serial = bambu
        .iter()
        .find(|c| c.name == "serial")
        .expect("the printer names a serial credential");
    assert!(serial.issued_by.is_none());
    assert!(serial.must_be_asked_for);
    assert!(
        serial
            .description
            .as_deref()
            .is_some_and(|d| d.contains("touchscreen")),
        "the prompt's words are the spec's: {:?}",
        serial.description
    );
    assert_eq!(
        serial.needed_by,
        vec!["pause", "pushall", "resume", "stop"],
        "every command publishes to a topic the serial addresses"
    );
}

/// The two televisions whose whole control surface is a WebSocket. Until this
/// branch their commands resolved to nothing at all — the resolver declined
/// the transport, which is what kept a card of dead buttons off the screen —
/// and the point of the work is that they now resolve from the spec with no
/// TV-specific code anywhere.
///
/// Pins what a consumer actually depends on: the remote reaches the surface,
/// the connect address and its fallback are readable, and a key press renders
/// to the exact frame the published clients send.
#[test]
fn the_vendored_samsung_spec_resolves_a_remote_over_its_websocket() {
    use liberated_bread_core::api::device_api::{
        network_entities_for_device, render_network_websocket_command, websocket_surface,
    };

    let yaml = fs::read_to_string(spec_path("samsung-tizen-tv.yaml")).expect("spec reads");

    let surface = websocket_surface(yaml.clone())
        .expect("parses")
        .expect("samsung declares a websocket surface");
    assert_eq!(surface.port, 8002);
    assert_eq!(surface.scheme, "wss");
    // The token rides the connect path, so its placeholder has to survive to
    // the caller that holds it — this crate never sees a credential. The Dart
    // filler (ws_control_service `_fillPath`) substitutes `{<credential_name>}`
    // and `{client_name}`, so assert the path spells exactly those: a spec that
    // renames the placeholder without the pairing block (or the reverse) leaves
    // the braces unfilled and pairing silently never succeeds, which is the
    // drift this guard exists to catch. (Upstream spells it `{samsung_token}`;
    // asserting the name dynamically keeps the guard correct across a rename.)
    let cred_name = surface
        .credential_name
        .as_deref()
        .expect("the pairing block names the credential the path carries");
    assert!(
        surface.path.contains(&format!("{{{cred_name}}}")),
        "connect path must carry the credential placeholder {{{cred_name}}}: {}",
        surface.path
    );
    assert!(surface.path.contains("{client_name}"), "{}", surface.path);
    // Older sets listen on the plain port and authenticate by name alone.
    assert_eq!(surface.fallback_port, Some(8001));
    assert_eq!(surface.fallback_scheme.as_deref(), Some("ws"));
    assert_eq!(surface.pairing_mode.as_deref(), Some("token_query"));
    assert_eq!(surface.issued_at.as_deref(), Some("data.token"));
    assert_eq!(surface.channels.len(), 1);
    assert!(surface.channels[0].is_default);

    let entities = network_entities_for_device(yaml.clone(), vec![]).expect("resolves a surface");
    let names: BTreeSet<&str> = entities.entities.iter().map(|e| e.name.as_str()).collect();
    assert!(
        !names.is_empty(),
        "a set whose commands all ride the websocket must now resolve controls"
    );

    let frame = render_network_websocket_command(
        yaml,
        "press_power".to_string(),
        std::collections::HashMap::new(),
        7,
    )
    .expect("a key press renders");
    let json: serde_json::Value = serde_json::from_str(&frame.text).expect("valid JSON");
    assert_eq!(json["method"], "ms.remote.control");
    assert_eq!(json["params"]["DataOfCmd"], "KEY_POWER");
    assert_eq!(json["params"]["TypeOfRemote"], "SendRemoteKey");
}

/// LG's is the harder shape and the reason `channels` is a list: SSAP requests
/// are JSON on the socket already open, and remote BUTTONS are plain text on a
/// second socket the TV hands out at runtime.
#[test]
fn the_vendored_lg_spec_renders_both_of_its_channels() {
    use liberated_bread_core::api::device_api::{
        render_network_websocket_command, websocket_surface,
    };

    let yaml = fs::read_to_string(spec_path("lg-webos.yaml")).expect("spec reads");

    let surface = websocket_surface(yaml.clone())
        .expect("parses")
        .expect("lg declares a websocket surface");
    assert_eq!((surface.port, surface.scheme.as_str()), (3000, "ws"));
    assert_eq!(surface.fallback_port, Some(3001));
    assert_eq!(surface.pairing_mode.as_deref(), Some("register_frame"));
    assert!(
        surface.register_frame.is_some(),
        "a register_frame pairing has to say what to send"
    );

    let pointer = surface
        .channels
        .iter()
        .find(|c| c.name == "pointer")
        .expect("declares the button channel");
    assert_eq!(pointer.encoding, "text");
    // Reachable, not merely described: the command that returns its address is
    // itself declared.
    assert_eq!(pointer.obtained_by.as_deref(), Some("get_pointer_socket"));

    // An SSAP request: JSON, on the main socket, with a numeric correlation id.
    let ssap = render_network_websocket_command(
        yaml.clone(),
        "volume_up".to_string(),
        std::collections::HashMap::new(),
        3,
    )
    .expect("an ssap request renders");
    assert_eq!(ssap.channel, "ssap");
    let json: serde_json::Value = serde_json::from_str(&ssap.text).expect("valid JSON");
    assert_eq!(json["id"], serde_json::json!(3));
    assert_eq!(json["type"], "request");
    assert_eq!(json["uri"], "ssap://audio/volumeUp");

    // A button: plain text, on the other socket entirely.
    let button = render_network_websocket_command(
        yaml,
        "press_home".to_string(),
        std::collections::HashMap::new(),
        4,
    )
    .expect("a button renders");
    assert_eq!(button.channel, "pointer");
    assert_eq!(button.text, "type:button\nname:HOME\n\n");
}

/// Every resolved action reports the transport the SPEC says it rides —
/// its own `transport:`, else the device's, else SOAP.
///
/// The invariant that was missing, and the reason seventy commands across the
/// two WebSocket TV specs spent a release labelled `soap`. Both sets declare
/// `device.transport: websocket` once and deliberately omit it on every
/// command; the admission gate resolved that correctly while the DTO builder
/// re-spelled `command.transport` on its own and fell through to the SOAP
/// default. Two derivations of one rule, and only one of them was tested.
///
/// So this asserts the rule over the whole catalogue rather than over the spec
/// that happened to break: any future spec written the same way, on any
/// transport, is covered the day it lands.
#[test]
fn every_resolved_action_reports_the_transport_its_spec_declares() {
    use liberated_bread_core::api::device_api::network_entities_for_device;

    let mut checked = 0usize;
    for path in vendored_yaml_paths() {
        let text = fs::read_to_string(&path).expect("spec reads");
        let file = path.file_name().unwrap().to_string_lossy().to_string();
        let Ok(spec) = parse_device_spec(&text) else {
            continue;
        };
        let Ok(surface) = network_entities_for_device(text, vec![]) else {
            continue;
        };
        // Two handlers SYNTHESISE their surface from `features` rather than
        // resolving it from the commands map — LIFX because its binary UDP
        // frames are not spec commands at all, the Roomba because its readings
        // are pushed and there is no poll to name. Their actions carry the
        // handler's own transport on purpose, so the commands map is not the
        // right thing to compare them against. Every other spec goes through
        // the resolver this test exists to pin.
        if matches!(
            spec.protocol_handler.as_deref(),
            Some("lifx_lan_udp") | Some("roomba_mqtt")
        ) {
            continue;
        }
        // The spec's own answer, derived here independently of the resolver.
        let device_transport = spec
            .device
            .extensions
            .get("transport")
            .and_then(|t| t.as_str());

        for entity in &surface.entities {
            for action in &entity.actions {
                // Only actions RESOLVED FROM A DECLARED COMMAND. LIFX's are
                // synthesised from an entity's `features` rather than from the
                // commands map, and carry the `lifx` transport on purpose so
                // the UI dispatches them to the UDP client; there is no spec
                // command to compare them against.
                let Some(command) = spec.commands.get(&action.command_name) else {
                    continue;
                };
                let declared = command
                    .transport
                    .as_deref()
                    .or(device_transport)
                    .unwrap_or("soap");
                assert_eq!(
                    action.transport, declared,
                    "{file}: action {:?} on {:?} reports transport {:?}, but the spec \
                     says {declared:?}. A consumer routes the send on this string.",
                    action.command_name, entity.name, action.transport,
                );
                checked += 1;
            }
        }
    }
    // A silent zero would make the assertions above decorative.
    assert!(
        checked > 100,
        "only {checked} actions resolved across the catalogue — this test is \
         reading the wrong thing"
    );
}

/// The two WebSocket sets resolve their remotes ON the websocket.
///
/// Named separately from the catalogue-wide invariant because these are the
/// specs the invariant was written for, and a regression here should say
/// "the TV remotes are broken" rather than "some spec somewhere disagrees".
#[test]
fn the_websocket_tv_remotes_report_the_websocket_transport() {
    use liberated_bread_core::api::device_api::network_entities_for_device;

    for file in ["samsung-tizen-tv.yaml", "lg-webos.yaml"] {
        let text = fs::read_to_string(spec_path(file)).expect("spec reads");
        let surface = network_entities_for_device(text, vec![]).expect("resolves a surface");
        let actions: Vec<&str> = surface
            .entities
            .iter()
            .flat_map(|e| e.actions.iter())
            .map(|a| a.transport.as_str())
            .collect();
        assert!(
            !actions.is_empty(),
            "{file} resolves no actions at all — the remote is gone"
        );
        // `launch_app` on the Samsung genuinely declares http; everything else
        // inherits the device's websocket. Nothing may say soap: neither set
        // ships a UPnP service, and the SOAP arm is what blocked the screen.
        assert!(
            !actions.contains(&"soap"),
            "{file}: {} of {} actions report soap",
            actions.iter().filter(|t| **t == "soap").count(),
            actions.len()
        );
        assert!(
            actions.contains(&"websocket"),
            "{file} resolves no websocket action"
        );
    }
}

/// `tcp-json` is admitted only for the handler that owns the framing.
///
/// The transport names a shape — JSON down a raw socket — that ten vendored
/// specs share and four of them frame incompatibly. Admitting on the string
/// alone gave Yeelight, Tuya, Roborock and the iKettle live controls whose
/// every press shipped TP-Link's XOR-autokey cipher at a device speaking
/// something else. A control that lies is worse than one that is missing, so
/// they are declined and counted until their handler is registered.
#[test]
fn tcp_json_resolves_only_for_the_handler_that_owns_the_framing() {
    use liberated_bread_core::api::device_api::network_entities_for_device;

    let kasa = fs::read_to_string(spec_path("tplink-kasa-smart-plug.yaml")).expect("spec reads");
    let surface = network_entities_for_device(kasa, vec![]).expect("kasa resolves a surface");
    assert!(
        surface
            .entities
            .iter()
            .any(|e| e.actions.iter().any(|a| a.transport == "tcp-json")),
        "the spec that declares tplink_smarthome must keep its controls"
    );

    // Every other tcp-json spec: no action may claim the transport, and the
    // entity has to be COUNTED rather than quietly dropped.
    for path in vendored_yaml_paths() {
        let text = fs::read_to_string(&path).expect("spec reads");
        let file = path.file_name().unwrap().to_string_lossy().to_string();
        let Ok(spec) = parse_device_spec(&text) else {
            continue;
        };
        if spec.protocol_handler.as_deref() == Some("tplink_smarthome") {
            continue;
        }
        let declares_tcp_json = spec
            .commands
            .values()
            .any(|c| c.transport.as_deref() == Some("tcp-json"))
            || spec
                .device
                .extensions
                .get("transport")
                .and_then(|t| t.as_str())
                == Some("tcp-json");
        if !declares_tcp_json {
            continue;
        }
        let Ok(surface) = network_entities_for_device(text, vec![]) else {
            continue;
        };
        for entity in &surface.entities {
            for action in &entity.actions {
                assert_ne!(
                    action.transport, "tcp-json",
                    "{file}: {:?} resolved a tcp-json action ({:?}) without declaring \
                     a handler that says how to frame it — it would be sent with \
                     TP-Link's cipher",
                    entity.name, action.command_name,
                );
            }
        }
    }

    // The four the gate was written for, named so a regression reads as "the
    // Yeelight is mis-sending again" rather than as an abstract invariant.
    // Zero sendable actions each: every command they declare is tcp-json, and
    // none of them says how it is framed. An entity that still names a
    // `state_command` survives as a reading, which is the existing rule for a
    // stateful entity that resolves no action and is not this test's business.
    for file in [
        "yeelight-cube-lamp.yaml",
        "tuya-wifi-gas-sensor.yaml",
        "roborock-local.yaml",
        "smarter-ikettle.yaml",
    ] {
        let text = fs::read_to_string(spec_path(file)).expect("spec reads");
        let surface = network_entities_for_device(text, vec![]).expect("resolves");
        let actions: Vec<&str> = surface
            .entities
            .iter()
            .flat_map(|e| e.actions.iter())
            .map(|a| a.command_name.as_str())
            .collect();
        assert!(
            actions.is_empty(),
            "{file} still offers {actions:?} — these would be sent with TP-Link's cipher"
        );
    }
}

/// Every role a spec binds is a role the resolver knows.
///
/// `entities[].commands` is declared in the schema as a bare
/// `{"type": "object"}`: any key is legal, and the resolver matches a closed
/// alias table and passes over the rest without a word. So a spec can spell a
/// role `set_rgb` where the table says `set_color`, and the control does not
/// appear — no error, no hidden-entities line if the entity resolved something
/// else, nothing. Ten role names across seven specs were in exactly that state.
///
/// This is the guard that makes the disagreement loud. It cannot decide which
/// side is wrong — sometimes the spec has a typo, sometimes the app owes the
/// catalogue a role — but it stops the answer being silence.
#[test]
fn every_role_the_catalogue_binds_is_one_the_resolver_knows() {
    use liberated_bread_core::spec::bindings::known_role_aliases;

    let mut unknown: Vec<String> = Vec::new();
    for path in vendored_yaml_paths() {
        let text = fs::read_to_string(&path).expect("spec reads");
        let file = path.file_name().unwrap().to_string_lossy().to_string();
        let Ok(spec) = parse_device_spec(&text) else {
            continue;
        };
        for entity in &spec.entities {
            // Reading platforms have no roles by design; an entity with no
            // platform at all is a sensor by the same default the panels use.
            let Some(platform) = entity.platform.as_deref() else {
                continue;
            };
            let known = known_role_aliases(platform);
            if known.is_empty() {
                // A platform the resolver has no roles for. Two very different
                // things land here and the guard used to skip BOTH, which made
                // it blind to the one drift case with no other symptom.
                //
                // A reading platform legitimately has no controls; the
                // catalogue's own rule (upstream's
                // `test_entity_roles_come_from_the_documented_vocabulary`) is
                // that it may bind `poll` and nothing else. Anything else on a
                // platform this resolver does not know — a typo, a platform
                // added upstream and not here — is a binding that resolves to
                // nothing, silently, on every device with that spec.
                let stray: Vec<&str> = entity
                    .commands
                    .keys()
                    .map(String::as_str)
                    .filter(|role| *role != "poll")
                    .collect();
                if !stray.is_empty() {
                    unknown.push(format!(
                        "{file}: {:?} is on platform {platform:?}, which this                          resolver has no roles for at all, and binds {stray:?}",
                        entity.name
                    ));
                }
                continue;
            }
            for role in entity.commands.keys() {
                if known.contains(&role.as_str()) {
                    continue;
                }
                unknown.push(format!(
                    "{file}: {:?} ({platform}) binds {role:?}, which no role on \
                     that platform accepts — known: {known:?}",
                    entity.name
                ));
            }
        }
    }
    assert!(
        unknown.is_empty(),
        "roles bound by the catalogue that resolve to nothing:\n  {}",
        unknown.join("\n  ")
    );
}

/// The TLS policy a spec declares reaches the consumer that opens the socket.
///
/// `identification.tls` was parsed by nothing. Two specs — the Envoy and
/// SmartCast, both `default_scheme: https` on a LAN address — ask for
/// `trust_on_first_use`, and what they got was a client excusing any
/// certificate from any host a caller had named. That is `none`'s behaviour
/// applied to devices that asked to be pinned, and it looks identical to
/// working right up until somebody is between you and the device.
///
/// Asserted over the whole catalogue rather than over the two: any spec that
/// declares the block should have it carried, and the second half of the test
/// is the half that would have caught the original bug — a scheme of `https`
/// with no policy behind it is a device whose trust decision nobody made.
#[test]
fn a_declared_tls_policy_reaches_the_capabilities_dto() {
    use liberated_bread_core::api::device_api::network_capabilities;

    let mut declared = 0usize;
    for path in vendored_yaml_paths() {
        let text = fs::read_to_string(&path).expect("spec reads");
        let file = path.file_name().unwrap().to_string_lossy().to_string();
        let Ok(spec) = parse_device_spec(&text) else {
            continue;
        };
        let Some(policy) = spec
            .device
            .identification
            .as_ref()
            .and_then(|i| i.tls.as_ref())
        else {
            continue;
        };
        declared += 1;

        let caps = network_capabilities(text).expect("capabilities resolve");
        assert_eq!(
            caps.tls_verification, policy.verification,
            "{file}: the spec states a TLS policy the consumer never sees"
        );
        assert_eq!(caps.tls_self_signed, policy.self_signed, "{file}");

        // A LAN certificate that will never validate is exactly the case where
        // a client has to be told what to do, so saying `self_signed` and
        // nothing else leaves the decision where it was: invented downstream.
        if policy.self_signed {
            assert!(
                policy.verification.is_some(),
                "{file}: declares a self-signed certificate and no policy for \
                 it, so every consumer invents one"
            );
        }
    }
    assert!(
        declared >= 2,
        "only {declared} spec(s) declare identification.tls — this test is \
         reading the wrong place"
    );
}

/// A bare web server on the LAN is not twenty-one smart devices.
///
/// `_http._tcp` is answered by every router admin page, NAS and printer web UI
/// there is, and seventeen vendored specs mention it inside a discovery method.
/// When the matcher started reading those methods, all seventeen began claiming
/// every web server on the link at `Possible` — the same failure the absent
/// port axis was removed for, arriving by a different door.
///
/// The rule that fixes it is not "never trust a shared type", because that
/// would also throw away the specs that say WHICH one they mean: ESPHome
/// narrows `_http._tcp` to nodes publishing a `config_hash` TXT record. So a
/// shared type counts as evidence only where the spec narrowed it, and this
/// pins both halves against the real catalogue.
#[test]
fn a_bare_shared_service_type_claims_nothing_in_the_catalogue() {
    use liberated_bread_core::api::device_api::{
        load_device_spec, match_network_device, NetworkDeviceDto, SpecIdentityDto,
    };

    let identities: Vec<SpecIdentityDto> = vendored_yaml_paths()
        .into_iter()
        .filter_map(|path| load_device_spec(fs::read_to_string(path).ok()?).ok())
        .map(|spec| SpecIdentityDto::from(&spec))
        .collect();
    assert!(identities.len() > 100, "the catalogue did not load");

    let bare = NetworkDeviceDto {
        name: String::new(),
        hostname: None,
        service_types: vec!["_http._tcp.local.".into()],
        ssdp_targets: Vec::new(),
        answered_lan_protocols: Vec::new(),
        txt: Default::default(),
        port: Some(80),
        mac: None,
    };
    let matches = match_network_device(identities.clone(), bare);
    assert!(
        matches.is_empty(),
        "a host whose only signal is `_http._tcp` was claimed by {} spec(s): {:?}",
        matches.len(),
        matches.iter().map(|m| &m.device_name).collect::<Vec<_>>()
    );

    // The SSDP counterpart. bose-soundtouch and hisense-vidaa both declare
    // the DLNA renderer class, squeezebox-slimproto the server class, and the
    // scan's `ssdp:all` search collects exactly those STs from every Sonos,
    // smart TV and NAS on the link — each of which came back a Strong Bose
    // tied with a Strong Hisense, or a Strong Squeezebox.
    for class in [
        "urn:schemas-upnp-org:device:MediaRenderer:1",
        "urn:schemas-upnp-org:device:MediaServer:1",
    ] {
        let dlna = NetworkDeviceDto {
            name: String::new(),
            hostname: None,
            service_types: Vec::new(),
            ssdp_targets: vec![class.into()],
            answered_lan_protocols: Vec::new(),
            txt: Default::default(),
            port: None,
            mac: None,
        };
        let matches = match_network_device(identities.clone(), dlna);
        assert!(
            matches.is_empty(),
            "a host whose only signal is `{class}` was claimed by {} spec(s): {:?}",
            matches.len(),
            matches.iter().map(|m| &m.device_name).collect::<Vec<_>>()
        );
    }

    // The half that must keep working: the same host, publishing what ESPHome
    // publishes, is an ESPHome node.
    let node = NetworkDeviceDto {
        name: String::new(),
        hostname: None,
        service_types: vec!["_http._tcp.local.".into()],
        ssdp_targets: Vec::new(),
        answered_lan_protocols: Vec::new(),
        txt: std::collections::HashMap::from([
            ("config_hash".to_string(), "0123abcd".to_string()),
            ("version".to_string(), "2026.1.0".to_string()),
        ]),
        port: Some(80),
        mac: None,
    };
    let named = match_network_device(identities, node);
    assert!(
        !named.is_empty(),
        "a narrowed shared type must still name its device"
    );
}

/// A BLE family spec narrows to the model in front of it.
///
/// `device.variants[]` had two axes, SSDP and a state probe, and a BLE device
/// has neither — so a family spec narrowed to nothing and every model's
/// entities came across at once. seeblue-motorcycle-led and
/// leds2rave4-lunchbox-led each declare TWO lights with the SAME NAME speaking
/// DIFFERENT command dialects, and the consumer's name dedupe kept whichever
/// the spec declared first: a LEDGlowV2 driven with the Direct dialect's
/// frames, silently and always.
#[test]
fn a_ble_family_spec_narrows_to_the_device_in_front_of_it() {
    use liberated_bread_core::api::device_api::ble_variant_names_for_device;

    let spec = |file: &str| fs::read_to_string(spec_path(file)).expect("spec reads");
    let matched = |file: &str, name: &str, uuids: &[&str]| {
        ble_variant_names_for_device(
            spec(file),
            name.to_string(),
            uuids.iter().map(|u| u.to_string()).collect(),
        )
        .expect("narrowing resolves")
    };

    // Two dialects, told apart only by the advertised name. Exactly one
    // variant survives, and it is the right one — which matters because the
    // two ENTITIES share a name, so the variant is the only thing that
    // distinguishes them.
    assert_eq!(
        matched("seeblue-motorcycle-led.yaml", "LEDGlowV2", &[]),
        vec!["LEDGlow-V2"]
    );
    assert_eq!(
        matched("seeblue-motorcycle-led.yaml", "LEDGlowMoto", &[]),
        vec!["Direct"]
    );

    // The trap. SP110E declares ONLY service ffe0, which SP107E also carries
    // alongside its name prefix — so a rule that merely required every
    // DECLARED axis to match would hand an SP107E device both dialects again.
    // The most specific match wins: two axes beat one.
    const FFE0: &str = "0000ffe0-0000-1000-8000-00805f9b34fb";
    assert_eq!(
        matched("leds2rave4-lunchbox-led.yaml", "SP107e_ABC", &[FFE0]),
        vec!["SP107E"],
        "SP107E must not also claim SP110E"
    );
    assert_eq!(
        matched("leds2rave4-lunchbox-led.yaml", "unnamed-strip", &[FFE0]),
        vec!["SP110E"]
    );

    // A treadmill's verbs come from the service it actually carries.
    const FTMS: &str = "00001826-0000-1000-8000-00805f9b34fb";
    const FT: &str = "0000fff0-0000-1000-8000-00805f9b34fb";
    assert_eq!(matched("urevo-walking-pad.yaml", "", &[FTMS]), vec!["FTMS"]);
    assert_eq!(matched("urevo-walking-pad.yaml", "", &[FT]), vec!["FT"]);

    // THE SPELLING THE APP ACTUALLY SENDS.
    //
    // Everything above hands over the full 128-bit form a spec is written in.
    // Dart does not: `SpecMatchRequest.forServices` folds every discovered
    // service through `normalizeUuid` first, so what crosses the FFI is
    // `1826`, `ffe0`. Comparing that to the spec's raw string is false, so the
    // service axis matched nothing, every variant was rejected for failing a
    // declared axis, and the empty result read as "do not narrow" — the
    // behaviour that shipped before any of this existed. Both features built
    // on this narrowing were inert in the app for as long as this test only
    // spoke the long form.
    //
    // So both spellings, on every spec that narrows by service. A test that
    // agrees with the code instead of with its caller is worth nothing, and
    // this is what that looks like when it happens.
    for (spec_file, name, short, long, expected) in [
        ("urevo-walking-pad.yaml", "", "1826", FTMS, "FTMS"),
        ("urevo-walking-pad.yaml", "", "fff0", FT, "FT"),
        ("kingsmith-walkingpad.yaml", "", "1826", FTMS, "FTMS"),
        (
            "kingsmith-walkingpad.yaml",
            "",
            "fe00",
            "0000fe00-0000-1000-8000-00805f9b34fb",
            "WiLink",
        ),
        (
            "leds2rave4-lunchbox-led.yaml",
            "unnamed-strip",
            "ffe0",
            FFE0,
            "SP110E",
        ),
    ] {
        assert_eq!(
            matched(spec_file, name, &[short]),
            vec![expected],
            "{spec_file} must narrow on the short form Dart sends ({short})"
        );
        assert_eq!(
            matched(spec_file, name, &[short]),
            matched(spec_file, name, &[long]),
            "{spec_file}: the two spellings of one UUID must agree"
        );
    }

    // The negative that matters most: a device matching NO variant narrows to
    // nothing, which the consumer reads as "show everything". Narrowing a
    // device we cannot identify would blank it.
    assert!(matched("urevo-walking-pad.yaml", "", &[]).is_empty());
    assert!(matched("seeblue-motorcycle-led.yaml", "SomethingElse", &[]).is_empty());

    // And the specs that narrow by service alone must still narrow: a real
    // Airthings carries one family's services.
    let airthings = parse_device_spec(&spec("airthings-wave-family.yaml")).expect("parses");
    let variants = airthings
        .device
        .variants
        .as_ref()
        .and_then(|v| v.as_sequence())
        .expect("airthings declares variants");
    let first: Vec<&str> = variants
        .iter()
        .filter_map(|v| {
            v.get("identification")?
                .get("service_uuids")?
                .as_sequence()?
                .first()?
                .as_str()
        })
        .take(1)
        .collect();
    assert!(
        !first.is_empty(),
        "airthings variants declare service uuids"
    );
    let one_model = matched("airthings-wave-family.yaml", "", &first);
    assert_eq!(
        one_model.len(),
        1,
        "one model's services identify one model: {one_model:?}"
    );
}

/// Every entity that scopes itself to a variant carries that scoping across
/// the FFI, or the consumer cannot apply the narrowing above.
#[test]
fn a_scoped_entity_carries_its_variants_across_the_ffi() {
    use liberated_bread_core::api::device_api::load_device_spec;

    let dto = load_device_spec(
        fs::read_to_string(spec_path("seeblue-motorcycle-led.yaml")).expect("reads"),
    )
    .expect("parses");
    let lights: Vec<&Vec<String>> = dto
        .entities
        .iter()
        .filter(|e| e.name == "Motorcycle LEDs")
        .map(|e| &e.variants)
        .collect();
    assert_eq!(
        lights.len(),
        2,
        "both dialects still cross; narrowing picks"
    );
    assert_ne!(
        lights[0], lights[1],
        "the variants are the ONLY thing telling these two apart — they share a name"
    );
    assert!(lights.iter().all(|v| !v.is_empty()));
}

/// The catalogue's setup restructure files a multi-phase route as ONE method
/// carrying `stages` — and a consumer that reads only `steps` silently
/// renders those routes as prose with no procedure. This pins, across every
/// vendored spec, that a method upstream gave stages surfaces them with their
/// steps intact, so the next restructure fails here instead of on a phone.
#[test]
fn staged_setup_routes_keep_their_procedures() {
    use liberated_bread_core::spec::setup::setup_instructions;

    let mut staged_specs = 0;
    for path in vendored_yaml_paths() {
        let yaml =
            fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
        let raw: serde_yaml::Value = match serde_yaml::from_str(&yaml) {
            Ok(v) => v,
            // every_vendored_spec_parses_ok owns unparseable specs.
            Err(_) => continue,
        };
        let raw_staged = raw
            .get("device")
            .and_then(|d| d.get("setup"))
            .and_then(|s| s.get("methods"))
            .and_then(|m| m.as_sequence())
            .map(|methods| methods.iter().filter(|m| m.get("stages").is_some()).count())
            .unwrap_or(0);
        if raw_staged == 0 {
            continue;
        }
        staged_specs += 1;

        let spec = parse_device_spec(&yaml)
            .unwrap_or_else(|e| panic!("{} should parse: {e}", path.display()));
        let instructions = setup_instructions(&spec).unwrap_or_else(|| {
            panic!(
                "{} declares staged setup methods but yields no instructions",
                path.display()
            )
        });
        let surfaced = instructions
            .methods
            .iter()
            .filter(|m| !m.stages.is_empty())
            .count();
        assert_eq!(
            surfaced,
            raw_staged,
            "{}: {raw_staged} staged method(s) in the YAML, {surfaced} surfaced",
            path.display()
        );
        for method in instructions.methods.iter().filter(|m| !m.stages.is_empty()) {
            let steps: usize = method.stages.iter().map(|s| s.steps.len()).sum();
            assert!(
                steps > 0,
                "{}: staged route {:?} surfaces no steps at all",
                path.display(),
                method.name
            );
        }
    }
    // The restructure folded eight routes; a catalogue refresh that loses
    // them all at once is a parse regression, not a spec change.
    assert!(
        staged_specs >= 8,
        "expected at least the eight staged routes upstream filed, found {staged_specs}"
    );
}

/// hue-bridge moved `issues_credentials` onto its button_pairing STAGE. If
/// the credential join stops seeing it, `must_be_asked_for` flips true and
/// the app prompts a person to hand-type the whitelist username the link
/// button was about to mint — the exact anti-pattern the credentials card's
/// own docs forbid.
#[test]
fn hue_username_is_issued_by_the_link_button_stage() {
    use liberated_bread_core::spec::credentials::required_credentials;

    let yaml = fs::read_to_string(spec_path("hue-bridge.yaml"))
        .expect("hue-bridge.yaml should be bundled");
    let spec = parse_device_spec(&yaml).expect("hue-bridge.yaml should parse");
    let credentials = required_credentials(&spec);
    let username = credentials
        .iter()
        .find(|c| c.name == "username")
        .expect("hue declares the whitelist username credential");
    let issued = username.issued_by.as_ref().expect(
        "the link-button stage issues the username; None here means the UI would prompt for it",
    );
    assert_eq!(issued.method, "button_pairing");
    assert!(!username.must_be_asked_for());
}

/// Every regex matcher the catalogue writes must COMPILE in this build.
/// Upstream validates patterns with Python `re`, which accepts `\d`, `\w`,
/// `\b` and `(?i)`; the regex crate only compiles those with its
/// `unicode-perl`/`unicode-case` features on. A pattern that fails to
/// compile is cached as a permanent non-match — a matcher that silently
/// claims nothing, which for a warning-category spec is fail-open. This
/// gate turns that silence into a red test the moment a refreshed catalogue
/// (or a feature-list trim in Cargo.toml) produces an uncompilable pattern.
#[test]
fn every_vendored_regex_matcher_compiles_in_this_build() {
    fn regex_values(node: &serde_yaml::Value, out: &mut Vec<String>) {
        match node {
            serde_yaml::Value::Mapping(map) => {
                let is_regex = map
                    .get("match")
                    .and_then(|m| m.as_str())
                    .is_some_and(|m| m == "regex");
                if is_regex {
                    if let Some(value) = map.get("value").and_then(|v| v.as_str()) {
                        out.push(value.to_string());
                    }
                    if let Some(values) = map.get("values").and_then(|v| v.as_sequence()) {
                        out.extend(values.iter().filter_map(|v| v.as_str().map(str::to_string)));
                    }
                }
                for (_, child) in map {
                    regex_values(child, out);
                }
            }
            serde_yaml::Value::Sequence(seq) => {
                for child in seq {
                    regex_values(child, out);
                }
            }
            _ => {}
        }
    }

    let mut patterns = Vec::new();
    for path in vendored_yaml_paths() {
        let text = fs::read_to_string(&path).expect("vendored yaml is readable");
        let Ok(doc) = serde_yaml::from_str::<serde_yaml::Value>(&text) else {
            continue; // every_vendored_spec_parses_ok owns parse failures
        };
        regex_values(&doc, &mut patterns);
    }
    assert!(
        patterns.len() >= 10,
        "expected the catalogue's dozen-odd regex matchers, found {} — \
         did the matcher shape change under this gate?",
        patterns.len()
    );
    for pattern in patterns {
        // The same builder settings `regex_for` compiles with (size limits
        // bounded so a hostile pattern cannot balloon); a pattern that fails
        // HERE would match nothing THERE.
        assert!(
            regex::RegexBuilder::new(&pattern)
                .size_limit(1 << 20)
                .dfa_size_limit(1 << 20)
                .build()
                .is_ok(),
            "vendored matcher pattern {pattern:?} does not compile in this build's \
             regex feature set (see the regex entry in Cargo.toml)"
        );
    }
}

/// Both vendored televisions must DECLARE their pairing token: the stores
/// are wired only for declared credentials, so a set whose token vanishes
/// from this list re-pairs on every group run — the Allow prompt raised
/// mid-run for a TV that was already paired.
#[test]
fn the_vendored_tvs_declare_their_pairing_tokens() {
    use liberated_bread_core::spec::credentials::required_credentials;

    for file in ["samsung-tizen-tv.yaml", "lg-webos.yaml"] {
        let yaml =
            fs::read_to_string(spec_path(file)).unwrap_or_else(|_| panic!("{file} is bundled"));
        let spec = parse_device_spec(&yaml).unwrap_or_else(|_| panic!("{file} parses"));
        let credentials = required_credentials(&spec);
        let token = credentials
            .iter()
            .find(|c| c.issued_by.as_ref().is_some_and(|i| i.method == "websocket_pairing"))
            .unwrap_or_else(|| {
                panic!("{file} must report its websocket pairing credential; an empty list is what re-paired TVs mid-group-run")
            });
        assert!(
            !token.must_be_asked_for(),
            "{file}: a pairing-minted token must never be prompted for"
        );
    }
}

/// The nine catalogue parameters that spell their enumeration `values` must
/// reach a consumer as a CHOICE, not as a range.
///
/// They are real switches and mode bytes — elk-bledom's on/off `state`,
/// wl-smartled's four-way `light_mode` — and the struct that carries a BLE
/// parameter had no field for the table, so every one of them drew as a
/// 0..255 slider with no hint that two or four values mean anything. Counted
/// here rather than listed one by one: the count is what says the whole set
/// is read, and a spec refresh that adds a tenth should notice it.
#[test]
fn the_vendored_coded_parameters_offer_their_codes_as_choices() {
    let mut coded: Vec<(String, String, String, usize)> = Vec::new();
    for path in vendored_yaml_paths() {
        let raw = fs::read_to_string(&path).expect("a bundled spec should read");
        let Ok(spec) = parse_device_spec(&raw) else {
            continue;
        };
        for service in &spec.services {
            for characteristic in &service.characteristics {
                let Some(commands) = &characteristic.commands else {
                    continue;
                };
                for (command_name, command) in commands {
                    let Some(parameters) = &command.parameters else {
                        continue;
                    };
                    for (name, parameter) in &parameters.params {
                        if parameter.values.is_none() {
                            continue;
                        }
                        let choices = parameter.allowed_with_labels().unwrap_or_else(|| {
                            panic!(
                                "{}: {command_name}.{name} declares a code table and \
                                     offers no choices",
                                path.display()
                            )
                        });
                        coded.push((
                            path.file_name().unwrap().to_string_lossy().into_owned(),
                            command_name.clone(),
                            name.clone(),
                            choices.len(),
                        ));
                    }
                }
            }
        }
    }
    assert_eq!(
        coded.len(),
        9,
        "the catalogue's coded BLE parameters, each offering its codes: {coded:#?}"
    );
    assert!(
        coded.iter().all(|(_, _, _, count)| *count >= 2),
        "a code table with one entry is not a choice: {coded:#?}"
    );
}

/// No bundled entity may claim a state poll the spec cannot answer.
///
/// `state_command` NAMES something in the spec's own vocabulary — the schema
/// says so in those words — and `render_state_request` answers CommandNotFound
/// for anything else. Divoom's panels and a Sony set write a wire call from
/// the vendor's own protocol there (`Channel/GetOnOff`, `getPowerStatus`), and
/// while those were admitted the screen polled them every four seconds and
/// drew sensors that could never fill. The resolver refuses them now; this is
/// the guard that a refresh reintroducing one is visible here rather than on a
/// device.
#[test]
fn no_vendored_entity_binds_a_state_command_that_cannot_be_rendered() {
    use liberated_bread_core::protocol::http::render_state_request;
    use liberated_bread_core::spec::bindings::{network_entities, state_binding, StateBinding};

    for path in vendored_yaml_paths() {
        let raw = fs::read_to_string(&path).expect("a bundled spec should read");
        let Ok(spec) = parse_device_spec(&raw) else {
            continue;
        };
        for entity in network_entities(&spec) {
            let Some(StateBinding::Command(name)) = state_binding(&spec, entity) else {
                continue;
            };
            // Placeholders are the caller's to fill, so an empty value map
            // may still fail on one; what must not happen is the command
            // being unknown.
            if let Err(e) = render_state_request(&spec, name, &Default::default()) {
                assert!(
                    !e.to_string().contains("not found"),
                    "{}: entity {:?} binds state_command {name:?}, which this \
                     spec describes nowhere: {e}",
                    path.display(),
                    entity.name
                );
            }
        }
    }
}

/// Every `udp_broadcast` block in the catalogue parses into the typed model.
///
/// Thirteen specs declare one and the app executed none of them: eight vendor
/// probes were Dart constants instead, so six devices whose spec is complete
/// could not be found at all, and adding a ninth meant editing a 2700-line
/// service (SPECS_TO_FIX.md S-10). Reading them as data is the first half of
/// closing that; this pins that the data is actually there and well-formed,
/// so the executor has something to stand on.
#[test]
fn every_declared_udp_probe_parses() {
    let mut declaring = 0usize;
    let mut with_payload = 0usize;
    let mut passive_only = 0usize;

    for file in vendored_yaml_paths() {
        let path = file.file_name().unwrap().to_string_lossy().into_owned();
        let yaml = fs::read_to_string(&file).expect("spec file should be readable");
        let Ok(spec) = parse_device_spec(&yaml) else {
            continue; // parseability is `every_vendored_spec_parses_ok`'s job
        };
        let probes = spec.device.udp_broadcast_probes();
        if probes.is_empty() {
            continue;
        }
        declaring += 1;
        for probe in &probes {
            assert!(
                probe.port.is_some(),
                "{path}: a udp_broadcast probe with no port cannot be sent or listened for"
            );
            // Either it says what to send, or it says the device speaks first.
            let speaks_first = probe.passive_ok.unwrap_or(false);
            match probe.probe_hex.as_deref() {
                Some(hex) => {
                    with_payload += 1;
                    assert!(
                        hex.len() % 2 == 0 && hex.chars().all(|c| c.is_ascii_hexdigit()),
                        "{path}: probe_hex is not hex: {hex}"
                    );
                }
                None => {
                    // A probe that neither carries a payload nor says the device
                    // speaks first tells a client nothing it can act on. One spec
                    // is in that state because the payload it needs is not
                    // expressible: the Aqara hub wants a JSON document carrying
                    // THIS phone's LAN address and listen port, so no fixed hex
                    // string can stand for it, and the bytes live in prose notes
                    // instead (SPECS_TO_FIX.md S-20).
                    const PAYLOAD_ONLY_IN_PROSE: &[&str] = &["aqara-hub.yaml"];
                    assert!(
                        speaks_first || PAYLOAD_ONLY_IN_PROSE.contains(&path.as_str()),
                        "{path}: a probe with no payload and no passive_ok says nothing a \
                         client could act on"
                    );
                    passive_only += 1;
                }
            }
            // Identity fields must name a dialect this app can grow to read.
            if let Some(mapping) = &probe.identity_mapping {
                for field in mapping.stable_keys.iter().chain(mapping.display.iter()) {
                    let (dialect, _) = field.dialect();
                    assert!(
                        matches!(dialect, "json" | "tlv" | "csv" | "payload"),
                        "{path}: identity source dialect {dialect} is not one the \
                         catalogue uses elsewhere (json/tlv/csv/payload)"
                    );
                    assert!(
                        !field.name().is_empty(),
                        "{path}: an identity field resolves to no name"
                    );
                }
            }
        }
    }

    assert!(
        declaring >= 10,
        "the catalogue declared {declaring} udp_broadcast specs; it had 10 when this \
         was written, and a drop means a spec lost its block"
    );
    assert!(
        with_payload > 0 && passive_only > 0,
        "both shapes are exercised"
    );
}

/// The probes the catalogue hands the scanner are the ones the app already
/// sends, byte for byte.
///
/// Four vendor probes lived as Dart constants beside a hand-written transport
/// each (`_ubiquitiProbe`, `_mikrotikProbe`, the Kasa `get_sysinfo` plaintext,
/// and Rust's own `roomba::DISCOVERY_PROBE`), with nothing tying them to the
/// spec that documents the same bytes. They agree today — this pins that, so
/// moving the transports onto catalogue data is a swap rather than a rewrite,
/// and so a spec edit that changes a probe cannot silently diverge from the
/// constant the way the LIFX header offset once did.
#[test]
fn the_catalogue_hands_over_the_probes_the_app_already_sends() {
    use liberated_bread_core::api::spec_handle::new_catalogue;

    let mut catalogue = new_catalogue();
    let paths = vendored_yaml_paths();
    let keys: Vec<String> = paths
        .iter()
        .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    let yamls: Vec<String> = paths
        .iter()
        .map(|p| fs::read_to_string(p).expect("spec file should be readable"))
        .collect();
    let failed = catalogue
        .add_specs(keys, yamls)
        .expect("the bundled catalogue should load");
    assert!(
        failed.is_empty(),
        "specs failed to parse: {:?}",
        failed.iter().map(|f| &f.key).collect::<Vec<_>>()
    );

    let probes = catalogue.udp_broadcast_probes();
    let by_key =
        |key: &str, port: u16| -> Vec<&liberated_bread_core::api::spec_handle::UdpProbeDto> {
            probes
                .iter()
                .filter(|p| p.spec_key == key && p.port == port)
                .collect()
        };

    // Ubiquiti and UniFi Protect: the same four bytes on 10001.
    for key in ["ubiquiti-unifi-device.yaml", "unifi-protect-camera.yaml"] {
        let found = by_key(key, 10001);
        assert_eq!(found.len(), 1, "{key}: one probe on 10001");
        assert_eq!(
            found[0].probe,
            vec![0x01, 0x00, 0x00, 0x00],
            "{key}: must match `_ubiquitiProbe` in real_network_scan_service.dart"
        );
    }

    // MikroTik MNDP: a four-byte-zero solicitation on 5678.
    let mikrotik = by_key("mikrotik-routeros.yaml", 5678);
    assert_eq!(mikrotik.len(), 1);
    assert_eq!(
        mikrotik[0].probe,
        vec![0, 0, 0, 0],
        "must match `_mikrotikProbe` in real_network_scan_service.dart"
    );
    assert!(
        mikrotik[0].passive_ok,
        "a RouterOS box also beacons unprompted, which is why that transport \
         binds :5678 rather than an ephemeral port"
    );

    // iRobot: the nine ASCII bytes Rust already holds.
    let roomba = by_key("irobot-roomba.yaml", 5678);
    assert_eq!(roomba.len(), 1);
    assert_eq!(
        roomba[0].probe,
        liberated_bread_core::protocol::roomba::DISCOVERY_PROBE.to_vec(),
        "the spec and `roomba::DISCOVERY_PROBE` describe the same nine bytes"
    );

    // Kasa: the spec carries the ENCRYPTED datagram, so it decrypts to the
    // plaintext the Dart constant holds. XOR-autokey, initial key 171.
    let kasa = by_key("tplink-kasa-smart-plug.yaml", 9999);
    assert_eq!(kasa.len(), 1);
    let mut key = 171u8;
    let plain: Vec<u8> = kasa[0]
        .probe
        .iter()
        .map(|&c| {
            let p = c ^ key;
            key = c;
            p
        })
        .collect();
    assert_eq!(
        String::from_utf8(plain).expect("the Kasa probe decrypts to JSON"),
        r#"{"system":{"get_sysinfo":null}}"#,
        "must match `_kasaProbeJson` in real_network_scan_service.dart"
    );

    // What the catalogue-driven transport actually sends, spelled out: the
    // probes that carry a payload, minus the five specs with a hand-written
    // transport in real_network_scan_service.dart. Today that is the Milight
    // bridge's two strings and nothing else — every other declared probe is
    // `passive_ok` with no payload (Tuya, Synology) or has no payload at all
    // (the Aqara hub, S-20). Pinned here rather than in Dart because this is
    // where the data is: a spec that adds a probe should show up as a change
    // to this list, which is the whole point of reading them as data.
    let mut would_send: Vec<String> = probes
        .iter()
        .filter(|p| !p.probe.is_empty())
        .filter(|p| {
            !matches!(
                p.spec_key.as_str(),
                "tplink-kasa-smart-plug.yaml"
                    | "mikrotik-routeros.yaml"
                    | "ubiquiti-unifi-device.yaml"
                    | "unifi-protect-camera.yaml"
                    | "irobot-roomba.yaml"
            )
        })
        .map(|p| format!("{}:{}", p.spec_key, p.port))
        .collect();
    would_send.sort();
    assert_eq!(
        would_send,
        vec![
            "limitlessled-milight-bridge.yaml:48899",
            "limitlessled-milight-bridge.yaml:48899",
        ]
    );

    // And the probes for devices the app cannot yet find are present, which is
    // the point of reading them as data (SPECS_TO_FIX.md S-10).
    assert_eq!(
        by_key("limitlessled-milight-bridge.yaml", 48899).len(),
        2,
        "the bridge answers two different probes depending on firmware"
    );
    let synology = by_key("synology-diskstation.yaml", 9999);
    assert_eq!(synology.len(), 1);
    assert!(
        synology[0].passive_ok && synology[0].probe.is_empty(),
        "a DiskStation is heard, not asked — it shares port 9999 with Kasa"
    );
}

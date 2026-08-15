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

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
    let names: Vec<_> = paths
        .iter()
        .map(|path| path.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, ["example-bulb.yaml"]);

    for path in &paths {
        let yaml = fs::read_to_string(path).expect("spec file should be readable");
        parse_device_spec(&yaml).unwrap_or_else(|e| {
            panic!(
                "vendored spec `{}` should parse, but failed: {e}",
                path.file_name().unwrap().to_string_lossy()
            )
        });
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

/// Invariant: `bundledSpecFiles` in `lib/providers/device_spec_provider.dart`
/// must list exactly the files under `assets/device_specs/`. Nothing enforces
/// this at build time — AssetBundle has no directory-listing API, so the Dart
/// list is hand-maintained, and asset-load failures are swallowed at runtime.
/// An asset missing from the list is therefore a spec that silently never
/// loads in-app; a listed-but-deleted asset is a dead entry. This test is the
/// mechanical coupling (the Dart source is read as text only — it belongs to
/// the Flutter side and is not edited from here).
#[test]
fn dart_bundled_spec_list_matches_asset_directory() {
    let dart_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust crate should have a parent repo dir")
        .join("lib/providers/device_spec_provider.dart");
    let dart_src = fs::read_to_string(&dart_path)
        .unwrap_or_else(|e| panic!("reading {}: {e}", dart_path.display()));

    // Simple string scan for 'assets/device_specs/<file>' literals: take
    // everything from the path prefix up to the closing quote. Quote-agnostic
    // so a lint-driven switch between '…' and "…" doesn't blind the scan.
    const PREFIX: &str = "assets/device_specs/";
    let mut declared = BTreeSet::new();
    for (idx, _) in dart_src.match_indices(PREFIX) {
        let rest = &dart_src[idx + PREFIX.len()..];
        if let Some(end) = rest.find(['\'', '"']) {
            let name = &rest[..end];
            if name.ends_with(".yaml") || name.ends_with(".yml") {
                declared.insert(name.to_string());
            }
        }
    }

    let on_disk: BTreeSet<String> = vendored_yaml_paths()
        .iter()
        .map(|p| p.file_name().unwrap().to_string_lossy().into_owned())
        .collect();

    assert_eq!(
        declared, on_disk,
        "bundledSpecFiles in lib/providers/device_spec_provider.dart must list \
         exactly the *.yaml files in assets/device_specs/ — an unlisted asset \
         never loads in the app, and a listed-but-missing one is a dead entry"
    );
}

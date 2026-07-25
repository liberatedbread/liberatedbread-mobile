// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! End-to-end consumption test: every bundled device spec in the Flutter app's
//! `assets/device_specs/` must parse via the real `parse_device_spec()`.
//!
//! The specs are read from the app's real asset directory at test time (the
//! same files `rootBundle` ships to the device), so this test fails loudly if a
//! bundled fallback spec cannot be parsed.

use std::fs;
use std::path::PathBuf;

use opengreeniot_core::spec::parser::parse_device_spec;

/// Absolute path to `<repo>/assets/device_specs`, derived from this crate's
/// manifest dir (`<repo>/rust`) so the test is location-independent.
fn assets_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("rust crate should have a parent repo dir")
        .join("assets/device_specs")
}

/// Every `*.yaml` under `assets/device_specs/` (manifest.json excluded).
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

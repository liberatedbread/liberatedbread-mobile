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

use liberated_bread_core::spec::parser::parse_device_spec;

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
    // fardriver-controller: declares `min` on a `bytes` parameter. Byte-string
    // parameters have no numeric range, so the bound is meaningless and the
    // validator is right to reject it — the spec should drop `min` or change
    // the type.
    const KNOWN_BAD: &[&str] = &["fardriver-controller.yaml"];

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

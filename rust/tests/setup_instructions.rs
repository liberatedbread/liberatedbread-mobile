// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Setup/troubleshooting instructions driven from the vendored catalogue.
//!
//! The unit tests in `spec::setup` pin the extractor against inline fixtures.
//! This closes the loop the other way: it reads the REAL vendored Ember spec —
//! the same file the app bundles — and asserts the "how to connect / why it
//! won't / how to reset" prose crosses into typed instructions with its labels
//! intact. A spec refresh that drops the setup block, renames the reset
//! procedure, or removes the single-connection rejoin note fails here instead
//! of silently emptying the in-app help screen.

use liberated_bread_core::spec::parser::parse_device_spec;
use liberated_bread_core::spec::setup::setup_instructions;

fn vendored(device: &str) -> String {
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .join("vendor/protocol-specs/device-specs/devices")
        .join(device);
    std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {path:?}: {e}"))
}

#[test]
fn the_ember_spec_yields_renderable_help() {
    let spec = parse_device_spec(&vendored("ember-mug.yaml")).expect("Ember spec parses");
    let help = setup_instructions(&spec).expect("Ember declares a setup block to render");

    // The pairing method carries steps a user can follow.
    assert!(
        help.methods.iter().any(|m| !m.steps.is_empty()),
        "at least one setup method should carry steps"
    );

    // The factory-reset procedure is named for what it is (the label the app
    // shows as the procedure heading), not the button motion.
    let reset = help
        .factory_reset
        .as_ref()
        .expect("Ember documents a factory reset");
    assert!(
        reset.procedures.iter().any(|p| p.name == "Factory reset"),
        "the reset procedure should be labelled 'Factory reset', got {:?}",
        reset.procedures.iter().map(|p| &p.name).collect::<Vec<_>>()
    );

    // The rejoin note is the actual answer to "why won't it connect" for this
    // device (a phone still holding the one allowed connection), so the help
    // screen leans on it — it must survive the crossing.
    let rejoin = help.rejoin.as_ref().expect("Ember documents rejoin");
    assert!(
        rejoin
            .notes
            .as_deref()
            .is_some_and(|n| !n.trim().is_empty()),
        "the rejoin note should be present and non-empty"
    );
}

#[test]
fn a_ble_spec_without_a_setup_block_yields_no_help() {
    // A minimal BLE spec with no setup block must produce no instructions, so
    // the UI shows no "How to connect" affordance rather than an empty screen.
    let yaml = r#"
device:
  name: "Bare Beacon"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
"#;
    let spec = parse_device_spec(yaml).expect("parses");
    assert!(setup_instructions(&spec).is_none());
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

use std::collections::HashMap;

use liberated_bread_core::api::device_api::encode_command;
use liberated_bread_core::spec::parser::parse_device_spec;

#[test]
fn foreo_commands_resolve_by_characteristic_when_service_is_unknown() {
    let yaml = include_str!("../../vendor/protocol-specs/device-specs/devices/foreo-peach-2.yaml");
    let bytes = encode_command(
        Some(yaml.to_string()),
        Some("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa".to_string()),
        "0000fff1-0000-1000-8000-00805f9b34fb".to_string(),
        "set_removal_mode_pro".to_string(),
        HashMap::new(),
    )
    .unwrap();
    assert_eq!(bytes, [0x0A, 0xD0, 0x06]);
}

#[test]
fn unknown_service_never_collapses_duplicate_characteristics() {
    let yaml = r#"
device:
  name: Duplicate Characteristics
  manufacturer: Test
  manufacturer_status: active
  protocol: ble
services:
  - uuid: "00000001-0000-1000-8000-00805f9b34fb"
    name: First
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: Shared
        properties: ["write"]
        commands:
          first:
            description: First command
            value: [1]
  - uuid: "00000002-0000-1000-8000-00805f9b34fb"
    name: Second
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: Shared
        properties: ["write"]
        commands:
          second:
            description: Second command
            value: [2]
"#;
    let spec = parse_device_spec(yaml).unwrap();
    assert!(
        spec.find_writable_characteristic_in(
            "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa",
            "0000fff1-0000-1000-8000-00805f9b34fb",
        )
        .is_none()
    );
}

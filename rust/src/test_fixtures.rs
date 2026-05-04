// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
#![cfg(test)]

//! Shared fixtures for unit tests across the crate.

/// Wrap a characteristic-level YAML block in a minimal device-spec skeleton:
/// one service, one characteristic, sentinel names. Use for tests that only
/// care about the contents of the characteristic block (e.g. parameter-bound
/// or format-field validation).
pub(crate) fn make_minimal_spec(char_block: &str) -> String {
    format!(
        r#"
device:
  name: x
  manufacturer: x
  manufacturer_status: abandoned
  protocol: ble
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: s
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: c
{char_block}
"#
    )
}

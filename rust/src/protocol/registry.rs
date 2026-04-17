// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Protocol registry — resolves a device spec or service UUID to the right
//! `DeviceProtocol` implementation.
//!
//! The registry checks standard BLE profiles first (Battery, Device Info, etc.)
//! and falls back to `GenericProtocol` for spec-driven devices.

use super::generic::GenericProtocol;
use super::profiles;
use super::traits::DeviceProtocol;
use crate::spec::types::DeviceSpec;

/// Manages protocol instances for device communication.
///
/// Used by the FFI API layer to get the right protocol for a given device.
#[derive(Default)]
pub struct ProtocolRegistry {}

impl ProtocolRegistry {
    pub fn new() -> Self {
        Self::default()
    }

    /// Get a protocol implementation for a device spec.
    ///
    /// Returns a `GenericProtocol` driven by the spec. For standard profiles,
    /// use `get_standard_profile` instead.
    pub fn get_protocol(&self, spec: &DeviceSpec) -> Box<dyn DeviceProtocol> {
        Box::new(GenericProtocol::new(spec.clone()))
    }

    /// Get a protocol for a standard BLE profile by service UUID.
    ///
    /// Returns `None` if the UUID doesn't match a known standard profile.
    pub fn get_standard_profile(&self, service_uuid: &str) -> Option<Box<dyn DeviceProtocol>> {
        profiles::lookup(service_uuid).map(|p| p.create_protocol())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;
    use std::collections::HashMap;

    const TEST_YAML: &str = r#"
device:
  name: "Test"
  manufacturer: "Test"
  manufacturer_status: "abandoned"
  protocol: "ble"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Control"
    characteristics:
      - uuid: "0000fff1-0000-1000-8000-00805f9b34fb"
        name: "Command"
        properties: ["write"]
        commands:
          power_on:
            description: "Turn on"
            value: [0x01, 0x01]
"#;

    #[test]
    fn get_protocol_returns_generic() {
        let registry = ProtocolRegistry::new();
        let spec = parse_device_spec(TEST_YAML).unwrap();
        let proto = registry.get_protocol(&spec);
        let bytes = proto
            .encode_command(
                "0000fff1-0000-1000-8000-00805f9b34fb",
                "power_on",
                &HashMap::new(),
            )
            .unwrap();
        assert_eq!(bytes, vec![0x01, 0x01]);
    }

    #[test]
    fn get_standard_profile_battery() {
        let registry = ProtocolRegistry::new();
        let proto = registry
            .get_standard_profile("0000180f-0000-1000-8000-00805f9b34fb")
            .expect("should find battery profile");
        let values = proto.decode_value("2a19", &[75]).unwrap();
        assert_eq!(
            values["battery_percent"],
            crate::codec::types::DecodedValue::Uint(75)
        );
    }

    #[test]
    fn get_standard_profile_device_info() {
        let registry = ProtocolRegistry::new();
        let proto = registry
            .get_standard_profile("180a")
            .expect("should find device info profile");
        let values = proto.decode_value("2a29", b"TestCo").unwrap();
        assert_eq!(
            values["value"],
            crate::codec::types::DecodedValue::String("TestCo".to_string())
        );
    }

    #[test]
    fn get_standard_profile_unknown() {
        let registry = ProtocolRegistry::new();
        assert!(registry.get_standard_profile("fff0").is_none());
    }
}

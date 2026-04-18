// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Built-in controllers for standard Bluetooth SIG profiles.
//!
//! These profiles have well-known UUIDs and data formats defined by the
//! Bluetooth specification, so they don't need YAML device specs.

pub mod battery;
pub mod device_info;

use super::traits::DeviceProtocol;

/// The standard Bluetooth base UUID suffix.
/// 16-bit UUIDs are expanded to 128-bit as: 0000XXXX-0000-1000-8000-00805f9b34fb
const BT_BASE_UUID_SUFFIX: &str = "-0000-1000-8000-00805f9b34fb";

/// Build a full 128-bit UUID from a short hex form (e.g. "180f").
fn full_uuid(short: &str) -> String {
    format!("0000{short}{BT_BASE_UUID_SUFFIX}")
}

/// A single Device Information Service characteristic definition.
///
/// `field_name` is the decoded-value key used by [`device_info::DeviceInfoProtocol`];
/// `display_name` is the human-readable label for UI rendering.
pub(crate) struct DeviceInfoCharDef {
    pub short_uuid: &'static str,
    pub field_name: &'static str,
    pub display_name: &'static str,
    pub can_notify: bool,
}

pub(crate) const DEVICE_INFO_CHARS: &[DeviceInfoCharDef] = &[
    DeviceInfoCharDef {
        short_uuid: "2a29",
        field_name: "manufacturer_name",
        display_name: "Manufacturer Name",
        can_notify: false,
    },
    DeviceInfoCharDef {
        short_uuid: "2a24",
        field_name: "model_number",
        display_name: "Model Number",
        can_notify: false,
    },
    DeviceInfoCharDef {
        short_uuid: "2a25",
        field_name: "serial_number",
        display_name: "Serial Number",
        can_notify: false,
    },
    DeviceInfoCharDef {
        short_uuid: "2a27",
        field_name: "hardware_revision",
        display_name: "Hardware Revision",
        can_notify: false,
    },
    DeviceInfoCharDef {
        short_uuid: "2a26",
        field_name: "firmware_revision",
        display_name: "Firmware Revision",
        can_notify: false,
    },
    DeviceInfoCharDef {
        short_uuid: "2a28",
        field_name: "software_revision",
        display_name: "Software Revision",
        can_notify: false,
    },
    DeviceInfoCharDef {
        short_uuid: "2a23",
        field_name: "system_id",
        display_name: "System ID",
        can_notify: false,
    },
];

/// Known standard Bluetooth profiles.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StandardProfile {
    /// Battery Service (0x180F)
    BatteryService,
    /// Device Information Service (0x180A)
    DeviceInformation,
}

impl StandardProfile {
    /// Human-readable name for the profile.
    pub fn name(self) -> &'static str {
        match self {
            StandardProfile::BatteryService => "Battery Service",
            StandardProfile::DeviceInformation => "Device Information",
        }
    }

    /// The standard 16-bit short UUID for this profile's service.
    pub fn short_uuid(self) -> &'static str {
        match self {
            StandardProfile::BatteryService => "180f",
            StandardProfile::DeviceInformation => "180a",
        }
    }

    /// Create a protocol controller for this profile.
    pub fn create_protocol(self) -> Box<dyn DeviceProtocol> {
        match self {
            StandardProfile::BatteryService => Box::new(battery::BatteryServiceProtocol::new()),
            StandardProfile::DeviceInformation => Box::new(device_info::DeviceInfoProtocol::new()),
        }
    }

    /// Characteristic metadata for this profile (uuid, name, can_read, can_write, can_notify).
    pub fn characteristics(self) -> Vec<ProfileCharacteristicInfo> {
        match self {
            StandardProfile::BatteryService => vec![ProfileCharacteristicInfo {
                uuid: full_uuid("2a19"),
                name: "Battery Level".to_string(),
                can_read: true,
                can_write: false,
                can_notify: true,
            }],
            StandardProfile::DeviceInformation => DEVICE_INFO_CHARS
                .iter()
                .map(|def| ProfileCharacteristicInfo {
                    uuid: full_uuid(def.short_uuid),
                    name: def.display_name.to_string(),
                    can_read: true,
                    can_write: false,
                    can_notify: def.can_notify,
                })
                .collect(),
        }
    }
}

/// Metadata about a characteristic within a standard profile.
#[derive(Debug, Clone)]
pub struct ProfileCharacteristicInfo {
    pub uuid: String,
    pub name: String,
    pub can_read: bool,
    pub can_write: bool,
    pub can_notify: bool,
}

/// All known standard profiles.
const ALL_PROFILES: &[StandardProfile] = &[
    StandardProfile::BatteryService,
    StandardProfile::DeviceInformation,
];

/// Look up a standard profile by service UUID.
///
/// Accepts both 16-bit short UUIDs ("180f") and full 128-bit UUIDs
/// ("0000180f-0000-1000-8000-00805f9b34fb"). Case-insensitive.
pub fn lookup(service_uuid: &str) -> Option<StandardProfile> {
    let normalized = normalize_uuid(service_uuid);
    ALL_PROFILES
        .iter()
        .find(|p| p.short_uuid() == normalized)
        .copied()
}

/// Strip leading zeros, keeping at least one character.
fn strip_leading_zeros(s: &str) -> String {
    let trimmed = s.trim_start_matches('0');
    if trimmed.is_empty() {
        "0".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Normalize a UUID to its short hex form for comparison.
///
/// - "180f" → "180f"
/// - "0000180F-0000-1000-8000-00805F9B34FB" → "180f"
/// - "0000180f-0000-1000-8000-00805f9b34fb" → "180f"
/// - "000000f0-0000-1000-8000-00805f9b34fb" → "f0"
pub(crate) fn normalize_uuid(uuid: &str) -> String {
    let lower = uuid.to_lowercase();

    if let Some(prefix) = lower.strip_suffix(BT_BASE_UUID_SUFFIX) {
        strip_leading_zeros(prefix)
    } else if lower.len() <= 8 && !lower.contains('-') {
        strip_leading_zeros(&lower)
    } else {
        lower
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_short_uuid() {
        assert_eq!(normalize_uuid("180f"), "180f");
        assert_eq!(normalize_uuid("180F"), "180f");
        assert_eq!(normalize_uuid("2A19"), "2a19");
    }

    #[test]
    fn normalize_short_uuid_with_leading_zeros() {
        // "0000180f" (8-char short form) should normalize to "180f"
        assert_eq!(normalize_uuid("0000180f"), "180f");
        // Edge case: UUID where meaningful part starts with 0
        assert_eq!(normalize_uuid("00f0"), "f0");
        // All zeros should return "0", not empty string
        assert_eq!(normalize_uuid("0000"), "0");
    }

    #[test]
    fn normalize_full_uuid_with_leading_zeros_in_short_part() {
        // UUID "000000f0-..." should normalize to "f0", not ""
        assert_eq!(normalize_uuid("000000f0-0000-1000-8000-00805f9b34fb"), "f0");
        // All-zero short part
        assert_eq!(normalize_uuid("00000000-0000-1000-8000-00805f9b34fb"), "0");
    }

    #[test]
    fn normalize_full_uuid() {
        assert_eq!(
            normalize_uuid("0000180f-0000-1000-8000-00805f9b34fb"),
            "180f"
        );
        assert_eq!(
            normalize_uuid("0000180A-0000-1000-8000-00805F9B34FB"),
            "180a"
        );
        assert_eq!(
            normalize_uuid("00002A19-0000-1000-8000-00805F9B34FB"),
            "2a19"
        );
    }

    #[test]
    fn lookup_battery_service() {
        assert_eq!(lookup("180f"), Some(StandardProfile::BatteryService));
        assert_eq!(
            lookup("0000180f-0000-1000-8000-00805f9b34fb"),
            Some(StandardProfile::BatteryService)
        );
        assert_eq!(
            lookup("0000180F-0000-1000-8000-00805F9B34FB"),
            Some(StandardProfile::BatteryService)
        );
    }

    #[test]
    fn lookup_device_info() {
        assert_eq!(lookup("180a"), Some(StandardProfile::DeviceInformation));
        assert_eq!(
            lookup("0000180a-0000-1000-8000-00805f9b34fb"),
            Some(StandardProfile::DeviceInformation)
        );
    }

    #[test]
    fn lookup_unknown_service() {
        assert_eq!(lookup("fff0"), None);
        assert_eq!(lookup("0000fff0-0000-1000-8000-00805f9b34fb"), None);
    }

    #[test]
    fn profile_names() {
        assert_eq!(StandardProfile::BatteryService.name(), "Battery Service");
        assert_eq!(
            StandardProfile::DeviceInformation.name(),
            "Device Information"
        );
    }

    #[test]
    fn profile_characteristics_count() {
        assert_eq!(StandardProfile::BatteryService.characteristics().len(), 1);
        assert_eq!(
            StandardProfile::DeviceInformation.characteristics().len(),
            7
        );
    }
}

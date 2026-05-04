// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Pick the right [`DeviceProtocol`] for an encode/decode request.

use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};
use std::sync::{Arc, LazyLock, Mutex};

use super::generic::GenericProtocol;
use super::profiles;
use super::traits::DeviceProtocol;
use crate::error::ProtocolError;
use crate::spec::parser::parse_device_spec;
use crate::spec::types::DeviceSpec;

/// Cache of parsed specs keyed by content hash. FFI calls re-supply the
/// same YAML on every `encode_command` / `decode_value`, so without this
/// the dispatcher pays the YAML-parse cost on every hop. Specs are
/// immutable assets so no invalidation is needed; the realistic upper
/// bound on entries is "number of distinct device specs the app loads,"
/// which is tiny.
static SPEC_CACHE: LazyLock<Mutex<HashMap<u64, Arc<DeviceSpec>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn parse_or_cached(yaml: &str) -> Result<Arc<DeviceSpec>, ProtocolError> {
    let mut hasher = DefaultHasher::new();
    yaml.hash(&mut hasher);
    let key = hasher.finish();

    let mut cache = SPEC_CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(spec) = cache.get(&key) {
        return Ok(spec.clone());
    }
    let spec = Arc::new(parse_device_spec(yaml)?);
    cache.insert(key, spec.clone());
    Ok(spec)
}

/// Pick the right [`DeviceProtocol`] for a request.
///
/// When both `spec_yaml` and `service_uuid` are supplied, the spec wins —
/// the spec author may have overridden a standard service. To force
/// standard-profile dispatch (e.g. for the Battery service), pass
/// `spec_yaml: None`.
pub fn select_protocol(
    spec_yaml: Option<&str>,
    service_uuid: Option<&str>,
) -> Result<Box<dyn DeviceProtocol>, ProtocolError> {
    if let Some(yaml) = spec_yaml {
        let spec = parse_or_cached(yaml)?;
        return Ok(Box::new(GenericProtocol::new((*spec).clone())));
    }
    if let Some(uuid) = service_uuid {
        if let Some(profile) = profiles::lookup(uuid) {
            return Ok(profile.create_protocol());
        }
    }
    Err(ProtocolError::NoProtocolForRequest)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::codec::types::DecodedValue;

    const BULB_YAML: &str = r#"
device:
  name: "Bulb"
  manufacturer: "Acme"
  manufacturer_status: "abandoned"
  protocol: "ble"
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: "Status"
    characteristics:
      - uuid: "0000fff2-0000-1000-8000-00805f9b34fb"
        name: "Level"
        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: "level"
            type: "uint8"
"#;

    /// A spec that re-defines the Battery Service characteristic with a
    /// distinct field name, so we can prove the spec dispatcher wins over
    /// the standard-profile dispatcher.
    const SPEC_OVERRIDING_BATTERY: &str = r#"
device:
  name: "Custom"
  manufacturer: "Acme"
  manufacturer_status: "abandoned"
  protocol: "ble"
services:
  - uuid: "0000180f-0000-1000-8000-00805f9b34fb"
    name: "Battery (custom)"
    characteristics:
      - uuid: "00002a19-0000-1000-8000-00805f9b34fb"
        name: "Level"
        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: "custom_level"
            type: "uint8"
"#;

    #[test]
    fn yaml_only_routes_to_generic_protocol() {
        let proto = select_protocol(Some(BULB_YAML), None).unwrap();
        let decoded = proto
            .decode_value("0000fff2-0000-1000-8000-00805f9b34fb", &[42])
            .unwrap();
        assert_eq!(decoded["level"], DecodedValue::Uint(42));
    }

    #[test]
    fn service_uuid_only_routes_to_standard_profile() {
        let proto = select_protocol(None, Some("180f")).unwrap();
        let decoded = proto.decode_value("2a19", &[55]).unwrap();
        // BatteryServiceProtocol decodes into "battery_percent".
        assert_eq!(decoded["battery_percent"], DecodedValue::Uint(55));
    }

    #[test]
    fn spec_wins_over_standard_profile() {
        let proto = select_protocol(Some(SPEC_OVERRIDING_BATTERY), Some("180f")).unwrap();
        // GenericProtocol matches on the full UUID present in the spec.
        let decoded = proto
            .decode_value("00002a19-0000-1000-8000-00805f9b34fb", &[77])
            .unwrap();
        // Spec-driven decoding produces "custom_level", not "battery_percent".
        assert_eq!(decoded["custom_level"], DecodedValue::Uint(77));
        assert!(!decoded.contains_key("battery_percent"));
    }

    fn assert_err<F>(
        result: Result<Box<dyn DeviceProtocol>, ProtocolError>,
        label: &str,
        predicate: F,
    ) where
        F: FnOnce(&ProtocolError) -> bool,
    {
        match result {
            Ok(_) => panic!("expected {label}, got Ok(_)"),
            Err(e) if predicate(&e) => (),
            Err(e) => panic!("expected {label}, got Err({e:?})"),
        }
    }

    #[test]
    fn neither_input_returns_no_protocol_for_request() {
        assert_err(select_protocol(None, None), "NoProtocolForRequest", |e| {
            matches!(e, ProtocolError::NoProtocolForRequest)
        });
    }

    #[test]
    fn unknown_service_uuid_returns_no_protocol_for_request() {
        assert_err(
            select_protocol(None, Some("ffff")),
            "NoProtocolForRequest",
            |e| matches!(e, ProtocolError::NoProtocolForRequest),
        );
    }

    #[test]
    fn malformed_yaml_returns_spec_parse_error() {
        assert_err(
            select_protocol(Some("not: valid: yaml: ["), None),
            "SpecParse",
            |e| matches!(e, ProtocolError::SpecParse(_)),
        );
    }

    // ── spec cache (2.8) ────────────────────────────────────────────────────
    //
    // These tests probe `parse_or_cached` directly via `Arc::ptr_eq`
    // rather than reading the global cache length, which is shared with
    // every other test running on the multithreaded test runner.

    #[test]
    fn cache_returns_same_allocation_for_identical_yaml() {
        let yaml = "
device:
  name: \"cache-test-A\"
  manufacturer: x
  manufacturer_status: abandoned
  protocol: ble
services: []
";
        let a = parse_or_cached(yaml).unwrap();
        let b = parse_or_cached(yaml).unwrap();
        assert!(
            Arc::ptr_eq(&a, &b),
            "second call should return a clone of the cached Arc, not a fresh parse"
        );
    }

    #[test]
    fn cache_distinguishes_distinct_yamls() {
        let yaml_x = "
device:
  name: \"cache-test-B\"
  manufacturer: x
  manufacturer_status: abandoned
  protocol: ble
services: []
";
        let yaml_y = "
device:
  name: \"cache-test-C\"
  manufacturer: x
  manufacturer_status: abandoned
  protocol: ble
services: []
";
        let a = parse_or_cached(yaml_x).unwrap();
        let b = parse_or_cached(yaml_y).unwrap();
        assert!(
            !Arc::ptr_eq(&a, &b),
            "different YAML must produce different cache entries"
        );
    }
}

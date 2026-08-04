// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Pick the right [`DeviceProtocol`] for an encode/decode request.

use std::collections::HashMap;
use std::sync::{Arc, LazyLock, Mutex};

use super::generic::GenericProtocol;
use super::profiles;
use super::traits::DeviceProtocol;
use crate::error::ProtocolError;
use crate::spec::parser::parse_device_spec;
use crate::spec::types::DeviceSpec;

/// Cache of parsed specs keyed by the full YAML text. FFI calls re-supply
/// the same YAML on every `encode_command` / `decode_value`, so without this
/// the dispatcher pays the YAML-parse cost on every hop. Specs are
/// immutable assets so no invalidation is needed; the realistic upper
/// bound on entries is "number of distinct device specs the app loads,"
/// which is tiny.
///
/// The key is the YAML `String` itself rather than a 64-bit non-cryptographic
/// hash: specs may be loaded from arbitrary remote URLs, and a hostile author
/// could otherwise craft two specs whose hashes collide, causing the wrong
/// `DeviceSpec` to be served for encode/decode. Keying on the full text makes
/// a collision impossible. The extra memory is a handful of small strings —
/// bounded by [`SPEC_CACHE_MAX_ENTRIES`], because those same remote URLs
/// could also feed us an endless stream of *distinct* keys (every whitespace
/// variation of a spec is a new entry) and grow the map without limit.
static SPEC_CACHE: LazyLock<Mutex<HashMap<String, Arc<DeviceSpec>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// Upper bound on cached specs. Generous for the legitimate workload (a
/// handful of bundled specs plus a few installed packs), tiny against a
/// hostile stream of never-repeating YAML strings. When the bound is hit the
/// whole cache is cleared rather than LRU-evicted: reaching it at all means
/// the workload is not the one the cache serves, and a documented clear is
/// simpler than an eviction policy (or an LRU dependency) — the cost of a
/// miss is one re-parse.
const SPEC_CACHE_MAX_ENTRIES: usize = 32;

fn parse_or_cached(yaml: &str) -> Result<Arc<DeviceSpec>, ProtocolError> {
    let mut cache = SPEC_CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(spec) = cache.get(yaml) {
        return Ok(spec.clone());
    }
    let spec = Arc::new(parse_device_spec(yaml)?);
    if cache.len() >= SPEC_CACHE_MAX_ENTRIES {
        cache.clear();
    }
    cache.insert(yaml.to_string(), spec.clone());
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
        // Hand the Arc straight through: GenericProtocol shares the cached
        // spec, so this is a refcount bump, not a deep clone per FFI call.
        let spec = parse_or_cached(yaml)?;
        return Ok(Box::new(GenericProtocol::new(spec)));
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

    /// The capacity test clears the shared global cache, which would race
    /// the identity assertions of the identical-YAML test if the two
    /// interleave on the parallel runner. Serialize just those two — the
    /// remaining tests only compare *content* or the identity of *distinct*
    /// specs, both of which survive a concurrent clear.
    static CACHE_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn cache_returns_same_allocation_for_identical_yaml() {
        let _guard = CACHE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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

    /// The cache must stay bounded even when every request carries distinct
    /// YAML (the remote-pack attack surface: whitespace-permuted copies of
    /// one spec are all different keys). Prove an entry gets evicted after
    /// SPEC_CACHE_MAX_ENTRIES fresh inserts — i.e. the map cannot grow
    /// without limit.
    #[test]
    fn cache_clears_when_capacity_is_reached() {
        let _guard = CACHE_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let base = "
device:
  name: \"cap-test-base\"
  manufacturer: x
  manufacturer_status: abandoned
  protocol: ble
services: []
";
        let before = parse_or_cached(base).unwrap();

        // Whatever the cache held beforehand, inserting MAX distinct specs
        // after `base` guarantees at least one clear happens after `base`
        // was cached (base + MAX fresh entries > MAX).
        for i in 0..SPEC_CACHE_MAX_ENTRIES {
            let yaml = format!(
                "
device:
  name: \"cap-test-{i}\"
  manufacturer: x
  manufacturer_status: abandoned
  protocol: ble
services: []
"
            );
            parse_or_cached(&yaml).unwrap();
        }

        let after = parse_or_cached(base).unwrap();
        assert!(
            !Arc::ptr_eq(&before, &after),
            "base entry should have been evicted by the capacity clear; \
             an identity hit here would mean the cache grew past its bound"
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

    /// The cache is keyed on the full YAML text, so distinct specs can never
    /// collide onto one entry (a real risk when it was keyed on a 64-bit
    /// non-cryptographic hash of attacker-supplied YAML). Prove each spec
    /// still decodes to *its own* content after both are cached.
    #[test]
    fn cache_serves_the_matching_spec_for_each_yaml() {
        const SPEC_ONE: &str = r#"
device:
  name: "collide-one"
  manufacturer: x
  manufacturer_status: abandoned
  protocol: ble
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: s
    characteristics:
      - uuid: "0000fff2-0000-1000-8000-00805f9b34fb"
        name: c
        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: "field_one"
            type: "uint8"
"#;
        const SPEC_TWO: &str = r#"
device:
  name: "collide-two"
  manufacturer: x
  manufacturer_status: abandoned
  protocol: ble
services:
  - uuid: "0000fff0-0000-1000-8000-00805f9b34fb"
    name: s
    characteristics:
      - uuid: "0000fff2-0000-1000-8000-00805f9b34fb"
        name: c
        properties: ["read"]
        format:
          - offset: 0
            length: 1
            name: "field_two"
            type: "uint8"
"#;
        let one = parse_or_cached(SPEC_ONE).unwrap();
        let two = parse_or_cached(SPEC_TWO).unwrap();
        assert!(!Arc::ptr_eq(&one, &two));

        // Route each through select_protocol (which re-hits the cache) and
        // confirm the decoded field name matches the spec that was supplied,
        // never the other one.
        let proto_one = select_protocol(Some(SPEC_ONE), None).unwrap();
        let decoded_one = proto_one
            .decode_value("0000fff2-0000-1000-8000-00805f9b34fb", &[7])
            .unwrap();
        assert_eq!(decoded_one["field_one"], DecodedValue::Uint(7));
        assert!(!decoded_one.contains_key("field_two"));

        let proto_two = select_protocol(Some(SPEC_TWO), None).unwrap();
        let decoded_two = proto_two
            .decode_value("0000fff2-0000-1000-8000-00805f9b34fb", &[9])
            .unwrap();
        assert_eq!(decoded_two["field_two"], DecodedValue::Uint(9));
        assert!(!decoded_two.contains_key("field_one"));
    }
}

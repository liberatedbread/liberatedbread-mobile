// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Pick the right [`DeviceProtocol`] for an encode/decode request.

use super::generic::GenericProtocol;
use super::profiles;
use super::traits::DeviceProtocol;
use crate::error::ProtocolError;
use crate::spec::parser::parse_device_spec;

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
        let spec = parse_device_spec(yaml)?;
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
}

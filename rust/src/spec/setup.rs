// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! What the catalogue says about adopting a reset device: which setup APs
//! exist, what their SSIDs start with, and where the device answers once
//! joined.
//!
//! `device.setup` stays untyped in [`DeviceInfo::extensions`] — it is mostly
//! prose for humans — and this module lifts out the handful of keys a client
//! needs *before* it knows which device it is looking at: the AP watcher
//! matches SSIDs against every spec's prefix, and the adopt flow probes every
//! spec's gateway. One profile per softap method, so a catalogue gaining a
//! third adoptable family is a spec change and nothing else.

use crate::spec::types::DeviceSpec;

/// One spec's softap setup method, reduced to what a client can act on.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SoftApProfile {
    /// `device.name` — what the adopt UI calls the family.
    pub spec_name: String,
    /// `device.category`, for the icon.
    pub category: Option<String>,
    /// `softap_soap`, `softap_udp`, `softap_http` — what the flow dispatches
    /// on.
    pub method_type: String,
    /// Case-insensitive SSID prefix of the setup AP.
    pub ssid_prefix: String,
    pub ssid_examples: Vec<String>,
    /// True when the setup AP takes no passphrase. `None` when the spec does
    /// not say.
    pub open_network: Option<bool>,
    /// Where the device answers on its own AP, when documented.
    pub gateway_ip: Option<String>,
    /// The documented port, then the probe list, deduplicated in order.
    pub ports: Vec<u16>,
}

impl SoftApProfile {
    /// Whether an SSID looks like this profile's setup AP. The spec declares
    /// prefix matching case-insensitive.
    pub fn matches_ssid(&self, ssid: &str) -> bool {
        ssid_matches_prefix(&self.ssid_prefix, ssid)
    }
}

/// The prefix rule on its own: case-insensitive, anchored at the start,
/// tolerant of the whitespace scan results sometimes carry. Empty prefixes
/// match nothing — an empty prefix is a claim on every network in the air.
pub fn ssid_matches_prefix(prefix: &str, ssid: &str) -> bool {
    let ssid = ssid.trim();
    !prefix.is_empty()
        && ssid.len() >= prefix.len()
        && ssid.is_char_boundary(prefix.len())
        && ssid[..prefix.len()].eq_ignore_ascii_case(prefix)
}

/// Every softap setup method the given specs declare, catalogue order.
pub fn soft_ap_profiles<'a>(specs: impl IntoIterator<Item = &'a DeviceSpec>) -> Vec<SoftApProfile> {
    specs.into_iter().flat_map(profiles_for_spec).collect()
}

fn profiles_for_spec(spec: &DeviceSpec) -> Vec<SoftApProfile> {
    let Some(setup) = spec.device.extensions.get("setup") else {
        return Vec::new();
    };
    let Some(methods) = setup.get("methods").and_then(|m| m.as_sequence()) else {
        return Vec::new();
    };

    // The flat identification prefix is the fallback for a spec that states
    // the AP's name once, outside the method block.
    let identification_prefix = spec
        .device
        .identification
        .as_ref()
        .and_then(|id| id.ssid_prefix.clone());

    methods
        .iter()
        .filter_map(|method| {
            let method_type = method.get("type")?.as_str()?;
            if !method_type.starts_with("softap_") {
                return None;
            }
            let softap = method.get("softap");
            let ssid_prefix = softap
                .and_then(|s| s.get("ssid_prefix"))
                .and_then(|p| p.as_str())
                .map(str::to_string)
                .or_else(|| identification_prefix.clone())
                // An empty prefix would match every network in the air, the
                // same trap `local_name_prefixes` guards against.
                .filter(|p| !p.is_empty())?;

            let ssid_examples = softap
                .and_then(|s| s.get("ssid_examples"))
                .and_then(|e| e.as_sequence())
                .map(|examples| {
                    examples
                        .iter()
                        .filter_map(|e| e.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();

            let mut ports: Vec<u16> = Vec::new();
            let mut push_port = |value: Option<&serde_yaml::Value>| {
                if let Some(port) = value
                    .and_then(|p| p.as_u64())
                    .and_then(|p| u16::try_from(p).ok())
                {
                    if !ports.contains(&port) {
                        ports.push(port);
                    }
                }
            };
            push_port(softap.and_then(|s| s.get("port")));
            if let Some(probe) = softap
                .and_then(|s| s.get("port_probe_list"))
                .and_then(|l| l.as_sequence())
            {
                for port in probe {
                    push_port(Some(port));
                }
            }

            Some(SoftApProfile {
                spec_name: spec.device.name.clone(),
                category: spec.device.category.clone(),
                method_type: method_type.to_string(),
                ssid_prefix,
                ssid_examples,
                open_network: softap
                    .and_then(|s| s.get("open_network"))
                    .and_then(|o| o.as_bool()),
                gateway_ip: softap
                    .and_then(|s| s.get("gateway_ip"))
                    .and_then(|g| g.as_str())
                    .map(str::to_string),
                ports,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn spec(yaml: &str) -> DeviceSpec {
        parse_device_spec(yaml).expect("fixture parses")
    }

    const SOAP_DEVICE: &str = r#"
device:
  name: "Test Plug"
  manufacturer: "Test"
  manufacturer_status: "shutdown"
  protocol: "wifi"
  category: "switch"
  setup:
    required: true
    methods:
      - type: "softap_soap"
        softap:
          ssid_prefix: "Plug."
          ssid_examples: ["Plug.Mini.4A2"]
          open_network: true
          gateway_ip: "10.22.22.1"
          port: 49153
          port_probe_list: [49153, 49152]
"#;

    #[test]
    fn a_softap_method_becomes_one_profile() {
        let spec = spec(SOAP_DEVICE);
        let profiles = soft_ap_profiles([&spec]);
        assert_eq!(profiles.len(), 1);
        let p = &profiles[0];
        assert_eq!(p.spec_name, "Test Plug");
        assert_eq!(p.method_type, "softap_soap");
        assert_eq!(p.ssid_prefix, "Plug.");
        assert_eq!(p.gateway_ip.as_deref(), Some("10.22.22.1"));
        // Declared port first, probe list after, no duplicate.
        assert_eq!(p.ports, vec![49153, 49152]);
        assert_eq!(p.open_network, Some(true));
    }

    #[test]
    fn ssid_matching_is_a_case_insensitive_prefix() {
        let spec = spec(SOAP_DEVICE);
        let profile = &soft_ap_profiles([&spec])[0];
        assert!(profile.matches_ssid("Plug.Mini.4A2"));
        assert!(profile.matches_ssid("PLUG.switch.7C4"));
        assert!(profile.matches_ssid("  plug.Insight.0F3  "));
        assert!(!profile.matches_ssid("Plug"), "shorter than the prefix");
        assert!(!profile.matches_ssid("MyPlug.Net"), "prefix, not substring");
    }

    #[test]
    fn the_flat_identification_prefix_is_the_fallback() {
        let yaml = r#"
device:
  name: "Test Strip"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "light"
  identification:
    ssid_prefix: "STRIP"
  setup:
    methods:
      - type: "softap_udp"
        softap:
          open_network: true
"#;
        let spec = spec(yaml);
        let profiles = soft_ap_profiles([&spec]);
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].ssid_prefix, "STRIP");
        assert!(profiles[0].ports.is_empty());
    }

    #[test]
    fn non_softap_methods_and_prefixless_specs_yield_nothing() {
        let yaml = r#"
device:
  name: "Test Hub"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "hub"
  setup:
    methods:
      - type: "wired"
      - type: "softap_http"
"#;
        let spec = spec(yaml);
        assert!(
            soft_ap_profiles([&spec]).is_empty(),
            "wired is not an AP, and a softap method with no prefix anywhere matches nothing"
        );
    }

    #[test]
    fn a_spec_with_no_setup_block_yields_nothing() {
        let yaml = r#"
device:
  name: "Test Sensor"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
"#;
        let spec = spec(yaml);
        assert!(soft_ap_profiles([&spec]).is_empty());
    }
}

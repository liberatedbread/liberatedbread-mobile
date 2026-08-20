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
//!
//! The second thing it lifts is the human-readable other half of the same
//! block: the pairing steps, the troubleshooting symptoms, the factory-reset
//! procedure and the rejoin note. That prose is exactly what a user wants when
//! a BLE connect fails, so [`setup_instructions`] shapes it into typed structs
//! the UI can render — where the softap extraction filters *to* one method
//! type, this keeps every method, because "how do I connect this" is a
//! question every setup block can answer.

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

// ── Human-readable setup / troubleshooting instructions ─────────────────────
// The prose half of `device.setup`, shaped so a client can render "how do I
// connect this / why won't it / how do I reset it" when a connect fails. Every
// field is optional or defaults to empty: setup blocks are uneven, and a
// section a spec omits must simply not appear, never render as a blank heading.

/// One `action`/`actor`/`expect` triple from a setup or reset step list.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupStep {
    /// What to do — the only required field.
    pub action: String,
    /// Who does it (`user` / `client`), when the spec says.
    pub actor: Option<String>,
    /// What confirms it worked, when the spec says.
    pub expect: Option<String>,
}

/// A `symptom` + its likely `causes`, from a method's `troubleshooting` list —
/// purpose-built for the "it won't connect" screen.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Troubleshooting {
    pub symptom: String,
    pub causes: Vec<String>,
}

/// One `setup.methods[]` entry, reduced to what a human needs to read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupMethod {
    /// `ble_direct`, `button_pairing`, `softap_http`, … — labels the method.
    pub method_type: Option<String>,
    pub description: Option<String>,
    pub steps: Vec<SetupStep>,
    pub troubleshooting: Vec<Troubleshooting>,
}

impl SetupMethod {
    /// A method with no prose at all is dropped — a bare `type:` teaches a
    /// reader nothing and would render as an empty card.
    fn is_empty(&self) -> bool {
        self.description.is_none() && self.steps.is_empty() && self.troubleshooting.is_empty()
    }
}

/// One named way to factory-reset the device.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FactoryResetProcedure {
    pub name: String,
    pub hold_seconds: Option<u32>,
    /// The LED/screen/audio signal that confirms the reset took.
    pub indicator: Option<String>,
    pub steps: Vec<SetupStep>,
}

/// `setup.factory_reset` — what a reset clears and how to trigger it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FactoryReset {
    pub effect: Option<String>,
    pub procedures: Vec<FactoryResetProcedure>,
}

/// `setup.rejoin` — whether a device that dropped can be reconnected in place,
/// and the note explaining what usually went wrong (for Ember, "a phone is
/// still holding the single allowed connection").
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Rejoin {
    pub in_place_supported: Option<bool>,
    pub requires_factory_reset: Option<bool>,
    pub notes: Option<String>,
}

impl Rejoin {
    fn is_empty(&self) -> bool {
        self.in_place_supported.is_none()
            && self.requires_factory_reset.is_none()
            && self.notes.is_none()
    }
}

/// The renderable digest of one spec's `device.setup` block.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SetupInstructions {
    pub notes: Option<String>,
    pub methods: Vec<SetupMethod>,
    pub factory_reset: Option<FactoryReset>,
    pub rejoin: Option<Rejoin>,
}

fn opt_str(value: Option<&serde_yaml::Value>) -> Option<String> {
    value.and_then(|v| v.as_str()).map(str::to_string)
}

fn parse_steps(value: Option<&serde_yaml::Value>) -> Vec<SetupStep> {
    value
        .and_then(|v| v.as_sequence())
        .map(|seq| {
            seq.iter()
                .filter_map(|s| {
                    // A step with no `action` is a step that says nothing to do.
                    let action = s.get("action")?.as_str()?.to_string();
                    Some(SetupStep {
                        action,
                        actor: opt_str(s.get("actor")),
                        expect: opt_str(s.get("expect")),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Lift one spec's `device.setup` block into renderable instructions, or `None`
/// when the block is absent or carries no prose a user could act on. Reaches
/// into the untyped `extensions` map by hand, the same way [`profiles_for_spec`]
/// does — `device.setup` is deliberately not a typed field (see
/// [`crate::spec::types::DeviceInfo`]).
pub fn setup_instructions(spec: &DeviceSpec) -> Option<SetupInstructions> {
    let setup = spec.device.extensions.get("setup")?;

    let methods: Vec<SetupMethod> = setup
        .get("methods")
        .and_then(|m| m.as_sequence())
        .map(|seq| {
            seq.iter()
                .map(|m| SetupMethod {
                    method_type: opt_str(m.get("type")),
                    description: opt_str(m.get("description")),
                    steps: parse_steps(m.get("steps")),
                    troubleshooting: m
                        .get("troubleshooting")
                        .and_then(|t| t.as_sequence())
                        .map(|ts| {
                            ts.iter()
                                .filter_map(|t| {
                                    let symptom = t.get("symptom")?.as_str()?.to_string();
                                    let causes = t
                                        .get("causes")
                                        .and_then(|c| c.as_sequence())
                                        .map(|cs| {
                                            cs.iter()
                                                .filter_map(|c| c.as_str().map(str::to_string))
                                                .collect()
                                        })
                                        .unwrap_or_default();
                                    Some(Troubleshooting { symptom, causes })
                                })
                                .collect()
                        })
                        .unwrap_or_default(),
                })
                .filter(|m| !m.is_empty())
                .collect()
        })
        .unwrap_or_default();

    let factory_reset = setup.get("factory_reset").and_then(|fr| {
        let effect = opt_str(fr.get("effect"));
        let procedures: Vec<FactoryResetProcedure> = fr
            .get("procedures")
            .and_then(|p| p.as_sequence())
            .map(|seq| {
                seq.iter()
                    .filter_map(|p| {
                        let name = p.get("name")?.as_str()?.to_string();
                        Some(FactoryResetProcedure {
                            name,
                            hold_seconds: p
                                .get("hold_seconds")
                                .and_then(|h| h.as_u64())
                                .and_then(|h| u32::try_from(h).ok()),
                            indicator: opt_str(p.get("indicator")),
                            steps: parse_steps(p.get("steps")),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        // A reset block that names neither an effect nor a procedure is noise.
        if effect.is_none() && procedures.is_empty() {
            None
        } else {
            Some(FactoryReset { effect, procedures })
        }
    });

    let rejoin = setup.get("rejoin").and_then(|r| {
        let rejoin = Rejoin {
            in_place_supported: r.get("in_place_supported").and_then(|b| b.as_bool()),
            requires_factory_reset: r.get("requires_factory_reset").and_then(|b| b.as_bool()),
            notes: opt_str(r.get("notes")),
        };
        if rejoin.is_empty() {
            None
        } else {
            Some(rejoin)
        }
    });

    let notes = opt_str(setup.get("notes"));

    // Nothing renderable → no affordance at all, rather than an empty screen.
    if notes.is_none() && methods.is_empty() && factory_reset.is_none() && rejoin.is_none() {
        return None;
    }

    Some(SetupInstructions {
        notes,
        methods,
        factory_reset,
        rejoin,
    })
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

    const BLE_SETUP: &str = r#"
device:
  name: "Test Mug"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
  setup:
    notes: "Enable Bluetooth, then connect."
    methods:
      - type: "ble_direct"
        description: "Direct BLE pairing."
        steps:
          - action: "Put the mug in pairing mode."
            actor: "user"
            expect: "The LED shows the pairing colour."
          - action: "Connect and read the state characteristics."
            actor: "client"
        troubleshooting:
          - symptom: "The mug will not connect."
            causes:
              - "A phone is still holding the single allowed connection."
              - "The mug is asleep off the coaster."
    factory_reset:
      effect: "Clears the claim and settings; identity survives."
      procedures:
        - name: "Factory reset"
          hold_seconds: 15
          indicator: "LED blue, then yellow, then red."
          steps:
            - action: "Hold the base button through blue and yellow, release at red."
              actor: "user"
    rejoin:
      in_place_supported: true
      requires_factory_reset: false
      notes: "Close the other client, or power-cycle on the coaster."
"#;

    #[test]
    fn ble_setup_block_lifts_every_section() {
        let spec = spec(BLE_SETUP);
        let s = setup_instructions(&spec).expect("has instructions");
        assert_eq!(s.notes.as_deref(), Some("Enable Bluetooth, then connect."));

        assert_eq!(s.methods.len(), 1);
        let m = &s.methods[0];
        assert_eq!(m.method_type.as_deref(), Some("ble_direct"));
        assert_eq!(m.description.as_deref(), Some("Direct BLE pairing."));
        assert_eq!(m.steps.len(), 2);
        assert_eq!(m.steps[0].actor.as_deref(), Some("user"));
        assert_eq!(
            m.steps[0].expect.as_deref(),
            Some("The LED shows the pairing colour.")
        );
        assert_eq!(m.steps[1].expect, None);

        assert_eq!(m.troubleshooting.len(), 1);
        assert_eq!(m.troubleshooting[0].symptom, "The mug will not connect.");
        assert_eq!(m.troubleshooting[0].causes.len(), 2);

        let fr = s.factory_reset.expect("has factory reset");
        assert!(fr.effect.is_some());
        assert_eq!(fr.procedures.len(), 1);
        assert_eq!(fr.procedures[0].name, "Factory reset");
        assert_eq!(fr.procedures[0].hold_seconds, Some(15));
        assert_eq!(fr.procedures[0].steps.len(), 1);

        let r = s.rejoin.expect("has rejoin");
        assert_eq!(r.in_place_supported, Some(true));
        assert_eq!(r.requires_factory_reset, Some(false));
        assert!(r.notes.is_some());
    }

    #[test]
    fn no_setup_block_yields_no_instructions() {
        let yaml = r#"
device:
  name: "Bare Sensor"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
"#;
        assert!(setup_instructions(&spec(yaml)).is_none());
    }

    #[test]
    fn a_setup_block_with_no_prose_yields_nothing() {
        // required: true is machinery, not something to read — an empty method
        // and no reset/rejoin/notes must not surface a blank help screen.
        let yaml = r#"
device:
  name: "Quiet Plug"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
  setup:
    required: true
    methods:
      - type: "ble_direct"
"#;
        assert!(
            setup_instructions(&spec(yaml)).is_none(),
            "a bare method with no description/steps/troubleshooting is dropped, leaving nothing"
        );
    }

    #[test]
    fn partial_blocks_keep_only_what_is_present() {
        let yaml = r#"
device:
  name: "Reset Only"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "ble"
  setup:
    factory_reset:
      effect: "Wipes the pairing."
"#;
        let s = setup_instructions(&spec(yaml)).expect("has instructions");
        assert!(s.notes.is_none());
        assert!(s.methods.is_empty());
        assert!(s.rejoin.is_none());
        assert_eq!(
            s.factory_reset.expect("reset present").effect.as_deref(),
            Some("Wipes the pairing.")
        );
    }
}

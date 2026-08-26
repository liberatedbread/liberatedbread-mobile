// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! What a spec says a client must HOLD before it can drive the device.
//!
//! A `credential:<name>` parameter is the schema's way of saying "this value
//! is not the user's choice and not the device's answer — it is something you
//! were given, and without it there is nowhere to send". The catalogue uses it
//! for four quite different things: a Hue whitelist username minted by the
//! link button, a Bambu printer's serial read off its touchscreen, a Hisense
//! set's client id that the CLIENT picks and the TV then authorises, and an
//! Electrolux appliance id that only the vendor's cloud knows.
//!
//! What they have in common is the only thing that matters here: the name.
//! `issues_credentials` keys its entries by the same spelling a `credential:`
//! parameter refers to — "the key spelling is the coupling", in the schema's
//! own words — so a consumer can run a pairing flow, store what it yields, and
//! fill the parameter later without a per-device credential table anywhere.
//! This module is the join of those two halves, done once.
//!
//! What deliberately does NOT live here is any judgement about whether a
//! credential is obtainable. A spec that names one the vendor never hands out
//! still declares it; saying so plainly is more useful than pretending the
//! device has no controls.

use std::collections::BTreeMap;

use crate::protocol::http::{parse_source, SourceScheme};
use crate::spec::types::DeviceSpec;

/// The setup method that mints a credential, from `issues_credentials`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CredentialIssuance {
    /// The `setup.methods[]` entry's `type` — `button_pairing`, `device_ui`,
    /// … Labels which flow to run.
    pub method: String,
    /// The named command whose reply carries the value, when the method has
    /// more than one exchange and the spec says which.
    pub command: Option<String>,
    /// Dotted path with bracketed indices into that reply:
    /// `[0].success.username`.
    pub reply_path: String,
    /// A request argument that must be set for the field to appear at all.
    /// Hue's `clientkey` exists only when `generateclientkey: true` rode the
    /// create request, and only at create time — a re-pair without it never
    /// sees the key again, which is worth telling a client BEFORE it pairs.
    pub request_condition: Option<String>,
}

/// One value a client must hold, and everything the spec says about it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CredentialRequirement {
    /// The name — the key a `credential:<name>` parameter refers to, the key
    /// `issues_credentials` uses, and the key it is stored under.
    pub name: String,
    /// What the spec says this value is and where a person gets it, taken
    /// from the parameter's own `description`. This is what a client shows
    /// when it has to ask; a spec that describes its credential well needs no
    /// UI copy written for it.
    pub description: Option<String>,
    /// Commands that cannot be sent without it, in declaration order.
    ///
    /// Empty means nothing consumes it YET — Hue's `clientkey` is issued at
    /// pairing, stored because it can never be obtained again, and used by no
    /// command in the catalogue. A client should keep such a value when a
    /// pairing hands it over and must not prompt for it: nothing would be
    /// unblocked by an answer.
    pub needed_by: Vec<String>,
    /// The setup method that issues it, when the spec declares one. `None`
    /// means the value comes from outside any flow this spec describes — off
    /// a touchscreen, out of an account — and a client that needs it has to
    /// ask.
    pub issued_by: Option<CredentialIssuance>,
}

impl CredentialRequirement {
    /// Whether a client should ask a person for this value.
    ///
    /// Something has to need it, and no declared flow can mint it. Both halves
    /// matter: prompting for a credential a pairing would issue trains people
    /// to paste secrets that the button press was about to hand over, and
    /// prompting for one nothing consumes asks a question no answer improves.
    pub fn must_be_asked_for(&self) -> bool {
        self.issued_by.is_none() && !self.needed_by.is_empty()
    }
}

/// Every credential this spec's own declarations refer to, by name.
///
/// Sorted by name so the order is the spec's meaning rather than its file
/// layout — two specs that declare the same credentials produce the same list.
pub fn required_credentials(spec: &DeviceSpec) -> Vec<CredentialRequirement> {
    let mut found: BTreeMap<String, CredentialRequirement> = BTreeMap::new();

    for (command_name, command) in &spec.commands {
        for parameter in command.parameters.values() {
            let Some(SourceScheme::Credential(name)) =
                parameter.source.as_deref().and_then(parse_source)
            else {
                continue;
            };
            let entry = found
                .entry(name.to_string())
                .or_insert_with(|| CredentialRequirement {
                    name: name.to_string(),
                    description: None,
                    needed_by: Vec::new(),
                    issued_by: None,
                });
            // The first description wins, and the rest are the same sentence:
            // Frigidaire repeats its applianceId prose on all thirteen
            // commands. Taking the first keeps a client from concatenating a
            // paragraph out of one fact stated many times.
            if entry.description.is_none() {
                entry.description = parameter.description.clone();
            }
            entry.needed_by.push(command_name.clone());
        }
    }

    for (name, issuance) in issued_credentials(spec) {
        found
            .entry(name.clone())
            .or_insert_with(|| CredentialRequirement {
                name,
                description: None,
                needed_by: Vec::new(),
                issued_by: None,
            })
            .issued_by = Some(issuance);
    }

    for requirement in found.values_mut() {
        requirement.needed_by.sort();
        requirement.needed_by.dedup();
    }
    found.into_values().collect()
}

/// The `issues_credentials` blocks across every setup method, flattened to
/// name → issuance.
///
/// Flattened because the name is the coupling and a name issued by two methods
/// would be one value with two routes to it, not two values. First method
/// wins, which is declaration order — the spec lists the flow it expects a
/// client to run first.
fn issued_credentials(spec: &DeviceSpec) -> Vec<(String, CredentialIssuance)> {
    let Some(methods) = spec
        .device
        .extensions
        .get("setup")
        .and_then(|setup| setup.get("methods"))
        .and_then(|methods| methods.as_sequence())
    else {
        return Vec::new();
    };
    let mut out: Vec<(String, CredentialIssuance)> = Vec::new();
    for method in methods {
        let method_type = method
            .get("type")
            .and_then(|t| t.as_str())
            .unwrap_or_default()
            .to_string();
        let Some(issues) = method
            .get("issues_credentials")
            .and_then(|issues| issues.as_mapping())
        else {
            continue;
        };
        for (name, body) in issues {
            let Some(name) = name.as_str() else { continue };
            // `reply_path` is the schema's one required field: without it the
            // block says a credential exists and not how to read it, which is
            // an issuance a client cannot run.
            let Some(reply_path) = body.get("reply_path").and_then(|p| p.as_str()) else {
                continue;
            };
            if out.iter().any(|(seen, _)| seen == name) {
                continue;
            }
            out.push((
                name.to_string(),
                CredentialIssuance {
                    method: method_type.clone(),
                    command: body
                        .get("command")
                        .and_then(|c| c.as_str())
                        .map(str::to_string),
                    reply_path: reply_path.to_string(),
                    request_condition: body
                        .get("request_condition")
                        .and_then(|c| c.as_str())
                        .map(str::to_string),
                },
            ));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A bridge shaped like Hue's: a pairing flow that issues two values, one
    /// of which every later request embeds and one of which nothing consumes.
    const BRIDGE: &str = r#"
device:
  name: Test Bridge
  manufacturer: Test
  manufacturer_status: active
  protocol: wifi
  setup:
    required: true
    methods:
      - type: button_pairing
        description: Press the link button, then create a user.
        issues_credentials:
          username:
            command: create_user
            reply_path: "[0].success.username"
          clientkey:
            command: create_user
            reply_path: "[0].success.clientkey"
            request_condition: "generateclientkey: true"
commands:
  create_user:
    description: Mint a whitelist entry.
    transport: http
    method: POST
    path: /api
  set_light:
    description: Write light state.
    transport: http
    method: PUT
    path: /api/{username}/lights/{id}/state
    parameters:
      username:
        type: string
        source: credential:username
        description: The whitelist username the link-button flow issued.
      id:
        type: string
        source: instance:id
  get_lights:
    description: Read light state.
    transport: http
    method: GET
    path: /api/{username}/lights
    parameters:
      username:
        type: string
        source: credential:username
        description: The whitelist username the link-button flow issued.
"#;

    fn bridge() -> DeviceSpec {
        parse_device_spec(BRIDGE).expect("test spec should parse")
    }

    #[test]
    fn a_credential_joins_its_consumers_to_the_flow_that_issues_it() {
        let found = required_credentials(&bridge());
        let names: Vec<&str> = found.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, vec!["clientkey", "username"]);

        let username = &found[1];
        assert_eq!(username.needed_by, vec!["get_lights", "set_light"]);
        assert_eq!(
            username.description.as_deref(),
            Some("The whitelist username the link-button flow issued.")
        );
        let issued = username.issued_by.as_ref().expect("the flow issues it");
        assert_eq!(issued.method, "button_pairing");
        assert_eq!(issued.command.as_deref(), Some("create_user"));
        assert_eq!(issued.reply_path, "[0].success.username");
    }

    #[test]
    fn a_credential_nothing_consumes_is_still_reported_and_never_asked_for() {
        // Hue's clientkey: obtainable only at creation time, so it is stored
        // when a pairing hands it over — but no command in the catalogue uses
        // it, and asking a person for it would be a question no answer helps.
        let found = required_credentials(&bridge());
        let clientkey = &found[0];
        assert_eq!(clientkey.name, "clientkey");
        assert!(clientkey.needed_by.is_empty());
        assert_eq!(
            clientkey
                .issued_by
                .as_ref()
                .unwrap()
                .request_condition
                .as_deref(),
            Some("generateclientkey: true")
        );
        assert!(!clientkey.must_be_asked_for());
        assert!(
            !found[1].must_be_asked_for(),
            "a pairing mints the username"
        );
    }

    #[test]
    fn a_credential_no_flow_issues_is_the_one_to_ask_for() {
        // The Bambu shape: the serial is read off the printer's touchscreen,
        // and no setup method in the spec can mint it.
        const PRINTER: &str = r#"
device:
  name: Test Printer
  manufacturer: Test
  manufacturer_status: active
  protocol: wifi
  transport: mqtt
commands:
  pause:
    description: Pause the print.
    transport: mqtt
    path: device/{serial}/request
    parameters:
      serial:
        type: string
        source: credential:serial
        description: The printer serial, read off the touchscreen during setup.
    body: '{"print":{"command":"pause"}}'
"#;
        let spec = parse_device_spec(PRINTER).expect("test spec should parse");
        let found = required_credentials(&spec);
        assert_eq!(found.len(), 1);
        assert_eq!(found[0].name, "serial");
        assert_eq!(found[0].needed_by, vec!["pause"]);
        assert!(found[0].issued_by.is_none());
        assert!(found[0].must_be_asked_for());
    }

    #[test]
    fn a_spec_that_names_no_credential_needs_none() {
        const PLAIN: &str = r#"
device:
  name: Test Remote
  manufacturer: Test
  manufacturer_status: active
  protocol: wifi
commands:
  press_home:
    description: Home.
    transport: http
    method: POST
    path: /keypress/Home
"#;
        let spec = parse_device_spec(PLAIN).expect("test spec should parse");
        assert!(required_credentials(&spec).is_empty());
    }
}

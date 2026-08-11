// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Drive a device whose control surface is SOAP actions rather than GATT
//! characteristics, from the spec and nothing else.
//!
//! The BLE path turns a spec command into bytes and hands them to the radio.
//! This is the same job one transport over: a spec command becomes an HTTP
//! request, and a returned value becomes an entity reading. Everything
//! device-specific — which action, which arguments, what a returned `8` means
//! — comes out of the YAML, so a second SOAP device is a spec, not a patch.
//!
//! What lives here is what a transport cannot work out for itself: parameter
//! defaulting, argument substitution, XML escaping, and the read-back rule
//! that keeps a two-argument action from clearing the argument nobody meant
//! to change. What deliberately does NOT live here is I/O. This crate has no
//! HTTP client and wants none: the caller resolves the address, sends the
//! request and hands the reply back as name→value pairs, exactly as the BLE
//! path hands back the bytes it read.

use std::collections::BTreeMap;

use crate::error::ProtocolError;
use crate::spec::types::{scalar_to_string, DeviceSpec, Entity, SpecCommand};

/// The SOAP transport a command must declare to be sendable from here.
pub const TRANSPORT: &str = "soap";

/// A rendered request, ready for whatever the caller uses to speak HTTP.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SoapRequest {
    /// `serviceType` URN. The caller resolves the control URL by matching this
    /// against the device's own service list — never by trusting a path.
    pub service: String,
    pub action: String,
    /// Value of the `SOAPACTION` header, quotes included. They are part of the
    /// value, and firmware that rejects the request does not say why.
    pub soap_action: String,
    /// Conventional path, when the spec states one. A fallback for a client
    /// that has not fetched the description yet, not an address to prefer.
    pub path: Option<String>,
    pub body: String,
}

/// The envelope every Wemo-generation SOAP device expects, used when the spec
/// publishes no template of its own.
///
/// Two things about this shape are load-bearing and neither is what a
/// general-purpose XML library emits by default: the `xmlns:u` declaration
/// sits **on the action element** rather than being hoisted to the envelope,
/// and the arguments are **unqualified** — `<ssid>x</ssid>`, never
/// `<u:ssid>x</u:ssid>`. Both are equivalent XML and neither is what these
/// devices are used to receiving.
const DEFAULT_TEMPLATE: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
<s:Body>
<u:{action} xmlns:u="{serviceType}">
{arguments}
</u:{action}>
</s:Body>
</s:Envelope>
"#;

/// Render one of the spec's `commands` into a request.
///
/// `values` supplies the parameters the caller owns; anything else the command
/// declares must carry a `default`, or this fails rather than sending a
/// half-filled action. Values are matched by name and stringified as the spec
/// author wrote them.
pub fn render_request(
    spec: &DeviceSpec,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<SoapRequest, ProtocolError> {
    let command =
        spec.commands
            .get(command_name)
            .ok_or_else(|| ProtocolError::CommandNotFound {
                uuid: "commands".to_string(),
                command: command_name.to_string(),
            })?;
    render_command(spec, command_name, command, values)
}

/// Render a command already in hand — the path a resolved control takes, which
/// has the command borrowed from its own resolution.
pub fn render_command(
    spec: &DeviceSpec,
    command_name: &str,
    command: &SpecCommand,
    values: &BTreeMap<String, String>,
) -> Result<SoapRequest, ProtocolError> {
    // A command for a transport this crate does not speak must not be rendered
    // as though it were SOAP: the result would be a well-formed request for
    // the wrong protocol, which fails at the device rather than here.
    if command.transport.as_deref().unwrap_or(TRANSPORT) != TRANSPORT {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            command.transport.clone().unwrap_or_default(),
        ));
    }
    let (Some(service), Some(action)) = (command.service.as_deref(), command.action.as_deref())
    else {
        return Err(ProtocolError::EmptyCommand);
    };

    let mut rendered = Vec::with_capacity(command.arguments.len());
    for (name, template) in &command.arguments {
        let literal =
            scalar_to_string(template).ok_or_else(|| ProtocolError::ParameterInvalid {
                name: name.clone(),
                value: 0.0,
                reason: "argument value is not a scalar".to_string(),
            })?;
        let value = match placeholder(&literal) {
            Some(param) => resolve_param(command, command_name, param, values)?,
            None => literal,
        };
        rendered.push(format!("<{name}>{}</{name}>", escape_xml(&value)));
    }

    let body = template_for(spec)
        .replace("{action}", action)
        .replace("{serviceType}", service)
        .replace("{arguments}", &rendered.join("\n"));

    Ok(SoapRequest {
        service: service.to_string(),
        action: action.to_string(),
        soap_action: format!("\"{service}#{action}\""),
        path: command.path.clone(),
        body: body.trim().to_string(),
    })
}

/// The request template the spec publishes, or the standard envelope.
///
/// Read from the spec first because a spec that documents its own wire format
/// byte for byte is making a claim a consumer should honour — and because the
/// next SOAP device may not spell the envelope the way Wemo does. `soap_common`
/// stays in `extensions`: nothing here needs the rest of the block, and lifting
/// a whole vendor section into typed fields to read one string would be a worse
/// trade than walking two keys.
fn template_for(spec: &DeviceSpec) -> String {
    spec.extensions
        .get("soap_common")
        .and_then(|block| block.get("request_format"))
        .and_then(|format| format.get("template"))
        .and_then(|template| template.as_str())
        .filter(|template| {
            // A template missing a placeholder would render a request with a
            // literal `{action}` in it. Fall back rather than send that.
            template.contains("{action}")
                && template.contains("{serviceType}")
                && template.contains("{arguments}")
        })
        .map_or_else(|| DEFAULT_TEMPLATE.to_string(), str::to_string)
}

/// `"{name}"` → `name`. Anything else is a literal the command already chose.
fn placeholder(value: &str) -> Option<&str> {
    value
        .strip_prefix('{')
        .and_then(|rest| rest.strip_suffix('}'))
        .filter(|name| !name.is_empty())
}

fn resolve_param(
    command: &SpecCommand,
    command_name: &str,
    param: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    if let Some(value) = values.get(param) {
        return Ok(value.clone());
    }
    command
        .parameters
        .get(param)
        .and_then(|p| p.default.as_ref())
        .and_then(scalar_to_string)
        .ok_or_else(|| ProtocolError::ParameterMissing(format!("{command_name}.{param}")))
}

/// Render the request that reads a state command's values — a SOAP call with
/// no arguments, addressed by what the spec's `http_endpoints` catalogue says
/// about the named action.
///
/// State reads are the one request an entity makes that no `commands` entry
/// covers: `GetCrockpotState` is invoked by nothing, it is only *read from*.
/// The endpoint entry carries its `service` (the schema declares the key for
/// exactly this reason — a SOAPACTION header cannot be built from prose) and
/// its conventional `path`.
pub fn render_state_request(
    spec: &DeviceSpec,
    state_command: &str,
) -> Result<SoapRequest, ProtocolError> {
    let endpoint =
        find_endpoint(spec, state_command).ok_or_else(|| ProtocolError::CommandNotFound {
            uuid: "http_endpoints".to_string(),
            command: state_command.to_string(),
        })?;
    let service = endpoint_service(&endpoint).ok_or_else(|| {
        ProtocolError::UnsupportedCommandEncoding(format!(
            "endpoint '{state_command}' declares no service, so its SOAPACTION cannot be built"
        ))
    })?;

    let body = template_for(spec)
        .replace("{action}", state_command)
        .replace("{serviceType}", &service)
        .replace("{arguments}", "");

    Ok(SoapRequest {
        soap_action: format!("\"{service}#{state_command}\""),
        service,
        action: state_command.to_string(),
        path: endpoint
            .get("path")
            .and_then(|p| p.as_str())
            .map(str::to_string),
        // An empty argument line would leave a blank line inside the action
        // element; harmless, but the published examples do not carry one.
        body: body.replace("\n\n", "\n").trim().to_string(),
    })
}

/// The `http_endpoints` entry named `name`, out of the untyped extension
/// block. Endpoints stay untyped because only two keys are read here and the
/// catalogue's endpoint entries vary widely.
fn find_endpoint(spec: &DeviceSpec, name: &str) -> Option<serde_yaml::Value> {
    spec.extensions
        .get("http_endpoints")?
        .as_sequence()?
        .iter()
        .find(|entry| entry.get("name").and_then(|n| n.as_str()) == Some(name))
        .cloned()
}

/// An endpoint's service URN: the declared `service` key, or — for a spec
/// written before the key existed — the first `urn:` token its description
/// quotes, minus any `#Action` suffix.
fn endpoint_service(endpoint: &serde_yaml::Value) -> Option<String> {
    if let Some(service) = endpoint.get("service").and_then(|s| s.as_str()) {
        return Some(service.to_string());
    }
    let description = endpoint.get("description")?.as_str()?;
    let start = description.find("urn:")?;
    let tail = &description[start..];
    let end = tail
        .find(|c: char| c == '#' || c == '"' || c.is_whitespace())
        .unwrap_or(tail.len());
    let urn = tail[..end].trim_end_matches(['.', ',']);
    (!urn.is_empty()).then(|| urn.to_string())
}

/// Escape the three characters that would otherwise close or open an element.
///
/// The spec calls this out because an SSID containing an ampersand is the
/// case that bites, and because pywemo does not escape at all — so this is a
/// deliberate divergence in our favour rather than a device behaviour.
fn escape_xml(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            _ => out.push(ch),
        }
    }
    out
}

/// What one entity reads out of a state call's return values.
#[derive(Debug, Clone, PartialEq)]
pub enum EntityReading {
    /// A switch or binary sensor: on, or off.
    OnOff(bool),
    /// A `select` whose raw value matched its option table.
    Option {
        raw: String,
        label: String,
    },
    /// A `select` whose raw value did NOT match. Kept distinct from
    /// [`Self::Option`] rather than collapsed to the first entry, because on a
    /// Crock-Pot that collapse reads "off" while the thing is heating.
    UnknownOption {
        raw: String,
    },
    Number(f64),
    Text(String),
}

/// Read one entity's state out of the name→value pairs a state call returned.
///
/// The rule, stated in the spec and transcribed here: `state_mapping.value`
/// names a value the call RETURNS; a `payload_formats` entry for that name
/// says how to get a field out of it; `on_when: nonzero` decides on/off; and
/// an `options` table turns a raw number into a label.
pub fn read_entity(
    spec: &DeviceSpec,
    entity: &Entity,
    returned: &BTreeMap<String, String>,
) -> Option<EntityReading> {
    let field = entity.value_field()?;
    let raw = returned.get(field)?;

    // A returned value may pack several fields into one string. Only the spec
    // knows: `GetBinaryState` answers `1` on one firmware and
    // `8|1492338954|…` on another, and both are the state of the same plug.
    let raw = match spec.payload_formats.get(field) {
        Some(format) => format.primary_value(raw)?,
        None => raw.as_str(),
    }
    .trim();

    if entity.on_when_nonzero() {
        return Some(EntityReading::OnOff(parse_number(raw)? != 0.0));
    }
    if let Some(on_value) = entity.on_value() {
        return Some(EntityReading::OnOff(parse_number(raw)? as i64 == on_value));
    }
    if !entity.options().is_empty() {
        return Some(match entity.option_label(raw) {
            Some(label) => EntityReading::Option {
                raw: raw.to_string(),
                label,
            },
            None => EntityReading::UnknownOption {
                raw: raw.to_string(),
            },
        });
    }
    match parse_number(raw) {
        // The entity layer's own scale, when it declares one: the same rule
        // the BLE path applies, so a reading means the same thing whichever
        // transport carried it.
        Some(number) => Some(EntityReading::Number(
            number * entity.value_scale().unwrap_or(1.0),
        )),
        None => Some(EntityReading::Text(raw.to_string())),
    }
}

fn parse_number(raw: &str) -> Option<f64> {
    raw.parse::<f64>().ok()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A miniature two-argument device, so the tests here exercise the rules
    /// rather than one catalogue spec. The real Wemo file is driven end to end
    /// in `tests/network_control.rs`.
    const SPEC: &str = r#"
device:
  name: "Test Cooker"
  manufacturer: "Test"
  manufacturer_status: "shutdown"
  protocol: "wifi"
  category: "appliance"
commands:
  turn_off:
    description: "Off."
    transport: "soap"
    service: "urn:Test:service:basicevent:1"
    action: "SetCookerState"
    arguments:
      mode: "0"
      time: "0"
  set_mode:
    description: "Mode, keeping the time."
    transport: "soap"
    service: "urn:Test:service:basicevent:1"
    action: "SetCookerState"
    arguments:
      mode: "{mode}"
      time: "{time}"
    parameters:
      mode:
        type: "integer"
        required: true
      time:
        type: "integer"
        source: "state:GetCookerState.time"
        default: 0
  rename:
    description: "A name is the argument that needs escaping."
    transport: "soap"
    service: "urn:Test:service:basicevent:1"
    action: "ChangeFriendlyName"
    arguments:
      FriendlyName: "{name}"
    parameters:
      name:
        type: "string"
        required: true
  over_zigbee:
    description: "A transport this crate does not speak."
    transport: "zigbee"
    service: "urn:Test:service:basicevent:1"
    action: "SetCookerState"
    arguments:
      mode: "1"
payload_formats:
  BinaryState:
    description: "State, sometimes with counters after it."
    delimiter: "|"
    fields:
      - index: 0
        name: "state"
entities:
  - platform: "switch"
    name: "Cooker"
    state_endpoint: "/upnp/control/basicevent1"
    state_command: "GetCookerState"
    state_mapping:
      value: "mode"
      on_when: "nonzero"
    commands:
      turn_off: "turn_off"
  - platform: "select"
    name: "Mode"
    state_command: "GetCookerState"
    state_mapping:
      value: "mode"
      options:
        0: "off"
        50: "warm"
        51: "low"
    commands:
      select_option: "set_mode"
  - platform: "sensor"
    name: "Plug"
    state_command: "GetBinaryState"
    state_mapping:
      value: "BinaryState"
"#;

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC).expect("fixture spec parses")
    }

    fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect()
    }

    #[test]
    fn renders_a_fixed_command_without_any_input() {
        let request = render_request(&spec(), "turn_off", &values(&[])).unwrap();
        assert_eq!(
            request.soap_action,
            "\"urn:Test:service:basicevent:1#SetCookerState\""
        );
        assert!(request.body.contains("<mode>0</mode>"));
        assert!(request.body.contains("<time>0</time>"));
        // The declaration belongs on the action element, and arguments are
        // unqualified. Both are what these devices expect and neither is what
        // an XML library does by default.
        assert!(request
            .body
            .contains("<u:SetCookerState xmlns:u=\"urn:Test:service:basicevent:1\">"));
        assert!(!request.body.contains("<u:mode>"));
    }

    #[test]
    fn substitutes_the_supplied_value_and_defaults_the_rest() {
        let request = render_request(&spec(), "set_mode", &values(&[("mode", "51")])).unwrap();
        assert!(request.body.contains("<mode>51</mode>"));
        // Not supplied, so the spec's default carries it — the argument the
        // control was never going to touch still goes out.
        assert!(request.body.contains("<time>0</time>"));
    }

    #[test]
    fn a_supplied_read_back_value_beats_the_default() {
        let request = render_request(
            &spec(),
            "set_mode",
            &values(&[("mode", "51"), ("time", "240")]),
        )
        .unwrap();
        assert!(request.body.contains("<time>240</time>"));
    }

    #[test]
    fn a_parameter_with_no_value_and_no_default_is_an_error() {
        let err = render_request(&spec(), "set_mode", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterMissing(name) if name == "set_mode.mode"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn argument_values_are_xml_escaped() {
        let request =
            render_request(&spec(), "rename", &values(&[("name", "Ben & Jerry's")])).unwrap();
        assert!(request
            .body
            .contains("<FriendlyName>Ben &amp; Jerry's</FriendlyName>"));
    }

    #[test]
    fn a_command_for_another_transport_is_declined_rather_than_rendered() {
        let err = render_request(&spec(), "over_zigbee", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::UnsupportedCommandEncoding(t) if t == "zigbee"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn an_unknown_command_names_itself_in_the_error() {
        let err = render_request(&spec(), "no_such_command", &values(&[])).unwrap_err();
        assert!(err.to_string().contains("no_such_command"));
    }

    #[test]
    fn a_spec_template_is_preferred_over_the_built_in_envelope() {
        let mut yaml = SPEC.to_string();
        yaml.push_str(
            r#"
soap_common:
  request_format:
    template: |
      <envelope><body><u:{action} xmlns:u="{serviceType}">
      {arguments}
      </u:{action}></body></envelope>
"#,
        );
        let spec = parse_device_spec(&yaml).unwrap();
        let request = render_command(
            &spec,
            "turn_off",
            spec.commands.get("turn_off").unwrap(),
            &values(&[]),
        )
        .unwrap();
        assert!(request.body.starts_with("<envelope>"));
        assert!(request.body.contains("<mode>0</mode>"));
    }

    #[test]
    fn a_template_missing_its_placeholders_falls_back() {
        let mut yaml = SPEC.to_string();
        yaml.push_str(
            r#"
soap_common:
  request_format:
    template: "<envelope>nothing to substitute</envelope>"
"#,
        );
        let spec = parse_device_spec(&yaml).unwrap();
        let request = render_request(&spec, "turn_off", &values(&[])).unwrap();
        assert!(
            request.body.contains("<mode>0</mode>"),
            "a template with no placeholders must not swallow the arguments"
        );
    }

    fn returned(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| ((*k).to_string(), (*v).to_string()))
            .collect()
    }

    #[test]
    fn a_switch_reads_on_from_any_nonzero_mode() {
        let spec = spec();
        let switch = &spec.entities[0];
        let state = read_entity(&spec, switch, &returned(&[("mode", "51")]));
        assert_eq!(state, Some(EntityReading::OnOff(true)));
        let state = read_entity(&spec, switch, &returned(&[("mode", "0")]));
        assert_eq!(state, Some(EntityReading::OnOff(false)));
    }

    #[test]
    fn a_select_reads_its_label_and_says_so_when_it_cannot() {
        let spec = spec();
        let select = &spec.entities[1];
        assert_eq!(
            read_entity(&spec, select, &returned(&[("mode", "51")])),
            Some(EntityReading::Option {
                raw: "51".to_string(),
                label: "low".to_string()
            })
        );
        // A mode the table does not know must not fold into the first entry:
        // that entry is `off`, and the device is not.
        assert_eq!(
            read_entity(&spec, select, &returned(&[("mode", "99")])),
            Some(EntityReading::UnknownOption {
                raw: "99".to_string()
            })
        );
    }

    #[test]
    fn a_delimited_payload_is_split_where_the_spec_says_it_is() {
        let spec = spec();
        let sensor = &spec.entities[2];
        assert_eq!(
            read_entity(&spec, sensor, &returned(&[("BinaryState", "1")])),
            Some(EntityReading::Number(1.0)),
            "the short form is the whole value"
        );
        assert_eq!(
            read_entity(
                &spec,
                sensor,
                &returned(&[("BinaryState", "8|1492338954|0|922")])
            ),
            Some(EntityReading::Number(8.0)),
            "the long form's state is field 0, not the whole string"
        );
    }

    #[test]
    fn a_value_the_call_did_not_return_reads_as_nothing() {
        let spec = spec();
        // Not an error and not a zero: a control with no reading shows as
        // unknown, where a fabricated 0 would show a plug as off.
        assert_eq!(read_entity(&spec, &spec.entities[0], &returned(&[])), None);
    }
}

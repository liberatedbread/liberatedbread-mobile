// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Drive a device whose control surface is plain HTTP requests, from the spec
//! and nothing else.
//!
//! The SOAP module renders an action into an envelope; this is the same job
//! for a transport with nothing to render — Roku ECP's whole instruction is
//! the method and the path, with an empty body. What lives here is the little
//! a transport that simple still needs: parameter substitution into the path,
//! percent-encoding of substituted values so a key like `Lit_ ` cannot break
//! the request line, and the same fail-visibly rule for `source` parameters
//! the SOAP renderer applies. What deliberately does NOT live here is I/O:
//! the caller owns the socket, exactly as it does for SOAP and BLE.

use std::collections::BTreeMap;

use crate::error::ProtocolError;
use crate::spec::types::{scalar_to_string, DeviceSpec, SpecCommand};

/// The transport a command must declare to be sendable from here.
pub const TRANSPORT: &str = "http";

/// The methods a client of this transport is expected to implement, and so
/// the ones a control may be offered for.
///
/// The command schema allows PUT, DELETE and PATCH as well; nothing in the
/// catalogue uses them, and the app's HTTP client sends only these two. The
/// list lives here, beside the renderer, so the capability gate and the
/// transport cannot drift into disagreeing — a control resolved for a method
/// nothing can send is a button whose every press fails, which is precisely
/// what the gate exists to prevent.
pub const SENDABLE_METHODS: &[&str] = &["GET", "POST"];

/// Whether a client of this transport can send `method`.
pub fn is_sendable_method(method: &str) -> bool {
    SENDABLE_METHODS
        .iter()
        .any(|known| method.eq_ignore_ascii_case(known))
}

/// A rendered request, ready for whatever the caller uses to speak HTTP.
///
/// The address is the caller's: discovery already knows the host and port
/// (Roku's SSDP LOCATION carries both), and this crate has no business
/// second-guessing it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HttpRequest {
    /// `GET` | `POST` | …, as the spec spelled it.
    pub method: String,
    /// Path with every placeholder substituted, starting with `/`.
    pub path: String,
    /// Request body. Empty for the command style this exists for — ECP
    /// commands carry the whole instruction in the path — but carried so a
    /// future spec with a body is a spec change, not a type change.
    pub body: String,
}

/// Render one of the spec's `commands` into a request.
///
/// `values` supplies the parameters the caller owns plus any read-back values
/// it fetched; everything else must carry a `default`, or this fails rather
/// than send a half-filled path. Substituted values are percent-encoded;
/// literal path text is the spec author's and goes out as written.
pub fn render_request(
    spec: &DeviceSpec,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<HttpRequest, ProtocolError> {
    let command =
        spec.commands
            .get(command_name)
            .ok_or_else(|| ProtocolError::CommandNotFound {
                uuid: "commands".to_string(),
                command: command_name.to_string(),
            })?;
    render_command(command_name, command, values)
}

/// Render a command already in hand — the path a resolved control takes.
pub fn render_command(
    command_name: &str,
    command: &SpecCommand,
    values: &BTreeMap<String, String>,
) -> Result<HttpRequest, ProtocolError> {
    // A command for another transport must not be rendered as though it were
    // plain HTTP: a SOAP action pushed through here would lose its envelope
    // and fail at the device rather than here. Absent means the spec's single
    // declared transport, which for every spec with SOAP commands is SOAP —
    // so only an explicit `http` qualifies.
    if command.transport.as_deref() != Some(TRANSPORT) {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            command.transport.clone().unwrap_or_default(),
        ));
    }
    let (Some(method), Some(path)) = (command.method.as_deref(), command.path.as_deref()) else {
        return Err(ProtocolError::EmptyCommand);
    };

    Ok(HttpRequest {
        method: method.to_string(),
        path: substitute(path, command, command_name, values)?,
        body: String::new(),
    })
}

/// Replace every `{name}` in `template` with its parameter's value.
///
/// Same resolution order as the SOAP renderer: the caller's value first, then
/// the parameter's declared `default`, then a visible failure. `source`
/// parameters have no default by the spec's own rule, so a skipped read-back
/// fails the render here too.
fn substitute(
    template: &str,
    command: &SpecCommand,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while let Some(start) = rest.find('{') {
        let (literal, tail) = rest.split_at(start);
        out.push_str(literal);
        let Some(end) = tail.find('}') else {
            // An unclosed brace is the spec author's literal; emit as written.
            out.push_str(tail);
            rest = "";
            break;
        };
        let param = &tail[1..end];
        let value = resolve_param(command, command_name, param, values)?;
        out.push_str(&percent_encode(&value));
        rest = &tail[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
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

/// The request an `http_endpoints` entry describes: its method and path.
///
/// The join `options_source`/`state_source` make by `command` name. Returns
/// nothing for an endpoint that is absent, incompletely declared, or marked
/// `sunset` — a query source pointing at a removed endpoint is a list that
/// can never load, and resolving it would put that dead list on screen.
pub fn endpoint_request(spec: &DeviceSpec, name: &str) -> Option<(String, String)> {
    let endpoint = spec
        .extensions
        .get("http_endpoints")?
        .as_sequence()?
        .iter()
        .find(|entry| entry.get("name").and_then(|n| n.as_str()) == Some(name))?
        .clone();
    if endpoint.get("status").and_then(|s| s.as_str()) == Some("sunset") {
        return None;
    }
    let method = endpoint.get("method")?.as_str()?;
    let path = endpoint.get("path")?.as_str()?;
    Some((method.to_string(), path.to_string()))
}

/// Percent-encode one substituted value for a path segment.
///
/// Unreserved characters (RFC 3986) pass through; everything else is encoded
/// byte-wise. Deliberately strict: a substituted value is data, never path
/// structure, so even `/` is encoded — the spec's literal text is where
/// structure lives.
fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for byte in value.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A miniature ECP-shaped device, so these tests exercise the rules. The
    /// real vendored Roku file is driven end to end in `tests/roku_control.rs`.
    const SPEC: &str = r#"
device:
  name: "Test Remote"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "tv"
commands:
  press_home:
    description: "Fixed path, nothing to fill."
    transport: "http"
    method: "POST"
    path: "/keypress/Home"
  type_char:
    description: "A substituted value that needs encoding."
    transport: "http"
    method: "POST"
    path: "/keypress/Lit_{char}"
    parameters:
      char:
        type: "string"
        required: true
  launch_defaulted:
    description: "A defaulted parameter is protocol filler."
    transport: "http"
    method: "POST"
    path: "/launch/{app_id}"
    parameters:
      app_id:
        type: "string"
        default: 12
  over_soap:
    description: "A transport this module does not speak."
    transport: "soap"
    service: "urn:Test:service:basicevent:1"
    action: "SetBinaryState"
  implicit_transport:
    description: "No transport stated; must not be guessed into HTTP."
    method: "POST"
    path: "/keypress/Home"
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
        let request = render_request(&spec(), "press_home", &values(&[])).unwrap();
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/keypress/Home");
        assert!(request.body.is_empty(), "ECP commands carry no body");
    }

    #[test]
    fn substituted_values_are_percent_encoded() {
        let request = render_request(&spec(), "type_char", &values(&[("char", " ")])).unwrap();
        assert_eq!(request.path, "/keypress/Lit_%20");
        // Structure stays the author's; data cannot add path segments.
        let sneaky = render_request(&spec(), "type_char", &values(&[("char", "a/b")])).unwrap();
        assert_eq!(sneaky.path, "/keypress/Lit_a%2Fb");
    }

    #[test]
    fn unreserved_characters_pass_through_unencoded() {
        let request = render_request(&spec(), "type_char", &values(&[("char", "a")])).unwrap();
        assert_eq!(request.path, "/keypress/Lit_a");
    }

    #[test]
    fn a_defaulted_parameter_fills_itself_in() {
        let request = render_request(&spec(), "launch_defaulted", &values(&[])).unwrap();
        assert_eq!(request.path, "/launch/12");
    }

    #[test]
    fn a_missing_parameter_is_an_error_not_a_blank() {
        let err = render_request(&spec(), "type_char", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterMissing(name) if name == "type_char.char"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn a_command_for_another_transport_is_declined() {
        let err = render_request(&spec(), "over_soap", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::UnsupportedCommandEncoding(t) if t == "soap"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn an_absent_transport_is_not_guessed_into_http() {
        // The SOAP renderer treats absent as SOAP (its specs predate the
        // key); this one must not claim the same commands.
        let err = render_request(&spec(), "implicit_transport", &values(&[])).unwrap_err();
        assert!(matches!(
            &err,
            ProtocolError::UnsupportedCommandEncoding(t) if t.is_empty()
        ));
    }

    #[test]
    fn an_unknown_command_names_itself_in_the_error() {
        let err = render_request(&spec(), "no_such_command", &values(&[])).unwrap_err();
        assert!(err.to_string().contains("no_such_command"));
    }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Drive a device whose control surface is plain HTTP requests, from the spec
//! and nothing else.
//!
//! The SOAP module renders an action into an envelope; this is the same job
//! for a transport that ranges from having nothing to render — Roku ECP's
//! whole instruction is the method and the path, with an empty body — to a
//! hub whose write is a JSON document (the Hue Bridge). What lives here is
//! what such a transport still needs: parameter substitution into the path,
//! percent-encoding of substituted values so a key like `Lit_ ` cannot break
//! the request line, a JSON body built in the spec's declared argument order
//! and typed by each parameter, and the same fail-visibly rule for `source`
//! parameters the SOAP renderer applies. Two source schemes beyond `state:`
//! ride this transport — `credential:` (a per-device secret stored at
//! pairing) and `instance:` (the id of the child a hub command addresses) —
//! and an instanced entity's state reply enumerates every child at once.
//! What deliberately does NOT live here is I/O: the caller owns the socket,
//! exactly as it does for SOAP and BLE.

use std::collections::BTreeMap;

use crate::error::ProtocolError;
use crate::protocol::soap::EntityReading;
use crate::spec::types::{
    scalar_to_string, DeviceSpec, Entity, EntityInstances, SpecCommand, SpecCommandParameter,
};

/// The transport a command must declare to be sendable from here.
pub const TRANSPORT: &str = "http";

/// The methods a client of this transport is expected to implement, and so
/// the ones a control may be offered for.
///
/// The command schema allows DELETE and PATCH as well; nothing in the
/// catalogue uses them, and the app's HTTP client sends only these three
/// (Roku keypresses POST, the Hue bridge reads with GET and writes light
/// state with PUT). The list lives here, beside the renderer, so the
/// capability gate and the transport cannot drift into disagreeing — a
/// control resolved for a method nothing can send is a button whose every
/// press fails, which is precisely what the gate exists to prevent.
pub const SENDABLE_METHODS: &[&str] = &["GET", "POST", "PUT"];

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
    /// Request body: empty when the command declares no `arguments` (ECP
    /// keypresses carry the whole instruction in the path), or a compact
    /// JSON object in the spec's declared argument order otherwise (the Hue
    /// bridge's `{"on":true,"bri":200}`). The caller sends a Content-Type
    /// only when this is non-empty.
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
        body: render_body(command, command_name, values)?,
    })
}

/// Build the JSON request body from a command's `arguments`, or the empty
/// string when it declares none.
///
/// Declared order is the canon — the spec's `example_body` is diffed against
/// this — and each value takes the JSON type its parameter declares: a `bri`
/// declared `integer` renders as the number `200`, never the string `"200"`,
/// because the Hue bridge rejects the quoted form and does not say why. A
/// `{name}` argument value substitutes like a path placeholder (same
/// resolution order, same fail-visibly rule); anything else is a literal the
/// command already chose, carried with its YAML type intact
/// (`generateclientkey: true` is a JSON `true`).
fn render_body(
    command: &SpecCommand,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    if command.arguments.is_empty() {
        return Ok(String::new());
    }
    let mut rendered = serde_json::Map::with_capacity(command.arguments.len());
    for (name, template) in &command.arguments {
        let value = match template.as_str().and_then(placeholder) {
            Some(param) => {
                let raw = resolve_param(command, command_name, param, values)?;
                typed_json(command.parameters.get(param), param, &raw)?
            }
            None => yaml_to_json(name, template)?,
        };
        rendered.insert(name.clone(), value);
    }
    Ok(serde_json::Value::Object(rendered).to_string())
}

/// `"{name}"` → `name`; anything else is a literal the command already chose.
fn placeholder(value: &str) -> Option<&str> {
    value
        .strip_prefix('{')
        .and_then(|rest| rest.strip_suffix('}'))
        .filter(|name| !name.is_empty())
}

/// Coerce a substituted string to the JSON type its parameter declares. An
/// undeclared type is a string, which is the YAML default reading.
fn typed_json(
    parameter: Option<&SpecCommandParameter>,
    name: &str,
    raw: &str,
) -> Result<serde_json::Value, ProtocolError> {
    let declared = parameter
        .and_then(|p| p.value_type.as_deref())
        .unwrap_or("string");
    let invalid = |reason: &str| ProtocolError::ParameterInvalid {
        name: name.to_string(),
        value: raw.parse().unwrap_or(0.0),
        reason: reason.to_string(),
    };
    match declared {
        "integer" => raw
            .trim()
            .parse::<i64>()
            .map(serde_json::Value::from)
            .map_err(|_| invalid("declared integer, and this is not one")),
        "number" => {
            let number: f64 = raw
                .trim()
                .parse()
                .map_err(|_| invalid("declared number, and this is not one"))?;
            serde_json::Number::from_f64(number)
                .map(serde_json::Value::Number)
                .ok_or_else(|| invalid("declared number, and this is not finite"))
        }
        "boolean" => match raw.trim() {
            "true" | "1" => Ok(serde_json::Value::Bool(true)),
            "false" | "0" => Ok(serde_json::Value::Bool(false)),
            _ => Err(invalid("declared boolean, and this is neither")),
        },
        _ => Ok(serde_json::Value::String(raw.to_string())),
    }
}

/// A literal argument's YAML value as JSON, type intact.
fn yaml_to_json(name: &str, value: &serde_yaml::Value) -> Result<serde_json::Value, ProtocolError> {
    match value {
        serde_yaml::Value::Bool(b) => Ok(serde_json::Value::Bool(*b)),
        serde_yaml::Value::Number(n) => {
            if let Some(integer) = n.as_i64() {
                Ok(serde_json::Value::from(integer))
            } else if let Some(unsigned) = n.as_u64() {
                Ok(serde_json::Value::from(unsigned))
            } else {
                n.as_f64()
                    .and_then(serde_json::Number::from_f64)
                    .map(serde_json::Value::Number)
                    .ok_or_else(|| ProtocolError::ParameterInvalid {
                        name: name.to_string(),
                        value: 0.0,
                        reason: "literal number does not fit JSON".to_string(),
                    })
            }
        }
        serde_yaml::Value::String(s) => Ok(serde_json::Value::String(s.clone())),
        serde_yaml::Value::Null => Ok(serde_json::Value::Null),
        other => Err(ProtocolError::ParameterInvalid {
            name: name.to_string(),
            value: 0.0,
            reason: format!("argument literals must be scalars, got {other:?}"),
        }),
    }
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

/// Render the request that reads a state command's values over HTTP — on an
/// instanced entity, the one GET that enumerates every child and carries all
/// their state.
///
/// Two vocabularies can name the poll, tried in order. A hub's state command
/// names an `http_endpoints` catalogue entry (the Hue bridge's `Lights`), its
/// path placeholders filled from `values` — a placeholder with no value fails
/// the render, the same fail-visibly rule a command's `source` gets, because
/// an unpaired client must not issue a credential-less read. A plain device's
/// state command names a `commands` entry instead (the Envoy's
/// `get_production_v1`), which renders exactly as it would for a send —
/// including the transport check, so a SOAP command handed here is still
/// declined.
pub fn render_state_request(
    spec: &DeviceSpec,
    state_command: &str,
    values: &BTreeMap<String, String>,
) -> Result<HttpRequest, ProtocolError> {
    let Some((method, path)) = endpoint_request(spec, state_command) else {
        let command =
            spec.commands
                .get(state_command)
                .ok_or_else(|| ProtocolError::CommandNotFound {
                    uuid: "http_endpoints".to_string(),
                    command: state_command.to_string(),
                })?;
        return render_command(state_command, command, values);
    };
    let mut out = String::with_capacity(path.len());
    let mut rest = path.as_str();
    while let Some(start) = rest.find('{') {
        let (literal, tail) = rest.split_at(start);
        out.push_str(literal);
        let Some(end) = tail.find('}') else {
            out.push_str(tail);
            rest = "";
            break;
        };
        let param = &tail[1..end];
        let value = values
            .get(param)
            .ok_or_else(|| ProtocolError::ParameterMissing(format!("{state_command}.{param}")))?;
        out.push_str(&percent_encode(value));
        rest = &tail[end + 1..];
    }
    out.push_str(rest);
    Ok(HttpRequest {
        method,
        path: out,
        body: String::new(),
    })
}

/// One child behind a hub, as enumerated from a state reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Instance {
    /// The hub's own id for the child ("1", "2", …) — the value that fills
    /// the `instance:` placeholder of every bound command.
    pub id: String,
    /// The child's human-facing name, from `instances.label_path`, or the id
    /// again when the spec names no path or the child no name.
    pub label: String,
}

/// Where a `source` parameter's value comes from, parsed from its scheme.
///
/// The renderer is scheme-blind — every source is a name the caller supplies
/// in `values` — but the CALLER needs to know what to fetch: a device
/// read-back, a stored credential, or the current child's id. This is that
/// answer, as data.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceScheme<'a> {
    /// `state:<command>.<field>` — read back from the device first.
    State { command: &'a str, field: &'a str },
    /// `credential:<name>` — a per-device secret stored at pairing.
    Credential(&'a str),
    /// `instance:<key>` — the id of the child currently addressed.
    Instance(&'a str),
}

/// Parse a parameter's `source` string into its scheme, or `None` for one
/// this crate does not know — the caller then treats the parameter as
/// unfillable, the same "decline, don't guess" rule an unknown transport gets.
pub fn parse_source(source: &str) -> Option<SourceScheme<'_>> {
    if let Some(rest) = source.strip_prefix("state:") {
        let (command, field) = rest.split_once('.')?;
        return Some(SourceScheme::State { command, field });
    }
    if let Some(name) = source.strip_prefix("credential:") {
        return (!name.is_empty()).then_some(SourceScheme::Credential(name));
    }
    if let Some(key) = source.strip_prefix("instance:") {
        return (!key.is_empty()).then_some(SourceScheme::Instance(key));
    }
    None
}

/// Enumerate the children an instanced entity's state reply carries.
///
/// The reply is a JSON object keyed by child id; ids sort numerically where
/// they are numbers (a bridge with eleven lights lists 2 before 10) and
/// lexically after that. A child whose `label_path` resolves to nothing keeps
/// its id as the label — honest, if it reads like a database.
pub fn list_instances(entity: &Entity, reply: &str) -> Result<Vec<Instance>, ProtocolError> {
    let instances = entity
        .instances
        .as_ref()
        .ok_or_else(|| ProtocolError::EntityNotInstanced(entity.name.clone()))?;
    Ok(instance_children(instances, reply)?
        .into_iter()
        .map(|(id, child)| Instance {
            label: instances
                .label_path
                .as_deref()
                .and_then(|path| walk(&child, path))
                .and_then(|v| v.as_str().map(str::to_string))
                .unwrap_or_else(|| id.clone()),
            id,
        })
        .collect())
}

/// Read one child's roles out of a state reply, per the entity's
/// `state_mapping`, whose dotted paths resolve INSIDE the child's object.
///
/// An absent child yields no readings rather than an error — a light
/// unplugged between enumeration and read shows as unknown, where a
/// fabricated reading would show it off. A role whose path resolves to
/// nothing is omitted for the same reason. Readings key by role in a
/// BTreeMap so callers see a stable order.
pub fn read_instance_entity(
    entity: &Entity,
    reply: &str,
    instance_id: &str,
) -> Result<BTreeMap<String, EntityReading>, ProtocolError> {
    let instances = entity
        .instances
        .as_ref()
        .ok_or_else(|| ProtocolError::EntityNotInstanced(entity.name.clone()))?;
    let children = instance_children(instances, reply)?;
    let Some((_, child)) = children.iter().find(|(id, _)| id == instance_id) else {
        return Ok(BTreeMap::new());
    };

    let on_when_nonzero = entity.on_when_nonzero();
    let mut readings = BTreeMap::new();
    for (role, path) in &entity.state_mapping {
        let Some(dotted) = path.as_str() else {
            continue;
        };
        let Some(value) = walk(child, dotted) else {
            continue;
        };
        // The JSON type decides the reading: a bool is on/off, a string is
        // text. A number is the number — UNLESS the entity declares
        // `on_when: nonzero`, in which case it is on/off (nonzero = on). A Hue
        // light already speaks boolean and needs no table; a Kasa outlet
        // reports `state` as 0/1 and does, exactly as the plain switch reads
        // relay_state.
        let reading = match value {
            serde_json::Value::Bool(b) => EntityReading::OnOff(*b),
            serde_json::Value::Number(n) => match n.as_f64() {
                Some(number) if on_when_nonzero => EntityReading::OnOff(number != 0.0),
                Some(number) => EntityReading::Number(number),
                None => continue,
            },
            serde_json::Value::String(s) => EntityReading::Text(s.clone()),
            _ => continue,
        };
        readings.insert(role.clone(), reading);
    }
    Ok(readings)
}

/// Enumerate an instanced entity's children from its state reply, as (id, child)
/// pairs in the order they should be shown.
///
/// Two shapes, chosen by whether `instances.children_path` is set:
/// - **Nested array** (a Kasa strip's `system.get_sysinfo.children`): each
///   element is a child and carries its own id in `instances.id_field`
///   (default `id`). A path that resolves to nothing yields no children — a
///   single-outlet plug reports no `children`, so the entity degrades to the
///   plain switch rather than erroring.
/// - **Object keyed by id** (a Hue bridge): the reply itself is the map, each
///   key an id.
///
/// Ids sort numerically where they are numbers (light 2 before light 10) and
/// lexically otherwise (Kasa's `<deviceId>00`, `<deviceId>01`, … stay in
/// outlet order).
fn instance_children(
    instances: &EntityInstances,
    reply: &str,
) -> Result<Vec<(String, serde_json::Value)>, ProtocolError> {
    let parsed: serde_json::Value =
        serde_json::from_str(reply).map_err(|e| ProtocolError::InvalidStateReply(e.to_string()))?;

    let mut children: Vec<(String, serde_json::Value)> = match instances.children_path.as_deref() {
        Some(path) => {
            let Some(node) = walk(&parsed, path) else {
                return Ok(Vec::new());
            };
            let serde_json::Value::Array(elements) = node else {
                return Err(ProtocolError::InvalidStateReply(format!(
                    "expected an array of children at {path}, got {}",
                    json_kind(node)
                )));
            };
            let id_field = instances.id_field.as_deref().unwrap_or("id");
            elements
                .iter()
                .filter_map(|child| {
                    let id = walk(child, id_field)?.as_str()?.to_string();
                    Some((id, child.clone()))
                })
                .collect()
        }
        None => match parsed {
            serde_json::Value::Object(map) => map.into_iter().collect(),
            other => {
                return Err(ProtocolError::InvalidStateReply(format!(
                    "expected an object keyed by instance id, got {}",
                    json_kind(&other)
                )))
            }
        },
    };
    children.sort_by(|a, b| match (a.0.parse::<u64>(), b.0.parse::<u64>()) {
        (Ok(x), Ok(y)) => x.cmp(&y),
        (Ok(_), Err(_)) => std::cmp::Ordering::Less,
        (Err(_), Ok(_)) => std::cmp::Ordering::Greater,
        (Err(_), Err(_)) => a.0.cmp(&b.0),
    });
    Ok(children)
}

fn json_kind(value: &serde_json::Value) -> &'static str {
    match value {
        serde_json::Value::Null => "null",
        serde_json::Value::Bool(_) => "a bool",
        serde_json::Value::Number(_) => "a number",
        serde_json::Value::String(_) => "a string",
        serde_json::Value::Array(_) => "an array",
        serde_json::Value::Object(_) => "an object",
    }
}

/// Resolve a dotted path inside one JSON value. Missing keys are `None`;
/// there is no array indexing because no catalogued mapping needs it yet.
fn walk<'a>(value: &'a serde_json::Value, dotted: &str) -> Option<&'a serde_json::Value> {
    let mut current = value;
    for part in dotted.split('.') {
        current = current.get(part)?;
    }
    Some(current)
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
  read_summary:
    description: "A state poll declared as a plain command, not an endpoint."
    transport: "http"
    method: "GET"
    path: "/api/v1/summary"
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

    // ── The hub side: JSON bodies, credentialed paths, instanced children ──
    //
    // A miniature hub, so these exercise the rules rather than one catalogue
    // spec; the real Hue file is driven end to end in
    // `tests/network_control_http.rs`.
    const HUB: &str = r#"
device:
  name: "Test Hub"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "hub"
commands:
  child_level:
    description: "Level, as a number on the wire, on in the same write."
    transport: "http"
    method: "PUT"
    path: "/api/{token}/things/{id}/state"
    arguments:
      "on": true
      level: "{level}"
    parameters:
      level: { type: "integer", required: true, min: 1, max: 254 }
      token: { type: "string", source: "credential:token" }
      id: { type: "string", source: "instance:id" }
  enroll:
    description: "A POST with a boolean literal riding along."
    transport: "http"
    method: "POST"
    path: "/api"
    arguments:
      devicetype: "{devicetype}"
      wantkey: true
    parameters:
      devicetype: { type: "string", required: true }
http_endpoints:
  - method: "GET"
    path: "/api/{token}/things"
    name: "Things"
    description: "All children, keyed by id."
entities:
  - platform: "light"
    name: "Child"
    instances: { keyed_by: "id", label_path: "name" }
    state_command: "Things"
    state_mapping: { is_on: "state.on", brightness: "state.level" }
    commands: { turn_on: "child_level", set_brightness: "child_level" }
"#;

    const REPLY: &str = r#"{
        "10": {"state": {"on": false, "level": 40}, "name": "Porch"},
        "2":  {"state": {"on": true,  "level": 254}, "name": "Desk"},
        "zz": {"state": {"on": true}}
    }"#;

    fn hub() -> DeviceSpec {
        parse_device_spec(HUB).expect("hub fixture parses")
    }

    // ── A Kasa power strip: children are a nested ARRAY, not a keyed object,
    // each carrying its id in a field, and its on/off as an integer state.
    const STRIP: &str = r#"
device:
  name: "Test Strip"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "switch"
commands:
  get_sysinfo:
    description: "Device info, including the children array."
    transport: "tcp-json"
    body: '{"system":{"get_sysinfo":{}}}'
  relay_on_child:
    description: "Turn one outlet on."
    transport: "tcp-json"
    body: '{"context":{"child_ids":["{child_id}"]},"system":{"set_relay_state":{"state":1}}}'
    parameters:
      child_id: { type: "string", source: "instance:id" }
  relay_off_child:
    description: "Turn one outlet off."
    transport: "tcp-json"
    body: '{"context":{"child_ids":["{child_id}"]},"system":{"set_relay_state":{"state":0}}}'
    parameters:
      child_id: { type: "string", source: "instance:id" }
entities:
  - platform: "switch"
    name: "Outlet"
    instances:
      keyed_by: "id"
      children_path: "system.get_sysinfo.children"
      id_field: "id"
      label_path: "alias"
    state_command: "get_sysinfo"
    state_mapping: { is_on: "state", on_when: "nonzero" }
    commands: { turn_on: "relay_on_child", turn_off: "relay_off_child" }
"#;

    const STRIP_REPLY: &str = r#"{"system":{"get_sysinfo":{
        "alias": "Rack Strip",
        "relay_state": 0,
        "children": [
            {"id": "8006AAA00", "alias": "RackFans", "state": 1},
            {"id": "8006AAA01", "alias": "Pleaky1",  "state": 0},
            {"id": "8006AAA02", "alias": "Spare",    "state": 1}
        ]
    }}}"#;

    // A single-outlet plug reports its relay at the top level and carries no
    // `children` array at all.
    const SINGLE_REPLY: &str =
        r#"{"system":{"get_sysinfo":{"alias": "Desk Lamp", "relay_state": 1}}}"#;

    fn strip() -> DeviceSpec {
        parse_device_spec(STRIP).expect("strip fixture parses")
    }

    #[test]
    fn a_json_body_renders_typed_and_in_declared_order() {
        let request = render_request(
            &hub(),
            "child_level",
            &values(&[("token", "tok"), ("id", "2"), ("level", "200")]),
        )
        .unwrap();
        assert_eq!(request.method, "PUT");
        assert_eq!(request.path, "/api/tok/things/2/state");
        // `on` first (declared order), the integer unquoted.
        assert_eq!(request.body, r#"{"on":true,"level":200}"#);
    }

    #[test]
    fn a_literal_argument_keeps_its_yaml_type() {
        let request = render_request(
            &hub(),
            "enroll",
            &values(&[("devicetype", "opengreeniot#hub")]),
        )
        .unwrap();
        assert_eq!(
            request.body,
            r#"{"devicetype":"opengreeniot#hub","wantkey":true}"#
        );
    }

    #[test]
    fn a_non_integer_where_the_spec_declares_one_is_rejected() {
        let err = render_request(
            &hub(),
            "child_level",
            &values(&[("token", "t"), ("id", "2"), ("level", "bright")]),
        )
        .unwrap_err();
        assert!(matches!(&err, ProtocolError::ParameterInvalid { name, .. } if name == "level"));
    }

    #[test]
    fn a_missing_credential_fails_the_send() {
        let err = render_request(
            &hub(),
            "child_level",
            &values(&[("id", "2"), ("level", "5")]),
        )
        .unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterMissing(name) if name == "child_level.token")
        );
    }

    #[test]
    fn a_state_request_substitutes_the_credential_and_fails_visibly_without_it() {
        let request = render_state_request(&hub(), "Things", &values(&[("token", "tok")])).unwrap();
        assert_eq!(
            (request.method.as_str(), request.path.as_str()),
            ("GET", "/api/tok/things")
        );
        assert!(request.body.is_empty());

        let err = render_state_request(&hub(), "Things", &values(&[])).unwrap_err();
        assert!(matches!(&err, ProtocolError::ParameterMissing(name) if name == "Things.token"));
    }

    #[test]
    fn a_state_command_naming_a_command_renders_like_a_send() {
        // The non-hub shape: the poll is a `commands` entry (the Envoy's
        // get_production_v1), not an `http_endpoints` name.
        let request = render_state_request(&spec(), "read_summary", &values(&[])).unwrap();
        assert_eq!(
            (request.method.as_str(), request.path.as_str()),
            ("GET", "/api/v1/summary")
        );
        assert!(request.body.is_empty());
    }

    #[test]
    fn a_state_command_for_another_transport_is_still_declined() {
        // The commands-block fallback goes through render_command, so the
        // transport check a direct send gets applies here too.
        let err = render_state_request(&spec(), "over_soap", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::UnsupportedCommandEncoding(t) if t == "soap"),
            "unexpected error: {err}"
        );

        let err = render_state_request(&spec(), "no_such_command", &values(&[])).unwrap_err();
        assert!(err.to_string().contains("no_such_command"));
    }

    #[test]
    fn instances_enumerate_numerically_with_a_label_fallback() {
        let spec = hub();
        let listed = list_instances(&spec.entities[0], REPLY).unwrap();
        assert_eq!(
            listed,
            vec![
                Instance {
                    id: "2".into(),
                    label: "Desk".into()
                },
                Instance {
                    id: "10".into(),
                    label: "Porch".into()
                },
                Instance {
                    id: "zz".into(),
                    label: "zz".into()
                },
            ]
        );
    }

    #[test]
    fn a_child_reads_its_roles_and_an_absent_one_reads_as_nothing() {
        let spec = hub();
        let entity = &spec.entities[0];
        let readings = read_instance_entity(entity, REPLY, "10").unwrap();
        assert_eq!(readings.get("is_on"), Some(&EntityReading::OnOff(false)));
        assert_eq!(
            readings.get("brightness"),
            Some(&EntityReading::Number(40.0))
        );

        // `zz` has no `state.level`: the role is omitted, not invented.
        let readings = read_instance_entity(entity, REPLY, "zz").unwrap();
        assert!(!readings.contains_key("brightness"));
        assert!(read_instance_entity(entity, REPLY, "404")
            .unwrap()
            .is_empty());
    }

    #[test]
    fn kasa_outlets_enumerate_from_the_nested_children_array() {
        let spec = strip();
        let listed = list_instances(&spec.entities[0], STRIP_REPLY).unwrap();
        assert_eq!(
            listed,
            vec![
                Instance {
                    id: "8006AAA00".into(),
                    label: "RackFans".into()
                },
                Instance {
                    id: "8006AAA01".into(),
                    label: "Pleaky1".into()
                },
                Instance {
                    id: "8006AAA02".into(),
                    label: "Spare".into()
                },
            ]
        );
    }

    #[test]
    fn a_kasa_outlet_reads_its_integer_state_as_on_off() {
        let spec = strip();
        let entity = &spec.entities[0];
        // state 1 with on_when: nonzero is on, not the number 1.
        let on = read_instance_entity(entity, STRIP_REPLY, "8006AAA00").unwrap();
        assert_eq!(on.get("is_on"), Some(&EntityReading::OnOff(true)));
        // state 0 is off.
        let off = read_instance_entity(entity, STRIP_REPLY, "8006AAA01").unwrap();
        assert_eq!(off.get("is_on"), Some(&EntityReading::OnOff(false)));
    }

    #[test]
    fn a_single_outlet_plug_has_no_children_to_enumerate() {
        let spec = strip();
        let entity = &spec.entities[0];
        // No `children` array: nothing to enumerate, so the caller falls back
        // to the plain switch rather than seeing a bogus instance.
        assert!(list_instances(entity, SINGLE_REPLY).unwrap().is_empty());
        assert!(read_instance_entity(entity, SINGLE_REPLY, "anything")
            .unwrap()
            .is_empty());
    }

    #[test]
    fn a_reply_that_is_not_an_object_names_what_it_is() {
        let spec = hub();
        let err = list_instances(&spec.entities[0], "[1,2]").unwrap_err();
        assert!(
            matches!(&err, ProtocolError::InvalidStateReply(reason) if reason.contains("an array"))
        );
    }

    #[test]
    fn source_schemes_parse_and_unknown_ones_do_not() {
        assert_eq!(
            parse_source("credential:username"),
            Some(SourceScheme::Credential("username"))
        );
        assert_eq!(
            parse_source("instance:id"),
            Some(SourceScheme::Instance("id"))
        );
        assert_eq!(
            parse_source("state:GetThing.time"),
            Some(SourceScheme::State {
                command: "GetThing",
                field: "time"
            })
        );
        assert_eq!(parse_source("credential:"), None);
        assert_eq!(parse_source("oracle:guess"), None);
    }
}

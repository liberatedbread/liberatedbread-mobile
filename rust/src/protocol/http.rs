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
    /// The SECOND path this same invocation may be spelled with, rendered
    /// exactly as [`Self::path`] is — the spec's `path_fallback` (or, for a
    /// state read, the entity's `state_topic_fallback`), and `None` for the
    /// overwhelming majority of the catalogue that declares neither.
    ///
    /// Both candidates are rendered here so the sender has no spec knowledge
    /// to acquire: it sends [`Self::path`], and ONLY if the device answers an
    /// unambiguous 404 does it send this one. Not on a timeout, a refusal, or
    /// a 5xx — a command that acts twice because the first send was merely
    /// slow is a worse failure than the 404 this exists to survive.
    pub path_fallback: Option<String>,
    /// Request body: empty when the command declares neither `arguments`
    /// nor `body` (ECP keypresses carry the whole instruction in the path);
    /// a compact JSON object in the spec's declared argument order when it
    /// declares `arguments` (the Hue bridge's `{"on":true,"bri":200}`); or
    /// the spec's literal `body` with its placeholders filled when it
    /// declares that instead (WLED's `{"bri": 200}`, SoundTouch's
    /// `<volume>30</volume>`). The caller sends a Content-Type only when
    /// this is non-empty.
    pub body: String,
    /// Request headers the command declares, name → value, in declared
    /// order and with every `{name}` placeholder filled — a header-borne
    /// credential (Vizio's `AUTH`) resolves through exactly the path a body
    /// placeholder does, stored-credential remap included. Empty for the
    /// whole catalogue as vendored today. A `Content-Type` here overrides
    /// the one the caller would infer from the body.
    pub headers: Vec<(String, String)>,
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
    let command = super::top_level_command(spec, command_name)?;
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
        // Substituted on exactly the terms the primary is: a fallback whose
        // placeholders cannot be filled is no fallback, and failing the whole
        // render over the SECOND spelling would take down a command whose
        // first spelling was fine.
        path_fallback: command
            .path_fallback
            .as_deref()
            .and_then(|path| substitute(path, command, command_name, values).ok()),
        body: render_http_body(command, command_name, values)?,
        headers: render_headers(command, command_name, values)?,
    })
}

/// Fill a command's declared `headers`, in declared order.
///
/// Each value is a template on the same terms as a literal `body`: the exact
/// `{name}` of a declared parameter is replaced (resolution order: the
/// caller's value, the stored credential its `source:` names, its `default`),
/// and a missing one fails the render rather than sending a header with a
/// hole in it — an `AUTH:` with nothing after it is a request the set will
/// refuse, and refusing here names the credential instead. A resolved value
/// is written verbatim (a token is not a path; percent-encoding it would
/// corrupt it), which is why the one thing that IS checked is that neither
/// the name nor the value can end the header line: a CR or LF in a
/// user-typed or device-supplied value would otherwise start a header of the
/// attacker's choosing.
fn render_headers(
    command: &SpecCommand,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<Vec<(String, String)>, ProtocolError> {
    let mut rendered = Vec::with_capacity(command.headers.len());
    for (name, template) in &command.headers {
        if name.is_empty() || !name.bytes().all(is_header_name_byte) {
            return Err(ProtocolError::UnsupportedCommandEncoding(format!(
                "{command_name} declares header {name:?}, which is not a valid header name"
            )));
        }
        let template = scalar_to_string(template).ok_or_else(|| {
            ProtocolError::UnsupportedCommandEncoding(format!(
                "{command_name} declares header {name} with a non-scalar value"
            ))
        })?;
        let value = fill_placeholders(&template, command, command_name, values, |param, raw| {
            if raw.contains(['\r', '\n', '\0']) {
                return Err(ProtocolError::ParameterInvalid {
                    name: param.to_string(),
                    value: 0.0,
                    reason: "a header value cannot contain a line break".to_string(),
                });
            }
            Ok(raw.to_string())
        })?;
        if value.contains(['\r', '\n', '\0']) {
            return Err(ProtocolError::UnsupportedCommandEncoding(format!(
                "{command_name} declares header {name} with a line break in its value"
            )));
        }
        rendered.push((name.clone(), value));
    }
    Ok(rendered)
}

/// RFC 9110's `tchar`: what an HTTP field name may be made of.
fn is_header_name_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte)
}

/// The request body an HTTP command declares: a JSON object from its
/// `arguments`, its literal `body` template with the placeholders filled, or
/// the empty string when it declares neither.
///
/// A literal `body` is how most of the catalogue's HTTP writes are declared —
/// WLED's `{"on": true}`, Valetudo's `{"action":"start"}`, SoundTouch's
/// `<key state="press" sender="Gabbo">POWER</key>` — and for a long time it
/// was never read on this transport: the admission gate offered those
/// controls, every press POSTed an empty body, and nothing changed at the
/// device. It is filled by [`render_literal_body`], with the same typed,
/// injection-safe placeholder rules the Kasa transport applies to its bodies.
///
/// A command declaring both is a spec bug rather than a merge — two answers
/// to one question — and is refused exactly as the MQTT renderer refuses it,
/// so the mistake surfaces at the first render instead of as half a payload.
/// This dispatch is the HTTP transport's own; [`render_body`] stays the
/// arguments-only renderer the WebSocket, MQTT and Roomba transports share,
/// each with its own reading of a literal `body`.
fn render_http_body(
    command: &SpecCommand,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    match command.body.as_deref() {
        Some(_) if !command.arguments.is_empty() => {
            // Named as an unsupported encoding rather than a missing
            // parameter: nothing is missing, the command asks for two bodies
            // at once.
            Err(ProtocolError::UnsupportedCommandEncoding(format!(
                "{command_name} declares both `arguments` and `body`; an HTTP \
                 command has one body, so declare one or the other"
            )))
        }
        Some(body) => render_literal_body(body, command, command_name, values),
        None => render_body(command, command_name, values),
    }
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
///
/// A literal `body` is not this function's business — it is the HTTP
/// transport's ([`render_http_body`]) and every other caller's own — so a
/// command declaring one and no `arguments` renders as empty here.
pub(crate) fn render_body(
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

/// Fill a command's literal `body` template.
///
/// The template's first character says which grammar the values must respect,
/// because "fill in the blank" is only safe when the blank's surroundings are
/// known: the catalogue's literal bodies are JSON documents or XML fragments,
/// nothing else. A body opening with `<` is markup, and a value landing in it
/// is XML-escaped — a `&` or `<` in a user-typed value would otherwise end the
/// element it sits in. Anything else is treated as JSON and filled by the Kasa
/// renderer's rule: only the exact `{name}` token of a DECLARED parameter is
/// replaced (every other brace is the author's JSON syntax), a string value is
/// JSON-escaped, and a numeric or boolean value is validated against its
/// declared type so `1},"x":{` dies as ParameterInvalid instead of rendering
/// as a valid document with an injected member.
fn render_literal_body(
    body: &str,
    command: &SpecCommand,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    if body.trim_start().starts_with('<') {
        substitute_markup(body, command, command_name, values)
    } else {
        crate::protocol::kasa::substitute(body, command, command_name, values)
    }
}

/// Replace every `{name}` in an XML template with its parameter's value.
///
/// Braces are not XML syntax, so the path renderer's brace scanner applies
/// as written — an undeclared placeholder fails visibly rather than going out
/// literally. A string value is escaped for element content and attribute
/// values alike (SoundTouch's `<volume>{level}</volume>` is content, but a
/// future template may quote a value); a numeric or boolean one is validated
/// by its declared type and written bare, because `</key><key>...` contains
/// no digit and must not become markup.
fn substitute_markup(
    template: &str,
    command: &SpecCommand,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    fill_placeholders(template, command, command_name, values, |param, raw| {
        let parameter = command.parameters.get(param);
        match declared_type(parameter.and_then(|p| p.value_type.as_deref())) {
            DeclaredType::String => Ok(xml_escape(raw)),
            _ => typed_json(parameter, param, raw).map(|v| v.to_string()),
        }
    })
}

/// The five characters XML reserves, replaced by their entities.
fn xml_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for c in value.chars() {
        match c {
            '&' => out.push_str("&amp;"),
            '<' => out.push_str("&lt;"),
            '>' => out.push_str("&gt;"),
            '"' => out.push_str("&quot;"),
            '\'' => out.push_str("&apos;"),
            other => out.push(other),
        }
    }
    out
}

/// The JSON value a parameter's declared `type` renders as.
///
/// The catalogue's network specs write their types in the BLE vocabulary as
/// often as in JSON's — Frigidaire's set-point is a `uint8`, ratgdo's door
/// position a `float`, WLED's brightness a `uint8` — and the vendored schema
/// constrains none of it. Matching only the JSON names quoted every one of
/// those (`{"targetTemperatureC":"22"}`, which the endpoint ignores) and,
/// worse, skipped the numeric validation that keeps a placeholder in numeric
/// position from carrying injected syntax. So the mapping lives in one place
/// and both renderers ask it; the fixed-width names carry the range the width
/// implies, which is the type's own meaning and costs nothing to enforce.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum DeclaredType {
    /// An integer, with the inclusive range its width name implies (`uint8`
    /// is 0..=255); `integer` and `int64` carry none.
    Integer(Option<(i64, i64)>),
    Number,
    Boolean,
    String,
}

/// Map a declared type name to what it renders as. Absent, unknown, and
/// `string` all mean a string, which is the YAML default reading.
pub(crate) fn declared_type(declared: Option<&str>) -> DeclaredType {
    match declared {
        Some("integer") | Some("int64") => DeclaredType::Integer(None),
        Some("int8") => DeclaredType::Integer(Some((i8::MIN as i64, i8::MAX as i64))),
        Some("int16") => DeclaredType::Integer(Some((i16::MIN as i64, i16::MAX as i64))),
        Some("int32") => DeclaredType::Integer(Some((i32::MIN as i64, i32::MAX as i64))),
        Some("uint8") => DeclaredType::Integer(Some((0, u8::MAX as i64))),
        Some("uint16") => DeclaredType::Integer(Some((0, u16::MAX as i64))),
        Some("uint24") => DeclaredType::Integer(Some((0, 0xFF_FFFF))),
        // `varint` is the BLE vocabulary's unbounded-width unsigned; the same
        // 32-bit ceiling `ValueType::integer_range` gives it.
        Some("uint32") | Some("varint") => DeclaredType::Integer(Some((0, u32::MAX as i64))),
        // Parsed as i64, so the upper half of the range is unreachable anyway.
        Some("uint64") => DeclaredType::Integer(Some((0, i64::MAX))),
        Some("number") | Some("float") | Some("double") => DeclaredType::Number,
        Some("boolean") | Some("bool") => DeclaredType::Boolean,
        _ => DeclaredType::String,
    }
}

/// Coerce a substituted string to the JSON type its parameter declares. An
/// undeclared type is a string, which is the YAML default reading.
///
/// `pub(crate)` because the Kasa/Rabbit Air substitution needs the same
/// answer for the same reason: a placeholder in NUMERIC position takes its
/// value verbatim, and "verbatim" is an injection when the value is
/// device-supplied or user-typed. Validating against the declared type is
/// how a `1},"system":{"reboot":{}` dies as ParameterInvalid instead of
/// rendering as valid JSON with an extra command in it.
pub(crate) fn typed_json(
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
    match declared_type(Some(declared)) {
        DeclaredType::Integer(range) => {
            let integer: i64 = raw.trim().parse().map_err(|_| {
                invalid(&format!("declared {declared}, and this is not an integer"))
            })?;
            if let Some((min, max)) = range {
                if integer < min || integer > max {
                    return Err(ProtocolError::ParameterOutOfRange {
                        name: name.to_string(),
                        value: integer as f64,
                        min: min as f64,
                        max: max as f64,
                    });
                }
            }
            Ok(serde_json::Value::from(integer))
        }
        DeclaredType::Number => {
            let number: f64 = raw
                .trim()
                .parse()
                .map_err(|_| invalid(&format!("declared {declared}, and this is not a number")))?;
            serde_json::Number::from_f64(number)
                .map(serde_json::Value::Number)
                .ok_or_else(|| invalid(&format!("declared {declared}, and this is not finite")))
        }
        DeclaredType::Boolean => match raw.trim() {
            "true" | "1" => Ok(serde_json::Value::Bool(true)),
            "false" | "0" => Ok(serde_json::Value::Bool(false)),
            _ => Err(invalid(&format!(
                "declared {declared}, and this is neither"
            ))),
        },
        DeclaredType::String => Ok(serde_json::Value::String(raw.to_string())),
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
    fill_placeholders(template, command, command_name, values, |_, raw| {
        Ok(percent_encode(raw))
    })
}

/// The brace scanner behind [`substitute`] and [`substitute_markup`]: the
/// same placeholder grammar and resolution order, with `render` deciding how
/// a resolved value is written into its surroundings (percent-encoded in a
/// path, entity-escaped in markup).
fn fill_placeholders(
    template: &str,
    command: &SpecCommand,
    command_name: &str,
    values: &BTreeMap<String, String>,
    render: impl Fn(&str, &str) -> Result<String, ProtocolError>,
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
        out.push_str(&render(param, &value)?);
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
    crate::protocol::resolve_parameter(command, command_name, param, values)
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

/// The value the spec itself declares for a placeholder that has no owning
/// command — the one inside a bare path.
///
/// A `state_topic` is a LOCATION, not a name, so there is no command whose
/// `parameters` block a `{placeholder}` in it could be read from. The spec
/// still declares what the name means: Philips writes `api_version` with
/// `default: '6'` on all fifty-four of its commands, and the state path
/// `/{api_version}/powerstate` means that same version. So the answer is read
/// from the spec's own parameter declarations, by name.
///
/// This is only sound because a name means one thing per spec: no spec in the
/// catalogue declares one parameter name with two different defaults, which
/// `a_parameter_name_means_one_thing_within_a_spec` pins. If that stops being
/// true the resolution has to become a per-command question again, and the
/// guard is what says so rather than a silently wrong path.
pub fn spec_wide_default(spec: &DeviceSpec, param: &str) -> Option<String> {
    spec.commands
        .values()
        .filter_map(|command| command.parameters.get(param))
        .find_map(|p| p.default.as_ref().and_then(scalar_to_string))
}

/// The credential a placeholder is sourced from, read across the spec by name.
///
/// The sibling of [`spec_wide_default`] and needed for the same reason: a bare
/// `state_topic` has no owning command, so a `{applianceId}` in one has nothing
/// to read a `source:` off. The spec still says what the name means — every
/// Frigidaire command declares `applianceId: {source: credential:appliance_id}`
/// — and a stored credential is filed under the CREDENTIAL's name, so without
/// this the read fails on a value the app is holding.
///
/// Sound for the same reason and pinned by the same guard: a parameter name
/// means one thing within a spec.
pub fn spec_wide_credential<'a>(spec: &'a DeviceSpec, param: &str) -> Option<&'a str> {
    spec.commands
        .values()
        .filter_map(|command| command.parameters.get(param))
        .filter_map(|p| p.source.as_deref())
        .find_map(|source| source.strip_prefix("credential:"))
        .filter(|name| !name.is_empty())
}

/// Fill the `{...}` placeholders in a path from `values`, then from what the
/// spec declares the name means.
///
/// `label` names the thing being rendered in the failure — a command name, or
/// the path itself for a bare `state_topic` — so a missing placeholder says
/// which read could not be issued.
pub fn fill_path(
    spec: &DeviceSpec,
    path: &str,
    values: &BTreeMap<String, String>,
    label: &str,
) -> Result<String, ProtocolError> {
    let mut out = String::with_capacity(path.len());
    let mut rest = path;
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
        let value = values
            .get(param)
            .cloned()
            // A stored credential is filed under the credential's name, which
            // is usually NOT the placeholder's — see [`spec_wide_credential`].
            .or_else(|| {
                spec_wide_credential(spec, param).and_then(|name| values.get(name).cloned())
            })
            .or_else(|| spec_wide_default(spec, param))
            .ok_or_else(|| ProtocolError::ParameterMissing(format!("{label}.{param}")))?;
        out.push_str(&percent_encode(&value));
        rest = &tail[end + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

/// Whether every placeholder in `path` can be filled from the spec ALONE — no
/// stored credential, no instance id, nothing a caller has to supply.
///
/// This is the admission question for a `state_topic` that names a path: an
/// entity whose reading can never be requested is the dead control the surface
/// rule exists to keep off screen. The Hue bridge's `/api/{username}/sensors/
/// {id}` is exactly that today — a credential this app does not yet store and
/// a child id nothing enumerates — so it stays off, and the screen counts it
/// among the controls it is honest about not drawing.
pub fn path_renderable_from_spec(spec: &DeviceSpec, path: &str) -> bool {
    fill_path(spec, path, &BTreeMap::new(), path).is_ok()
}

/// Render the request that reads a state command's values over HTTP — on an
/// instanced entity, the one GET that enumerates every child and carries all
/// their state.
///
/// Three vocabularies can name the poll, tried in order. A hub's state command
/// names an `http_endpoints` catalogue entry (the Hue bridge's `Lights`), its
/// path placeholders filled from `values` — a placeholder with no value fails
/// the render, the same fail-visibly rule a command's `source` gets, because
/// an unpaired client must not issue a credential-less read. A plain device's
/// state command names a `commands` entry instead (the Envoy's
/// `get_production_v1`), which renders exactly as it would for a send —
/// including the transport check, so a SOAP command handed here is still
/// declined.
///
/// The third is a bare path, which is what an entity's `state_topic` holds on
/// a device that answers over HTTP: `/json/state` on a WLED controller,
/// `/query/active-app` on a Roku. It names no command because there is none to
/// name — the reading is a resource, and reading a resource is a GET of it.
/// See [`crate::spec::bindings::state_binding`], which is what decides that a
/// given `state_topic` means this rather than an MQTT subscription.
///
/// Only the second vocabulary can carry headers: a command declares them, an
/// endpoint entry and a bare path have nowhere to. A device whose state reads
/// need a credential header (Vizio's `/state/device/power_mode` wants `AUTH`)
/// has to name a `commands` entry from `state_command` for the poll to be
/// authenticated.
pub fn render_state_request(
    spec: &DeviceSpec,
    state_command: &str,
    values: &BTreeMap<String, String>,
) -> Result<HttpRequest, ProtocolError> {
    if let Some((method, path)) = endpoint_request(spec, state_command) {
        return Ok(HttpRequest {
            method,
            path: fill_path(spec, &path, values, state_command)?,
            // An `http_endpoints` entry is named, not addressed by a
            // firmware-dependent spelling, so it has no second candidate.
            path_fallback: None,
            body: String::new(),
            headers: Vec::new(),
        });
    }
    if let Some(command) = spec.commands.get(state_command) {
        return render_command(state_command, command, values);
    }
    if state_command.starts_with('/') {
        return Ok(HttpRequest {
            method: "GET".to_string(),
            path: fill_path(spec, state_command, values, state_command)?,
            path_fallback: state_topic_fallback(spec, state_command)
                .and_then(|path| fill_path(spec, path, values, state_command).ok()),
            body: String::new(),
            headers: Vec::new(),
        });
    }
    Err(ProtocolError::CommandNotFound {
        uuid: "http_endpoints".to_string(),
        command: state_command.to_string(),
    })
}

/// The second spelling of a bare `state_topic`, as the entity that owns it
/// declares.
///
/// A `state_topic` reaches the renderer as a bare string — it is a LOCATION,
/// and the caller passes the location, not the entity. The `state_topic_fallback`
/// beside it is a property of the ENTITY, so it is read back here by the one
/// thing the caller did hand over: the topic itself. Sound because a fallback
/// is by definition the same reading spelled twice, so two entities sharing a
/// `state_topic` share its fallback too; the first declaration wins either way.
fn state_topic_fallback<'a>(spec: &'a DeviceSpec, topic: &str) -> Option<&'a str> {
    spec.entities
        .iter()
        .find(|entity| entity.state_topic.as_deref() == Some(topic))
        .and_then(|entity| entity.state_topic_fallback.as_deref())
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
  press_standby:
    description: "A versioned path — the Philips shape, where the version is
      declared on every command and a bare state path names the same one."
    transport: "http"
    method: "POST"
    path: "/{api_version}/input/key"
    parameters:
      api_version:
        type: "string"
        default: "6"
  light_on:
    description: "A literal JSON body with nothing to fill — the WLED shape."
    transport: "http"
    method: "POST"
    path: "/json/state"
    body: '{"on": true}'
  light_level:
    description: "A literal JSON body with a placeholder in NUMERIC position,
      typed in the BLE vocabulary."
    transport: "http"
    method: "POST"
    path: "/json/state"
    body: '{"bri": {brightness}}'
    parameters:
      brightness:
        type: "uint8"
        required: true
  name_segment:
    description: "A literal JSON body with a placeholder inside a string."
    transport: "http"
    method: "POST"
    path: "/json/state"
    body: '{"seg": [{"id": 0, "n": "{label}"}]}'
    parameters:
      label:
        type: "string"
        required: true
  press_preset:
    description: "A literal XML body with a numeric placeholder — SoundTouch."
    transport: "http"
    method: "POST"
    path: "/key"
    body: '<key state="press" sender="Gabbo">PRESET_{n}</key>'
    parameters:
      n:
        type: "integer"
        required: true
  set_zone_name:
    description: "A literal XML body with a string placeholder."
    transport: "http"
    method: "POST"
    path: "/name"
    body: '<name>{label}</name>'
    parameters:
      label:
        type: "string"
        required: true
  two_bodies:
    description: "Declares both — a spec bug, not a merge."
    transport: "http"
    method: "POST"
    path: "/x"
    body: '{"a": 1}'
    arguments:
      b: 2
  press_auth:
    description: "The SmartCast shape: a JSON PUT under a credential header."
    transport: "http"
    method: "PUT"
    path: "/key_command/"
    headers:
      Content-Type: "application/json"
      AUTH: "{auth_token}"
      X-Client: "lb/{app_id}"
    arguments: {CODESET: 11, CODE: 1, ACTION: "KEYPRESS"}
    parameters:
      auth_token:
        type: "string"
        source: "credential:auth_token"
        description: "The token pairing issued."
      app_id:
        type: "string"
        default: 12
  bad_header_name:
    description: "A header name the wire cannot carry."
    transport: "http"
    method: "GET"
    path: "/x"
    headers:
      "Bad Name": "v"
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

    // ── Literal bodies: the `body:` most of the catalogue's HTTP writes
    // declare, which used to render as nothing at all.

    #[test]
    fn a_literal_json_body_renders_verbatim() {
        let request = render_request(&spec(), "light_on", &values(&[])).unwrap();
        assert_eq!(request.method, "POST");
        assert_eq!(request.path, "/json/state");
        assert_eq!(request.body, r#"{"on": true}"#);
    }

    #[test]
    fn a_literal_body_placeholder_renders_by_its_declared_type() {
        // `uint8` is the BLE vocabulary; in numeric position it must render
        // bare, not as the string "100" the JSON-names-only match produced.
        let request =
            render_request(&spec(), "light_level", &values(&[("brightness", "100")])).unwrap();
        assert_eq!(request.body, r#"{"bri": 100}"#);
    }

    #[test]
    fn a_literal_body_placeholder_refuses_injected_syntax() {
        let err = render_request(
            &spec(),
            "light_level",
            &values(&[("brightness", r#"1},"x":{"#)]),
        )
        .unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterInvalid { name, .. } if name == "brightness"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn a_fixed_width_type_refuses_a_value_past_its_width() {
        let err =
            render_request(&spec(), "light_level", &values(&[("brightness", "300")])).unwrap_err();
        assert!(
            matches!(
                &err,
                ProtocolError::ParameterOutOfRange { name, max, .. }
                    if name == "brightness" && *max == 255.0
            ),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn a_string_inside_a_literal_json_body_is_escaped() {
        let request = render_request(
            &spec(),
            "name_segment",
            &values(&[("label", r#"Desk "A""#)]),
        )
        .unwrap();
        assert_eq!(request.body, r#"{"seg": [{"id": 0, "n": "Desk \"A\""}]}"#);
    }

    #[test]
    fn an_xml_body_escapes_a_string_value() {
        let request = render_request(
            &spec(),
            "set_zone_name",
            &values(&[("label", "Tom & <Jerry>")]),
        )
        .unwrap();
        assert_eq!(request.body, "<name>Tom &amp; &lt;Jerry&gt;</name>");
    }

    #[test]
    fn an_xml_body_validates_a_numeric_value_and_writes_it_bare() {
        let request = render_request(&spec(), "press_preset", &values(&[("n", "3")])).unwrap();
        assert_eq!(
            request.body,
            r#"<key state="press" sender="Gabbo">PRESET_3</key>"#
        );
        // Markup in a numeric slot is not a number; it must not become an
        // element.
        let err =
            render_request(&spec(), "press_preset", &values(&[("n", "3</key><key>")])).unwrap_err();
        assert!(matches!(&err, ProtocolError::ParameterInvalid { name, .. } if name == "n"));
    }

    #[test]
    fn a_missing_placeholder_in_an_xml_body_is_an_error_not_a_blank() {
        let err = render_request(&spec(), "press_preset", &values(&[])).unwrap_err();
        assert!(matches!(&err, ProtocolError::ParameterMissing(p) if p == "press_preset.n"));
    }

    #[test]
    fn headers_render_in_declared_order_with_credentials_filled() {
        let request =
            render_request(&spec(), "press_auth", &values(&[("auth_token", "Z2x6")])).unwrap();
        assert_eq!(request.method, "PUT");
        assert_eq!(
            request.body,
            r#"{"CODESET":11,"CODE":1,"ACTION":"KEYPRESS"}"#
        );
        assert_eq!(
            request.headers,
            vec![
                ("Content-Type".to_string(), "application/json".to_string()),
                ("AUTH".to_string(), "Z2x6".to_string()),
                ("X-Client".to_string(), "lb/12".to_string()),
            ]
        );
    }

    #[test]
    fn a_header_credential_is_a_credential_like_any_other() {
        // The same declaration that fills the header is what the credentials
        // card reads, so a header-borne token is asked for, not guessed.
        let spec = spec();
        let required = crate::spec::credentials::required_credentials(&spec);
        let auth = required
            .iter()
            .find(|c| c.name == "auth_token")
            .expect("the header's credential is declared");
        assert_eq!(auth.needed_by, vec!["press_auth".to_string()]);
        assert!(auth.must_be_asked_for());
        // And a stored credential filed under its own name fills it, as a
        // body placeholder is filled.
        let request = render_request(&spec, "press_auth", &values(&[("auth_token", "t")])).unwrap();
        assert!(request
            .headers
            .contains(&("AUTH".to_string(), "t".to_string())));
    }

    #[test]
    fn a_missing_header_credential_fails_the_send() {
        let err = render_request(&spec(), "press_auth", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterMissing(name) if name == "press_auth.auth_token")
        );
    }

    #[test]
    fn a_header_value_is_written_verbatim_but_cannot_break_the_line() {
        // A token is not a path: `+`, `/` and `=` go out as they are.
        let request =
            render_request(&spec(), "press_auth", &values(&[("auth_token", "a+b/c==")])).unwrap();
        assert!(request
            .headers
            .contains(&("AUTH".to_string(), "a+b/c==".to_string())));

        let err = render_request(
            &spec(),
            "press_auth",
            &values(&[("auth_token", "x\r\nEvil: yes")]),
        )
        .unwrap_err();
        assert!(matches!(
            &err,
            ProtocolError::ParameterInvalid { name, .. } if name == "auth_token"
        ));
    }

    #[test]
    fn a_header_name_the_wire_cannot_carry_is_refused() {
        let err = render_request(&spec(), "bad_header_name", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::UnsupportedCommandEncoding(msg) if msg.contains("Bad Name"))
        );
    }

    #[test]
    fn a_command_without_headers_renders_none() {
        let request = render_request(&spec(), "press_home", &values(&[])).unwrap();
        assert!(request.headers.is_empty());
        let request = render_state_request(&spec(), "/json/state", &values(&[])).unwrap();
        assert!(request.headers.is_empty());
    }

    #[test]
    fn a_command_declaring_both_arguments_and_body_is_refused() {
        let err = render_request(&spec(), "two_bodies", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::UnsupportedCommandEncoding(why) if why.contains("two_bodies")),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn declared_types_map_the_ble_vocabulary_onto_json() {
        assert_eq!(declared_type(None), DeclaredType::String);
        assert_eq!(declared_type(Some("string")), DeclaredType::String);
        assert_eq!(declared_type(Some("bytes")), DeclaredType::String);
        assert_eq!(declared_type(Some("integer")), DeclaredType::Integer(None));
        assert_eq!(
            declared_type(Some("uint8")),
            DeclaredType::Integer(Some((0, 255)))
        );
        assert_eq!(
            declared_type(Some("int16")),
            DeclaredType::Integer(Some((-32768, 32767)))
        );
        assert_eq!(
            declared_type(Some("varint")),
            DeclaredType::Integer(Some((0, u32::MAX as i64)))
        );
        assert_eq!(declared_type(Some("number")), DeclaredType::Number);
        assert_eq!(declared_type(Some("float")), DeclaredType::Number);
        assert_eq!(declared_type(Some("double")), DeclaredType::Number);
        assert_eq!(declared_type(Some("boolean")), DeclaredType::Boolean);
        assert_eq!(declared_type(Some("bool")), DeclaredType::Boolean);
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
  move_cover:
    description: "Arguments typed in the BLE vocabulary — the ratgdo/ESPHome
      and Frigidaire shapes."
    transport: "http"
    method: "POST"
    path: "/cover/set"
    arguments:
      position: "{position}"
      level: "{level}"
      lit: "{lit}"
    parameters:
      position: { type: "float", required: true }
      level: { type: "uint8", required: true }
      lit: { type: "bool", required: true }
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
    fn arguments_typed_in_the_ble_vocabulary_render_as_numbers() {
        // `float`, `uint8` and `bool` are what the catalogue's network specs
        // actually write; each used to fall through to the string arm and
        // render quoted, which the endpoints ignore.
        let request = render_request(
            &hub(),
            "move_cover",
            &values(&[("position", "42.5"), ("level", "7"), ("lit", "true")]),
        )
        .unwrap();
        assert_eq!(request.body, r#"{"position":42.5,"level":7,"lit":true}"#);
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

    /// The ESPHome rename, as data: both spellings of one invocation are
    /// rendered, in order, so the sender has a second candidate to try when
    /// the first answers 404 — and no spec knowledge to acquire to do it.
    #[test]
    fn both_spellings_of_a_path_are_rendered_in_order() {
        const TWO_WAYS: &str = r#"
device:
  name: "Opener"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
commands:
  door_open:
    description: "Two firmware generations, two correct paths."
    transport: "http"
    method: "POST"
    path: "/cover/Door/open"
    path_fallback: "/cover/door/open"
  set_position:
    description: "A placeholder in both spellings."
    transport: "http"
    method: "POST"
    path: "/cover/Door/set?position={position}"
    path_fallback: "/cover/door/set?position={position}"
    parameters:
      position:
        type: "string"
        required: true
  press_home:
    description: "One path, one candidate."
    transport: "http"
    method: "POST"
    path: "/keypress/Home"
entities: []
"#;
        let spec = parse_device_spec(TWO_WAYS).expect("spec parses");

        let open = render_request(&spec, "door_open", &values(&[])).unwrap();
        assert_eq!(open.path, "/cover/Door/open");
        assert_eq!(open.path_fallback.as_deref(), Some("/cover/door/open"));

        // The fallback is substituted exactly as the primary is — a fallback
        // still carrying `{position}` would 404 for the wrong reason.
        let set = render_request(&spec, "set_position", &values(&[("position", "50")])).unwrap();
        assert_eq!(set.path, "/cover/Door/set?position=50");
        assert_eq!(
            set.path_fallback.as_deref(),
            Some("/cover/door/set?position=50")
        );

        // Nothing invents a second candidate: a blind retry on a command that
        // states one path is a device that acts twice.
        let home = render_request(&spec, "press_home", &values(&[])).unwrap();
        assert_eq!(home.path_fallback, None);
    }

    /// The reading half of the same rename. A `state_topic` arrives at the
    /// renderer as a bare location, so the entity that owns it is what the
    /// second spelling has to be read back from.
    #[test]
    fn a_state_topic_carries_the_entity_s_fallback_spelling() {
        const TWO_WAYS: &str = r#"
device:
  name: "Opener"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
commands:
  door_open:
    description: "Something to make the device speak HTTP."
    transport: "http"
    method: "POST"
    path: "/cover/Door/open"
entities:
  - name: "Garage Door"
    platform: "cover"
    state_topic: "/cover/Door"
    state_topic_fallback: "/cover/door"
    state_mapping:
      value: "value"
  - name: "Obstruction"
    platform: "binary_sensor"
    state_topic: "/binary_sensor/Obstruction"
    state_mapping:
      value: "state"
"#;
        let spec = parse_device_spec(TWO_WAYS).expect("spec parses");

        let door = render_state_request(&spec, "/cover/Door", &values(&[])).unwrap();
        assert_eq!(
            (door.method.as_str(), door.path.as_str()),
            ("GET", "/cover/Door")
        );
        assert_eq!(door.path_fallback.as_deref(), Some("/cover/door"));

        // An entity stating one spelling gets one: the read is retried on a
        // 404, and a second read of a path the spec never claimed is noise.
        let obstruction =
            render_state_request(&spec, "/binary_sensor/Obstruction", &values(&[])).unwrap();
        assert_eq!(obstruction.path_fallback, None);
    }

    #[test]
    fn a_bare_path_renders_as_the_get_it_is() {
        // What an entity's `state_topic` holds on a device that answers over
        // HTTP. It names no command because there is none to name.
        let request = render_state_request(&spec(), "/json/state", &values(&[])).unwrap();
        assert_eq!(
            (request.method.as_str(), request.path.as_str()),
            ("GET", "/json/state")
        );
        assert!(request.body.is_empty());
    }

    #[test]
    fn a_bare_path_is_the_last_resort_not_the_first() {
        // A name that is BOTH an endpoint and path-shaped resolves as the
        // endpoint: the declared vocabularies come first, and the bare-path
        // branch only catches what neither claimed. Otherwise an
        // `http_endpoints` entry whose name began with a slash would quietly
        // lose its declared method.
        let mut spec = hub();
        if let Some(endpoints) = spec
            .extensions
            .get_mut("http_endpoints")
            .and_then(|e| e.as_sequence_mut())
        {
            endpoints
                .push(serde_yaml::from_str("name: /probe\nmethod: POST\npath: /real").unwrap());
        }
        let request = render_state_request(&spec, "/probe", &values(&[])).unwrap();
        assert_eq!(
            (request.method.as_str(), request.path.as_str()),
            ("POST", "/real")
        );
    }

    #[test]
    fn a_path_placeholder_falls_back_to_what_the_spec_says_the_name_means() {
        // The Philips case: `/{api_version}/powerstate` has no owning command
        // to read a default from, and the spec declares `api_version` on its
        // commands. A caller's own value still wins.
        assert_eq!(
            spec_wide_default(&spec(), "api_version").as_deref(),
            Some("6")
        );
        let request = render_state_request(&spec(), "/{api_version}/powerstate", &values(&[]))
            .expect("the spec's own declaration fills it");
        assert_eq!(request.path, "/6/powerstate");

        let request = render_state_request(
            &spec(),
            "/{api_version}/powerstate",
            &values(&[("api_version", "1")]),
        )
        .unwrap();
        assert_eq!(request.path, "/1/powerstate");

        // A placeholder the spec never declares fails visibly, naming the path
        // that could not be issued rather than sending one with a brace in it.
        let err =
            render_state_request(&spec(), "/api/{username}/sensors", &values(&[])).unwrap_err();
        assert!(
            matches!(&err, ProtocolError::ParameterMissing(name)
                if name == "/api/{username}/sensors.username"),
            "unexpected error: {err}"
        );
        assert!(!path_renderable_from_spec(
            &spec(),
            "/api/{username}/sensors"
        ));
        assert!(path_renderable_from_spec(
            &spec(),
            "/{api_version}/powerstate"
        ));
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

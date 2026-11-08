// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Drive a Yeelight LAN light from its spec: plaintext JSON lines over a raw
//! TCP socket on port 55443.
//!
//! The same shape as [`crate::protocol::kasa`] one framing over. A command's
//! whole instruction is the JSON in its `body`; where Kasa wraps that in a
//! length prefix and an XOR autokey, Yeelight terminates it with CRLF, in both
//! directions.
//!
//! Replies are the one part that cannot be left to the generic flattener.
//! `get_prop` answers positionally — `{"id":1,"result":["on","100",...]}` lines
//! up with the REQUEST's `params` and names nothing — while the entity's
//! `state_mapping` names the request's own parameters (`is_on: "power"`). So
//! [`decode_reply`] zips the two, which is what the entity's notes tell a
//! consumer to do. It also tells a reply from the unsolicited
//! `{"method":"props",...}` notifications the lamp pushes on the same socket.
//!
//! Nothing here opens a socket.

use std::collections::BTreeMap;

use crate::error::ProtocolError;
use crate::spec::types::{DeviceSpec, SpecCommand};

/// The transport the spec's commands declare. Shared with Kasa and two other
/// vendors, which is why [`HANDLER_NAME`] is what admits one of these.
pub const TRANSPORT: &str = "tcp-json";

/// The spec `protocol_handler` this module answers to, and the transport a
/// resolved action carries so the sender can route it: `tcp-json` alone means
/// Kasa's cipher to everything downstream of the resolver.
pub const HANDLER_NAME: &str = "yeelight_lan";

/// The LAN control port (`identification.default_port`).
pub const PORT: u16 = 55443;

/// The command the `set_segments` role resolves to. The spec keeps per-row
/// colour off its entity and binds no role to it, so the resolver names the
/// command itself.
pub const SEGMENT_COMMAND: &str = "cube_set_segment_rgb";

/// Entries per attached 5x5 module in a `set_segment_rgb` array.
pub const SEGMENTS_PER_MODULE: usize = 5;

/// The largest value a packed 24-bit RGB colour can take.
const MAX_RGB: u64 = 0xFF_FFFF;

/// A rendered request: the JSON to send, before the line terminator.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct YeelightRequest {
    pub json: String,
}

/// What one line off the socket means for the request in flight.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct YeelightReply {
    /// False for a `props` notification, another id's reply or a line that is
    /// not JSON: the caller keeps reading.
    pub answers_request: bool,
    pub error_code: Option<i64>,
    pub error_message: Option<String>,
    /// A `get_prop` result keyed by the name it was requested under.
    pub fields: BTreeMap<String, String>,
}

/// Render one of the spec's `commands`, refusing a spec of another handler —
/// the guard [`crate::protocol::kasa::render_request`] explains.
pub fn render_request(
    spec: &DeviceSpec,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<YeelightRequest, ProtocolError> {
    if spec.protocol_handler.as_deref() != Some(HANDLER_NAME) {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            spec.protocol_handler.clone().unwrap_or_default(),
        ));
    }
    let command = super::top_level_command(spec, command_name)?;
    render_command(command_name, command, values)
}

/// Render the request that polls a state command.
pub fn render_state_request(
    spec: &DeviceSpec,
    state_command: &str,
) -> Result<YeelightRequest, ProtocolError> {
    render_request(spec, state_command, &BTreeMap::new())
}

/// Render a command already in hand.
pub fn render_command(
    command_name: &str,
    command: &SpecCommand,
    values: &BTreeMap<String, String>,
) -> Result<YeelightRequest, ProtocolError> {
    if command.transport.as_deref() != Some(TRANSPORT) {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            command.transport.clone().unwrap_or_default(),
        ));
    }
    let Some(body) = command.body.as_deref() else {
        return Err(ProtocolError::EmptyCommand);
    };
    Ok(YeelightRequest {
        json: fill_body(body, command, command_name, values)?,
    })
}

/// The Kasa renderer's substitution rule, plus the one thing it has no reason
/// to know: `cube_set_segment_rgb` declares an `array`, which lands bare in
/// the body (`"params":{colors}`) rather than as a quoted string.
fn fill_body(
    template: &str,
    command: &SpecCommand,
    command_name: &str,
    values: &BTreeMap<String, String>,
) -> Result<String, ProtocolError> {
    crate::protocol::walk_placeholders(template, |name| {
        let Some(parameter) = command.parameters.get(name) else {
            return Ok(None);
        };
        let value = crate::protocol::resolve_parameter(command, command_name, name, values)?;
        let rendered = if parameter.value_type.as_deref() == Some("array") {
            segment_array(name, &value)?
        } else {
            match crate::protocol::http::declared_type(parameter.value_type.as_deref()) {
                crate::protocol::http::DeclaredType::String => {
                    crate::protocol::kasa::json_escape(&value)
                }
                _ => crate::protocol::http::typed_json(Some(parameter), name, &value)?.to_string(),
            }
        };
        Ok(Some(rendered))
    })
}

/// A `set_segment_rgb` colour array, re-serialized from its parsed form so no
/// caller text reaches the wire: flat 24-bit integers, five per module.
fn segment_array(name: &str, raw: &str) -> Result<String, ProtocolError> {
    let invalid = |reason: &str| ProtocolError::ParameterValueInvalid {
        name: name.to_string(),
        value: raw.to_string(),
        reason: reason.to_string(),
    };
    let parsed: Vec<serde_json::Value> =
        serde_json::from_str(raw).map_err(|_| invalid("not a JSON array"))?;
    if parsed.is_empty() || !parsed.len().is_multiple_of(SEGMENTS_PER_MODULE) {
        return Err(invalid("expected five colours per module"));
    }
    let colours = parsed
        .iter()
        .map(|v| v.as_u64().filter(|c| *c <= MAX_RGB))
        .collect::<Option<Vec<u64>>>()
        .ok_or_else(|| invalid("every colour must be an integer from 0 to 16777215"))?;
    Ok(serde_json::json!(colours).to_string())
}

/// One message as it goes on the wire: the JSON and its CRLF.
pub fn encode_line(json: &str) -> Vec<u8> {
    let mut out = Vec::with_capacity(json.len() + 2);
    out.extend_from_slice(json.as_bytes());
    out.extend_from_slice(b"\r\n");
    out
}

/// Read one line off the socket against the request it may be answering.
///
/// Never an error: a line this cannot read is not the answer, and the caller's
/// timeout is what reports a lamp that never gives one.
pub fn decode_reply(request_json: &str, line: &str) -> YeelightReply {
    let Ok(reply) = serde_json::from_str::<serde_json::Value>(line.trim()) else {
        return YeelightReply::default();
    };
    let Ok(request) = serde_json::from_str::<serde_json::Value>(request_json) else {
        return YeelightReply::default();
    };
    if reply.get("method").is_some() {
        return YeelightReply::default();
    }
    // An error may carry no id at all; anything else must echo ours.
    let error = reply.get("error");
    let id_matches = reply.get("id") == request.get("id");
    if !id_matches && (error.is_none() || reply.get("id").is_some_and(|id| !id.is_null())) {
        return YeelightReply::default();
    }
    if let Some(error) = error {
        return YeelightReply {
            answers_request: true,
            error_code: error.get("code").and_then(|c| c.as_i64()),
            error_message: error
                .get("message")
                .and_then(|m| m.as_str())
                .map(str::to_string),
            fields: BTreeMap::new(),
        };
    }
    if reply.get("result").is_none() {
        return YeelightReply::default();
    }
    YeelightReply {
        answers_request: true,
        error_code: None,
        error_message: None,
        fields: state_fields(&request, &reply),
    }
}

/// Zip a `get_prop` result onto the names it was requested under.
///
/// Refused outright when the lengths differ: the pairing is by position, so a
/// reply of another length would hand every field its neighbour's value. A
/// property the lamp does not have answers `""` and reads as absent.
fn state_fields(
    request: &serde_json::Value,
    reply: &serde_json::Value,
) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    if request.get("method").and_then(|m| m.as_str()) != Some("get_prop") {
        return out;
    }
    let names = request.get("params").and_then(|p| p.as_array());
    let values = reply.get("result").and_then(|r| r.as_array());
    let (Some(names), Some(values)) = (names, values) else {
        return out;
    };
    if names.len() != values.len() {
        return out;
    }
    for (name, value) in names.iter().zip(values) {
        let Some(name) = name.as_str() else { continue };
        let text = match value {
            serde_json::Value::String(s) => s.clone(),
            serde_json::Value::Number(n) => n.to_string(),
            serde_json::Value::Bool(b) => b.to_string(),
            _ => continue,
        };
        if !text.is_empty() {
            out.insert(name.to_string(), text);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    fn spec() -> DeviceSpec {
        let raw = std::fs::read_to_string(
            std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../vendor/protocol-specs/device-specs/devices/yeelight-cube-lamp.yaml"),
        )
        .expect("the cube spec is vendored");
        parse_device_spec(&raw).expect("the cube spec parses")
    }

    fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    /// Every command the spec gives an `example_body` renders to exactly that,
    /// with the example's own values filled in.
    #[test]
    fn renders_each_spec_literal_frame() {
        let spec = spec();
        for (command, filled) in [
            ("turn_on", vec![]),
            ("turn_off", vec![]),
            ("toggle", vec![]),
            ("set_brightness", vec![("brightness", "50")]),
            ("set_rgb", vec![("rgb", "16711680")]),
            ("set_hsv", vec![("hue", "240"), ("sat", "100")]),
            ("set_color_temp", vec![("ct", "4000")]),
            (
                "set_music_on",
                vec![("host", "192.168.1.50"), ("port", "54321")],
            ),
            ("set_default", vec![]),
            ("cube_activate_fx_mode", vec![]),
            (
                "cube_set_segment_rgb",
                vec![("colors", "[255,16743680,0,0,16711680]")],
            ),
            ("get_prop", vec![]),
        ] {
            let rendered = render_request(&spec, command, &values(&filled)).expect(command);
            let example = spec.commands[command]
                .example_body
                .as_deref()
                .unwrap_or_else(|| panic!("{command} states an example"));
            assert_eq!(rendered.json, example, "{command}");
        }
    }

    /// The literal strings themselves, so a spec refresh that rewrites an
    /// example cannot quietly move the wire format with it.
    #[test]
    fn the_wire_is_crlf_terminated_plaintext_json() {
        let spec = spec();
        let on = render_request(&spec, "turn_on", &BTreeMap::new()).unwrap();
        assert_eq!(
            encode_line(&on.json),
            b"{\"id\":1,\"method\":\"set_power\",\"params\":[\"on\",\"smooth\",500]}\r\n"
        );
        let rgb = render_request(&spec, "set_rgb", &values(&[("rgb", "16711680")])).unwrap();
        assert_eq!(
            rgb.json,
            r#"{"id":1,"method":"set_rgb","params":[16711680,"smooth",500]}"#
        );
        let ct = render_request(&spec, "set_color_temp", &values(&[("ct", "4000")])).unwrap();
        assert_eq!(
            ct.json,
            r#"{"id":1,"method":"set_ct_abx","params":[4000,"smooth",500]}"#
        );
        let rows = render_request(
            &spec,
            SEGMENT_COMMAND,
            &values(&[("colors", "[255, 16743680, 0, 0, 16711680]")]),
        )
        .unwrap();
        assert_eq!(
            rows.json,
            r#"{"id":1,"method":"set_segment_rgb","params":[255,16743680,0,0,16711680]}"#
        );
    }

    #[test]
    fn a_declared_range_is_enforced() {
        let spec = spec();
        for (command, name, bad) in [
            ("set_brightness", "brightness", "0"),
            ("set_brightness", "brightness", "101"),
            ("set_rgb", "rgb", "16777216"),
            ("set_color_temp", "ct", "1699"),
            ("set_color_temp", "ct", "6501"),
        ] {
            let result = render_request(&spec, command, &values(&[(name, bad)]));
            assert!(
                matches!(result, Err(ProtocolError::ParameterOutOfRange { .. })),
                "{command} {bad}: {result:?}"
            );
        }
    }

    #[test]
    fn a_value_cannot_inject_json() {
        let spec = spec();
        let result = render_request(
            &spec,
            "set_brightness",
            &values(&[("brightness", r#"1,"smooth",500]},{"id":2"#)]),
        );
        assert!(result.is_err(), "{result:?}");
        let rows = render_request(
            &spec,
            SEGMENT_COMMAND,
            &values(&[("colors", r#"[1,2,3,4,"x"]"#)]),
        );
        assert!(rows.is_err(), "{rows:?}");
    }

    #[test]
    fn a_segment_array_is_five_per_module_of_24_bit_colours() {
        let spec = spec();
        let render = |colors: &str| {
            render_request(&spec, SEGMENT_COMMAND, &values(&[("colors", colors)])).map(|r| r.json)
        };
        assert!(render("[]").is_err());
        assert!(render("[1,2,3,4]").is_err());
        assert!(render("[1,2,3,4,16777216]").is_err());
        assert!(render("[1,2,3,4,-1]").is_err());
        assert!(render("not json").is_err());
        assert!(
            render("[1,2,3,4,5,6,7,8,9,10]").is_ok(),
            "a second stacked module appends five more"
        );
    }

    #[test]
    fn another_handlers_spec_is_refused() {
        let mut spec = spec();
        spec.protocol_handler = Some("tplink_smarthome".to_string());
        assert!(matches!(
            render_request(&spec, "turn_on", &BTreeMap::new()),
            Err(ProtocolError::UnsupportedCommandEncoding(_))
        ));
    }

    const GET_PROP: &str = r#"{"id":1,"method":"get_prop","params":["power","bright","ct","rgb","hue","sat","color_mode","name"]}"#;

    /// The reply the entity's mapping has to be read through: positional, and
    /// named only by the request.
    #[test]
    fn a_state_reply_is_zipped_onto_the_requested_names() {
        let reply = decode_reply(
            GET_PROP,
            "{\"id\":1,\"result\":[\"on\",\"100\",\"4000\",\"16711680\",\"359\",\"100\",\"2\",\"Desk\"]}\r\n",
        );
        assert!(reply.answers_request);
        assert_eq!(reply.fields["power"], "on");
        assert_eq!(reply.fields["bright"], "100");
        assert_eq!(reply.fields["ct"], "4000");
        assert_eq!(reply.fields["rgb"], "16711680");
        assert_eq!(reply.fields["color_mode"], "2");
        assert_eq!(reply.fields["name"], "Desk");
    }

    #[test]
    fn a_property_the_lamp_lacks_reads_as_absent() {
        let reply = decode_reply(
            GET_PROP,
            r#"{"id":1,"result":["on","100","","16711680","","","1",""]}"#,
        );
        assert!(!reply.fields.contains_key("ct"));
        assert!(!reply.fields.contains_key("name"));
        assert_eq!(reply.fields["rgb"], "16711680");
    }

    #[test]
    fn a_reply_of_another_length_is_not_paired_by_position() {
        let reply = decode_reply(GET_PROP, r#"{"id":1,"result":["ok"]}"#);
        assert!(reply.answers_request);
        assert!(reply.fields.is_empty());
    }

    #[test]
    fn a_pushed_notification_is_not_the_answer() {
        let reply = decode_reply(
            GET_PROP,
            r#"{"method":"props","params":{"power":"off","bright":"20"}}"#,
        );
        assert!(!reply.answers_request);
    }

    #[test]
    fn another_ids_reply_and_noise_are_not_the_answer() {
        assert!(!decode_reply(GET_PROP, r#"{"id":7,"result":["ok"]}"#).answers_request);
        assert!(!decode_reply(GET_PROP, "not json").answers_request);
        assert!(!decode_reply(GET_PROP, r#"{"id":1}"#).answers_request);
    }

    #[test]
    fn a_device_error_answers_and_says_why() {
        let set = r#"{"id":1,"method":"set_rgb","params":[255,"smooth",500]}"#;
        let reply = decode_reply(
            set,
            r#"{"id":1,"error":{"code":-1,"message":"client quota exceeded"}}"#,
        );
        assert!(reply.answers_request);
        assert_eq!(reply.error_code, Some(-1));
        assert_eq!(
            reply.error_message.as_deref(),
            Some("client quota exceeded")
        );

        let unaddressed = decode_reply(set, r#"{"error":{"code":-1,"message":"nope"}}"#);
        assert!(unaddressed.answers_request);
        assert_eq!(unaddressed.error_code, Some(-1));

        let someone_elses = decode_reply(set, r#"{"id":9,"error":{"code":-1,"message":"x"}}"#);
        assert!(!someone_elses.answers_request);
    }

    #[test]
    fn a_set_acknowledgement_carries_no_fields() {
        let set = r#"{"id":1,"method":"set_power","params":["on","smooth",500]}"#;
        let reply = decode_reply(set, r#"{"id":1,"result":["ok"]}"#);
        assert!(reply.answers_request);
        assert_eq!(reply.error_code, None);
        assert!(reply.fields.is_empty());
    }
}

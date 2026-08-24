// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! The WebSocket control surface: where the socket is, and what one command
//! looks like on it.
//!
//! What is NOT here is the socket. Dart owns that, exactly as it owns the TLS
//! socket for MQTT and the UDP one for LIFX — this module reads the spec's
//! `websocket:` block and turns a command into the bytes of one frame.
//!
//! Two devices, two shapes, and the difference is real rather than cosmetic: a
//! Samsung set takes `{"method": …, "params": …}` on a single socket, while an
//! LG set takes `{"id": …, "type": "request", "uri": …, "payload": …}` on one
//! socket and plain-text `type:button\nname:HOME\n\n` on a SECOND socket it
//! hands out at runtime. Both are declared, so neither is written here.

use std::collections::BTreeMap;

use crate::error::ProtocolError;
use crate::spec::types::{DeviceSpec, SpecCommand};

/// The transport string a command must declare — or inherit from
/// `device.transport` — to be rendered from here.
pub const TRANSPORT: &str = "websocket";

/// Where to open the socket, and what the certificate is worth.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Address {
    pub port: u16,
    /// `ws` or `wss`.
    pub scheme: String,
    /// Path with its `{name}` placeholders still in place — the caller fills
    /// them from stored credentials, which this crate never holds.
    pub path: String,
}

/// How a client is authorised on the socket.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Pairing {
    /// `token_query` or `register_frame`.
    pub mode: String,
    /// What the issued secret is stored as, and the name the connect path or
    /// register frame fills from it.
    pub credential_name: Option<String>,
    /// Dotted path into the device's reply where the secret appears.
    pub issued_at: Option<String>,
    /// The frame to send for `register_frame`, as JSON.
    pub register_frame: Option<String>,
    /// What the viewer must do, so a client can say it rather than appearing
    /// to hang.
    pub prompt_notes: Option<String>,
}

/// One frame shape the device speaks.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Channel {
    pub name: String,
    pub is_default: bool,
    /// `json` or `text`.
    pub encoding: String,
    /// For `json`: the frame object, as JSON with placeholders intact.
    pub frame: Option<String>,
    /// For `text`: the literal frame template.
    pub frame_template: Option<String>,
    /// The command whose reply carries this channel's own address, for a
    /// second socket the device hands out at runtime.
    pub obtained_by: Option<String>,
    /// Dotted path into that reply where the address is.
    pub address_path: Option<String>,
}

/// A spec's whole WebSocket surface.
// No `Eq`: `heartbeat_seconds` is a float, and a heartbeat is a duration
// rather than an identity — nothing compares two surfaces for equality.
#[derive(Debug, Clone, PartialEq)]
pub struct Surface {
    pub connect: Address,
    /// A second address to try when the first is refused. LG's clients are
    /// required to: late firmware listens on the TLS port only.
    pub fallback: Option<Address>,
    /// Extra handshake headers the device requires.
    pub headers: BTreeMap<String, String>,
    /// True when the certificate is self-signed with no chain, so validating
    /// it cannot succeed.
    pub tls_self_signed: bool,
    /// What a client should actually do about that certificate.
    pub tls_verification: Option<String>,
    pub heartbeat_seconds: Option<f64>,
    pub pairing: Option<Pairing>,
    pub channels: Vec<Channel>,
}

impl Surface {
    /// The channel a command names, or the default when it names none.
    ///
    /// `None` for a command naming a channel the spec does not declare — a
    /// caller declines rather than silently sending it somewhere else, which
    /// on this device means the wrong socket entirely.
    pub fn channel_for(&self, command: &SpecCommand) -> Option<&Channel> {
        match command.channel.as_deref() {
            Some(named) => self.channels.iter().find(|c| c.name == named),
            None => self.channels.iter().find(|c| c.is_default),
        }
    }
}

/// Read a spec's `websocket:` block, or `None` when it declares none.
///
/// Reaches into the untyped `extensions` map by hand, the way `setup.rs` reads
/// `device.setup`: the block is one more access surface among several, and
/// promoting it to a typed field on `DeviceSpec` would model a great deal for
/// the two specs that carry it.
pub fn surface(spec: &DeviceSpec) -> Option<Surface> {
    let ws = spec.extensions.get("websocket")?;
    let connect = ws.get("connect")?;

    let address = |node: &serde_yaml::Value, default_path: &str| -> Option<Address> {
        Some(Address {
            port: u16::try_from(node.get("port")?.as_u64()?).ok()?,
            scheme: node.get("scheme")?.as_str()?.to_string(),
            path: node
                .get("path")
                .and_then(|p| p.as_str())
                .unwrap_or(default_path)
                .to_string(),
        })
    };

    let main = address(connect, "/")?;
    // A fallback that omits its path reuses the main one — the two differ in
    // port and scheme, which is the whole point of declaring it.
    let fallback = connect
        .get("fallback")
        .and_then(|f| address(f, &main.path.clone()));

    let headers = connect
        .get("headers")
        .and_then(|h| h.as_mapping())
        .map(|map| {
            map.iter()
                .filter_map(|(k, v)| Some((k.as_str()?.to_string(), v.as_str()?.to_string())))
                .collect()
        })
        .unwrap_or_default();

    let tls = connect.get("tls");
    let pairing = ws.get("pairing").map(|p| Pairing {
        mode: p
            .get("mode")
            .and_then(|m| m.as_str())
            .unwrap_or_default()
            .to_string(),
        credential_name: opt_str(p.get("credential_name")),
        issued_at: opt_str(p.get("issued_at")),
        register_frame: p
            .get("register_frame")
            .and_then(|f| serde_json::to_string(&yaml_to_json(f)).ok()),
        prompt_notes: opt_str(p.get("prompt_notes")),
    });

    let channels = ws
        .get("channels")
        .and_then(|c| c.as_sequence())
        .map(|seq| {
            seq.iter()
                .filter_map(|c| {
                    Some(Channel {
                        name: c.get("name")?.as_str()?.to_string(),
                        is_default: c.get("default").and_then(|d| d.as_bool()).unwrap_or(false),
                        encoding: c.get("encoding")?.as_str()?.to_string(),
                        frame: c
                            .get("frame")
                            .and_then(|f| serde_json::to_string(&yaml_to_json(f)).ok()),
                        frame_template: opt_str(c.get("frame_template")),
                        obtained_by: opt_str(c.get("obtained_by")),
                        address_path: opt_str(c.get("address_path")),
                    })
                })
                .collect()
        })
        .unwrap_or_default();

    Some(Surface {
        connect: main,
        fallback,
        headers,
        tls_self_signed: tls
            .and_then(|t| t.get("self_signed"))
            .and_then(|s| s.as_bool())
            .unwrap_or(false),
        tls_verification: tls.and_then(|t| opt_str(t.get("verification"))),
        heartbeat_seconds: connect.get("heartbeat_seconds").and_then(|h| h.as_f64()),
        pairing,
        channels,
    })
}

fn opt_str(value: Option<&serde_yaml::Value>) -> Option<String> {
    value.and_then(|v| v.as_str()).map(str::to_string)
}

/// YAML → JSON, for the frame templates that are declared as YAML mappings.
fn yaml_to_json(value: &serde_yaml::Value) -> serde_json::Value {
    match value {
        serde_yaml::Value::Null => serde_json::Value::Null,
        serde_yaml::Value::Bool(b) => serde_json::Value::Bool(*b),
        serde_yaml::Value::Number(n) => n
            .as_i64()
            .map(serde_json::Value::from)
            .or_else(|| n.as_f64().map(serde_json::Value::from))
            .unwrap_or(serde_json::Value::Null),
        serde_yaml::Value::String(s) => serde_json::Value::String(s.clone()),
        serde_yaml::Value::Sequence(seq) => {
            serde_json::Value::Array(seq.iter().map(yaml_to_json).collect())
        }
        serde_yaml::Value::Mapping(map) => serde_json::Value::Object(
            map.iter()
                .filter_map(|(k, v)| Some((k.as_str()?.to_string(), yaml_to_json(v))))
                .collect(),
        ),
        serde_yaml::Value::Tagged(tagged) => yaml_to_json(&tagged.value),
    }
}

/// One rendered frame, and which channel it goes to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    /// The channel's name — which socket the caller writes this to.
    pub channel: String,
    /// The frame itself: a JSON document, or the literal text a `text`
    /// channel declared.
    pub text: String,
}

/// Render one of a spec's `transport: websocket` commands.
///
/// `request_id` is the client's correlation integer, required rather than
/// invented here for the reason the Roomba's timestamp is: this crate has no
/// counter, and a frame rendered with a fixed id would match every reply to
/// the same request.
pub fn render_command(
    spec: &DeviceSpec,
    command_name: &str,
    command: &SpecCommand,
    values: &BTreeMap<String, String>,
    request_id: i64,
) -> Result<Frame, ProtocolError> {
    let Some(surface) = surface(spec) else {
        return Err(ProtocolError::UnsupportedCommandEncoding(
            "the spec declares no `websocket` block".to_string(),
        ));
    };
    let Some(channel) = surface.channel_for(command) else {
        // Naming a channel the spec does not declare is not a near miss: on a
        // device with two sockets it is the difference between a button that
        // works and one that goes to the JSON socket and is ignored.
        return Err(ProtocolError::UnsupportedCommandEncoding(format!(
            "{command_name} rides channel {:?}, which the spec does not declare",
            command.channel.as_deref().unwrap_or("<default>")
        )));
    };
    let Some(action) = command.action.as_deref() else {
        // The action IS the instruction here — a wire method for Samsung, an
        // SSAP URI or a button name for LG.
        return Err(ProtocolError::EmptyCommand);
    };

    // The command's own arguments, rendered exactly as every other transport
    // renders them: declared order, each value taking its parameter's JSON
    // type. An `{}` payload is what a command with no arguments sends.
    let arguments = if command.arguments.is_empty() {
        "{}".to_string()
    } else {
        crate::protocol::http::render_body(command, command_name, values)?
    };

    let text = match channel.encoding.as_str() {
        "json" => {
            let Some(template) = channel.frame.as_deref() else {
                return Err(ProtocolError::EmptyCommand);
            };
            splice_json(template, action, &arguments, request_id)
        }
        "text" => {
            let Some(template) = channel.frame_template.as_deref() else {
                return Err(ProtocolError::EmptyCommand);
            };
            template
                .replace("{action}", action)
                .replace("{request_id}", &request_id.to_string())
        }
        other => {
            return Err(ProtocolError::UnsupportedCommandEncoding(format!(
                "channel {} declares encoding {other:?}",
                channel.name
            )));
        }
    };

    Ok(Frame {
        channel: channel.name.clone(),
        text,
    })
}

/// Fill a JSON frame template.
///
/// `"{action}"` and `"{request_id}"` are whole VALUES, so they are replaced
/// with a JSON string and a JSON number respectively — a request id sent as
/// `"12"` is a different frame from one sent as `12`, and the TV correlating
/// replies is the one who notices. `"{arguments}"` splices the already-
/// rendered arguments object in place of the quoted placeholder, which is why
/// it is matched WITH its quotes: the template is valid JSON either way, and
/// leaving the quotes would send the payload as a string.
fn splice_json(template: &str, action: &str, arguments: &str, request_id: i64) -> String {
    template
        .replace(
            "\"{action}\"",
            &serde_json::Value::String(action.to_string()).to_string(),
        )
        .replace("\"{request_id}\"", &request_id.to_string())
        .replace("\"{arguments}\"", arguments)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// Two channels on one device — the LG shape, reduced. The button channel
    /// is plain text on a socket the TV hands out at runtime; the ssap one is
    /// JSON on the socket already open.
    const TWO_CHANNEL_TV: &str = r#"
device:
  name: "Test TV"
  manufacturer: "Test"
  manufacturer_status: "active"
  protocol: "wifi"
  category: "tv"
  transport: "websocket"
websocket:
  connect:
    port: 3000
    scheme: "ws"
    path: "/"
    fallback:
      port: 3001
      scheme: "wss"
    tls:
      self_signed: true
      verification: "none"
    heartbeat_seconds: 5
  pairing:
    mode: "register_frame"
    credential_name: "tv_client_key"
    issued_at: "payload.client-key"
    register_frame:
      id: "register_0"
      type: "register"
  channels:
    - name: "ssap"
      default: true
      encoding: "json"
      frame:
        id: "{request_id}"
        type: "request"
        uri: "{action}"
        payload: "{arguments}"
    - name: "pointer"
      encoding: "text"
      frame_template: "type:button\nname:{action}\n\n"
      obtained_by: "get_pointer_socket"
      address_path: "payload.socketPath"
commands:
  get_pointer_socket:
    description: "Ask for the button socket."
    action: "ssap://com.webos.service.networkinput/getPointerInputSocket"
  set_volume:
    description: "Set volume."
    action: "ssap://audio/setVolume"
    parameters:
      volume:
        type: "integer"
        required: true
    arguments:
      volume: "{volume}"
  press_home:
    description: "Home."
    action: "HOME"
    channel: "pointer"
  press_nowhere:
    description: "A button whose channel does not exist."
    action: "NOWHERE"
    channel: "typo"
"#;

    fn spec() -> DeviceSpec {
        parse_device_spec(TWO_CHANNEL_TV).expect("fixture parses")
    }

    fn render(name: &str, values: &[(&str, &str)]) -> Result<Frame, ProtocolError> {
        let spec = spec();
        let command = spec.commands.get(name).expect("declared");
        let values = values
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        render_command(&spec, name, command, &values, 12)
    }

    #[test]
    fn the_connect_address_and_its_fallback_are_read() {
        let surface = surface(&spec()).expect("declares a websocket block");
        assert_eq!(surface.connect.port, 3000);
        assert_eq!(surface.connect.scheme, "ws");
        let fallback = surface.fallback.expect("declares a fallback");
        assert_eq!(fallback.port, 3001);
        assert_eq!(fallback.scheme, "wss");
        // The fallback omitted its path, so it reuses the main one — what
        // differs between the two is the port and the scheme.
        assert_eq!(fallback.path, "/");
        assert!(surface.tls_self_signed);
        assert_eq!(surface.tls_verification.as_deref(), Some("none"));
        assert_eq!(surface.heartbeat_seconds, Some(5.0));
    }

    #[test]
    fn a_json_frame_carries_a_typed_id_and_a_spliced_payload() {
        let frame = render("set_volume", &[("volume", "12")]).expect("renders");
        assert_eq!(frame.channel, "ssap");
        let json: serde_json::Value = serde_json::from_str(&frame.text).expect("valid JSON");
        // The id is a NUMBER: a TV correlating replies is the one who notices
        // the difference between 12 and "12".
        assert_eq!(json["id"], serde_json::json!(12));
        assert_eq!(json["type"], "request");
        assert_eq!(json["uri"], "ssap://audio/setVolume");
        // And the payload is an object, not a string containing one.
        assert_eq!(json["payload"], serde_json::json!({"volume": 12}));
    }

    #[test]
    fn a_command_with_no_arguments_sends_an_empty_payload() {
        let frame = render("get_pointer_socket", &[]).expect("renders");
        let json: serde_json::Value = serde_json::from_str(&frame.text).expect("valid JSON");
        assert_eq!(json["payload"], serde_json::json!({}));
    }

    /// A button is not JSON and does not go to the JSON socket. Both halves
    /// matter: the frame is plain text, and the channel name tells the caller
    /// which socket to write it to.
    #[test]
    fn a_text_frame_is_literal_and_names_its_own_socket() {
        let frame = render("press_home", &[]).expect("renders");
        assert_eq!(frame.channel, "pointer");
        assert_eq!(frame.text, "type:button\nname:HOME\n\n");
    }

    #[test]
    fn a_channel_the_spec_does_not_declare_is_refused() {
        let error = render("press_nowhere", &[]).expect_err("a typo must not reach a socket");
        assert!(
            matches!(error, ProtocolError::UnsupportedCommandEncoding(_)),
            "{error}"
        );
    }

    #[test]
    fn the_runtime_channel_says_which_command_finds_it() {
        let surface = surface(&spec()).expect("declares a websocket block");
        let pointer = surface
            .channels
            .iter()
            .find(|c| c.name == "pointer")
            .expect("declared");
        assert_eq!(pointer.obtained_by.as_deref(), Some("get_pointer_socket"));
        assert_eq!(pointer.address_path.as_deref(), Some("payload.socketPath"));
    }

    #[test]
    fn the_pairing_block_says_what_it_issues_and_where() {
        let pairing = surface(&spec())
            .expect("declares a websocket block")
            .pairing
            .expect("declares pairing");
        assert_eq!(pairing.mode, "register_frame");
        assert_eq!(pairing.credential_name.as_deref(), Some("tv_client_key"));
        assert_eq!(pairing.issued_at.as_deref(), Some("payload.client-key"));
        let frame: serde_json::Value =
            serde_json::from_str(&pairing.register_frame.expect("declares a frame"))
                .expect("valid JSON");
        assert_eq!(frame["type"], "register");
    }

    #[test]
    fn a_spec_with_no_websocket_block_has_no_surface() {
        let yaml = TWO_CHANNEL_TV
            .split("websocket:")
            .next()
            .unwrap()
            .to_string()
            + "http_endpoints:\n  - method: \"GET\"\n    path: \"/\"\n    name: \"Root\"\n";
        let spec = parse_device_spec(&yaml).expect("fixture parses");
        assert!(surface(&spec).is_none());
    }
}

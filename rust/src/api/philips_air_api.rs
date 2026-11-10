// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! The Philips encrypted-CoAP purifier's bridge: the datagrams a session
//! sends and what the ones it receives mean. The socket is Dart's; the
//! envelope, the counter and every CoAP byte are
//! [`crate::protocol::philips_air`]'s.

use std::collections::{BTreeMap, HashMap};

use crate::protocol::philips_air;

/// One control write, enveloped and framed, and the counter it went under.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhilipsAirControlFrameDto {
    pub datagram: Vec<u8>,
    pub counter: String,
}

/// What one received datagram means for the request in flight.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhilipsAirReplyDto {
    pub answers_request: bool,
    /// Bytes to send back first: an ACK owed to a confirmable reply, or a
    /// Reset for a confirmable message on a token never asked.
    pub owe: Option<Vec<u8>>,
    /// The CoAP code as RFC 7252 writes it (`2.05`), empty when not ours.
    pub code: String,
    /// True for a 2.xx code.
    pub success_class: bool,
    pub payload: Vec<u8>,
    pub max_age: Option<u32>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn philips_air_default_port() -> u16 {
    philips_air::PORT
}

#[flutter_rust_bridge::frb(sync)]
pub fn philips_air_sync_request(
    message_id: u16,
    token: Vec<u8>,
    nonce: String,
) -> anyhow::Result<Vec<u8>> {
    Ok(philips_air::sync_request(message_id, &token, &nonce)?)
}

#[flutter_rust_bridge::frb(sync)]
pub fn philips_air_status_request(message_id: u16, token: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(philips_air::status_request(message_id, &token)?)
}

#[flutter_rust_bridge::frb(sync)]
pub fn philips_air_status_deregister(message_id: u16, token: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(philips_air::status_deregister(message_id, &token)?)
}

/// Read a datagram against the token of the request in flight.
#[flutter_rust_bridge::frb(sync)]
pub fn philips_air_read_reply(datagram: Vec<u8>, token: Vec<u8>) -> PhilipsAirReplyDto {
    let reply = philips_air::read_reply(&datagram, &token);
    PhilipsAirReplyDto {
        answers_request: reply.answers_request,
        owe: reply.owe,
        code: if reply.answers_request {
            crate::protocol::coap::code::dotted(reply.code)
        } else {
            String::new()
        },
        success_class: reply.answers_request && crate::protocol::coap::code::class(reply.code) == 2,
        payload: reply.payload,
        max_age: reply.max_age,
    }
}

/// The device's counter from a sync reply, as eight uppercase hex digits.
#[flutter_rust_bridge::frb(sync)]
pub fn philips_air_parse_sync_reply(payload: Vec<u8>) -> anyhow::Result<String> {
    Ok(philips_air::format_counter(philips_air::parse_sync_reply(
        &payload,
    )?))
}

/// Render one of the spec's control writes to its JSON plaintext.
pub fn philips_air_render_control(
    spec_yaml: String,
    command_name: String,
    values: HashMap<String, String>,
) -> anyhow::Result<String> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let values: BTreeMap<String, String> = values.into_iter().collect();
    Ok(philips_air::render_control(&spec, &command_name, &values)?)
}

/// Envelope `plaintext` under the counter after `synced_counter` and frame
/// it as the control POST. The plaintext must be one [`philips_air_render_control`]
/// produced; it is re-checked to be a desired-state write.
#[flutter_rust_bridge::frb(sync)]
pub fn philips_air_control_request(
    message_id: u16,
    token: Vec<u8>,
    synced_counter: String,
    plaintext: String,
) -> anyhow::Result<PhilipsAirControlFrameDto> {
    let parsed: serde_json::Value = serde_json::from_str(&plaintext)
        .map_err(|e| crate::error::ProtocolError::InvalidStateReply(e.to_string()))?;
    if !parsed["state"]["desired"].is_object() {
        anyhow::bail!("not a state.desired write");
    }
    let counter = philips_air::next_counter(philips_air::parse_counter(&synced_counter)?)?;
    let envelope = philips_air::encode_envelope(counter, &plaintext);
    Ok(PhilipsAirControlFrameDto {
        datagram: philips_air::control_request(message_id, &token, &envelope)?,
        counter: philips_air::format_counter(counter),
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn philips_air_control_succeeded(payload: Vec<u8>) -> bool {
    philips_air::control_succeeded(&payload)
}

/// A status payload's decrypted JSON.
#[flutter_rust_bridge::frb(sync)]
pub fn philips_air_decode_status(payload: Vec<u8>) -> anyhow::Result<String> {
    Ok(philips_air::decode_status(&payload)?)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_control_frame_goes_under_the_counter_after_the_sync() {
        let plaintext = r#"{"state": {"desired": {"CommandType": "app", "DeviceId": "", "EnduserId": "", "pwr": "1"}}}"#;
        let frame = philips_air_control_request(9, vec![1, 2], "6D2C0F41".into(), plaintext.into())
            .unwrap();
        assert_eq!(frame.counter, "6D2C0F42");
        let message = crate::protocol::coap::decode(&frame.datagram).unwrap();
        let envelope = String::from_utf8(message.payload).unwrap();
        assert!(envelope.starts_with("6D2C0F4242DC07095A0FD808"));
        assert!(philips_air_control_request(9, vec![1], "6D2C0F41".into(), "{}".into()).is_err());
        assert!(
            philips_air_control_request(9, vec![1], "FFFFFFFF".into(), plaintext.into()).is_err()
        );
    }

    #[test]
    fn a_reply_reports_its_code_class() {
        let token = vec![7u8; 4];
        let datagram = crate::protocol::coap::encode(&crate::protocol::coap::Message {
            message_type: crate::protocol::coap::MessageType::NonConfirmable,
            code: 0x84,
            message_id: 1,
            token: token.clone(),
            options: Vec::new(),
            payload: Vec::new(),
        })
        .unwrap();
        let reply = philips_air_read_reply(datagram, token);
        assert!(reply.answers_request);
        assert_eq!(reply.code, "4.04");
        assert!(!reply.success_class);
    }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! The Mattel MPID session's bridge (`protocol::mattel_mpid`). Dart owns the
//! connection and holds the session's three values for its lifetime; every
//! byte of crypto and framing is computed here. [`mpid_seal`] takes a body
//! the spec's commands rendered and refuses anything else.

use crate::protocol::mattel_mpid::{self, Session};

/// Where the session lives on the unit, and the spec's pacing.
#[derive(Debug, Clone)]
pub struct MpidChannelsDto {
    pub service_uuid: String,
    pub tx_uuid: String,
    pub rx_uuid: String,
    pub token_uuid: String,
    pub session_uuid: String,
    /// The Nordic DFU service on the same unit, which nothing writes.
    pub dfu_service_uuid: String,
    pub after_session_write_ms: u32,
    pub after_enable_rx_ms: u32,
    pub between_commands_ms: u32,
    /// ENABLE_RX, sealed as frame 1.
    pub enable_rx: Vec<u8>,
    /// REQUEST_GLOBAL_STATE, sent once after ENABLE_RX so a screen that just
    /// connected has a state to show.
    pub request_global_state: Vec<u8>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn mpid_channels() -> MpidChannelsDto {
    MpidChannelsDto {
        service_uuid: mattel_mpid::SERVICE_UUID.to_string(),
        tx_uuid: mattel_mpid::TX_UUID.to_string(),
        rx_uuid: mattel_mpid::RX_UUID.to_string(),
        token_uuid: mattel_mpid::TOKEN_UUID.to_string(),
        session_uuid: mattel_mpid::SESSION_UUID.to_string(),
        dfu_service_uuid: mattel_mpid::DFU_SERVICE_UUID.to_string(),
        after_session_write_ms: mattel_mpid::AFTER_SESSION_WRITE_MS,
        after_enable_rx_ms: mattel_mpid::AFTER_ENABLE_RX_MS,
        between_commands_ms: mattel_mpid::BETWEEN_COMMANDS_MS,
        enable_rx: mattel_mpid::ENABLE_RX.to_vec(),
        request_global_state: mattel_mpid::REQUEST_GLOBAL_STATE.to_vec(),
    }
}

/// One connection's session. Ephemeral: nothing stores it.
#[derive(Debug, Clone)]
pub struct MpidSessionDto {
    pub key: Vec<u8>,
    pub app_nonce: Vec<u8>,
    pub device_salt: Vec<u8>,
    /// What to write to the session characteristic, with response.
    pub session_write: Vec<u8>,
}

/// Agree a session with the unit whose factory token was just read.
pub fn mpid_start_session(token: Vec<u8>) -> anyhow::Result<MpidSessionDto> {
    let (session, session_write) = mattel_mpid::start_session(&token)?;
    Ok(MpidSessionDto {
        key: session.key.to_vec(),
        app_nonce: session.app_nonce.to_vec(),
        device_salt: session.device_salt.to_vec(),
        session_write,
    })
}

fn session_of(key: &[u8], app_nonce: &[u8], device_salt: &[u8]) -> anyhow::Result<Session> {
    Ok(Session {
        key: key
            .try_into()
            .map_err(|_| anyhow::anyhow!("an MPID session key is 16 bytes"))?,
        app_nonce: app_nonce
            .try_into()
            .map_err(|_| anyhow::anyhow!("an MPID app nonce is 4 bytes"))?,
        device_salt: device_salt
            .try_into()
            .map_err(|_| anyhow::anyhow!("an MPID device salt is 4 bytes"))?,
    })
}

/// Frame number `seq` around `body`, encrypted for the unit.
#[flutter_rust_bridge::frb(sync)]
pub fn mpid_seal(
    key: Vec<u8>,
    app_nonce: Vec<u8>,
    device_salt: Vec<u8>,
    seq: u32,
    body: Vec<u8>,
) -> anyhow::Result<Vec<u8>> {
    let session = session_of(&key, &app_nonce, &device_salt)?;
    Ok(mattel_mpid::seal(&session, seq, &body)?)
}

/// One notification from the unit, decrypted, without its CRC.
#[flutter_rust_bridge::frb(sync)]
pub fn mpid_open(
    key: Vec<u8>,
    app_nonce: Vec<u8>,
    device_salt: Vec<u8>,
    frame: Vec<u8>,
) -> anyhow::Result<Vec<u8>> {
    let session = session_of(&key, &app_nonce, &device_salt)?;
    Ok(mattel_mpid::open(&session, &frame)?.body)
}

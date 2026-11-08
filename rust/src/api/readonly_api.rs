// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! The read-only handlers' bridge. Everything crossing here reads; there is
//! deliberately no entry point that takes a command name, a function code, an
//! opcode or an address. See [`crate::protocol::readonly`].

use crate::api::device_api::SafetyAdvisoryDto;
use crate::protocol::{acinfinity, modbus_sunspec, readonly, yummly};

pub use crate::protocol::acinfinity::{
    AcInfinityFeedDto, AcInfinityPortDto, AcInfinityStatusDto, AcInfinityStoredDto,
};
pub use crate::protocol::modbus_sunspec::{
    SunSpecCommonDto, SunSpecInverterDto, SunSpecMeterDto, SunSpecMeterPowerDto,
};
pub use crate::protocol::readonly::ReadOnlyCommandDto;
pub use crate::protocol::yummly::{YummlyFrameDto, YummlyFrameKind};

/// What a read-only spec's screen needs to know before it reads anything.
#[derive(Debug, Clone)]
pub struct ReadOnlySurfaceDto {
    pub handler: String,
    pub default_port: Option<u16>,
    pub safety_advisory: Option<SafetyAdvisoryDto>,
    /// Every command the spec declares, and whether this app sends it.
    pub commands: Vec<ReadOnlyCommandDto>,
}

/// The read-only surface of a spec, or `None` if its handler is not one.
pub fn read_only_surface(spec_yaml: String) -> anyhow::Result<Option<ReadOnlySurfaceDto>> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let Some(handler) = readonly::read_only_handler(&spec) else {
        return Ok(None);
    };
    Ok(Some(ReadOnlySurfaceDto {
        handler: handler.name.to_string(),
        default_port: spec
            .device
            .identification
            .as_ref()
            .and_then(|identification| identification.default_port),
        safety_advisory: spec
            .device
            .safety_advisory
            .as_ref()
            .map(SafetyAdvisoryDto::from),
        commands: readonly::command_policy(&spec),
    }))
}

/// A SunSpec read this app makes; the registers are the protocol module's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SunSpecReadKind {
    CommonBlock,
    InverterBlock,
    Meter1Common,
    Meter1Power,
}

impl From<SunSpecReadKind> for modbus_sunspec::SunSpecRead {
    fn from(kind: SunSpecReadKind) -> Self {
        match kind {
            SunSpecReadKind::CommonBlock => Self::CommonBlock,
            SunSpecReadKind::InverterBlock => Self::InverterBlock,
            SunSpecReadKind::Meter1Common => Self::Meter1Common,
            SunSpecReadKind::Meter1Power => Self::Meter1Power,
        }
    }
}

#[flutter_rust_bridge::frb(sync)]
pub fn sunspec_encode_read(
    kind: SunSpecReadKind,
    transaction_id: u16,
    unit_id: u8,
) -> Result<Vec<u8>, crate::error::ProtocolError> {
    modbus_sunspec::encode_read(kind.into(), transaction_id, unit_id)
}

#[flutter_rust_bridge::frb(sync)]
pub fn sunspec_reply_length(head: Vec<u8>) -> Option<u32> {
    modbus_sunspec::reply_length(&head).map(|length| length as u32)
}

/// The exception code when `reply` is a Modbus exception to this transaction.
#[flutter_rust_bridge::frb(sync)]
pub fn sunspec_exception_code(reply: Vec<u8>, transaction_id: u16, unit_id: u8) -> Option<u8> {
    modbus_sunspec::exception_code(&reply, transaction_id, unit_id)
}

#[flutter_rust_bridge::frb(sync)]
pub fn sunspec_exception_meaning(code: u8) -> String {
    modbus_sunspec::exception_meaning(code).to_string()
}

pub fn sunspec_decode_common(
    reply: Vec<u8>,
    transaction_id: u16,
    unit_id: u8,
) -> anyhow::Result<SunSpecCommonDto> {
    Ok(modbus_sunspec::decode_common(
        &reply,
        transaction_id,
        unit_id,
    )?)
}

pub fn sunspec_decode_inverter(
    reply: Vec<u8>,
    transaction_id: u16,
    unit_id: u8,
) -> anyhow::Result<SunSpecInverterDto> {
    Ok(modbus_sunspec::decode_inverter(
        &reply,
        transaction_id,
        unit_id,
    )?)
}

pub fn sunspec_decode_meter_common(
    reply: Vec<u8>,
    transaction_id: u16,
    unit_id: u8,
) -> anyhow::Result<SunSpecMeterDto> {
    Ok(modbus_sunspec::decode_meter_common(
        &reply,
        transaction_id,
        unit_id,
    )?)
}

pub fn sunspec_decode_meter_power(
    reply: Vec<u8>,
    transaction_id: u16,
    unit_id: u8,
) -> anyhow::Result<SunSpecMeterPowerDto> {
    Ok(modbus_sunspec::decode_meter_power(
        &reply,
        transaction_id,
        unit_id,
    )?)
}

/// A Yummly XW2 read this app makes; the request bytes are the protocol
/// module's.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum YummlyReadKind {
    DockFirmware,
    DockBattery,
    ProbeMac,
    ProbeName,
    ProbeBattery,
}

impl From<YummlyReadKind> for yummly::YummlyRead {
    fn from(kind: YummlyReadKind) -> Self {
        match kind {
            YummlyReadKind::DockFirmware => Self::DockFirmware,
            YummlyReadKind::DockBattery => Self::DockBattery,
            YummlyReadKind::ProbeMac => Self::ProbeMac,
            YummlyReadKind::ProbeName => Self::ProbeName,
            YummlyReadKind::ProbeBattery => Self::ProbeBattery,
        }
    }
}

pub fn yummly_encode_challenge_reply(selector: u8) -> anyhow::Result<Vec<u8>> {
    Ok(yummly::encode_challenge_reply(selector)?)
}

pub fn yummly_encode_read(
    kind: YummlyReadKind,
    probe_address_reversed: Option<Vec<u8>>,
) -> anyhow::Result<Vec<u8>> {
    Ok(yummly::encode_read(
        kind.into(),
        probe_address_reversed.as_deref(),
    )?)
}

pub fn yummly_decode_frame(frame: Vec<u8>) -> anyhow::Result<YummlyFrameDto> {
    Ok(yummly::decode_frame(&frame)?)
}

pub fn acinfinity_encode_get_model_data(port: u8, sequence: u16) -> anyhow::Result<Vec<u8>> {
    Ok(acinfinity::encode_get_model_data(port, sequence)?)
}

pub fn acinfinity_decode_status(frame: Vec<u8>) -> anyhow::Result<AcInfinityStatusDto> {
    Ok(acinfinity::decode_status(&frame)?)
}

pub fn acinfinity_decode_model_data(
    frame: Vec<u8>,
    sequence: u16,
    port: u8,
) -> anyhow::Result<AcInfinityStoredDto> {
    Ok(acinfinity::decode_model_data(&frame, sequence, port)?)
}

pub fn acinfinity_feed(
    frame_buffer: Vec<u8>,
    status_buffer: Vec<u8>,
    chunk: Vec<u8>,
) -> AcInfinityFeedDto {
    acinfinity::feed(&frame_buffer, &status_buffer, &chunk)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn spec_text(file: &str) -> String {
        std::fs::read_to_string(format!(
            "{}/../vendor/protocol-specs/device-specs/devices/{file}",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap()
    }

    #[test]
    fn each_read_only_spec_names_its_surface() {
        let solar = read_only_surface(spec_text("solaredge-modbus-tcp.yaml"))
            .unwrap()
            .unwrap();
        assert_eq!(solar.handler, "modbus_tcp_sunspec");
        assert_eq!(solar.default_port, Some(1502));
        assert!(solar.safety_advisory.is_some());
        let refused = solar
            .commands
            .iter()
            .find(|c| c.name == "set_active_power_limit")
            .unwrap();
        assert!(!refused.sent);

        let yummly = read_only_surface(spec_text("yummly-smart-thermometer.yaml"))
            .unwrap()
            .unwrap();
        assert_eq!(yummly.handler, "yummly_xw2_tlv");
        assert!(yummly.safety_advisory.is_some());

        let acinfinity = read_only_surface(spec_text("acinfinity-uis-controller.yaml"))
            .unwrap()
            .unwrap();
        assert_eq!(acinfinity.handler, "acinfinity_a5");
        assert!(acinfinity.safety_advisory.is_some());
    }

    #[test]
    fn a_spec_under_another_handler_has_no_read_only_surface() {
        assert!(read_only_surface(spec_text("tplink-kasa-smart-plug.yaml"))
            .unwrap()
            .is_none());
    }
}

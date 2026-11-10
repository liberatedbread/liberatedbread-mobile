// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! The HT-W01 thermal camera's command-channel bridge. Every frame is built
//! by a named function for one setting the app offers; nothing here takes a
//! command type, an action id or a raw parameter id. See
//! [`crate::protocol::ht_w01`].

use crate::protocol::ht_w01;

pub use crate::protocol::ht_w01::{HtW01Param, HtW01Range, HtW01ReplyDto, HtW01SplitDto};
pub use crate::protocol::readonly::ReadOnlyCommandDto;

/// One palette the camera offers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HtW01PaletteDto {
    pub value: u8,
    pub name: String,
}

/// Every command the spec declares, and whether this app sends it.
pub fn ht_w01_command_policy(spec_yaml: String) -> anyhow::Result<Vec<ReadOnlyCommandDto>> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    Ok(ht_w01::command_policy(&spec))
}

#[flutter_rust_bridge::frb(sync)]
pub fn ht_w01_palettes() -> Vec<HtW01PaletteDto> {
    ht_w01::PALETTES
        .iter()
        .map(|(value, name)| HtW01PaletteDto {
            value: *value,
            name: name.to_string(),
        })
        .collect()
}

#[flutter_rust_bridge::frb(sync)]
pub fn ht_w01_heartbeat(counter: u8) -> Vec<u8> {
    ht_w01::heartbeat(counter)
}

#[flutter_rust_bridge::frb(sync)]
pub fn ht_w01_get(param: HtW01Param) -> Vec<u8> {
    ht_w01::get_param(param)
}

#[flutter_rust_bridge::frb(sync)]
pub fn ht_w01_set_palette(value: u8) -> anyhow::Result<Vec<u8>> {
    Ok(ht_w01::set_palette(value)?)
}

#[flutter_rust_bridge::frb(sync)]
pub fn ht_w01_set_measuring_range(range: HtW01Range) -> Vec<u8> {
    ht_w01::set_measuring_range(range)
}

#[flutter_rust_bridge::frb(sync)]
pub fn ht_w01_set_emissivity(hundredths: u8) -> anyhow::Result<Vec<u8>> {
    Ok(ht_w01::set_emissivity(hundredths)?)
}

#[flutter_rust_bridge::frb(sync)]
pub fn ht_w01_refresh_shutter() -> Vec<u8> {
    ht_w01::refresh_shutter()
}

#[flutter_rust_bridge::frb(sync)]
pub fn ht_w01_split_stream(buffer: Vec<u8>) -> HtW01SplitDto {
    ht_w01::split_stream(&buffer)
}

/// A one-byte value from a GET reply, or `None` when the reply is not
/// `[parameter id, value]` (the reply layout is not recovered).
#[flutter_rust_bridge::frb(sync)]
pub fn ht_w01_reply_value(reply: HtW01ReplyDto, param: HtW01Param) -> Option<u8> {
    ht_w01::reply_value(&reply, param)
}

#[flutter_rust_bridge::frb(sync)]
pub fn ht_w01_status_meaning(code: u8) -> String {
    ht_w01::status_meaning(code).to_string()
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Radio programming, exposed to Flutter via flutter_rust_bridge.
//!
//! Every function here is pure: bytes in, bytes out. Rust decides what to
//! send and what a reply means; Dart owns the GATT tunnel and the timing.
//! That is the house split, and it is also what lets a whole programming
//! session be tested against an emulated peripheral with no radio present.

use crate::protocol::radio::codeplug::{self, ChannelRecord, Tone};
use crate::protocol::radio::models::{self, RadioModel};
use crate::protocol::radio::uv17pro;

// ── DTOs ────────────────────────────────────────────────────────────────────

/// A radio this codec can program.
#[derive(Debug, Clone)]
pub struct RadioModelDto {
    pub id: String,
    pub display_name: String,
    /// The 16-byte string that puts the radio into programming mode.
    pub ident_magic: Vec<u8>,
    pub image_len: u32,
    pub channel_count: u16,
    pub name_len: u32,
}

/// One block of a read or a write.
#[derive(Debug, Clone)]
pub struct CodeplugBlockDto {
    /// Address on the radio.
    pub addr: u16,
    /// Offset into the flat image.
    pub image_offset: u32,
    pub len: u8,
}

/// A step of the post-ident handshake.
#[derive(Debug, Clone)]
pub struct HandshakeStepDto {
    pub request: Vec<u8>,
    /// How many bytes the reply is. Dart reads exactly this many rather than
    /// guessing when the radio has finished talking.
    pub expected_reply_len: u32,
}

/// How a channel squelches, flattened for the boundary.
///
/// A tagged struct rather than a Rust enum with payloads: FRB renders those
/// as sealed classes that the Dart side then has to pattern-match, and this
/// crosses the boundary in both directions on every channel.
#[derive(Debug, Clone)]
pub struct ToneDto {
    /// "none", "ctcss" or "dcs".
    pub mode: String,
    /// CTCSS in tenths of a hertz.
    pub ctcss_tenth_hz: u16,
    pub dcs_code: u16,
    pub dcs_inverted: bool,
}

impl ToneDto {
    fn none() -> Self {
        Self {
            mode: "none".to_string(),
            ctcss_tenth_hz: 0,
            dcs_code: 0,
            dcs_inverted: false,
        }
    }

    fn from_tone(tone: Tone) -> Self {
        match tone {
            Tone::None => Self::none(),
            Tone::Ctcss(tenths) => Self {
                mode: "ctcss".to_string(),
                ctcss_tenth_hz: tenths,
                dcs_code: 0,
                dcs_inverted: false,
            },
            Tone::Dcs { code, inverted } => Self {
                mode: "dcs".to_string(),
                ctcss_tenth_hz: 0,
                dcs_code: code,
                dcs_inverted: inverted,
            },
        }
    }

    fn to_tone(&self) -> Tone {
        match self.mode.as_str() {
            "ctcss" => Tone::Ctcss(self.ctcss_tenth_hz),
            "dcs" => Tone::Dcs {
                code: self.dcs_code,
                inverted: self.dcs_inverted,
            },
            _ => Tone::None,
        }
    }
}

/// One memory channel.
#[derive(Debug, Clone)]
pub struct RadioChannelDto {
    /// Slot number, from 1, as the radio counts them.
    pub slot: u16,
    pub name: String,
    pub rx_freq_hz: u32,
    pub tx_freq_hz: u32,
    pub rx_only: bool,
    pub tx_tone: ToneDto,
    pub rx_tone: ToneDto,
    pub narrow: bool,
    pub low_power: bool,
    pub skip: bool,
}

impl RadioChannelDto {
    fn to_channel(&self) -> ChannelRecord {
        ChannelRecord {
            name: self.name.clone(),
            rx_freq_hz: self.rx_freq_hz,
            tx_freq_hz: self.tx_freq_hz,
            rx_only: self.rx_only,
            tx_tone: self.tx_tone.to_tone(),
            rx_tone: self.rx_tone.to_tone(),
            narrow: self.narrow,
            low_power: self.low_power,
            skip: self.skip,
        }
    }

    fn from_channel(slot: u16, channel: &ChannelRecord) -> Self {
        Self {
            slot,
            name: channel.name.clone(),
            rx_freq_hz: channel.rx_freq_hz,
            tx_freq_hz: channel.tx_freq_hz,
            rx_only: channel.rx_only,
            tx_tone: ToneDto::from_tone(channel.tx_tone),
            rx_tone: ToneDto::from_tone(channel.rx_tone),
            narrow: channel.narrow,
            low_power: channel.low_power,
            skip: channel.skip,
        }
    }
}

fn model_or_error(model_id: &str) -> anyhow::Result<&'static RadioModel> {
    models::model_by_id(model_id)
        .ok_or_else(|| anyhow::anyhow!("no radio model with id '{model_id}'"))
}

// ── The API ─────────────────────────────────────────────────────────────────

/// Every radio this codec can program.
pub fn radio_models() -> Vec<RadioModelDto> {
    models::MODELS
        .iter()
        .map(|model| RadioModelDto {
            id: model.id.to_string(),
            display_name: model.display_name.to_string(),
            ident_magic: model.ident_magic.to_vec(),
            image_len: model.image_len,
            channel_count: model.channel_count,
            name_len: model.name_len as u32,
        })
        .collect()
}

/// The string that puts this radio into programming mode.
pub fn radio_ident_magic(model_id: String) -> anyhow::Result<Vec<u8>> {
    Ok(model_or_error(&model_id)?.ident_magic.to_vec())
}

/// The byte the radio answers a good command with.
pub fn radio_ack_byte() -> u8 {
    uv17pro::ACK
}

/// The handshake to run once the ident magic has been acknowledged.
pub fn radio_handshake_steps() -> Vec<HandshakeStepDto> {
    uv17pro::handshake_steps()
        .iter()
        .map(|step| HandshakeStepDto {
            request: step.request.to_vec(),
            expected_reply_len: step.expected_reply_len as u32,
        })
        .collect()
}

/// Every block of a full read, in order.
pub fn radio_read_plan(model_id: String) -> anyhow::Result<Vec<CodeplugBlockDto>> {
    let model = model_or_error(&model_id)?;
    Ok(uv17pro::read_plan(model.regions, uv17pro::BLOCK_SIZE)
        .into_iter()
        .map(|block| CodeplugBlockDto {
            addr: block.addr,
            image_offset: block.image_offset,
            len: block.len,
        })
        .collect())
}

/// Every block of a full write, in order.
///
/// `block_size` is a parameter because the radio's own Bluetooth takes
/// 0x80-byte writes while a cable takes 0x40 -- one codec, two callers.
pub fn radio_write_plan(
    model_id: String,
    block_size: u16,
) -> anyhow::Result<Vec<CodeplugBlockDto>> {
    let model = model_or_error(&model_id)?;
    if block_size == 0 || block_size > 0xFF {
        anyhow::bail!("block size {block_size} does not fit a one-byte length");
    }
    Ok(uv17pro::read_plan(model.regions, block_size)
        .into_iter()
        .map(|block| CodeplugBlockDto {
            addr: block.addr,
            image_offset: block.image_offset,
            len: block.len,
        })
        .collect())
}

/// The write block size the radio's own Bluetooth expects.
pub fn radio_ble_write_block_size() -> u16 {
    uv17pro::BLE_WRITE_BLOCK_SIZE
}

/// The request that reads `len` bytes from `addr`.
pub fn radio_read_command(addr: u16, len: u8) -> Vec<u8> {
    uv17pro::read_command(addr, len)
}

/// How many bytes that read will answer with, header included.
///
/// Over Bluetooth the reply arrives in ~20-byte notifications; this is how
/// the Dart side tells "still arriving" from "done".
pub fn radio_expected_reply_len(len: u8) -> u32 {
    uv17pro::expected_read_reply_len(len) as u32
}

/// The payload of a read reply, substitution undone and header checked.
pub fn radio_parse_read_reply(reply: Vec<u8>, addr: u16, len: u8) -> anyhow::Result<Vec<u8>> {
    Ok(uv17pro::parse_read_reply(
        &reply,
        addr,
        len,
        uv17pro::DEFAULT_SYMBOL_INDEX,
    )?)
}

/// The request that writes `data` to `addr`.
pub fn radio_write_command(addr: u16, data: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(uv17pro::write_command(
        addr,
        &data,
        uv17pro::DEFAULT_SYMBOL_INDEX,
    )?)
}

/// Whether a reply is the radio's acknowledgement.
pub fn radio_is_ack(reply: Vec<u8>) -> bool {
    uv17pro::is_ack(&reply)
}

/// The channels in a codeplug image. Empty slots are omitted; each channel
/// carries the slot it came from.
pub fn radio_decode_channels(
    image: Vec<u8>,
    model_id: String,
) -> anyhow::Result<Vec<RadioChannelDto>> {
    let model = model_or_error(&model_id)?;
    Ok(codeplug::decode_channels(&image, model)?
        .into_iter()
        .enumerate()
        .filter_map(|(index, channel)| {
            channel.map(|c| RadioChannelDto::from_channel(index as u16 + 1, &c))
        })
        .collect())
}

/// A copy of `image` with `channels` written from slot 1 up and the rest of
/// the slots cleared.
///
/// Everything outside the channel records survives: the settings, the DTMF
/// codes, the parts of each record this codec does not model.
pub fn radio_encode_channels(
    image: Vec<u8>,
    channels: Vec<RadioChannelDto>,
    model_id: String,
) -> anyhow::Result<Vec<u8>> {
    let model = model_or_error(&model_id)?;
    let decoded: Vec<ChannelRecord> = channels.iter().map(|c| c.to_channel()).collect();
    Ok(codeplug::encode_channels(&image, &decoded, model)?)
}

/// Whether an image is the size this model reads back.
///
/// Checked before a write, because an image of the wrong length means the
/// read that produced it was cut short, and writing it back would leave the
/// radio holding half a codeplug.
pub fn radio_image_is_complete(image_len: u32, model_id: String) -> anyhow::Result<bool> {
    Ok(image_len == model_or_error(&model_id)?.image_len)
}

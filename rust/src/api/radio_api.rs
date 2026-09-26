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
use crate::protocol::radio::uv5r::{self, BandLimit, BandLimits, LimitLayout, Uv5rModel};
use crate::protocol::radio::{self as radio, Block};

// ── DTOs ────────────────────────────────────────────────────────────────────

/// A radio these codecs can program, of either family: what the Dart
/// profile of the same id has to agree with.
#[derive(Debug, Clone)]
pub struct RadioModelDto {
    pub id: String,
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

fn block_dtos(blocks: Vec<Block>) -> Vec<CodeplugBlockDto> {
    blocks
        .into_iter()
        .map(|block| CodeplugBlockDto {
            addr: block.addr,
            image_offset: block.image_offset as u32,
            len: block.len,
        })
        .collect()
}

// ── The API ─────────────────────────────────────────────────────────────────

/// Every radio these codecs can program, both families.
///
/// Exists for one reason: a test that holds it against the Dart profiles, so
/// a capacity or a name length that drifts between the two tables fails
/// there rather than as a plan cut short or a codeplug overrun.
pub fn radio_models() -> Vec<RadioModelDto> {
    let newer = models::MODELS.iter().map(|model| RadioModelDto {
        id: model.id.to_string(),
        image_len: model.image_len,
        channel_count: model.channel_count,
        name_len: models::NAME_LEN as u32,
    });
    let older = uv5r::MODELS.iter().map(|model| RadioModelDto {
        id: model.id.to_string(),
        image_len: uv5r::IMAGE_LEN as u32,
        channel_count: uv5r::CHANNEL_COUNT as u16,
        name_len: uv5r::NAME_LEN as u32,
    });
    newer.chain(older).collect()
}

/// The string that puts this radio into programming mode.
pub fn radio_ident_magic(model_id: String) -> anyhow::Result<Vec<u8>> {
    Ok(model_or_error(&model_id)?.ident_magic.to_vec())
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
    Ok(block_dtos(uv17pro::read_plan(
        model.regions,
        uv17pro::BLOCK_SIZE,
    )))
}

/// Every block of a full write over the radio's own Bluetooth, in order.
///
/// Bigger blocks than a read: the tunnel re-blocks uploads to 0x80. Over a
/// cable this family writes 0x40, which is what this would take as a
/// parameter the day there is a cable driver for it.
pub fn radio_write_plan(model_id: String) -> anyhow::Result<Vec<CodeplugBlockDto>> {
    let model = model_or_error(&model_id)?;
    Ok(block_dtos(uv17pro::read_plan(
        model.regions,
        uv17pro::BLE_WRITE_BLOCK_SIZE,
    )))
}

/// The request that reads `len` bytes from `addr`.
pub fn radio_read_command(addr: u16, len: u8) -> Vec<u8> {
    uv17pro::read_command(addr, len)
}

/// How many bytes a read of `len` answers with, header included -- in
/// either family, whose answers share their framing. Not counting the older
/// family's leading acknowledgement, which is not part of the answer.
pub fn radio_read_reply_len(len: u8) -> u32 {
    radio::read_reply_len(len) as u32
}

/// The payload of a read reply, substitution undone and header checked.
pub fn radio_parse_read_reply(reply: Vec<u8>, addr: u16, len: u8) -> anyhow::Result<Vec<u8>> {
    Ok(uv17pro::parse_read_reply(&reply, addr, len)?)
}

/// The request that writes `data` to `addr`.
pub fn radio_write_command(addr: u16, data: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(uv17pro::write_command(addr, &data)?)
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

// ── The UV-5R family, over a cable ──────────────────────────────────────────
//
// The older serial family has a conversation of its own, so it has functions
// of its own rather than a flag on the ones above. The shape is the same:
// Rust says what to send and what an answer means, Dart owns the port and the
// timing. See `protocol::radio::uv5r` for the conversation itself.

/// A read that is not part of the image: made, checked, and set aside.
#[derive(Debug, Clone)]
pub struct ReadRequestDto {
    pub addr: u16,
    pub len: u8,
}

/// What the reads after the ident found out about the radio.
#[derive(Debug, Clone)]
pub struct Uv5rProbeDto {
    pub firmware: String,
    /// Read the end of the aux block sixteen bytes at a time.
    pub drops_byte: bool,
}

/// One band's transmit limits, in whole megahertz.
#[derive(Debug, Clone)]
pub struct BandLimitDto {
    pub tx_enabled: bool,
    pub lower_mhz: u16,
    pub upper_mhz: u16,
}

/// Both bands' transmit limits, and which layout they were read from.
#[derive(Debug, Clone)]
pub struct BandLimitsDto {
    pub vhf: BandLimitDto,
    pub uhf: BandLimitDto,
    /// "old" or "new" -- informational; writes work it out again from the
    /// image rather than trusting a value that crossed the boundary.
    pub layout: String,
}

impl BandLimitDto {
    fn from_limit(limit: BandLimit) -> Self {
        Self {
            tx_enabled: limit.tx_enabled,
            lower_mhz: limit.lower_mhz,
            upper_mhz: limit.upper_mhz,
        }
    }

    fn to_limit(&self) -> BandLimit {
        BandLimit {
            tx_enabled: self.tx_enabled,
            lower_mhz: self.lower_mhz,
            upper_mhz: self.upper_mhz,
        }
    }
}

fn uv5r_model_or_error(model_id: &str) -> anyhow::Result<&'static Uv5rModel> {
    uv5r::model_by_id(model_id)
        .ok_or_else(|| anyhow::anyhow!("no UV-5R-family radio called {model_id:?}"))
}

/// The layout `image`'s limits live in, for the radio `model_id` names.
fn uv5r_layout(image: &[u8], model_id: &str) -> anyhow::Result<LimitLayout> {
    Ok(uv5r::limit_layout(image, uv5r_model_or_error(model_id)?)?)
}

/// The ident magics to try for this radio, in order.
pub fn uv5r_ident_magics(model_id: String) -> anyhow::Result<Vec<Vec<u8>>> {
    Ok(uv5r_model_or_error(&model_id)?
        .idents
        .iter()
        .map(|magic| magic.to_vec())
        .collect())
}

pub fn uv5r_baud_rate() -> u32 {
    uv5r::BAUD_RATE
}

/// The byte that asks an acknowledged radio for its ident.
pub fn uv5r_ident_request() -> u8 {
    uv5r::IDENT_REQUEST
}

/// Whether the ident read so far is all of it.
pub fn uv5r_ident_reply_complete(reply: Vec<u8>) -> bool {
    uv5r::ident_reply_complete(&reply)
}

/// The eight-byte ident, from however the radio sent it.
pub fn uv5r_parse_ident(reply: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(uv5r::parse_ident(&reply)?.to_vec())
}

/// The reads made right after the ident, before the image is read.
///
/// The first is the session's first command, answered without a leading
/// acknowledgement; every later answer has one.
pub fn uv5r_probe_reads() -> Vec<ReadRequestDto> {
    uv5r::PROBE_READS
        .iter()
        .map(|&(addr, len)| ReadRequestDto { addr, len })
        .collect()
}

/// What the second and third probe reads say.
pub fn uv5r_parse_probe(
    firmware_block: Vec<u8>,
    drop_block: Vec<u8>,
) -> anyhow::Result<Uv5rProbeDto> {
    let probe = uv5r::parse_probe(&firmware_block, &drop_block)?;
    Ok(Uv5rProbeDto {
        firmware: probe.firmware,
        drops_byte: probe.drops_byte,
    })
}

/// Every read of the image after the probe, in image order. The session's
/// eight ident bytes come first in the image; these fill the rest.
pub fn uv5r_read_plan(drops_byte: bool) -> Vec<CodeplugBlockDto> {
    block_dtos(uv5r::read_plan(drops_byte))
}

pub fn uv5r_image_len() -> u32 {
    uv5r::IMAGE_LEN as u32
}

pub fn uv5r_read_command(addr: u16, len: u8) -> Vec<u8> {
    uv5r::read_command(addr, len).to_vec()
}

pub fn uv5r_parse_read_reply(reply: Vec<u8>, addr: u16, len: u8) -> anyhow::Result<Vec<u8>> {
    Ok(uv5r::parse_read_reply(&reply, addr, len)?)
}

pub fn uv5r_write_command(addr: u16, data: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(uv5r::write_command(addr, &data)?)
}

/// The firmware string an image carries.
pub fn uv5r_firmware(image: Vec<u8>) -> anyhow::Result<String> {
    Ok(uv5r::firmware(&image)?)
}

/// The channels in an image. Empty slots are omitted; each channel carries
/// the slot it came from.
pub fn uv5r_decode_channels(
    image: Vec<u8>,
    model_id: String,
) -> anyhow::Result<Vec<RadioChannelDto>> {
    uv5r_model_or_error(&model_id)?;
    Ok(uv5r::decode_channels(&image)?
        .into_iter()
        .enumerate()
        .filter_map(|(index, channel)| {
            channel.map(|c| RadioChannelDto::from_channel(index as u16 + 1, &c))
        })
        .collect())
}

/// A copy of `image` with `channels` from slot 1 up and every later slot
/// cleared, keeping what the app does not model.
pub fn uv5r_encode_channels(
    image: Vec<u8>,
    channels: Vec<RadioChannelDto>,
    model_id: String,
) -> anyhow::Result<Vec<u8>> {
    let model = uv5r_model_or_error(&model_id)?;
    let decoded: Vec<ChannelRecord> = channels.iter().map(|c| c.to_channel()).collect();
    Ok(uv5r::encode_channels(&image, &decoded, model)?)
}

/// The blocks to write to turn the radio from `base` into `updated`: only
/// those that differ, and an error if any of them is somewhere this app never
/// writes.
pub fn uv5r_changed_blocks(
    base: Vec<u8>,
    updated: Vec<u8>,
    model_id: String,
) -> anyhow::Result<Vec<CodeplugBlockDto>> {
    let layout = uv5r_layout(&base, &model_id)?;
    Ok(block_dtos(uv5r::changed_blocks(&base, &updated, layout)?))
}

/// The reads that check `changed` landed: whole blocks, each read once.
pub fn uv5r_verify_plan(
    changed: Vec<CodeplugBlockDto>,
    drops_byte: bool,
) -> anyhow::Result<Vec<CodeplugBlockDto>> {
    let blocks = changed
        .iter()
        .map(|dto| {
            uv5r::image_offset(dto.addr)
                .map(|image_offset| Block {
                    addr: dto.addr,
                    len: dto.len,
                    image_offset,
                })
                .ok_or_else(|| anyhow::anyhow!("0x{:04X} is not in the image", dto.addr))
        })
        .collect::<anyhow::Result<Vec<_>>>()?;
    Ok(block_dtos(uv5r::verify_plan(&blocks, drops_byte)))
}

/// Every block a full restore of `image` writes.
pub fn uv5r_restore_plan(
    image: Vec<u8>,
    model_id: String,
) -> anyhow::Result<Vec<CodeplugBlockDto>> {
    Ok(block_dtos(uv5r::restore_plan(uv5r_layout(
        &image, &model_id,
    )?)))
}

/// The transmit limits an image holds, read from whichever layout the
/// radio's firmware uses.
pub fn uv5r_read_band_limits(image: Vec<u8>, model_id: String) -> anyhow::Result<BandLimitsDto> {
    let layout = uv5r_layout(&image, &model_id)?;
    let limits = uv5r::read_band_limits(&image, layout)?;
    Ok(BandLimitsDto {
        vhf: BandLimitDto::from_limit(limits.vhf),
        uhf: BandLimitDto::from_limit(limits.uhf),
        layout: match layout {
            LimitLayout::Old => "old",
            LimitLayout::New => "new",
        }
        .to_string(),
    })
}

/// A copy of `image` with `limits` written, and nothing else changed.
pub fn uv5r_apply_band_limits(
    image: Vec<u8>,
    limits: BandLimitsDto,
    model_id: String,
) -> anyhow::Result<Vec<u8>> {
    let layout = uv5r_layout(&image, &model_id)?;
    Ok(uv5r::apply_band_limits(
        &image,
        &BandLimits {
            vhf: limits.vhf.to_limit(),
            uhf: limits.uhf.to_limit(),
        },
        layout,
    )?)
}

#[cfg(test)]
mod tests {
    //! The bridge's own work: the DTOs, the model lookups and what crosses
    //! as a string. The codecs behind it have their tests in
    //! `protocol::radio`, and the round trip through the real library is
    //! Dart's `radio_api_test.dart`.
    use super::*;
    use crate::protocol::radio::uv5r::image_with_firmware;

    fn dto(slot: u16, name: &str, hz: u32) -> RadioChannelDto {
        RadioChannelDto {
            slot,
            name: name.to_string(),
            rx_freq_hz: hz,
            tx_freq_hz: hz,
            rx_only: false,
            tx_tone: ToneDto::none(),
            rx_tone: ToneDto::none(),
            narrow: false,
            low_power: false,
            skip: false,
        }
    }

    #[test]
    fn the_model_table_covers_both_families() {
        let ids: Vec<String> = radio_models().into_iter().map(|m| m.id).collect();
        for id in [
            "uv-5r-mini",
            "uv-5g-mini",
            "uv-32",
            "uv5r",
            "bf-f8hp",
            "ar-152",
        ] {
            assert!(ids.iter().any(|i| i == id), "{id} missing from {ids:?}");
        }
        assert!(
            !ids.iter().any(|i| i == "uv-5g"),
            "its memory is not a UV-5R's"
        );
        assert!(uv5r_ident_magics("uv-5g".into()).is_err());
        assert_eq!(uv5r_ident_magics("uv5r".into()).unwrap().len(), 3);
    }

    #[test]
    fn uv5r_channels_cross_the_boundary_and_back() {
        let written = uv5r_encode_channels(
            image_with_firmware("BFB297"),
            vec![dto(1, "ONE", 146_520_000), dto(2, "TWO", 446_000_000)],
            "uv5r".into(),
        )
        .unwrap();
        let read = uv5r_decode_channels(written, "uv5r".into()).unwrap();
        assert_eq!(read.len(), 2);
        assert_eq!(read[1].slot, 2);
        assert_eq!(read[1].name, "TWO");
        assert_eq!(read[1].rx_freq_hz, 446_000_000);
    }

    #[test]
    fn uv5r_band_limits_name_the_layout_the_firmware_implies() {
        for (firmware, layout) in [("BFB290", "old"), ("BFB297", "new")] {
            let applied = uv5r_apply_band_limits(
                image_with_firmware(firmware),
                BandLimitsDto {
                    vhf: BandLimitDto {
                        tx_enabled: true,
                        lower_mhz: 130,
                        upper_mhz: 180,
                    },
                    uhf: BandLimitDto {
                        tx_enabled: true,
                        lower_mhz: 400,
                        upper_mhz: 520,
                    },
                    layout: "ignored".into(),
                },
                "uv5r".into(),
            )
            .unwrap();
            let limits = uv5r_read_band_limits(applied, "uv5r".into()).unwrap();
            assert_eq!(limits.layout, layout);
            assert_eq!((limits.vhf.lower_mhz, limits.vhf.upper_mhz), (130, 180));
            assert_eq!((limits.uhf.lower_mhz, limits.uhf.upper_mhz), (400, 520));
        }
    }

    #[test]
    fn uv5r_verify_plan_crosses_and_refuses_addresses_outside_the_image() {
        let changed = vec![CodeplugBlockDto {
            addr: 0x0010,
            image_offset: 0x18,
            len: 0x10,
        }];
        let plan = uv5r_verify_plan(changed, false).unwrap();
        assert_eq!(
            (plan[0].addr, plan[0].len, plan[0].image_offset),
            (0x0000, 0x40, 8)
        );
        let outside = vec![CodeplugBlockDto {
            addr: 0x1E80,
            image_offset: 0,
            len: 0x10,
        }];
        assert!(uv5r_verify_plan(outside, false).is_err());
    }
}

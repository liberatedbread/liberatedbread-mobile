// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Radio programming, exposed to Flutter via flutter_rust_bridge.
//!
//! Every function here is pure: bytes in, bytes out. Rust decides what to
//! send and what a reply means; Dart owns the GATT tunnel and the timing.
//! That is the house split, and it is also what lets a whole programming
//! session be tested against an emulated peripheral with no radio present.

use crate::protocol::radio::codeplug::{self, ChannelRecord, Power, Tone};
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
    /// The transmit power levels the radio has, as [`RadioChannelDto::power`]
    /// names them, in the order its records index them.
    pub power_levels: Vec<String>,
}

/// A power level's name at the boundary.
fn power_name(power: Power) -> String {
    match power {
        Power::High => "high",
        Power::Medium => "medium",
        Power::Low => "low",
    }
    .to_string()
}

/// A power level from its name. Anything else is refused rather than
/// guessed: a guess here is a transmit power nobody chose.
fn power_from_name(name: &str) -> anyhow::Result<Power> {
    match name {
        "high" => Ok(Power::High),
        "medium" => Ok(Power::Medium),
        "low" => Ok(Power::Low),
        other => Err(anyhow::anyhow!("{other:?} is not a power level")),
    }
}

fn power_names(levels: &[Power]) -> Vec<String> {
    levels.iter().map(|&p| power_name(p)).collect()
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
    /// "high", "medium" or "low". A name rather than the record's index,
    /// because the index means different levels on different radios, and a
    /// name rather than a low-power flag, because a flag cannot say medium.
    /// A level the radio lacks is written as the nearest one below it.
    pub power: String,
    pub skip: bool,
    /// The record's own power index when the channel was read from a radio,
    /// written back while `power` still reads from it -- so a UV-82HP's Low
    /// (2, behind a two-level profile that lists Low as 1) is not rewritten
    /// as its Med. Absent for a channel made or re-levelled in the app.
    pub power_raw: Option<u8>,
}

impl RadioChannelDto {
    fn to_channel(&self) -> anyhow::Result<ChannelRecord> {
        Ok(ChannelRecord {
            name: self.name.clone(),
            rx_freq_hz: self.rx_freq_hz,
            tx_freq_hz: self.tx_freq_hz,
            rx_only: self.rx_only,
            tx_tone: self.tx_tone.to_tone(),
            rx_tone: self.rx_tone.to_tone(),
            narrow: self.narrow,
            power: power_from_name(&self.power)?,
            skip: self.skip,
            power_raw: self.power_raw,
        })
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
            power: power_name(channel.power),
            skip: channel.skip,
            power_raw: channel.power_raw,
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
        power_levels: power_names(model.power_levels),
    });
    let older = uv5r::MODELS.iter().map(|model| RadioModelDto {
        id: model.id.to_string(),
        image_len: uv5r::IMAGE_LEN as u32,
        channel_count: uv5r::CHANNEL_COUNT as u16,
        name_len: uv5r::NAME_LEN as u32,
        power_levels: power_names(model.power_levels),
    });
    newer.chain(older).collect()
}

/// The strings that put this radio into programming mode, in the order to
/// try them. More than one where firmware versions differ (the UV-5G Mini);
/// a radio ignores a string it does not answer to, so the caller tries the
/// next one after silence.
pub fn radio_ident_magics(model_id: String) -> anyhow::Result<Vec<Vec<u8>>> {
    Ok(model_or_error(&model_id)?
        .idents
        .iter()
        .map(|ident| ident.to_vec())
        .collect())
}

/// The handshake to run once this model's ident has been acknowledged.
///
/// Per model: the UV-32 answers `M` with 7 bytes where the Minis send 15,
/// and reading the wrong count either stalls or slips the conversation.
pub fn radio_handshake_steps(model_id: String) -> anyhow::Result<Vec<HandshakeStepDto>> {
    Ok(model_or_error(&model_id)?
        .handshake
        .iter()
        .map(|step| HandshakeStepDto {
            request: step.request.to_vec(),
            expected_reply_len: step.expected_reply_len as u32,
        })
        .collect())
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
///
/// An error, before anything is sent, for a model whose Bluetooth write
/// frame nobody has seen: the padded frames overwrite memory past each
/// region's end, which is known harmless only where CHIRP does the same.
/// See [`RadioModel::ble_write_frame`].
pub fn radio_write_plan(model_id: String) -> anyhow::Result<Vec<CodeplugBlockDto>> {
    let model = model_or_error(&model_id)?;
    let frame = model.ble_write_frame.ok_or_else(|| {
        anyhow::anyhow!(
            "Writing a {} over Bluetooth is turned off until someone captures \
             what it accepts: the way the Minis are written would overwrite \
             memory this app never read. Nothing was written.",
            model.display_name
        )
    })?;
    // `radio_write_command` sends one frame size; a plan cut to another
    // would have its blocks padded or refused mid-write.
    if frame != uv17pro::BLE_WRITE_BLOCK_SIZE {
        anyhow::bail!("no write command for 0x{frame:02X}-byte frames");
    }
    Ok(block_dtos(uv17pro::read_plan(model.regions, frame)))
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

/// The request that writes `data` to `addr` over the radio's own Bluetooth.
///
/// Always a 0x80-byte frame: a block of the write plan shorter than that (the
/// end of a region) is padded with 0xFF and still says 0x80, because a short
/// write frame over the tunnel is never acked. `data` longer than 0x80 is an
/// error.
pub fn radio_write_command(addr: u16, data: Vec<u8>) -> anyhow::Result<Vec<u8>> {
    Ok(uv17pro::write_command(
        addr,
        &data,
        uv17pro::BLE_WRITE_BLOCK_SIZE,
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
    let decoded = channels
        .iter()
        .map(RadioChannelDto::to_channel)
        .collect::<anyhow::Result<Vec<ChannelRecord>>>()?;
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
    let model = uv5r_model_or_error(&model_id)?;
    Ok(uv5r::decode_channels(&image, model)?
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
    let decoded = channels
        .iter()
        .map(RadioChannelDto::to_channel)
        .collect::<anyhow::Result<Vec<ChannelRecord>>>()?;
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
            power: "high".into(),
            skip: false,
            power_raw: None,
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
    fn the_handshake_and_idents_are_the_models_own() {
        let m_len = |id: &str| radio_handshake_steps(id.into()).unwrap()[1].expected_reply_len;
        assert_eq!(m_len("uv-32"), 7);
        for id in ["uv-5r-mini", "uv-5g-mini", "uv-17r-plus"] {
            assert_eq!(m_len(id), 15, "{id}");
        }
        assert!(radio_handshake_steps("nokia-3310".into()).is_err());

        let magics = radio_ident_magics("uv-5g-mini".into()).unwrap();
        assert_eq!(
            magics,
            vec![b"PROGRAMGMRS5RMIU".to_vec(), b"PROGRAMCOLORPROU".to_vec()]
        );
        assert_eq!(radio_ident_magics("uv-5r-mini".into()).unwrap().len(), 1);
        assert!(radio_ident_magics("nokia-3310".into()).is_err());
    }

    #[test]
    fn a_bluetooth_write_frame_is_always_0x80() {
        // The trailing 0x40 blocks of the Mini's regions went out with a 0x40
        // length byte, which the radio never acks over Bluetooth.
        let frame = radio_write_command(0xA180, vec![0x42; 0x40]).unwrap();
        assert_eq!(&frame[..4], &[0x57, 0xA1, 0x80, 0x80]);
        assert_eq!(frame.len(), 0x84);
        assert!(frame[0x44..].iter().all(|&b| b == 0xFF));
        assert!(radio_write_command(0, vec![0; 0x81]).is_err());
    }

    #[test]
    fn only_models_with_a_known_bluetooth_frame_get_a_write_plan() {
        // The UV-32 was sent the Minis' padded 0x80 frames, writing 0xFF over
        // 0xA2C0-0xA2FF and 0xD040-0xD07F, which nobody reads or backs up.
        for id in ["uv-5r-mini", "uv-5g-mini"] {
            assert!(!radio_write_plan(id.into()).unwrap().is_empty(), "{id}");
        }
        for id in ["uv-32", "uv-17r-plus"] {
            let err = radio_write_plan(id.into()).unwrap_err().to_string();
            assert!(err.contains("Nothing was written"), "{id}: {err}");
        }
    }

    #[test]
    fn power_crosses_the_boundary_by_name() {
        // A low-power flag could not say medium: a UV-32 channel read at
        // Medium came back as "low", and one moved to another slot was
        // written as whatever that slot held.
        let image = vec![0xFFu8; models::UV32.image_len as usize];
        let mut channels = vec![dto(1, "M", 146_520_000), dto(2, "L", 146_540_000)];
        channels[0].power = "medium".into();
        channels[1].power = "low".into();
        let written = radio_encode_channels(image.clone(), channels, "uv-32".into()).unwrap();
        assert_eq!(written[14] & 0x03, 2);
        assert_eq!(written[32 + 14] & 0x03, 1);
        let read = radio_decode_channels(written, "uv-32".into()).unwrap();
        assert_eq!(read[0].power, "medium");
        assert_eq!(read[1].power, "low");

        let mut bad = dto(1, "X", 146_520_000);
        bad.power = "loud".into();
        assert!(radio_encode_channels(image, vec![bad], "uv-32".into()).is_err());

        let levels = |id: &str| {
            radio_models()
                .into_iter()
                .find(|m| m.id == id)
                .unwrap()
                .power_levels
        };
        assert_eq!(levels("uv-32"), ["high", "low", "medium"]);
        assert_eq!(levels("uv-5r-mini"), ["high", "low"]);
        assert_eq!(levels("bf-f8hp"), ["high", "medium", "low"]);
        assert_eq!(levels("uv5r"), ["high", "low"]);
    }

    #[test]
    fn the_raw_power_index_crosses_the_boundary_both_ways() {
        // A UV-82HP-shaped Mini image: Low is 2, which the two-level
        // profile does not list. It reads back as "low" carrying its 2, and
        // a channel carrying the 2 goes back as 2 onto that radio.
        let mut image = vec![0xFFu8; models::UV5R_MINI.image_len as usize];
        let mut low = dto(1, "L", 146_520_000);
        low.power = "low".into();
        low.power_raw = Some(2);
        let channels = vec![dto(1, "H", 146_540_000), low.clone()];

        // Onto a radio none of whose records hold a 2 -- a plan read from a
        // BF-F8HP, whose Low is 2, written to a Mini -- the level is
        // encoded afresh: the Mini's firmware never defined a 2.
        let written =
            radio_encode_channels(image.clone(), channels.clone(), "uv-5r-mini".into()).unwrap();
        assert_eq!(written[32 + 14] & 0x03, 1);

        // The HP's own image holds its 2s, so they are kept.
        image = written;
        image[32 + 14] = (image[32 + 14] & !0x03) | 2;
        let written = radio_encode_channels(image.clone(), channels, "uv-5r-mini".into()).unwrap();
        assert_eq!(written[32 + 14] & 0x03, 2);
        let read = radio_decode_channels(written.clone(), "uv-5r-mini".into()).unwrap();
        assert_eq!(read[1].power, "low");
        assert_eq!(read[1].power_raw, Some(2));
        assert_eq!(read[0].power_raw, Some(0));

        // The first deleted: the Low moves up a slot and keeps its 2.
        let moved =
            radio_encode_channels(written, vec![read[1].clone()], "uv-5r-mini".into()).unwrap();
        assert_eq!(moved[14] & 0x03, 2);

        // Without an index of its own, a Low takes the unlisted Low this
        // image holds (the 2), not the profile's 1 -- see power_bits.
        low.power_raw = None;
        let fresh = radio_encode_channels(image, vec![low], "uv-5r-mini".into()).unwrap();
        assert_eq!(fresh[14] & 0x03, 2);
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

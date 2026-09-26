// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! The older Baofeng serial family: the UV-5R, and the radios that program
//! like it — the BF-F8HP, the UV-82, and the AR-152, which is reported to
//! program as an F8HP.
//!
//! Facts, not code: the conversation and the memory layout below are
//! established from CHIRP's published `chirp/drivers/uv5r.py`, under the same
//! terms as the rest of this module (see [`super`]). Every routine here is
//! written from the description, not translated from that driver. Nothing in
//! this file has been run against a radio.
//!
//! # The conversation
//!
//! 9600 baud, 8N1, and nothing is scrambled. The host sends a seven-byte
//! ident magic, a byte at a time; a radio that recognises it answers 0x06.
//! The host asks for the ident with 0x02 and the radio answers with eight
//! bytes (twelve on some UV-6s, compacted to eight here) ending in 0xDD.
//! One more 0x06 each way and the radio is in clone mode.
//!
//! A read is `S`, a big-endian address and a length. The radio answers `X`,
//! the same address and length, then the data; the host acknowledges every
//! block with 0x06. Every answer after the first is preceded by the radio's
//! own 0x06 — Dart reads that byte, this module never sees it. A write is
//! `X`, address, length and sixteen bytes of data, answered with 0x06.
//!
//! # The image
//!
//! What this module calls an image is the eight ident bytes, then radio
//! memory 0x0000..0x1800, then the auxiliary block 0x1EC0..0x2000: 0x1948
//! bytes. The ident goes first because it says which variant the image came
//! from, and a write can then check it is going back to the same kind of
//! radio.

use super::codeplug::{decode_bcd, decode_tone, encode_bcd, encode_tone, ChannelRecord};
pub use super::Block;
use super::{read_reply_len, REPLY_HEADER_LEN};
use crate::error::ProtocolError;

// ── The conversation ────────────────────────────────────────────────────────

pub const BAUD_RATE: u32 = 9600;

/// Sent after an acknowledged magic, to ask for the ident.
pub const IDENT_REQUEST: u8 = 0x02;

/// The last byte of an ident.
pub const IDENT_END: u8 = 0xDD;

/// The longest ident a radio sends.
pub const IDENT_MAX_REPLY_LEN: usize = 12;

pub const CMD_READ: u8 = b'S';

/// Both the header of a read's answer and a write's command.
pub const CMD_DATA: u8 = b'X';

pub const READ_BLOCK_LEN: u8 = 0x40;

/// Aux reads on the radios that drop a byte from a full-size one.
pub const SMALL_READ_BLOCK_LEN: u8 = 0x10;

/// Every write is this size.
pub const WRITE_BLOCK_LEN: u8 = 0x10;

// ── The image ───────────────────────────────────────────────────────────────

pub const IDENT_LEN: usize = 8;
pub const MAIN_END: u16 = 0x1800;
pub const AUX_START: u16 = 0x1EC0;
pub const AUX_END: u16 = 0x2000;

/// Ident, main memory and the aux block: 0x1948 bytes.
pub const IMAGE_LEN: usize = IDENT_LEN + MAIN_END as usize + (AUX_END - AUX_START) as usize;

pub const CHANNEL_COUNT: usize = 128;
const RECORD_LEN: usize = 16;
const NAMES_ADDR: u16 = 0x1000;
const NAME_SLOT_LEN: usize = 16;

/// The longest channel name the radio shows.
pub const NAME_LEN: usize = 7;

/// The firmware version string, in the aux block.
const FIRMWARE_ADDR: u16 = 0x1EF0;
const FIRMWARE_LEN: usize = 14;

/// A read made outside the aux block before any read inside it. Newer
/// radios answer an aux read made cold with the wrong data.
pub const PRIMING_READ_ADDR: u16 = 0x1E80;

/// The address of the aux block's first 0x40 bytes, which carry the
/// firmware string.
pub const FIRMWARE_BLOCK_ADDR: u16 = AUX_START;

/// The last 0x40 bytes of the aux block, read whole during the probe to see
/// whether this radio drops a byte from them.
pub const DROP_PROBE_ADDR: u16 = 0x1FC0;

/// Where, in a full-size read of [`DROP_PROBE_ADDR`], a radio that drops a
/// byte shows 0xFF: every byte after the dropped one moves up a place.
const DROP_PROBE_INDEX: usize = 15;

/// Main-memory windows never written. Upload tools skip them; so does this.
const MAIN_WRITE_SKIPS: [(u16, u16); 2] = [(0x0CF0, 0x0D00), (0x0DF0, 0x0E00)];

/// Characters the display has. Anything else is written as a space.
const NAME_CHARSET: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZ 1234567890!@#$%^&*()+-=[]:\";'<>?,./";

// ── Models ──────────────────────────────────────────────────────────────────

const MAGIC_291: [u8; 7] = [0x50, 0xBB, 0xFF, 0x20, 0x12, 0x07, 0x25];
const MAGIC_ORIGINAL: [u8; 7] = [0x50, 0xBB, 0xFF, 0x01, 0x25, 0x98, 0x4D];
const MAGIC_UV82: [u8; 7] = [0x50, 0xBB, 0xFF, 0x20, 0x13, 0x01, 0x05];
const MAGIC_A58: [u8; 7] = [0x50, 0xBB, 0xFF, 0x20, 0x14, 0x04, 0x13];

/// A radio of this family.
#[derive(Debug)]
pub struct Uv5rModel {
    /// Matches the Dart profile id, as in [`super::models`].
    pub id: &'static str,

    /// Tried in order. A radio acknowledges one and ignores the rest.
    pub idents: &'static [[u8; 7]],

    /// High, mid and low power, rather than high and low.
    pub tri_power: bool,

    /// Uses the newer band-limit layout whatever its firmware string says.
    pub always_new_limits: bool,
}

/// The UV-5R, which the app's profile also offers for the UV-82 and GT-5R —
/// hence the UV-82's ident in its list.
pub const UV5R: Uv5rModel = Uv5rModel {
    id: "uv5r",
    idents: &[MAGIC_291, MAGIC_ORIGINAL, MAGIC_UV82],
    tri_power: false,
    always_new_limits: false,
};

pub const BF_F8HP: Uv5rModel = Uv5rModel {
    id: "bf-f8hp",
    idents: &[MAGIC_291, MAGIC_A58],
    tri_power: true,
    always_new_limits: true,
};

/// Reported to program exactly as a BF-F8HP. Unconfirmed; the app says so.
pub const AR152: Uv5rModel = Uv5rModel {
    id: "ar-152",
    idents: &[MAGIC_291, MAGIC_A58],
    tri_power: true,
    always_new_limits: true,
};

/// Every model this codec programs.
///
/// Not the UV-5G: its radio answers an ident of its own, and the driver this
/// layout comes from deliberately refuses it — its memory is not a UV-5R's.
/// A profile with no row here cannot be programmed, which is the point.
pub const MODELS: &[Uv5rModel] = &[UV5R, BF_F8HP, AR152];

pub fn model_by_id(id: &str) -> Option<&'static Uv5rModel> {
    MODELS.iter().find(|model| model.id == id)
}

// ── Framing ─────────────────────────────────────────────────────────────────

/// Whether the ident reply read so far is all there is: it ended, or it is
/// as long as an ident gets.
pub fn ident_reply_complete(reply: &[u8]) -> bool {
    reply.last() == Some(&IDENT_END) || reply.len() >= IDENT_MAX_REPLY_LEN
}

/// The eight-byte ident from the radio's reply.
///
/// Refuses the 220 MHz variant, whose upper band is not the one this layout
/// describes: byte 3 of its ident is 0x02.
pub fn parse_ident(reply: &[u8]) -> Result<[u8; IDENT_LEN], ProtocolError> {
    let ident: [u8; IDENT_LEN] = match reply.len() {
        8 => reply.try_into().expect("length checked"),
        // The twelve-byte form carries padding at 1, 2, 4 and 6.
        12 => [
            reply[0], reply[3], reply[5], reply[7], reply[8], reply[9], reply[10], reply[11],
        ],
        n => {
            return Err(ProtocolError::MalformedReply(format!(
                "a radio ident is 8 or 12 bytes, not {n}"
            )))
        }
    };
    if ident[3] == 0x02 {
        return Err(ProtocolError::MalformedReply(
            "this is the 220 MHz variant, whose memory this app does not describe".to_string(),
        ));
    }
    Ok(ident)
}

pub fn read_command(addr: u16, len: u8) -> [u8; 4] {
    let [hi, lo] = addr.to_be_bytes();
    [CMD_READ, hi, lo, len]
}

/// The data from a read's answer, after checking it answers this read.
pub fn parse_read_reply(reply: &[u8], addr: u16, len: u8) -> Result<Vec<u8>, ProtocolError> {
    if reply.len() != read_reply_len(len) {
        return Err(ProtocolError::MalformedReply(format!(
            "a read of {len} bytes at 0x{addr:04X} is answered with {} bytes, not {}",
            read_reply_len(len),
            reply.len()
        )));
    }
    let [hi, lo] = addr.to_be_bytes();
    if reply[..REPLY_HEADER_LEN] != [CMD_DATA, hi, lo, len] {
        return Err(ProtocolError::MalformedReply(format!(
            "the radio answered a read at 0x{addr:04X} with the header {:02X?}",
            &reply[..REPLY_HEADER_LEN]
        )));
    }
    Ok(reply[REPLY_HEADER_LEN..].to_vec())
}

/// A write: exactly [`WRITE_BLOCK_LEN`] bytes, which is all the radio takes.
pub fn write_command(addr: u16, data: &[u8]) -> Result<Vec<u8>, ProtocolError> {
    if data.len() != WRITE_BLOCK_LEN as usize {
        return Err(ProtocolError::MalformedReply(format!(
            "writes are {WRITE_BLOCK_LEN} bytes, not {}",
            data.len()
        )));
    }
    let [hi, lo] = addr.to_be_bytes();
    let mut frame = vec![CMD_DATA, hi, lo, WRITE_BLOCK_LEN];
    frame.extend_from_slice(data);
    Ok(frame)
}

// ── The probe, and reading ──────────────────────────────────────────────────

/// The reads made right after the ident, in order, before anything else.
///
/// The first primes the aux block (see [`PRIMING_READ_ADDR`]) and is thrown
/// away; the second carries the firmware string; the third shows whether this
/// radio drops a byte. The first is also the session's first command, which
/// the radio answers without a leading 0x06.
pub const PROBE_READS: [(u16, u8); 3] = [
    (PRIMING_READ_ADDR, READ_BLOCK_LEN),
    (FIRMWARE_BLOCK_ADDR, READ_BLOCK_LEN),
    (DROP_PROBE_ADDR, READ_BLOCK_LEN),
];

/// What the probe found.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Probe {
    pub firmware: String,

    /// The radio drops a byte from a full-size read of the aux block's end,
    /// so that part is read sixteen bytes at a time.
    pub drops_byte: bool,
}

pub fn parse_probe(firmware_block: &[u8], drop_block: &[u8]) -> Result<Probe, ProtocolError> {
    let offset = (FIRMWARE_ADDR - FIRMWARE_BLOCK_ADDR) as usize;
    let firmware = firmware_block
        .get(offset..offset + FIRMWARE_LEN)
        .ok_or_else(|| ProtocolError::MalformedReply("the firmware block is short".into()))?;
    let flag = drop_block
        .get(DROP_PROBE_INDEX)
        .ok_or_else(|| ProtocolError::MalformedReply("the probe block is short".into()))?;
    Ok(Probe {
        firmware: decode_text(firmware),
        drops_byte: *flag == 0xFF,
    })
}

/// Where a radio address lives in the image, or `None` if it is in neither
/// region the image holds.
pub fn image_offset(addr: u16) -> Option<usize> {
    if addr < MAIN_END {
        Some(IDENT_LEN + addr as usize)
    } else if (AUX_START..AUX_END).contains(&addr) {
        Some(IDENT_LEN + MAIN_END as usize + (addr - AUX_START) as usize)
    } else {
        None
    }
}

fn blocks(start: u16, end: u16, len: u8) -> impl Iterator<Item = Block> {
    (start..end).step_by(len as usize).map(move |addr| Block {
        addr,
        len,
        image_offset: image_offset(addr).expect("inside the image"),
    })
}

/// Every read after the probe, in image order: the ident, which the session
/// already has, goes first, and these fill the rest.
pub fn read_plan(drops_byte: bool) -> Vec<Block> {
    let mut plan: Vec<Block> = blocks(0, MAIN_END, READ_BLOCK_LEN).collect();
    if drops_byte {
        plan.extend(blocks(AUX_START, DROP_PROBE_ADDR, READ_BLOCK_LEN));
        plan.extend(blocks(DROP_PROBE_ADDR, AUX_END, SMALL_READ_BLOCK_LEN));
    } else {
        plan.extend(blocks(AUX_START, AUX_END, READ_BLOCK_LEN));
    }
    plan
}

// ── Writing ─────────────────────────────────────────────────────────────────

/// Which of the two band-limit layouts a radio uses.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LimitLayout {
    /// Firmware before BFB291.
    Old,
    New,
}

/// The firmware string an image carries.
pub fn firmware(image: &[u8]) -> Result<String, ProtocolError> {
    check_image(image)?;
    let start = image_offset(FIRMWARE_ADDR).expect("inside the image");
    Ok(decode_text(&image[start..start + FIRMWARE_LEN]))
}

/// The band-limit layout of the radio an image came from.
///
/// The newer layout unless the firmware string says `BFB` and a number
/// below 291. An unreadable number is an error rather than a guess: this
/// decides which bytes a limit write touches.
pub fn limit_layout(image: &[u8], model: &Uv5rModel) -> Result<LimitLayout, ProtocolError> {
    let version = firmware(image)?;
    if model.always_new_limits {
        return Ok(LimitLayout::New);
    }
    let Some(index) = version.find("BFB") else {
        return Ok(LimitLayout::New);
    };
    let digits: String = version[index + 3..].chars().take(3).collect();
    match digits.parse::<u16>() {
        Ok(number) if digits.len() == 3 => Ok(if number < 291 {
            LimitLayout::Old
        } else {
            LimitLayout::New
        }),
        _ => Err(ProtocolError::MalformedReply(format!(
            "cannot read a firmware number from {version:?}"
        ))),
    }
}

/// The aux ranges a write may touch: the welcome message, and then what the
/// firmware generation keeps where.
fn aux_writable(layout: LimitLayout) -> &'static [(u16, u16)] {
    match layout {
        LimitLayout::Old => &[(0x1EE0, 0x1EF0), (0x1FC0, 0x1FE0)],
        LimitLayout::New => &[
            (0x1EE0, 0x1EF0),
            (0x1F60, 0x1F70),
            (0x1F80, 0x1F90),
            (0x1FC0, 0x1FD0),
        ],
    }
}

fn main_writable() -> Vec<(u16, u16)> {
    let mut ranges = Vec::new();
    let mut start = 0;
    for (skip_start, skip_end) in MAIN_WRITE_SKIPS {
        ranges.push((start, skip_start));
        start = skip_end;
    }
    ranges.push((start, MAIN_END));
    ranges
}

fn writable(layout: LimitLayout, addr: u16) -> bool {
    main_writable()
        .iter()
        .chain(aux_writable(layout))
        .any(|&(start, end)| addr >= start && addr < end)
}

/// Every block a restore writes: all of main memory but the skipped windows,
/// and the aux ranges this layout keeps its settings in.
pub fn restore_plan(layout: LimitLayout) -> Vec<Block> {
    main_writable()
        .into_iter()
        .chain(aux_writable(layout).iter().copied())
        .flat_map(|(start, end)| blocks(start, end, WRITE_BLOCK_LEN))
        .collect()
}

/// The blocks that differ between `base` — read from this radio — and
/// `updated`, which is `base` with changes applied.
///
/// Only those are written. A change anywhere this app never writes is an
/// error, not something to send: it means the image did not come from the
/// edit it claims to.
pub fn changed_blocks(
    base: &[u8],
    updated: &[u8],
    layout: LimitLayout,
) -> Result<Vec<Block>, ProtocolError> {
    check_image(base)?;
    check_image(updated)?;
    if base[..IDENT_LEN] != updated[..IDENT_LEN] {
        return Err(ProtocolError::MalformedReply(
            "the image is for a different radio than the one read".to_string(),
        ));
    }
    let mut changed = Vec::new();
    let all =
        blocks(0, MAIN_END, WRITE_BLOCK_LEN).chain(blocks(AUX_START, AUX_END, WRITE_BLOCK_LEN));
    for block in all {
        let range = block.image_offset..block.image_offset + block.len as usize;
        if base[range.clone()] == updated[range] {
            continue;
        }
        if !writable(layout, block.addr) {
            return Err(ProtocolError::MalformedReply(format!(
                "the change at 0x{:04X} is in memory this app never writes",
                block.addr
            )));
        }
        changed.push(block);
    }
    Ok(changed)
}

/// The reads that check a write landed: one read-sized block around each
/// changed block, each read once, in address order.
///
/// Read-sized means what a read of that address may safely be: 0x40 bytes on
/// a 0x40 boundary, except the end of the aux block on a radio that drops a
/// byte, which is read sixteen bytes at a time. Older radios cannot read the
/// aux block in small pieces at all, which is why this is not simply "read
/// back exactly what was written".
pub fn verify_plan(changed: &[Block], drops_byte: bool) -> Vec<Block> {
    let mut plan: Vec<Block> = Vec::new();
    for block in changed {
        let len = if drops_byte && block.addr >= DROP_PROBE_ADDR {
            SMALL_READ_BLOCK_LEN
        } else {
            READ_BLOCK_LEN
        };
        let addr = block.addr - block.addr % len as u16;
        if plan.iter().any(|b| b.addr == addr) {
            continue;
        }
        if let Some(image_offset) = image_offset(addr) {
            plan.push(Block {
                addr,
                len,
                image_offset,
            });
        }
    }
    plan.sort_by_key(|block| block.addr);
    plan
}

// ── Channels ────────────────────────────────────────────────────────────────

fn check_image(image: &[u8]) -> Result<(), ProtocolError> {
    if image.len() != IMAGE_LEN {
        return Err(ProtocolError::MalformedReply(format!(
            "a UV-5R image is {IMAGE_LEN} bytes, not {}",
            image.len()
        )));
    }
    Ok(())
}

fn record_range(slot: usize) -> std::ops::Range<usize> {
    let start = IDENT_LEN + slot * RECORD_LEN;
    start..start + RECORD_LEN
}

fn name_range(slot: usize) -> std::ops::Range<usize> {
    let start = IDENT_LEN + NAMES_ADDR as usize + slot * NAME_SLOT_LEN;
    start..start + NAME_SLOT_LEN
}

/// Big-endian BCD, as the band limits store whole megahertz.
fn decode_bbcd(bytes: &[u8]) -> Option<u16> {
    let mut value = 0u16;
    for &byte in bytes {
        let (hi, lo) = (byte >> 4, byte & 0x0F);
        if hi > 9 || lo > 9 {
            return None;
        }
        value = value * 100 + (hi as u16) * 10 + lo as u16;
    }
    Some(value)
}

fn encode_bbcd(value: u16) -> [u8; 2] {
    let digits = |pair: u16| (((pair / 10) << 4) | (pair % 10)) as u8;
    [digits(value / 100), digits(value % 100)]
}

/// Text from a padded field. 0xFF is padding wherever it falls — the
/// vendor software has been seen to leave it mid-name — so it reads as a
/// space, and trailing spaces go.
fn decode_text(raw: &[u8]) -> String {
    raw.iter()
        .map(|&b| match b {
            0x20..=0x7E => b as char,
            _ => ' ',
        })
        .collect::<String>()
        .trim_end()
        .to_string()
}

/// A frequency in the same four-byte field the newer family uses, refused
/// rather than rounded when it is finer than the ten hertz the field holds.
fn encode_frequency(hz: u32, out: &mut [u8]) -> Result<(), ProtocolError> {
    if hz % 10 != 0 {
        return Err(ProtocolError::MalformedReply(format!(
            "{hz} Hz is finer than the 10 Hz this radio stores"
        )));
    }
    encode_bcd(hz, out)
}

/// The channels in an image, one entry per slot, `None` for an empty one.
///
/// A slot whose frequency is not valid BCD also reads as `None`: there is
/// nothing it could honestly be shown as.
pub fn decode_channels(image: &[u8]) -> Result<Vec<Option<ChannelRecord>>, ProtocolError> {
    check_image(image)?;
    Ok((0..CHANNEL_COUNT)
        .map(|slot| decode_channel(&image[record_range(slot)], &image[name_range(slot)]))
        .collect())
}

fn decode_channel(record: &[u8], name: &[u8]) -> Option<ChannelRecord> {
    if record[0] == 0xFF {
        return None;
    }
    let rx_freq_hz = decode_bcd(&record[0..4])?;
    let rx_only = record[4..8].iter().all(|&b| b == 0xFF);
    let tx_freq_hz = if rx_only {
        rx_freq_hz
    } else {
        decode_bcd(&record[4..8])?
    };
    let power_level = record[14] & 0x03;
    Some(ChannelRecord {
        name: decode_text(&name[..NAME_LEN]),
        rx_freq_hz,
        tx_freq_hz,
        rx_only,
        rx_tone: decode_tone(u16::from_le_bytes([record[8], record[9]])),
        tx_tone: decode_tone(u16::from_le_bytes([record[10], record[11]])),
        // Two-level radios: 0 high, 1 low. Three-level: 0 high, 1 mid,
        // 2 low. Anything but high reads as low; encode keeps a mid a mid.
        low_power: power_level != 0,
        narrow: record[15] & 0x40 == 0,
        skip: record[15] & 0x04 == 0,
    })
}

/// A copy of `image` with `channels` in slots 1 up and every later slot
/// cleared — which is what "write this plan" means.
///
/// Everything outside the records and names survives. So do the parts of an
/// occupied record the app does not model — its busy-channel lockout,
/// signal code and PTT-ID — which is what the vendor software keeps too.
pub fn encode_channels(
    image: &[u8],
    channels: &[ChannelRecord],
    model: &Uv5rModel,
) -> Result<Vec<u8>, ProtocolError> {
    check_image(image)?;
    if channels.len() > CHANNEL_COUNT {
        return Err(ProtocolError::MalformedReply(format!(
            "{} channels do not fit in {CHANNEL_COUNT}",
            channels.len()
        )));
    }
    let mut out = image.to_vec();
    for slot in 0..CHANNEL_COUNT {
        match channels.get(slot) {
            Some(channel) => encode_channel(&mut out, slot, channel, model)?,
            None => {
                out[record_range(slot)].fill(0xFF);
                out[name_range(slot)].fill(0xFF);
            }
        }
    }
    Ok(out)
}

fn encode_channel(
    image: &mut [u8],
    slot: usize,
    channel: &ChannelRecord,
    model: &Uv5rModel,
) -> Result<(), ProtocolError> {
    let previous: [u8; RECORD_LEN] = image[record_range(slot)].try_into().expect("record length");
    let occupied = previous[0] != 0xFF;

    let mut record = [0u8; RECORD_LEN];
    encode_frequency(channel.rx_freq_hz, &mut record[0..4])?;
    if channel.rx_only {
        record[4..8].fill(0xFF);
    } else {
        encode_frequency(channel.tx_freq_hz, &mut record[4..8])?;
    }
    record[8..10].copy_from_slice(&encode_tone(channel.rx_tone)?.to_le_bytes());
    record[10..12].copy_from_slice(&encode_tone(channel.tx_tone)?.to_le_bytes());

    // Kept from an occupied slot: the signal code (low nibble of 12), busy
    // channel lockout (bit 3 of 15) and PTT-ID (bits 0-1 of 15).
    if occupied {
        record[12] = previous[12] & 0x0F;
        record[15] = previous[15] & 0x0B;
    }
    record[14] = if !channel.low_power {
        0
    } else if model.tri_power {
        // A three-level radio's mid setting reads back as low. Writing it
        // back must not quietly turn mid into low.
        if occupied && previous[14] & 0x03 == 1 {
            1
        } else {
            2
        }
    } else {
        1
    };
    if !channel.narrow {
        record[15] |= 0x40;
    }
    if !channel.skip {
        record[15] |= 0x04;
    }
    image[record_range(slot)].copy_from_slice(&record);

    let name = &mut image[name_range(slot)];
    let mut chars = channel.name.chars().map(|c| c.to_ascii_uppercase());
    for byte in name.iter_mut().take(NAME_LEN) {
        *byte = match chars.next() {
            Some(c) if NAME_CHARSET.contains(c) => c as u8,
            Some(_) => b' ',
            None => 0xFF,
        };
    }
    Ok(())
}

// ── Band limits ─────────────────────────────────────────────────────────────

/// One band's transmit limits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BandLimit {
    /// Transmitting in this band is allowed at all.
    pub tx_enabled: bool,
    pub lower_mhz: u16,
    pub upper_mhz: u16,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BandLimits {
    pub vhf: BandLimit,
    pub uhf: BandLimit,
}

const LIMIT_FIELD_LEN: usize = 5;

/// The highest limit a field holds — and CHIRP's own bound for it.
pub const LIMIT_MAX_MHZ: u16 = 1000;

fn limit_addrs(layout: LimitLayout) -> (u16, u16) {
    match layout {
        LimitLayout::Old => (0x1FCA, 0x1FDA),
        LimitLayout::New => (0x1FC0, 0x1FC5),
    }
}

fn limit_range(addr: u16) -> std::ops::Range<usize> {
    let start = image_offset(addr).expect("inside the aux block");
    start..start + LIMIT_FIELD_LEN
}

fn decode_limit(field: &[u8]) -> Result<BandLimit, ProtocolError> {
    let unreadable = || ProtocolError::MalformedReply("a band limit is not valid BCD".into());
    Ok(BandLimit {
        tx_enabled: field[0] != 0,
        lower_mhz: decode_bbcd(&field[1..3]).ok_or_else(unreadable)?,
        upper_mhz: decode_bbcd(&field[3..5]).ok_or_else(unreadable)?,
    })
}

pub fn read_band_limits(image: &[u8], layout: LimitLayout) -> Result<BandLimits, ProtocolError> {
    check_image(image)?;
    let (vhf, uhf) = limit_addrs(layout);
    Ok(BandLimits {
        vhf: decode_limit(&image[limit_range(vhf)])?,
        uhf: decode_limit(&image[limit_range(uhf)])?,
    })
}

/// A copy of `image` with `limits` written into the layout's fields, and
/// nothing else changed.
pub fn apply_band_limits(
    image: &[u8],
    limits: &BandLimits,
    layout: LimitLayout,
) -> Result<Vec<u8>, ProtocolError> {
    check_image(image)?;
    let mut out = image.to_vec();
    let (vhf, uhf) = limit_addrs(layout);
    for (addr, limit) in [(vhf, limits.vhf), (uhf, limits.uhf)] {
        if limit.lower_mhz == 0
            || limit.upper_mhz > LIMIT_MAX_MHZ
            || limit.lower_mhz > limit.upper_mhz
        {
            return Err(ProtocolError::MalformedReply(format!(
                "{}-{} MHz is not a band limit this radio can hold",
                limit.lower_mhz, limit.upper_mhz
            )));
        }
        let field = &mut out[limit_range(addr)];
        // An enabled flag keeps whatever non-zero value the radio used.
        field[0] = match (limit.tx_enabled, field[0]) {
            (false, _) => 0,
            (true, 0) => 1,
            (true, existing) => existing,
        };
        field[1..3].copy_from_slice(&encode_bbcd(limit.lower_mhz));
        field[3..5].copy_from_slice(&encode_bbcd(limit.upper_mhz));
    }
    Ok(out)
}

/// A blank image as a radio might hand it over: an ident, every slot empty,
/// and a firmware string in the aux block. For this crate's tests, here and
/// in the bridge's.
#[cfg(test)]
pub(crate) fn image_with_firmware(firmware: &str) -> Vec<u8> {
    let mut image = vec![0u8; IMAGE_LEN];
    image[..IDENT_LEN].copy_from_slice(&[0xAA, 0x30, 0x76, 0x04, 0x00, 0x05, 0x20, 0xDD]);
    for slot in 0..CHANNEL_COUNT {
        image[record_range(slot)].fill(0xFF);
        image[name_range(slot)].fill(0xFF);
    }
    let start = image_offset(FIRMWARE_ADDR).unwrap();
    image[start..start + FIRMWARE_LEN].fill(0xFF);
    image[start..start + firmware.len()].copy_from_slice(firmware.as_bytes());
    image
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::radio::codeplug::Tone;

    fn blank() -> Vec<u8> {
        image_with_firmware("BFB297")
    }

    fn channel(name: &str, rx: u32, tx: u32) -> ChannelRecord {
        ChannelRecord {
            name: name.to_string(),
            rx_freq_hz: rx,
            tx_freq_hz: tx,
            ..Default::default()
        }
    }

    // ── framing ──

    #[test]
    fn the_image_is_ident_main_and_aux() {
        assert_eq!(IMAGE_LEN, 0x1948);
        assert_eq!(image_offset(0x0000), Some(8));
        assert_eq!(image_offset(0x17FF), Some(0x1807));
        assert_eq!(image_offset(0x1800), None);
        assert_eq!(image_offset(0x1EBF), None);
        assert_eq!(image_offset(0x1EC0), Some(0x1808));
        assert_eq!(image_offset(0x1FFF), Some(0x1947));
    }

    #[test]
    fn an_ident_is_eight_bytes_or_twelve_compacted() {
        let eight = [0xAA, 0x30, 0x76, 0x04, 0x00, 0x05, 0x20, 0xDD];
        assert_eq!(parse_ident(&eight).unwrap(), eight);
        let twelve = [
            0xAA, 0x01, 0x01, 0x30, 0x01, 0x76, 0x01, 0x04, 0x00, 0x05, 0x20, 0xDD,
        ];
        assert_eq!(parse_ident(&twelve).unwrap(), eight);
        assert!(parse_ident(&[0xAA, 0xDD]).is_err());
    }

    #[test]
    fn the_220_variant_is_refused() {
        let ident = [0xAA, 0x30, 0x76, 0x02, 0x00, 0x05, 0x20, 0xDD];
        assert!(parse_ident(&ident).is_err());
    }

    #[test]
    fn an_ident_reply_is_complete_at_its_end_byte_or_its_longest() {
        assert!(!ident_reply_complete(&[0xAA, 0x30]));
        assert!(ident_reply_complete(&[0xAA, 0xDD]));
        assert!(ident_reply_complete(&[0; IDENT_MAX_REPLY_LEN]));
    }

    #[test]
    fn reads_are_framed_big_endian() {
        assert_eq!(read_command(0x1EC0, 0x40), [b'S', 0x1E, 0xC0, 0x40]);
        let mut reply = vec![b'X', 0x1E, 0xC0, 0x40];
        reply.extend(0..0x40u8);
        assert_eq!(
            parse_read_reply(&reply, 0x1EC0, 0x40).unwrap(),
            (0..0x40u8).collect::<Vec<_>>()
        );
    }

    #[test]
    fn a_reply_to_another_read_is_rejected() {
        let mut reply = vec![b'X', 0x00, 0x40, 0x40];
        reply.extend([0u8; 0x40]);
        assert!(
            parse_read_reply(&reply, 0x0000, 0x40).is_err(),
            "wrong address"
        );
        assert!(
            parse_read_reply(&reply[..20], 0x0040, 0x40).is_err(),
            "short"
        );
        reply[0] = b'Y';
        assert!(
            parse_read_reply(&reply, 0x0040, 0x40).is_err(),
            "wrong command"
        );
    }

    #[test]
    fn a_write_is_sixteen_bytes_and_nothing_else() {
        let frame = write_command(0x1FC0, &[7u8; 16]).unwrap();
        assert_eq!(&frame[..4], &[b'X', 0x1F, 0xC0, 0x10]);
        assert_eq!(frame.len(), 20);
        assert!(write_command(0x1FC0, &[0u8; 0x40]).is_err());
        assert!(write_command(0x1FC0, &[]).is_err());
    }

    #[test]
    fn every_model_has_seven_byte_idents_on_the_family_prefix() {
        for model in MODELS {
            assert!(!model.idents.is_empty(), "{}", model.id);
            for ident in model.idents {
                assert_eq!(&ident[..3], &[0x50, 0xBB, 0xFF], "{}", model.id);
            }
        }
        assert!(
            model_by_id("uv-5g").is_none(),
            "its memory is not a UV-5R's"
        );
        assert!(model_by_id("uv5r").is_some());
    }

    // ── the probe and the read plan ──

    #[test]
    fn the_probe_reads_the_firmware_and_spots_a_dropped_byte() {
        let mut firmware_block = [0u8; 0x40];
        firmware_block[48..54].copy_from_slice(b"BFB297");
        firmware_block[54..62].fill(0xFF);
        let mut drop_block = [0u8; 0x40];
        let probe = parse_probe(&firmware_block, &drop_block).unwrap();
        assert_eq!(probe.firmware, "BFB297");
        assert!(!probe.drops_byte);

        drop_block[15] = 0xFF;
        assert!(
            parse_probe(&firmware_block, &drop_block)
                .unwrap()
                .drops_byte
        );
        assert!(parse_probe(&firmware_block[..10], &drop_block).is_err());
    }

    #[test]
    fn the_read_plan_fills_the_image_after_the_ident_exactly_once() {
        for drops_byte in [false, true] {
            let plan = read_plan(drops_byte);
            let mut next = IDENT_LEN;
            for block in &plan {
                assert_eq!(block.image_offset, next, "contiguous, in order");
                next += block.len as usize;
            }
            assert_eq!(next, IMAGE_LEN);
            let small = plan
                .iter()
                .filter(|b| b.len == SMALL_READ_BLOCK_LEN)
                .count();
            assert_eq!(small > 0, drops_byte);
            if drops_byte {
                assert!(plan
                    .iter()
                    .filter(|b| b.addr >= DROP_PROBE_ADDR)
                    .all(|b| b.len == SMALL_READ_BLOCK_LEN));
            }
        }
    }

    // ── channels ──

    #[test]
    fn channels_round_trip() {
        let channels = vec![
            ChannelRecord {
                name: "W1AW".into(),
                rx_freq_hz: 146_940_000,
                tx_freq_hz: 146_340_000,
                tx_tone: Tone::Ctcss(1000),
                rx_tone: Tone::Dcs {
                    code: 23,
                    inverted: true,
                },
                narrow: true,
                low_power: true,
                skip: true,
                rx_only: false,
            },
            ChannelRecord {
                name: "GMRS 15".into(),
                rx_freq_hz: 462_562_500,
                tx_freq_hz: 467_562_500,
                tx_tone: Tone::Dcs {
                    code: 645,
                    inverted: false,
                },
                rx_tone: Tone::Dcs {
                    code: 754,
                    inverted: false,
                },
                ..Default::default()
            },
            ChannelRecord {
                name: "NOAA 1".into(),
                rx_freq_hz: 162_550_000,
                tx_freq_hz: 162_550_000,
                rx_only: true,
                ..Default::default()
            },
        ];
        let image = encode_channels(&blank(), &channels, &UV5R).unwrap();
        let decoded = decode_channels(&image).unwrap();
        let back: Vec<_> = decoded.iter().flatten().cloned().collect();
        assert_eq!(back, channels);
        assert_eq!(
            decoded.iter().filter(|c| c.is_none()).count(),
            CHANNEL_COUNT - 3
        );
    }

    #[test]
    fn frequencies_are_little_endian_bcd_in_tens_of_hertz() {
        let image =
            encode_channels(&blank(), &[channel("A", 146_520_000, 146_520_000)], &UV5R).unwrap();
        // 14652000 tens of hertz, lowest digit pair first.
        assert_eq!(&image[record_range(0)][0..4], &[0x00, 0x20, 0x65, 0x14]);
    }

    #[test]
    fn the_645_code_sits_in_its_sorted_place() {
        // The UV-5R's table is the standard one plus 645, sorted, and a record
        // stores the index: 645 is the 94th code, so index 93, stored as 94.
        let mut ch = channel("A", 146_520_000, 146_520_000);
        ch.tx_tone = Tone::Dcs {
            code: 645,
            inverted: false,
        };
        let image = encode_channels(&blank(), &[ch], &UV5R).unwrap();
        assert_eq!(
            u16::from_le_bytes([image[record_range(0)][10], image[record_range(0)][11]]),
            94
        );
    }

    #[test]
    fn a_finer_frequency_than_the_radio_stores_is_refused() {
        assert!(
            encode_channels(&blank(), &[channel("A", 146_520_005, 146_520_005)], &UV5R).is_err()
        );
    }

    #[test]
    fn names_are_uppercased_limited_and_padded() {
        let image = encode_channels(
            &blank(),
            &[channel("simplex_2m!", 146_520_000, 146_520_000)],
            &UV5R,
        )
        .unwrap();
        let name = &image[name_range(0)];
        // Seven characters; '_' is not on the display, so it is a space.
        assert_eq!(&name[..NAME_LEN], b"SIMPLEX");
        let decoded = decode_channels(&image).unwrap()[0].clone().unwrap();
        assert_eq!(decoded.name, "SIMPLEX");

        let short =
            encode_channels(&blank(), &[channel("a_b", 146_520_000, 146_520_000)], &UV5R).unwrap();
        assert_eq!(
            &short[name_range(0)][..NAME_LEN],
            &[b'A', b' ', b'B', 0xFF, 0xFF, 0xFF, 0xFF]
        );
    }

    #[test]
    fn padding_in_the_middle_of_a_name_reads_as_a_space() {
        let mut image =
            encode_channels(&blank(), &[channel("AB", 146_520_000, 146_520_000)], &UV5R).unwrap();
        let range = name_range(0);
        image[range.start + 2] = 0xFF;
        image[range.start + 3] = b'C';
        let decoded = decode_channels(&image).unwrap()[0].clone().unwrap();
        assert_eq!(decoded.name, "AB C");
    }

    #[test]
    fn writing_a_plan_clears_every_later_slot() {
        let three = vec![
            channel("A", 146_520_000, 146_520_000),
            channel("B", 146_540_000, 146_540_000),
            channel("C", 146_560_000, 146_560_000),
        ];
        let full = encode_channels(&blank(), &three, &UV5R).unwrap();
        let one = encode_channels(&full, &three[..1], &UV5R).unwrap();
        let decoded = decode_channels(&one).unwrap();
        assert!(decoded[0].is_some());
        assert!(decoded[1..].iter().all(Option::is_none));
        assert!(one[record_range(1)].iter().all(|&b| b == 0xFF));
        assert!(one[name_range(1)].iter().all(|&b| b == 0xFF));
    }

    #[test]
    fn what_the_app_does_not_model_survives_a_rewrite() {
        let mut image =
            encode_channels(&blank(), &[channel("A", 146_520_000, 146_520_000)], &UV5R).unwrap();
        let range = record_range(0);
        image[range.start + 12] |= 0x05; // signal code 5
        image[range.start + 15] |= 0x08 | 0x02; // lockout on, PTT-ID "EOT"

        let rewritten =
            encode_channels(&image, &[channel("B", 446_000_000, 446_000_000)], &UV5R).unwrap();
        assert_eq!(rewritten[range.start + 12] & 0x0F, 0x05);
        assert_eq!(rewritten[range.start + 15] & 0x0B, 0x0A);
    }

    #[test]
    fn an_empty_slot_starts_from_nothing() {
        let image =
            encode_channels(&blank(), &[channel("A", 146_520_000, 146_520_000)], &UV5R).unwrap();
        let record = &image[record_range(0)];
        assert_eq!(record[12], 0);
        assert_eq!(record[13], 0);
        // Wide and scanned: the two bits a default channel sets.
        assert_eq!(record[15], 0x40 | 0x04);
    }

    #[test]
    fn a_three_level_radio_keeps_mid_power() {
        let mut low = channel("A", 146_520_000, 146_520_000);
        low.low_power = true;
        let image = encode_channels(&blank(), &[low.clone()], &BF_F8HP).unwrap();
        let range = record_range(0);
        assert_eq!(image[range.start + 14] & 0x03, 2, "low on a fresh slot");

        let mut mid = image.clone();
        mid[range.start + 14] = (mid[range.start + 14] & !0x03) | 1;
        let decoded = decode_channels(&mid).unwrap()[0].clone().unwrap();
        assert!(decoded.low_power, "mid reads as not-high");
        let rewritten = encode_channels(&mid, &[decoded], &BF_F8HP).unwrap();
        assert_eq!(
            rewritten[range.start + 14] & 0x03,
            1,
            "and is written back as mid"
        );

        let two = encode_channels(&blank(), &[low], &UV5R).unwrap();
        assert_eq!(
            two[range.start + 14] & 0x03,
            1,
            "a two-level radio's low is 1"
        );
    }

    #[test]
    fn a_record_that_is_not_bcd_reads_as_empty() {
        let mut image = blank();
        image[record_range(0)][..4].copy_from_slice(&[0x0A, 0x00, 0x00, 0x00]);
        assert!(decode_channels(&image).unwrap()[0].is_none());
    }

    #[test]
    fn an_image_of_the_wrong_size_is_refused() {
        assert!(decode_channels(&[0u8; 0x1808]).is_err());
        assert!(encode_channels(&[0u8; 0x1808], &[], &UV5R).is_err());
        assert!(encode_channels(&blank(), &vec![ChannelRecord::default(); 129], &UV5R).is_err());
    }

    // ── band limits ──

    #[test]
    fn the_firmware_decides_the_limit_layout() {
        assert_eq!(
            limit_layout(&image_with_firmware("BFB290"), &UV5R).unwrap(),
            LimitLayout::Old
        );
        assert_eq!(
            limit_layout(&image_with_firmware("BFB291"), &UV5R).unwrap(),
            LimitLayout::New
        );
        assert_eq!(
            limit_layout(&image_with_firmware("BFS311"), &UV5R).unwrap(),
            LimitLayout::New
        );
        assert_eq!(
            limit_layout(&image_with_firmware("BFB250"), &BF_F8HP).unwrap(),
            LimitLayout::New,
            "the F8HP always uses the newer layout"
        );
        assert!(limit_layout(&image_with_firmware("BFBXYZ"), &UV5R).is_err());
        assert_eq!(firmware(&image_with_firmware("BFB297")).unwrap(), "BFB297");
    }

    fn limits(vhf: (bool, u16, u16), uhf: (bool, u16, u16)) -> BandLimits {
        BandLimits {
            vhf: BandLimit {
                tx_enabled: vhf.0,
                lower_mhz: vhf.1,
                upper_mhz: vhf.2,
            },
            uhf: BandLimit {
                tx_enabled: uhf.0,
                lower_mhz: uhf.1,
                upper_mhz: uhf.2,
            },
        }
    }

    #[test]
    fn band_limits_round_trip_in_both_layouts() {
        let wanted = limits((true, 130, 180), (true, 400, 520));
        for layout in [LimitLayout::Old, LimitLayout::New] {
            let image = apply_band_limits(&blank(), &wanted, layout).unwrap();
            assert_eq!(
                read_band_limits(&image, layout).unwrap(),
                wanted,
                "{layout:?}"
            );
        }
    }

    #[test]
    fn band_limits_are_big_endian_bcd_megahertz_where_the_layout_says() {
        let image = apply_band_limits(
            &blank(),
            &limits((true, 136, 174), (false, 400, 520)),
            LimitLayout::New,
        )
        .unwrap();
        let vhf = image_offset(0x1FC0).unwrap();
        assert_eq!(&image[vhf..vhf + 5], &[0x01, 0x01, 0x36, 0x01, 0x74]);
        let uhf = image_offset(0x1FC5).unwrap();
        assert_eq!(&image[uhf..uhf + 5], &[0x00, 0x04, 0x00, 0x05, 0x20]);

        let old = apply_band_limits(
            &blank(),
            &limits((true, 136, 174), (true, 400, 520)),
            LimitLayout::Old,
        )
        .unwrap();
        let old_vhf = image_offset(0x1FCA).unwrap();
        assert_eq!(&old[old_vhf + 1..old_vhf + 5], &[0x01, 0x36, 0x01, 0x74]);
    }

    #[test]
    fn a_limit_write_touches_nothing_else() {
        let base = blank();
        for layout in [LimitLayout::Old, LimitLayout::New] {
            let image =
                apply_band_limits(&base, &limits((true, 130, 180), (true, 400, 520)), layout)
                    .unwrap();
            let (vhf, uhf) = limit_addrs(layout);
            for (i, (a, b)) in base.iter().zip(&image).enumerate() {
                if a != b {
                    assert!(
                        limit_range(vhf).contains(&i) || limit_range(uhf).contains(&i),
                        "{layout:?} changed byte {i:#x}"
                    );
                }
            }
        }
    }

    #[test]
    fn an_enabled_flag_keeps_the_radios_own_value() {
        let mut base = blank();
        let vhf = image_offset(0x1FC0).unwrap();
        base[vhf] = 0x55;
        let image = apply_band_limits(
            &base,
            &limits((true, 130, 180), (true, 400, 520)),
            LimitLayout::New,
        )
        .unwrap();
        assert_eq!(image[vhf], 0x55);
    }

    #[test]
    fn impossible_limits_are_refused() {
        for bad in [
            limits((true, 180, 130), (true, 400, 520)),
            limits((true, 0, 180), (true, 400, 520)),
            limits((true, 130, 180), (true, 400, 1001)),
        ] {
            assert!(
                apply_band_limits(&blank(), &bad, LimitLayout::New).is_err(),
                "{bad:?}"
            );
        }
    }

    #[test]
    fn unreadable_limits_are_an_error_not_a_guess() {
        let mut image = blank();
        let vhf = image_offset(0x1FC0).unwrap();
        image[vhf + 1] = 0xFF;
        assert!(read_band_limits(&image, LimitLayout::New).is_err());
    }

    // ── what a write sends ──

    #[test]
    fn only_changed_blocks_are_written() {
        let base = blank();
        let updated =
            encode_channels(&base, &[channel("A", 146_520_000, 146_520_000)], &UV5R).unwrap();
        let blocks = changed_blocks(&base, &updated, LimitLayout::New).unwrap();
        // Slot 1's record, and slot 1's name.
        assert_eq!(
            blocks.iter().map(|b| b.addr).collect::<Vec<_>>(),
            [0x0000, 0x1000]
        );
        assert!(blocks.iter().all(|b| b.len == WRITE_BLOCK_LEN));
        assert!(changed_blocks(&base, &base, LimitLayout::New)
            .unwrap()
            .is_empty());
    }

    #[test]
    fn a_limit_change_writes_the_limit_block_alone() {
        let base = blank();
        for layout in [LimitLayout::Old, LimitLayout::New] {
            let updated =
                apply_band_limits(&base, &limits((true, 130, 180), (true, 400, 520)), layout)
                    .unwrap();
            let blocks = changed_blocks(&base, &updated, layout).unwrap();
            assert!(!blocks.is_empty());
            assert!(
                blocks.iter().all(|b| b.addr >= 0x1FC0 && b.addr < 0x1FE0),
                "{layout:?}"
            );
        }
    }

    #[test]
    fn a_change_in_memory_never_written_is_refused() {
        let base = blank();
        let mut updated = base.clone();
        updated[image_offset(0x0CF4).unwrap()] ^= 0xFF;
        assert!(changed_blocks(&base, &updated, LimitLayout::New).is_err());

        let mut squelch = base.clone();
        squelch[image_offset(0x1F64).unwrap()] ^= 0xFF;
        assert!(
            changed_blocks(&base, &squelch, LimitLayout::Old).is_err(),
            "the old layout has no squelch range to write"
        );
        assert!(changed_blocks(&base, &squelch, LimitLayout::New).is_ok());
    }

    #[test]
    fn an_image_from_another_radio_is_refused() {
        let base = blank();
        let mut other = base.clone();
        other[0] ^= 0x01;
        assert!(changed_blocks(&base, &other, LimitLayout::New).is_err());
    }

    #[test]
    fn a_write_is_checked_by_reading_whole_blocks_back_once_each() {
        let changed = [
            Block {
                addr: 0x0000,
                len: 0x10,
                image_offset: 8,
            },
            Block {
                addr: 0x0010,
                len: 0x10,
                image_offset: 0x18,
            },
            Block {
                addr: 0x1000,
                len: 0x10,
                image_offset: 0x1008,
            },
        ];
        let plan = verify_plan(&changed, false);
        assert_eq!(
            plan.iter().map(|b| (b.addr, b.len)).collect::<Vec<_>>(),
            [(0x0000, 0x40), (0x1000, 0x40)],
            "both records share one read"
        );
        assert_eq!(plan[1].image_offset, image_offset(0x1000).unwrap());
    }

    #[test]
    fn a_limit_write_is_checked_in_small_reads_on_a_radio_that_drops_a_byte() {
        let changed = [Block {
            addr: 0x1FC0,
            len: 0x10,
            image_offset: image_offset(0x1FC0).unwrap(),
        }];
        let small = verify_plan(&changed, true);
        assert_eq!(
            small.iter().map(|b| (b.addr, b.len)).collect::<Vec<_>>(),
            [(0x1FC0, 0x10)]
        );
        let whole = verify_plan(&changed, false);
        assert_eq!(
            whole.iter().map(|b| (b.addr, b.len)).collect::<Vec<_>>(),
            [(0x1FC0, 0x40)]
        );

        // Aux blocks earlier than the probe address are read whole either way.
        let welcome = [Block {
            addr: 0x1EE0,
            len: 0x10,
            image_offset: image_offset(0x1EE0).unwrap(),
        }];
        assert_eq!(verify_plan(&welcome, true)[0].addr, 0x1EC0);
        assert_eq!(verify_plan(&welcome, true)[0].len, 0x40);
    }

    #[test]
    fn every_block_a_restore_writes_is_read_back() {
        for layout in [LimitLayout::Old, LimitLayout::New] {
            let writes = restore_plan(layout);
            let reads = verify_plan(&writes, false);
            for write in &writes {
                assert!(
                    reads
                        .iter()
                        .any(|r| write.addr >= r.addr && write.addr < r.addr + r.len as u16),
                    "{layout:?}: 0x{:04X} is never read back",
                    write.addr
                );
            }
        }
    }

    #[test]
    fn a_restore_writes_everything_writable_and_nothing_else() {
        for layout in [LimitLayout::Old, LimitLayout::New] {
            let plan = restore_plan(layout);
            assert!(plan.iter().all(|b| b.len == WRITE_BLOCK_LEN));
            assert!(plan.iter().all(|b| writable(layout, b.addr)));
            assert!(!plan.iter().any(|b| (0x0CF0..0x0D00).contains(&b.addr)));
            assert!(!plan.iter().any(|b| (0x0DF0..0x0E00).contains(&b.addr)));
            // Every main-memory block but the two skipped windows.
            let main = plan.iter().filter(|b| b.addr < MAIN_END).count();
            assert_eq!(main, (0x1800 - 0x20) / 0x10);
            let (vhf, _) = limit_addrs(layout);
            let limits_block = vhf & !0x0F;
            assert!(plan.iter().any(|b| b.addr == limits_block), "{layout:?}");
        }
    }
}

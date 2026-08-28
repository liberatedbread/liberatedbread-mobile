// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! ChannelRecord records: the 32 bytes a memory occupies, in both directions.

use super::models::{RadioModel, CHANNEL_RECORD_LEN};
use crate::error::ProtocolError;

/// The DCS codes this family indexes, in the order it indexes them.
///
/// The standard 104, plus 645, sorted. A record stores the *index* into this
/// list rather than the code itself, so the list's order is load-bearing: get
/// it wrong and every DCS channel comes back as a different code.
pub const DCS_CODES: [u16; 105] = [
    23, 25, 26, 31, 32, 36, 43, 47, 51, 53, 54, 65, 71, 72, 73, 74, 114, 115, 116, 122, 125, 131,
    132, 134, 143, 145, 152, 155, 156, 162, 165, 172, 174, 205, 212, 223, 225, 226, 243, 244, 245,
    246, 251, 252, 255, 261, 263, 265, 266, 271, 274, 306, 311, 315, 325, 331, 332, 343, 346, 351,
    356, 364, 365, 371, 411, 412, 413, 423, 431, 432, 445, 446, 452, 454, 455, 462, 464, 465, 466,
    503, 506, 516, 523, 526, 532, 546, 565, 606, 612, 624, 627, 631, 632, 645, 654, 662, 664, 703,
    712, 723, 731, 732, 734, 743, 754,
];

/// Below this the field is a DCS index; at or above it, tenths of a hertz.
///
/// 600 is 60.0 Hz, comfortably under the lowest standard CTCSS tone (67.0),
/// so the two encodings cannot collide.
const TONE_DCS_CEILING: u16 = 0x0258;

/// Where an inverted DCS index starts.
const DCS_INVERTED_BASE: u16 = 0x6A;

/// A channel's squelch setting for one direction.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Tone {
    #[default]
    None,
    /// CTCSS, in tenths of a hertz -- the same unit the field itself uses.
    Ctcss(u16),
    Dcs {
        code: u16,
        inverted: bool,
    },
}

/// One memory channel, in the terms the app speaks.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ChannelRecord {
    pub name: String,
    pub rx_freq_hz: u32,
    pub tx_freq_hz: u32,
    /// The radio will not transmit here.
    pub rx_only: bool,
    pub tx_tone: Tone,
    pub rx_tone: Tone,
    /// Narrow (12.5 kHz) rather than wide.
    pub narrow: bool,
    pub low_power: bool,
    /// Skipped when scanning.
    pub skip: bool,
}

/// Decode a four-byte little-endian BCD frequency field.
///
/// The field holds the frequency in units of ten hertz, least significant
/// digit pair first. A nibble above 9 is not a digit, and a record carrying
/// one is not a channel -- almost always because it is an unwritten slot full
/// of 0xFF.
fn decode_bcd(bytes: &[u8]) -> Option<u32> {
    let mut value: u32 = 0;
    for &byte in bytes.iter().rev() {
        let high = (byte >> 4) as u32;
        let low = (byte & 0x0F) as u32;
        if high > 9 || low > 9 {
            return None;
        }
        value = value * 100 + high * 10 + low;
    }
    value.checked_mul(10)
}

/// Encode hertz into the same field.
fn encode_bcd(hz: u32, out: &mut [u8]) -> Result<(), ProtocolError> {
    let mut tens = hz / 10;
    if tens > 99_999_999 {
        return Err(ProtocolError::MalformedReply(format!(
            "{hz} Hz does not fit an eight-digit field"
        )));
    }
    for slot in out.iter_mut() {
        let low = (tens % 10) as u8;
        let high = ((tens / 10) % 10) as u8;
        *slot = (high << 4) | low;
        tens /= 100;
    }
    Ok(())
}

/// Read a tone field.
pub fn decode_tone(raw: u16) -> Tone {
    if raw == 0 || raw == 0xFFFF {
        return Tone::None;
    }
    if raw >= TONE_DCS_CEILING {
        return Tone::Ctcss(raw);
    }
    let (index, inverted) = if raw > 0x69 {
        (raw - DCS_INVERTED_BASE, true)
    } else {
        (raw - 1, false)
    };
    match DCS_CODES.get(index as usize) {
        Some(&code) => Tone::Dcs { code, inverted },
        // An index past the table is a field this codec does not understand.
        // No tone is the reading that cannot key a repeater unexpectedly.
        None => Tone::None,
    }
}

/// Write a tone field.
pub fn encode_tone(tone: Tone) -> Result<u16, ProtocolError> {
    Ok(match tone {
        Tone::None => 0,
        Tone::Ctcss(tenths) => {
            if tenths < TONE_DCS_CEILING {
                return Err(ProtocolError::MalformedReply(format!(
                    "{tenths} tenths of a hertz is below the lowest tone this field can hold"
                )));
            }
            tenths
        }
        Tone::Dcs { code, inverted } => {
            let index =
                DCS_CODES.iter().position(|&c| c == code).ok_or_else(|| {
                    ProtocolError::MalformedReply(format!("{code} is not a DCS code"))
                })? as u16;
            if inverted {
                index + 1 + 0x69
            } else {
                index + 1
            }
        }
    })
}

/// Whether a record is an unwritten slot.
fn is_empty_record(record: &[u8]) -> bool {
    record.first() == Some(&0xFF)
}

/// Whether the transmit field says "do not transmit".
fn is_tx_inhibited(tx: &[u8]) -> bool {
    tx.iter().all(|&b| b == 0xFF) || tx.iter().all(|&b| b == 0x00)
}

/// Trim a name field: the radio pads with 0xFF or 0x00, and neither is text.
fn decode_name(raw: &[u8]) -> String {
    raw.iter()
        .take_while(|&&b| b != 0xFF && b != 0x00)
        .map(|&b| b as char)
        .collect::<String>()
        .trim_end()
        .to_string()
}

/// Read one 32-byte record. `None` for an empty slot.
pub fn decode_channel(record: &[u8], name_len: usize) -> Option<ChannelRecord> {
    if record.len() < CHANNEL_RECORD_LEN as usize || is_empty_record(record) {
        return None;
    }

    let rx_freq_hz = decode_bcd(&record[0..4])?;
    if rx_freq_hz == 0 {
        return None;
    }

    let rx_only = is_tx_inhibited(&record[4..8]);
    let tx_freq_hz = if rx_only {
        rx_freq_hz
    } else {
        decode_bcd(&record[4..8]).unwrap_or(rx_freq_hz)
    };

    let rx_tone = decode_tone(u16::from_le_bytes([record[8], record[9]]));
    let tx_tone = if rx_only {
        Tone::None
    } else {
        decode_tone(u16::from_le_bytes([record[10], record[11]]))
    };

    // Byte 14 packs its fields most-significant first; transmit power is the
    // bottom two bits, where 0 is high.
    let low_power = (record[14] & 0x03) != 0;
    // Byte 15, same packing. The bit named "wide" in the layout is set for
    // NARROW -- worth stating, because the obvious reading is backwards.
    let narrow = (record[15] & 0x40) != 0;
    let skip = (record[15] & 0x04) == 0;

    let name_end = (20 + name_len).min(record.len());
    Some(ChannelRecord {
        name: decode_name(&record[20..name_end]),
        rx_freq_hz,
        tx_freq_hz,
        rx_only,
        tx_tone,
        rx_tone,
        narrow,
        low_power,
        skip,
    })
}

/// Write one 32-byte record in place, preserving the bits this codec does not
/// model.
///
/// Preserving them matters: a record carries settings no screen in this app
/// shows -- DTMF codes, busy-channel lockout, scramble -- and a write that
/// zeroed them would quietly undo whatever the owner had set with other
/// software.
pub fn encode_channel(
    record: &mut [u8],
    channel: &ChannelRecord,
    name_len: usize,
) -> Result<(), ProtocolError> {
    if record.len() < CHANNEL_RECORD_LEN as usize {
        return Err(ProtocolError::BufferTooShort {
            needed: CHANNEL_RECORD_LEN as usize,
            got: record.len(),
        });
    }

    // A slot that was empty has no settings worth keeping, and its 0xFF fill
    // would otherwise survive into the flag bytes.
    if is_empty_record(record) {
        record[..CHANNEL_RECORD_LEN as usize].fill(0x00);
    }

    encode_bcd(channel.rx_freq_hz, &mut record[0..4])?;
    if channel.rx_only {
        record[4..8].fill(0xFF);
    } else {
        encode_bcd(channel.tx_freq_hz, &mut record[4..8])?;
    }

    let rx_tone = encode_tone(channel.rx_tone)?;
    let tx_tone = encode_tone(if channel.rx_only {
        Tone::None
    } else {
        channel.tx_tone
    })?;
    record[8..10].copy_from_slice(&rx_tone.to_le_bytes());
    record[10..12].copy_from_slice(&tx_tone.to_le_bytes());

    record[14] = (record[14] & !0x03) | if channel.low_power { 1 } else { 0 };
    let mut flags = record[15] & !(0x40 | 0x04);
    if channel.narrow {
        flags |= 0x40;
    }
    if !channel.skip {
        flags |= 0x04;
    }
    record[15] = flags;

    let field = &mut record[20..20 + name_len];
    field.fill(0x00);
    for (slot, byte) in field.iter_mut().zip(channel.name.bytes().take(name_len)) {
        *slot = byte;
    }
    Ok(())
}

/// Mark a slot unwritten.
pub fn clear_channel(record: &mut [u8]) -> Result<(), ProtocolError> {
    if record.len() < CHANNEL_RECORD_LEN as usize {
        return Err(ProtocolError::BufferTooShort {
            needed: CHANNEL_RECORD_LEN as usize,
            got: record.len(),
        });
    }
    record[..CHANNEL_RECORD_LEN as usize].fill(0xFF);
    Ok(())
}

/// Every channel in an image, by slot, with empties as `None`.
pub fn decode_channels(
    image: &[u8],
    model: &RadioModel,
) -> Result<Vec<Option<ChannelRecord>>, ProtocolError> {
    if image.len() < model.image_len as usize {
        return Err(ProtocolError::BufferTooShort {
            needed: model.image_len as usize,
            got: image.len(),
        });
    }
    Ok((0..model.channel_count)
        .map(|index| {
            model
                .channel_range(index)
                .and_then(|(start, end)| decode_channel(&image[start..end], model.name_len))
        })
        .collect())
}

/// Write `channels` into a copy of `image`, from slot 0 up, clearing the rest.
///
/// A copy rather than a fresh image, because everything this codec does not
/// model -- every setting, every DTMF code -- lives in the same bytes and has
/// to survive.
pub fn encode_channels(
    image: &[u8],
    channels: &[ChannelRecord],
    model: &RadioModel,
) -> Result<Vec<u8>, ProtocolError> {
    if image.len() < model.image_len as usize {
        return Err(ProtocolError::BufferTooShort {
            needed: model.image_len as usize,
            got: image.len(),
        });
    }
    if channels.len() > model.channel_count as usize {
        return Err(ProtocolError::MalformedReply(format!(
            "{} channels do not fit {}'s {} slots",
            channels.len(),
            model.display_name,
            model.channel_count
        )));
    }

    let mut out = image.to_vec();
    for index in 0..model.channel_count {
        let Some((start, end)) = model.channel_range(index) else {
            continue;
        };
        match channels.get(index as usize) {
            Some(channel) => {
                encode_channel(&mut out[start..end], channel, model.name_len)?;
            }
            None => clear_channel(&mut out[start..end])?,
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::radio::models::{UV17R_PLUS, UV5R_MINI};

    /// A blank image the size a Mini reads back, filled the way an unwritten
    /// radio is.
    fn blank_image(model: &RadioModel) -> Vec<u8> {
        vec![0xFF; model.image_len as usize]
    }

    fn channel(name: &str) -> ChannelRecord {
        ChannelRecord {
            name: name.to_string(),
            rx_freq_hz: 146_940_000,
            tx_freq_hz: 146_340_000,
            rx_only: false,
            tx_tone: Tone::Ctcss(1000),
            rx_tone: Tone::None,
            narrow: false,
            low_power: false,
            skip: false,
        }
    }

    #[test]
    fn the_dcs_table_is_the_standard_codes_plus_645() {
        assert_eq!(DCS_CODES.len(), 105);
        assert!(DCS_CODES.contains(&645));
        assert_eq!(DCS_CODES[0], 23);
        assert_eq!(DCS_CODES[104], 754);
        // Sorted, and the order is what the index means.
        let mut sorted = DCS_CODES;
        sorted.sort_unstable();
        assert_eq!(sorted, DCS_CODES);
    }

    #[test]
    fn tones_round_trip() {
        let tones = [
            Tone::None,
            Tone::Ctcss(670),
            Tone::Ctcss(1000),
            Tone::Ctcss(2541),
            Tone::Dcs {
                code: 23,
                inverted: false,
            },
            Tone::Dcs {
                code: 23,
                inverted: true,
            },
            Tone::Dcs {
                code: 645,
                inverted: false,
            },
            Tone::Dcs {
                code: 754,
                inverted: true,
            },
        ];
        for tone in tones {
            let raw = encode_tone(tone).unwrap();
            assert_eq!(decode_tone(raw), tone, "{tone:?} did not survive");
        }
    }

    #[test]
    fn every_ctcss_tone_and_dcs_code_round_trips() {
        for tenths in [670, 693, 719, 1072, 1622, 1995, 2541] {
            assert_eq!(
                decode_tone(encode_tone(Tone::Ctcss(tenths)).unwrap()),
                Tone::Ctcss(tenths)
            );
        }
        for &code in DCS_CODES.iter() {
            for inverted in [false, true] {
                let tone = Tone::Dcs { code, inverted };
                assert_eq!(decode_tone(encode_tone(tone).unwrap()), tone);
            }
        }
    }

    #[test]
    fn both_no_tone_encodings_read_as_no_tone() {
        // An unwritten field is 0xFFFF; a cleared one is 0.
        assert_eq!(decode_tone(0), Tone::None);
        assert_eq!(decode_tone(0xFFFF), Tone::None);
    }

    #[test]
    fn the_two_dcs_index_ranges_meet_exactly_where_they_should() {
        // Normal codes run 1..=105, inverted 0x6A..=0xD2. The boundaries are
        // where an off-by-one turns every inverted code into a normal one.
        assert_eq!(
            decode_tone(1),
            Tone::Dcs {
                code: 23,
                inverted: false
            }
        );
        assert_eq!(
            decode_tone(105),
            Tone::Dcs {
                code: 754,
                inverted: false
            }
        );
        assert_eq!(
            decode_tone(0x6A),
            Tone::Dcs {
                code: 23,
                inverted: true
            }
        );
        assert_eq!(
            decode_tone(0xD2),
            Tone::Dcs {
                code: 754,
                inverted: true
            }
        );
    }

    #[test]
    fn a_tone_index_past_the_table_reads_as_no_tone() {
        // Between the last inverted index and the lowest CTCSS tone there is
        // a band of values that mean nothing. No tone is the reading that
        // cannot key a repeater unexpectedly.
        for raw in [0xD3u16, 300, 0x257] {
            assert_eq!(decode_tone(raw), Tone::None, "0x{raw:04X}");
        }
    }

    #[test]
    fn an_impossible_tone_is_refused_rather_than_written() {
        assert!(encode_tone(Tone::Ctcss(5)).is_err());
        assert!(encode_tone(Tone::Dcs {
            code: 999,
            inverted: false
        })
        .is_err());
    }

    #[test]
    fn frequencies_round_trip_exactly() {
        let mut field = [0u8; 4];
        for hz in [
            146_940_000u32,
            146_340_000,
            462_562_500,
            467_712_500,
            162_550_000,
            446_000_000,
            108_000_000,
            520_000_000,
        ] {
            encode_bcd(hz, &mut field).unwrap();
            assert_eq!(decode_bcd(&field), Some(hz), "{hz} Hz did not survive");
        }
    }

    #[test]
    fn a_frequency_field_is_little_endian_bcd() {
        // 146.940 MHz is 14694000 in units of ten hertz, least significant
        // digit pair first.
        let mut field = [0u8; 4];
        encode_bcd(146_940_000, &mut field).unwrap();
        assert_eq!(field, [0x00, 0x40, 0x69, 0x14]);
    }

    #[test]
    fn a_field_full_of_0xff_is_not_a_frequency() {
        assert_eq!(decode_bcd(&[0xFF, 0xFF, 0xFF, 0xFF]), None);
        assert_eq!(decode_bcd(&[0x00, 0x40, 0x69, 0x1A]), None);
    }

    #[test]
    fn an_unwritten_slot_decodes_as_empty() {
        let record = [0xFFu8; 32];
        assert!(decode_channel(&record, 12).is_none());
    }

    #[test]
    fn a_channel_round_trips_through_a_record() {
        let mut record = [0xFFu8; 32];
        let original = channel("W1AW");
        encode_channel(&mut record, &original, 12).unwrap();
        assert_eq!(decode_channel(&record, 12), Some(original));
    }

    #[test]
    fn every_flag_round_trips() {
        for narrow in [false, true] {
            for low_power in [false, true] {
                for skip in [false, true] {
                    let mut record = [0xFFu8; 32];
                    let mut original = channel("FLAGS");
                    original.narrow = narrow;
                    original.low_power = low_power;
                    original.skip = skip;
                    encode_channel(&mut record, &original, 12).unwrap();
                    let decoded = decode_channel(&record, 12).unwrap();
                    assert_eq!(decoded.narrow, narrow);
                    assert_eq!(decoded.low_power, low_power);
                    assert_eq!(decoded.skip, skip);
                }
            }
        }
    }

    #[test]
    fn a_receive_only_channel_writes_an_inhibited_transmit_field() {
        // This is the byte pattern that stops the radio keying, and it is
        // what a weather channel depends on.
        let mut record = [0xFFu8; 32];
        let mut original = channel("WX1");
        original.rx_only = true;
        original.rx_freq_hz = 162_550_000;
        original.tx_freq_hz = 162_550_000;
        encode_channel(&mut record, &original, 12).unwrap();

        assert_eq!(&record[4..8], &[0xFF, 0xFF, 0xFF, 0xFF]);
        let decoded = decode_channel(&record, 12).unwrap();
        assert!(decoded.rx_only);
        assert_eq!(decoded.tx_freq_hz, decoded.rx_freq_hz);
        assert_eq!(decoded.tx_tone, Tone::None);
    }

    #[test]
    fn a_zeroed_transmit_field_also_reads_as_receive_only() {
        let mut record = [0x00u8; 32];
        encode_bcd(162_550_000, &mut record[0..4]).unwrap();
        let decoded = decode_channel(&record, 12).unwrap();
        assert!(decoded.rx_only);
    }

    #[test]
    fn a_receive_only_channel_cannot_carry_a_transmit_tone() {
        let mut record = [0xFFu8; 32];
        let mut original = channel("QUIET");
        original.rx_only = true;
        original.tx_tone = Tone::Ctcss(1000);
        encode_channel(&mut record, &original, 12).unwrap();
        assert_eq!(&record[10..12], &[0x00, 0x00]);
    }

    #[test]
    fn names_are_clipped_and_padded_rather_than_overrunning() {
        let mut record = [0x00u8; 32];
        let mut original = channel("A NAME FAR TOO LONG");
        original.name = "A NAME FAR TOO LONG".to_string();
        encode_channel(&mut record, &original, 12).unwrap();

        // Nothing written past the record.
        assert_eq!(decode_channel(&record, 12).unwrap().name, "A NAME FAR T");
        assert_eq!(record.len(), 32);
    }

    #[test]
    fn a_name_padded_by_the_radio_comes_back_trimmed() {
        let mut record = [0x00u8; 32];
        encode_bcd(146_940_000, &mut record[0..4]).unwrap();
        encode_bcd(146_940_000, &mut record[4..8]).unwrap();
        record[20..32].copy_from_slice(b"W1AW\xFF\xFF\xFF\xFF\xFF\xFF\xFF\xFF");
        assert_eq!(decode_channel(&record, 12).unwrap().name, "W1AW");

        record[20..32].copy_from_slice(b"W1AW        ");
        assert_eq!(decode_channel(&record, 12).unwrap().name, "W1AW");
    }

    #[test]
    fn writing_a_channel_preserves_the_bits_this_codec_does_not_model() {
        // A record carries settings no screen in this app shows. Zeroing them
        // would quietly undo whatever the owner set with other software.
        let mut record = [0x00u8; 32];
        record[12] = 0x03; // scode
        record[13] = 0x02; // pttid
        record[14] = 0x30; // scramble bits
        record[15] = 0x08; // bcl
        record[16..20].copy_from_slice(&[0xAA, 0xBB, 0xCC, 0xDD]);

        encode_channel(&mut record, &channel("KEEP"), 12).unwrap();

        assert_eq!(record[12], 0x03);
        assert_eq!(record[13], 0x02);
        assert_eq!(record[14] & 0xF0, 0x30);
        assert_eq!(record[15] & 0x08, 0x08);
        assert_eq!(&record[16..20], &[0xAA, 0xBB, 0xCC, 0xDD]);
    }

    #[test]
    fn writing_over_an_unwritten_slot_clears_its_fill_first() {
        // Without this the 0xFF fill survives into the flag bytes and every
        // freshly written channel comes back low-power, narrow and skipped.
        let mut record = [0xFFu8; 32];
        let mut original = channel("FRESH");
        original.narrow = false;
        original.low_power = false;
        original.skip = false;
        encode_channel(&mut record, &original, 12).unwrap();

        let decoded = decode_channel(&record, 12).unwrap();
        assert!(!decoded.narrow);
        assert!(!decoded.low_power);
        assert!(!decoded.skip);
    }

    #[test]
    fn clearing_a_slot_makes_it_empty_again() {
        let mut record = [0x00u8; 32];
        encode_channel(&mut record, &channel("GONE"), 12).unwrap();
        clear_channel(&mut record).unwrap();
        assert!(decode_channel(&record, 12).is_none());
    }

    #[test]
    fn a_short_record_is_an_error_rather_than_a_panic() {
        let mut short = [0u8; 8];
        assert!(encode_channel(&mut short, &channel("X"), 12).is_err());
        assert!(clear_channel(&mut short).is_err());
        assert!(decode_channel(&short, 12).is_none());
    }

    #[test]
    fn a_whole_image_round_trips() {
        let image = blank_image(&UV5R_MINI);
        let channels = vec![channel("ONE"), channel("TWO"), channel("THREE")];
        let written = encode_channels(&image, &channels, &UV5R_MINI).unwrap();

        let read_back = decode_channels(&written, &UV5R_MINI).unwrap();
        assert_eq!(read_back.len(), UV5R_MINI.channel_count as usize);
        assert_eq!(read_back[0].as_ref().unwrap().name, "ONE");
        assert_eq!(read_back[2].as_ref().unwrap().name, "THREE");
        assert!(read_back[3].is_none());
        assert!(read_back[998].is_none());
    }

    #[test]
    fn encoding_is_stable_across_a_second_pass() {
        // The property that matters for a write-read-write cycle: nothing
        // drifts.
        let image = blank_image(&UV5R_MINI);
        let channels = vec![channel("ONE"), channel("TWO")];
        let once = encode_channels(&image, &channels, &UV5R_MINI).unwrap();
        let decoded: Vec<ChannelRecord> = decode_channels(&once, &UV5R_MINI)
            .unwrap()
            .into_iter()
            .flatten()
            .collect();
        let twice = encode_channels(&once, &decoded, &UV5R_MINI).unwrap();
        assert_eq!(once, twice);
    }

    #[test]
    fn writing_channels_leaves_the_rest_of_the_image_alone() {
        // The settings blocks live in the same image and must survive.
        let mut image = blank_image(&UV5R_MINI);
        image[0x8080] = 0x42;
        image[0x8200] = 0x43;

        let written = encode_channels(&image, &[channel("ONE")], &UV5R_MINI).unwrap();
        assert_eq!(written[0x8080], 0x42);
        assert_eq!(written[0x8200], 0x43);
        assert_eq!(written.len(), image.len());
    }

    #[test]
    fn more_channels_than_slots_is_refused() {
        let image = blank_image(&UV5R_MINI);
        let too_many = vec![channel("X"); UV5R_MINI.channel_count as usize + 1];
        assert!(encode_channels(&image, &too_many, &UV5R_MINI).is_err());
    }

    #[test]
    fn a_short_image_is_refused_rather_than_read_past() {
        let short = vec![0xFFu8; 16];
        assert!(decode_channels(&short, &UV5R_MINI).is_err());
        assert!(encode_channels(&short, &[], &UV5R_MINI).is_err());
    }

    #[test]
    fn the_larger_family_members_use_the_same_record() {
        let image = blank_image(&UV17R_PLUS);
        let written = encode_channels(&image, &[channel("SAME")], &UV17R_PLUS).unwrap();
        assert_eq!(
            decode_channels(&written, &UV17R_PLUS).unwrap()[0]
                .as_ref()
                .unwrap()
                .name,
            "SAME"
        );
    }
}

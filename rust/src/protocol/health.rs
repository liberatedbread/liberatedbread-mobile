// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

use anyhow::{anyhow, bail, Result};

use crate::codec::types::{decode_all_fields, DecodedValues};
use crate::spec::types::{Characteristic, DeviceSpec, FormatField, Service};

#[derive(Debug, Clone, PartialEq)]
pub struct PulseOxSample {
    pub spo2_percent: f64,
    pub pulse_bpm: f64,
    pub perfusion_index_percent: Option<f64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct BloodPressureReading {
    pub systolic_mmhg: f64,
    pub diastolic_mmhg: f64,
    pub mean_arterial_mmhg: Option<f64>,
    pub pulse_bpm: Option<f64>,
    pub measured_at: Option<String>,
    pub user_slot: Option<u8>,
    pub irregular_heartbeat: Option<bool>,
    pub sufficient_rest: Option<bool>,
    pub converted_from_kpa: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum HealthSample {
    PulseOximeter(PulseOxSample),
    BloodPressure(BloodPressureReading),
    /// A well-formed frame that carries no measurement: an oximeter with no
    /// finger in it, or one of its other frame types. Not an error, and not
    /// a value to show.
    NoReading,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PulseOxSession {
    pub record_index: u8,
    pub started_at: String,
    pub ended_at: String,
    pub spo2_min: u8,
    pub spo2_max: u8,
    pub spo2_avg: u8,
    pub pulse_min_bpm: u16,
    pub pulse_max_bpm: u16,
    pub pulse_avg_bpm: u16,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PulseOxHistoryChunk {
    pub consumed: usize,
    pub sessions: Vec<PulseOxSession>,
    pub records: u8,
    /// Records that arrived whole and would not read as a session. They are
    /// consumed and counted rather than failing the transfer: one bad record
    /// used to take every session after it with it.
    pub skipped: u8,
    pub end_of_transfer: bool,
}

pub fn decode_live_sample(
    spec: &DeviceSpec,
    char_uuid: &str,
    bytes: &[u8],
) -> Result<HealthSample> {
    let kind = spec
        .device
        .category_hierarchy
        .last()
        .map(String::as_str)
        .unwrap_or_default();
    match kind {
        "pulse_oximetry" if has_command(spec, "poll_measurement") => {
            decode_f7_sample(bytes).map(|sample| match sample {
                Some(sample) => HealthSample::PulseOximeter(sample),
                None => HealthSample::NoReading,
            })
        }
        "blood_pressure" => {
            decode_blood_pressure(spec, char_uuid, bytes).map(HealthSample::BloodPressure)
        }
        _ => bail!("no live health decoder for characteristic {char_uuid}"),
    }
}

pub fn decode_po60_history(spec: &DeviceSpec, bytes: &[u8]) -> Result<PulseOxHistoryChunk> {
    if spec.device.category_hierarchy.last().map(String::as_str) != Some("pulse_oximetry") {
        bail!("stored pulse-ox history requested for a different device kind");
    }
    let (_, response) = po60_response(spec)?;
    let fields = response
        .format
        .as_deref()
        .ok_or_else(|| anyhow!("PO60 response characteristic has no record format"))?;
    const RECORD_LEN: usize = 24;
    if fields.is_empty()
        || fields
            .iter()
            .any(|field| field.offset + field.length > RECORD_LEN)
    {
        bail!("PO60 record format does not fit its 24-byte frame");
    }

    let mut sessions = Vec::new();
    let mut records = 0_u8;
    let mut skipped = 0_u8;
    let mut consumed = 0;
    let mut end_of_transfer = false;
    while consumed < bytes.len() {
        if bytes[consumed] != 0xE9 {
            let Some(relative) = bytes[consumed..].iter().position(|byte| *byte == 0xE9) else {
                consumed = bytes.len();
                break;
            };
            consumed += relative;
        }
        if bytes.len() - consumed < RECORD_LEN {
            break;
        }
        let record = &bytes[consumed..consumed + RECORD_LEN];
        let record_index = masked_field(record, fields, "record_index", false)
            .ok_or_else(|| anyhow!("PO60 record has no index"))? as u8;
        consumed += RECORD_LEN;
        let session = decode_po60_session(record, fields, record_index);
        if record_index >> 4 == 0x4 {
            // The flag marks the LAST record, and the spec does not say it
            // is an empty one — it carries a record index like the rest. So
            // a session in it is kept; anything else is just the terminator.
            if let Ok(session) = session {
                sessions.push(session);
            }
            end_of_transfer = true;
            break;
        }
        match session {
            Ok(session) => sessions.push(session),
            Err(_) => skipped = skipped.saturating_add(1),
        }
        records = records.saturating_add(1);
    }

    Ok(PulseOxHistoryChunk {
        consumed,
        sessions,
        records,
        skipped,
        end_of_transfer,
    })
}

/// `None` for a frame that is the oximeter's but holds no reading: another
/// frame type on the same characteristic (history packets ride it too), or
/// zeros for SpO2 or pulse, which is how the sensor says nothing is in it.
/// Zero is not a physiological value, and shown as one it lands in the
/// reference table's lowest band.
fn decode_f7_sample(bytes: &[u8]) -> Result<Option<PulseOxSample>> {
    if bytes.len() < 9 {
        bail!(
            "F7 measurement is short: expected 9 bytes, got {}",
            bytes.len()
        );
    }
    if bytes[0] != 0xAB {
        bail!("notification is not an F7 measurement response");
    }
    if bytes[4] != 0x30 {
        return Ok(None);
    }
    let spo2 = bytes[7];
    if spo2 > 100 {
        bail!("F7 reported an invalid SpO2 percentage");
    }
    if spo2 == 0 || bytes[6] == 0 {
        return Ok(None);
    }
    Ok(Some(PulseOxSample {
        spo2_percent: f64::from(spo2),
        pulse_bpm: f64::from(bytes[6]),
        perfusion_index_percent: Some(f64::from(bytes[8]) / 10.0),
    }))
}

fn decode_blood_pressure(
    spec: &DeviceSpec,
    char_uuid: &str,
    bytes: &[u8],
) -> Result<BloodPressureReading> {
    let (_, characteristic) = spec
        .find_decodable_characteristic(char_uuid)
        .ok_or_else(|| anyhow!("blood-pressure characteristic {char_uuid} has no format"))?;
    let values = decode_all_fields(bytes, characteristic.format.as_deref().unwrap_or_default())?;
    let flags = required_raw(&values, "flags")? as u8;
    let kpa = flags & 0x01 != 0;
    let pressure = |name: &str| -> Result<f64> {
        let raw = required_raw(&values, name)? as u16;
        let value = decode_sfloat(raw)
            .ok_or_else(|| anyhow!("blood-pressure field {name} is not a finite SFLOAT"))?;
        Ok(if kpa { value * 7.50061683 } else { value })
    };
    let optional_pressure = |name: &str| -> Option<f64> {
        let raw = optional_raw(&values, name)? as u16;
        let value = decode_sfloat(raw)?;
        value
            .is_finite()
            .then_some(if kpa { value * 7.50061683 } else { value })
    };
    let status = optional_raw(&values, "status").map(|value| value as u8);
    let systolic = pressure("systolic_sfloat")?;
    let diastolic = pressure("diastolic_sfloat")?;
    // A cuff that has no result says so in zeros, and 0/0 would be shown
    // against the reference table as a normal pressure.
    if systolic <= 0.0 || diastolic <= 0.0 {
        bail!("blood-pressure record carries no result");
    }

    Ok(BloodPressureReading {
        systolic_mmhg: systolic,
        diastolic_mmhg: diastolic,
        mean_arterial_mmhg: optional_pressure("map_sfloat"),
        pulse_bpm: optional_raw(&values, "pulse_sfloat")
            .and_then(|raw| decode_sfloat(raw as u16))
            .filter(|value| value.is_finite()),
        measured_at: timestamp_from_decoded(&values),
        user_slot: optional_raw(&values, "user_slot").map(|value| value as u8),
        irregular_heartbeat: status.map(|value| value & 0x04 != 0),
        sufficient_rest: status.and_then(|value| match (value >> 6) & 0x03 {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }),
        converted_from_kpa: kpa,
    })
}

fn decode_sfloat(raw: u16) -> Option<f64> {
    let exponent = i32::from((raw >> 12) as u8);
    let exponent = if exponent >= 8 {
        exponent - 16
    } else {
        exponent
    };
    let mantissa = raw & 0x0FFF;
    if exponent == 0 && matches!(mantissa, 0x07FE..=0x0802) {
        return None;
    }
    let mantissa = if mantissa & 0x0800 != 0 {
        (mantissa | 0xF000) as i16
    } else {
        mantissa as i16
    };
    let value = f64::from(mantissa) * 10_f64.powi(exponent);
    value.is_finite().then_some(value)
}

fn decode_po60_session(
    record: &[u8],
    fields: &[FormatField],
    record_index: u8,
) -> Result<PulseOxSession> {
    let required = |name: &str| {
        masked_field(record, fields, name, true)
            .ok_or_else(|| anyhow!("PO60 record is missing {name}"))
    };
    let escape = required("pr_escape_flags")? as u8;
    let escaped_pulse = |name: &str, bit: u8| -> Result<u16> {
        let value = required(name)? as u16;
        Ok(value + if escape & bit != 0 { 128 } else { 0 })
    };
    let spo2_max = required("spo2_max")? as u8;
    let spo2_min = required("spo2_min")? as u8;
    let spo2_avg = required("spo2_avg")? as u8;
    let pulse_max_bpm = escaped_pulse("pr_max", 0x04)?;
    let pulse_min_bpm = escaped_pulse("pr_min", 0x08)?;
    let pulse_avg_bpm = escaped_pulse("pr_avg", 0x10)?;
    // Zero is an empty slot (or a terminator), not a session at 0 %.
    if spo2_min == 0 || pulse_min_bpm == 0 {
        bail!("PO60 record carries no measurement");
    }
    if spo2_max > 100 || spo2_min > spo2_avg || spo2_avg > spo2_max {
        bail!("PO60 record has inconsistent SpO2 summary values");
    }
    if pulse_min_bpm > pulse_avg_bpm || pulse_avg_bpm > pulse_max_bpm {
        bail!("PO60 record has inconsistent pulse summary values");
    }
    let started_at = timestamp_from_record(record, fields, "start_")?;
    let ended_at = timestamp_from_record(record, fields, "end_")?;
    if ended_at < started_at {
        bail!("PO60 session ends before it starts");
    }
    Ok(PulseOxSession {
        record_index: record_index & 0x0F,
        started_at,
        ended_at,
        spo2_max,
        spo2_min,
        spo2_avg,
        pulse_max_bpm,
        pulse_min_bpm,
        pulse_avg_bpm,
    })
}

fn timestamp_from_record(record: &[u8], fields: &[FormatField], prefix: &str) -> Result<String> {
    let part = |name: &str| {
        masked_field(record, fields, &format!("{prefix}{name}"), true)
            .ok_or_else(|| anyhow!("PO60 timestamp is missing {prefix}{name}"))
    };
    let year = part("year")? as i32;
    let month = part("month")? as u32;
    let day = part("day")? as u32;
    let hour = part("hour")? as u32;
    let minute = part("minute")? as u32;
    let second = part("second")? as u32;
    valid_timestamp(year, month, day, hour, minute, second)
        .ok_or_else(|| anyhow!("PO60 record contains an invalid timestamp"))
}

fn timestamp_from_decoded(values: &DecodedValues) -> Option<String> {
    let year = optional_raw(values, "year")? as i32;
    let month = optional_raw(values, "month")? as u32;
    let day = optional_raw(values, "day")? as u32;
    let hour = optional_raw(values, "hour")? as u32;
    let minute = optional_raw(values, "minute")? as u32;
    let second = optional_raw(values, "second")? as u32;
    valid_timestamp(year, month, day, hour, minute, second)
}

pub(crate) fn valid_timestamp(
    year: i32,
    month: u32,
    day: u32,
    hour: u32,
    minute: u32,
    second: u32,
) -> Option<String> {
    let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    let days = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return None,
    };
    if !(1..=days).contains(&day) || hour > 23 || minute > 59 || second > 59 {
        return None;
    }
    Some(format!(
        "{year:04}-{month:02}-{day:02}T{hour:02}:{minute:02}:{second:02}"
    ))
}

fn masked_field(
    record: &[u8],
    fields: &[FormatField],
    name: &str,
    apply_transform: bool,
) -> Option<i64> {
    let field = fields.iter().find(|field| field.name == name)?;
    if field.length != 1 || record.get(field.offset).is_none() {
        return None;
    }
    let mut value = i64::from(record[field.offset] & 0x7F);
    if apply_transform {
        value = (value as f64 * field.scale.unwrap_or(1.0) + field.value_offset.unwrap_or(0.0))
            .round() as i64;
    }
    Some(value)
}

fn required_raw(values: &DecodedValues, name: &str) -> Result<i64> {
    optional_raw(values, name).ok_or_else(|| anyhow!("health record is missing {name}"))
}

fn optional_raw(values: &DecodedValues, name: &str) -> Option<i64> {
    values.get(name)?.as_int()
}

fn has_command(spec: &DeviceSpec, name: &str) -> bool {
    spec.services.iter().any(|service| {
        service.characteristics.iter().any(|characteristic| {
            characteristic
                .commands
                .as_ref()
                .is_some_and(|commands| commands.contains_key(name))
        })
    })
}

fn po60_response(spec: &DeviceSpec) -> Result<(&Service, &Characteristic)> {
    let service = spec
        .services
        .iter()
        .find(|service| {
            service.characteristics.iter().any(|characteristic| {
                characteristic
                    .commands
                    .as_ref()
                    .is_some_and(|commands| commands.contains_key("get_measurements_page"))
            })
        })
        .ok_or_else(|| anyhow!("spec has no PO60 history command"))?;
    service
        .characteristics
        .iter()
        .find(|characteristic| characteristic.format.is_some())
        .map(|characteristic| (service, characteristic))
        .ok_or_else(|| anyhow!("spec has no PO60 history response format"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::dispatch::parse_or_cached;

    #[test]
    fn decodes_f7_values_and_rejects_wrong_frames() {
        let sample = decode_f7_sample(&[0xAB, 0, 3, 0xFF, 0x30, 0x80, 72, 97, 15])
            .unwrap()
            .unwrap();
        assert_eq!(sample.spo2_percent, 97.0);
        assert_eq!(sample.pulse_bpm, 72.0);
        assert_eq!(sample.perfusion_index_percent, Some(1.5));
        assert!(decode_f7_sample(&[0xAB, 0, 3]).is_err());
        assert!(decode_f7_sample(&[0x00, 0, 3, 0xFF, 0x30, 0x80, 72, 97, 15]).is_err());
        assert!(decode_f7_sample(&[0xAB, 0, 3, 0xFF, 0x30, 0x80, 72, 101, 15]).is_err());
    }

    #[test]
    fn an_f7_frame_with_nothing_in_it_is_no_reading_not_zero_percent() {
        // No finger: zeros where the values go. Shown as a value, 0 % SpO2
        // sits in the reference table's hypoxemia band.
        for frame in [
            [0xAB, 0, 3, 0xFF, 0x30, 0x80, 0, 0, 0],
            [0xAB, 0, 3, 0xFF, 0x30, 0x80, 72, 0, 15],
            [0xAB, 0, 3, 0xFF, 0x30, 0x80, 0, 97, 15],
            // Another frame type on the same characteristic.
            [0xAB, 0, 3, 0xFF, 0x51, 0x80, 72, 97, 15],
        ] {
            assert_eq!(decode_f7_sample(&frame).unwrap(), None, "{frame:02x?}");
        }
    }

    #[test]
    fn a_blood_pressure_record_of_zeros_is_not_a_reading() {
        let spec = beurer_spec();
        let mut record = [
            0x02, 0x00, 0x78, 0x00, 0x50, 0x00, 0x5D, 0xEA, 0x07, 11, 8, 14, 32, 15, 0x00, 0x48, 2,
            0, 0x44,
        ];
        record[1..5].fill(0);
        let error = decode_blood_pressure(&spec, BP_CHAR, &record).unwrap_err();
        assert!(error.to_string().contains("no result"), "{error}");
    }

    #[test]
    fn decodes_beurer_big_endian_sfloat_timestamp_and_flags() {
        let bytes = [
            0x02, 0x00, 0x78, 0x00, 0x50, 0x00, 0x5D, 0xEA, 0x07, 11, 8, 14, 32, 15, 0x00, 0x48, 2,
            0, 0x44,
        ];
        let spec = beurer_spec();
        let reading = decode_blood_pressure(&spec, BP_CHAR, &bytes).unwrap();
        assert_eq!(reading.systolic_mmhg, 120.0);
        assert_eq!(reading.diastolic_mmhg, 80.0);
        assert_eq!(reading.mean_arterial_mmhg, Some(93.0));
        assert_eq!(reading.pulse_bpm, Some(72.0));
        assert_eq!(reading.measured_at.as_deref(), Some("2026-11-08T14:32:15"));
        assert_eq!(reading.user_slot, Some(2));
        assert_eq!(reading.irregular_heartbeat, Some(true));
        assert_eq!(reading.sufficient_rest, Some(true));
        assert!(!reading.converted_from_kpa);
    }

    #[test]
    fn converts_kpa_pressures_but_not_pulse() {
        let bytes = [
            0x03, 0xF0, 0xA0, 0xF0, 0x6B, 0xF0, 0x78, 0xEA, 0x07, 11, 8, 14, 32, 15, 0x00, 0x48, 1,
            0, 0,
        ];
        let reading = decode_blood_pressure(&beurer_spec(), BP_CHAR, &bytes).unwrap();
        assert!((reading.systolic_mmhg - 120.00986928).abs() < 0.000001);
        assert!((reading.diastolic_mmhg - 80.256601).abs() < 0.0001);
        assert_eq!(reading.pulse_bpm, Some(72.0));
        assert!(reading.converted_from_kpa);
    }

    #[test]
    fn sfloat_handles_fractions_signed_mantissas_and_sentinels() {
        assert_eq!(decode_sfloat(0xF09E), Some(15.8));
        assert_eq!(decode_sfloat(0xFFFE), Some(-0.2));
        for sentinel in [0x07FE, 0x07FF, 0x0800, 0x0801, 0x0802] {
            assert_eq!(decode_sfloat(sentinel), None);
        }
    }

    #[test]
    fn po60_reassembles_chunks_and_applies_pulse_escape_bits() {
        let first = po60_record(1, false);
        let mut second = po60_record(2, false);
        second[14] = 0x1C;
        second[20] = 71;
        second[21] = 60;
        second[22] = 65;
        let end = po60_record(3, true);
        let wire = [first.as_slice(), second.as_slice(), end.as_slice()].concat();
        let split = 20;
        let first_chunk = decode_po60_history(&po60_spec(), &wire[..split]).unwrap();
        assert_eq!(first_chunk.consumed, 0);
        assert!(first_chunk.sessions.is_empty());
        let all = decode_po60_history(&po60_spec(), &wire).unwrap();
        assert_eq!(all.consumed, wire.len());
        assert_eq!(all.records, 2);
        assert!(all.end_of_transfer);
        // The flagged record is the last SESSION, not a bare terminator.
        assert_eq!(all.sessions.len(), 3);
        assert_eq!(all.sessions[2].record_index, 3);
        assert_eq!(all.sessions[0].started_at, "2026-11-08T14:30:01");
        assert_eq!(all.sessions[0].ended_at, "2026-11-08T14:31:02");
        assert_eq!(all.sessions[1].pulse_max_bpm, 199);
        assert_eq!(all.sessions[1].pulse_min_bpm, 188);
        assert_eq!(all.sessions[1].pulse_avg_bpm, 193);
    }

    #[test]
    fn po60_skips_clock_ack_and_preserves_partial_records() {
        let record = po60_record(1, false);
        let wire = [&[0xF3, 0x00], &record[..10]].concat();
        let chunk = decode_po60_history(&po60_spec(), &wire).unwrap();
        assert_eq!(chunk.consumed, 2);
        assert!(chunk.sessions.is_empty());
        assert!(!chunk.end_of_transfer);
    }

    #[test]
    fn po60_skips_a_record_it_cannot_read_and_keeps_the_rest() {
        // An impossible date, then inconsistent SpO2, then a good record.
        let mut bad_date = po60_record(1, false);
        bad_date[3] = 2;
        bad_date[4] = 30;
        let mut bad_summary = po60_record(2, false);
        bad_summary[18] = 98;
        let good = po60_record(3, false);
        let wire = [bad_date.as_slice(), bad_summary.as_slice(), good.as_slice()].concat();
        let chunk = decode_po60_history(&po60_spec(), &wire).unwrap();
        assert_eq!(chunk.consumed, wire.len());
        assert_eq!(chunk.records, 3);
        assert_eq!(chunk.skipped, 2);
        assert_eq!(chunk.sessions.len(), 1);
        assert_eq!(chunk.sessions[0].record_index, 3);
    }

    #[test]
    fn po60_end_record_with_no_session_in_it_is_only_the_end() {
        let mut end = po60_record(1, true);
        end[2..].fill(0);
        let chunk = decode_po60_history(&po60_spec(), &end).unwrap();
        assert!(chunk.end_of_transfer);
        assert!(chunk.sessions.is_empty());
        assert_eq!(chunk.skipped, 0);

        let mut record = po60_record(1, false);
        record[20] = 60;
        let chunk = decode_po60_history(&po60_spec(), &record).unwrap();
        assert_eq!((chunk.skipped, chunk.sessions.len()), (1, 0));
    }

    const BP_CHAR: &str = "00002a35-0000-1000-8000-00805f9b34fb";

    fn beurer_spec() -> std::sync::Arc<DeviceSpec> {
        parse_or_cached(include_str!("../../../vendor/protocol-specs/device-specs/devices/beurer-series800-blood-pressure.yaml"))
            .unwrap()
    }

    fn po60_spec() -> std::sync::Arc<DeviceSpec> {
        parse_or_cached(include_str!(
            "../../../vendor/protocol-specs/device-specs/devices/beurer-po60-pulse-oximeter.yaml"
        ))
        .unwrap()
    }

    fn po60_record(index: u8, end: bool) -> [u8; 24] {
        let mut record = [0_u8; 24];
        record[0] = 0xE9;
        record[1] = if end { 0x40 | index } else { index };
        record[2..8].copy_from_slice(&[26, 11, 8, 14, 30, 1]);
        record[8..14].copy_from_slice(&[26, 11, 8, 14, 31, 2]);
        record[17] = 99;
        record[18] = 94;
        record[19] = 97;
        record[20] = 80;
        record[21] = 65;
        record[22] = 72;
        record
    }
}

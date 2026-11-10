// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

use std::collections::HashMap;

use anyhow::{bail, Result};

use super::device_api::{encode_command_with_spec, EntityWriteDto};
use crate::protocol::health::{
    self, BloodPressureReading, HealthSample, PulseOxHistoryChunk, PulseOxSample, PulseOxSession,
};
use crate::spec::types::DeviceSpec;

#[derive(Debug, Clone)]
pub struct PulseOxSampleDto {
    pub spo2_percent: f64,
    pub pulse_bpm: f64,
    pub perfusion_index_percent: Option<f64>,
}

#[derive(Debug, Clone)]
pub struct BloodPressureReadingDto {
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

#[derive(Debug, Clone)]
pub struct HealthSampleDto {
    pub pulse_oximeter: Option<PulseOxSampleDto>,
    pub blood_pressure: Option<BloodPressureReadingDto>,
}

#[derive(Debug, Clone)]
pub struct PulseOxSessionDto {
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

#[derive(Debug, Clone)]
pub struct PulseOxHistoryChunkDto {
    pub consumed: u32,
    pub sessions: Vec<PulseOxSessionDto>,
    pub records: u8,
    pub skipped: u8,
    pub end_of_transfer: bool,
}

#[derive(Debug, Clone)]
pub struct HealthClockDto {
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
}

pub fn decode_health_sample(
    spec_yaml: String,
    char_uuid: String,
    bytes: Vec<u8>,
) -> Result<HealthSampleDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    Ok(health::decode_live_sample(&spec, &char_uuid, &bytes)?.into())
}

pub fn decode_pulse_ox_history(
    spec_yaml: String,
    bytes: Vec<u8>,
) -> Result<PulseOxHistoryChunkDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    Ok(health::decode_po60_history(&spec, &bytes)?.into())
}

pub fn encode_health_command(
    spec_yaml: String,
    command_name: String,
    page: Option<u8>,
    clock: Option<HealthClockDto>,
) -> Result<EntityWriteDto> {
    let spec = crate::protocol::dispatch::parse_or_cached(&spec_yaml)?;
    let (service_uuid, char_uuid) = command_binding(&spec, &command_name)?;
    let mut params = HashMap::new();
    match command_name.as_str() {
        "poll_measurement" => {}
        "get_measurements_page" => {
            let page = page.unwrap_or(0);
            if page > 1 {
                bail!("PO60 history page selector must be start (0) or next (1)");
            }
            params.insert("page".to_string(), f64::from(page));
            params.insert(
                "checksum".to_string(),
                f64::from((i16::from(page) - 103).rem_euclid(128) as u8),
            );
        }
        "set_datetime" => {
            let clock = clock.ok_or_else(|| anyhow::anyhow!("clock sync needs a time"))?;
            let timestamp = health::valid_timestamp(
                i32::from(clock.year),
                u32::from(clock.month),
                u32::from(clock.day),
                u32::from(clock.hour),
                u32::from(clock.minute),
                u32::from(clock.second),
            );
            if timestamp.is_none() || !(2000..=2099).contains(&clock.year) {
                bail!("clock sync needs a valid date between 2000 and 2099");
            }
            params.insert("year".to_string(), f64::from(clock.year - 2000));
            params.insert("month".to_string(), f64::from(clock.month));
            params.insert("day".to_string(), f64::from(clock.day));
            params.insert("hour".to_string(), f64::from(clock.hour));
            params.insert("minute".to_string(), f64::from(clock.minute));
            params.insert("second".to_string(), f64::from(clock.second));
            params.insert("checksum".to_string(), 0.0);
        }
        _ => bail!("unsupported health command {command_name}"),
    }

    let mut bytes = encode_command_with_spec(
        spec,
        Some(service_uuid.clone()),
        char_uuid.clone(),
        command_name.clone(),
        params,
    )?;
    if command_name == "set_datetime" {
        if bytes.len() != 10 || bytes.first() != Some(&0x83) {
            bail!("unexpected PO60 clock command layout");
        }
        let checksum = bytes[..bytes.len() - 1]
            .iter()
            .fold(0_u8, |sum, byte| sum.wrapping_add(*byte))
            & 0x7F;
        let last = bytes.last_mut().expect("length checked above");
        *last = checksum;
    }
    Ok(EntityWriteDto {
        service_uuid,
        characteristic_uuid: char_uuid,
        bytes,
    })
}

fn command_binding(spec: &DeviceSpec, command_name: &str) -> Result<(String, String)> {
    for service in &spec.services {
        for characteristic in &service.characteristics {
            if characteristic
                .commands
                .as_ref()
                .is_some_and(|commands| commands.contains_key(command_name))
            {
                return Ok((service.uuid.clone(), characteristic.uuid.clone()));
            }
        }
    }
    bail!("spec does not declare health command {command_name}")
}

impl From<PulseOxSample> for PulseOxSampleDto {
    fn from(sample: PulseOxSample) -> Self {
        Self {
            spo2_percent: sample.spo2_percent,
            pulse_bpm: sample.pulse_bpm,
            perfusion_index_percent: sample.perfusion_index_percent,
        }
    }
}

impl From<BloodPressureReading> for BloodPressureReadingDto {
    fn from(reading: BloodPressureReading) -> Self {
        Self {
            systolic_mmhg: reading.systolic_mmhg,
            diastolic_mmhg: reading.diastolic_mmhg,
            mean_arterial_mmhg: reading.mean_arterial_mmhg,
            pulse_bpm: reading.pulse_bpm,
            measured_at: reading.measured_at,
            user_slot: reading.user_slot,
            irregular_heartbeat: reading.irregular_heartbeat,
            sufficient_rest: reading.sufficient_rest,
            converted_from_kpa: reading.converted_from_kpa,
        }
    }
}

impl From<HealthSample> for HealthSampleDto {
    fn from(sample: HealthSample) -> Self {
        match sample {
            HealthSample::PulseOximeter(sample) => Self {
                pulse_oximeter: Some(sample.into()),
                blood_pressure: None,
            },
            HealthSample::BloodPressure(reading) => Self {
                pulse_oximeter: None,
                blood_pressure: Some(reading.into()),
            },
            // Neither: a frame with nothing to show.
            HealthSample::NoReading => Self {
                pulse_oximeter: None,
                blood_pressure: None,
            },
        }
    }
}

impl From<PulseOxSession> for PulseOxSessionDto {
    fn from(session: PulseOxSession) -> Self {
        Self {
            record_index: session.record_index,
            started_at: session.started_at,
            ended_at: session.ended_at,
            spo2_min: session.spo2_min,
            spo2_max: session.spo2_max,
            spo2_avg: session.spo2_avg,
            pulse_min_bpm: session.pulse_min_bpm,
            pulse_max_bpm: session.pulse_max_bpm,
            pulse_avg_bpm: session.pulse_avg_bpm,
        }
    }
}

impl From<PulseOxHistoryChunk> for PulseOxHistoryChunkDto {
    fn from(chunk: PulseOxHistoryChunk) -> Self {
        Self {
            consumed: chunk.consumed as u32,
            sessions: chunk.sessions.into_iter().map(Into::into).collect(),
            records: chunk.records,
            skipped: chunk.skipped,
            end_of_transfer: chunk.end_of_transfer,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const PO60_YAML: &str = include_str!(
        "../../../vendor/protocol-specs/device-specs/devices/beurer-po60-pulse-oximeter.yaml"
    );

    #[test]
    fn history_pages_use_the_po60_checksum_rule() {
        let start = encode_health_command(
            PO60_YAML.to_string(),
            "get_measurements_page".to_string(),
            Some(0),
            None,
        )
        .unwrap();
        assert_eq!(start.bytes, [0x99, 0x00, 0x19]);
        let next = encode_health_command(
            PO60_YAML.to_string(),
            "get_measurements_page".to_string(),
            Some(1),
            None,
        )
        .unwrap();
        assert_eq!(next.bytes, [0x99, 0x01, 0x1A]);
        assert_eq!(start.service_uuid, next.service_uuid);
        assert_eq!(start.characteristic_uuid, next.characteristic_uuid);
    }

    #[test]
    fn clock_write_uses_real_fields_and_a_seven_bit_checksum() {
        let write = encode_health_command(
            PO60_YAML.to_string(),
            "set_datetime".to_string(),
            None,
            Some(HealthClockDto {
                year: 2026,
                month: 11,
                day: 8,
                hour: 14,
                minute: 32,
                second: 15,
            }),
        )
        .unwrap();
        assert_eq!(write.bytes.len(), 10);
        assert_eq!(&write.bytes[..9], &[0x83, 26, 11, 8, 14, 32, 15, 0, 0]);
        let expected = write.bytes[..9]
            .iter()
            .fold(0_u8, |sum, byte| sum.wrapping_add(*byte))
            & 0x7F;
        assert_eq!(write.bytes[9], expected);
    }

    #[test]
    fn clock_write_rejects_invalid_dates_and_missing_time() {
        let invalid = encode_health_command(
            PO60_YAML.to_string(),
            "set_datetime".to_string(),
            None,
            Some(HealthClockDto {
                year: 2026,
                month: 2,
                day: 30,
                hour: 14,
                minute: 32,
                second: 15,
            }),
        );
        assert!(invalid.is_err());
        assert!(encode_health_command(
            PO60_YAML.to_string(),
            "set_datetime".to_string(),
            None,
            None,
        )
        .is_err());
    }

    #[test]
    fn f7_decode_returns_only_a_pulse_sample() {
        let yaml = include_str!(
            "../../../vendor/protocol-specs/device-specs/devices/ble-pulse-oximeter.yaml"
        );
        let sample = decode_health_sample(
            yaml.to_string(),
            "6e400003-b5a3-f393-e0a9-e50e24dcca9e".to_string(),
            vec![0xAB, 0, 3, 0xFF, 0x30, 0x80, 72, 97, 15],
        )
        .unwrap();
        let pulse = sample.pulse_oximeter.unwrap();
        assert_eq!(pulse.spo2_percent, 97.0);
        assert_eq!(pulse.pulse_bpm, 72.0);
        assert_eq!(pulse.perfusion_index_percent, Some(1.5));
        assert!(sample.blood_pressure.is_none());
    }

    #[test]
    fn beurer_decode_returns_only_a_blood_pressure_reading() {
        let yaml = include_str!(
            "../../../vendor/protocol-specs/device-specs/devices/beurer-series800-blood-pressure.yaml"
        );
        let sample = decode_health_sample(
            yaml.to_string(),
            "00002a35-0000-1000-8000-00805f9b34fb".to_string(),
            vec![
                0x02, 0x00, 0x78, 0x00, 0x50, 0x00, 0x5D, 0xEA, 0x07, 11, 8, 14, 32, 15, 0x00,
                0x48, 2, 0, 0x44,
            ],
        )
        .unwrap();
        let reading = sample.blood_pressure.unwrap();
        assert_eq!(reading.systolic_mmhg, 120.0);
        assert_eq!(reading.diastolic_mmhg, 80.0);
        assert_eq!(reading.mean_arterial_mmhg, Some(93.0));
        assert_eq!(reading.pulse_bpm, Some(72.0));
        assert_eq!(reading.measured_at.as_deref(), Some("2026-11-08T14:32:15"));
        assert_eq!(reading.user_slot, Some(2));
        assert_eq!(reading.irregular_heartbeat, Some(true));
        assert_eq!(reading.sufficient_rest, Some(true));
        assert!(!reading.converted_from_kpa);
        assert!(sample.pulse_oximeter.is_none());
    }

    #[test]
    fn po60_decode_maps_sessions_and_transfer_status() {
        let mut record = vec![0_u8; 24];
        record[0] = 0xE9;
        record[1] = 1;
        record[2..8].copy_from_slice(&[26, 11, 8, 14, 30, 1]);
        record[8..14].copy_from_slice(&[26, 11, 8, 14, 31, 2]);
        record[17] = 99;
        record[18] = 94;
        record[19] = 97;
        record[20] = 80;
        record[21] = 65;
        record[22] = 72;
        let chunk = decode_pulse_ox_history(PO60_YAML.to_string(), record).unwrap();
        assert_eq!(chunk.consumed, 24);
        assert_eq!(chunk.records, 1);
        assert!(!chunk.end_of_transfer);
        assert_eq!(chunk.sessions.len(), 1);
        let session = &chunk.sessions[0];
        assert_eq!(session.record_index, 1);
        assert_eq!(session.started_at, "2026-11-08T14:30:01");
        assert_eq!(session.ended_at, "2026-11-08T14:31:02");
        assert_eq!(session.spo2_avg, 97);
        assert_eq!(session.pulse_avg_bpm, 72);
    }
}

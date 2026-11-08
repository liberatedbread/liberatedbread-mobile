// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

//! SolarEdge inverter readings over Modbus TCP (SunSpec), read-only.
//!
//! The `solaredge-modbus-tcp` spec's `protocol_details.modbus_tcp` states the
//! frame and `register_map` the addresses; this module owns both sides of the
//! bytes and Dart owns the socket.
//!
//! ```text
//! request: [transaction u16][protocol 0 u16][length u16][unit][03][start u16][quantity u16]
//! reply:   [transaction u16][protocol 0 u16][length u16][unit][03][byte count][registers]
//! failure: [transaction u16][protocol 0 u16][length u16][unit][83][exception code]
//! ```
//!
//! READ-ONLY BY CONSTRUCTION. The only frame this file can build is function
//! 0x03 at one of the fixed addresses in [`SunSpecRead`]; neither a function
//! code nor an address is a parameter of anything public. The spec's write
//! commands (0x06 and 0x10 on the power-control registers) curtail a
//! grid-connected inverter, and nothing here can produce one.

use crate::error::ProtocolError;

/// `protocol_handler` name this module implements.
pub const HANDLER_NAME: &str = "modbus_tcp_sunspec";

const FUNCTION_READ_HOLDING: u8 = 0x03;
const EXCEPTION_FLAG: u8 = 0x80;
const MBAP_AND_UNIT: usize = 7;
const MAX_UNIT_ID: u8 = 247;

const NOT_IMPLEMENTED_U16: u16 = 0xFFFF;
const NOT_IMPLEMENTED_I16: u16 = 0x8000;

/// Everything this app reads. Which registers is the spec's fact, repeated
/// here as named reads rather than taken as arguments so that no caller can
/// point a request at the control block.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SunSpecRead {
    /// `read_common_block`: 69 registers from 40000.
    CommonBlock,
    /// `read_inverter_block`: 40 registers from 40069.
    InverterBlock,
    /// `read_meter_1_common`: 67 registers from 40121.
    Meter1Common,
    /// `read_meter_1_power`: 5 registers from 40206.
    Meter1Power,
}

impl SunSpecRead {
    fn start(self) -> u16 {
        match self {
            Self::CommonBlock => 40000,
            Self::InverterBlock => 40069,
            Self::Meter1Common => 40121,
            Self::Meter1Power => 40206,
        }
    }

    fn quantity(self) -> u16 {
        match self {
            Self::CommonBlock => 69,
            Self::InverterBlock => 40,
            Self::Meter1Common => 67,
            Self::Meter1Power => 5,
        }
    }
}

/// `read_common_block`'s reply: who answered.
#[derive(Debug, Clone, PartialEq)]
pub struct SunSpecCommonDto {
    pub manufacturer: String,
    pub model: String,
    pub version: String,
    pub serial: String,
    pub unit_id: u16,
}

/// `read_inverter_block`'s reply. A field the inverter marks not implemented,
/// or whose scale factor is unusable, is `None` rather than a number.
#[derive(Debug, Clone, PartialEq)]
pub struct SunSpecInverterDto {
    /// 101 single phase, 102 split phase, 103 three phase.
    pub model_id: u16,
    pub ac_current_a: Option<f64>,
    pub ac_voltage_ab_v: Option<f64>,
    pub ac_voltage_an_v: Option<f64>,
    pub ac_power_w: Option<f64>,
    pub ac_frequency_hz: Option<f64>,
    pub ac_apparent_va: Option<f64>,
    pub ac_reactive_var: Option<f64>,
    pub ac_power_factor_percent: Option<f64>,
    /// None when the register reads 0, SunSpec's "not accumulated", so a bad
    /// read can never look like a lifetime total that went backwards to zero.
    pub lifetime_energy_wh: Option<f64>,
    pub dc_current_a: Option<f64>,
    pub dc_voltage_v: Option<f64>,
    pub dc_power_w: Option<f64>,
    pub heat_sink_c: Option<f64>,
    pub status_code: u16,
    /// The spec's `Operating State` mapping; `None` for a value it omits.
    pub status_label: Option<String>,
    pub vendor_status: Option<u16>,
}

/// `read_meter_1_common`'s reply. `role` is the C_Option text naming what the
/// meter measures (Export+Import, Production, Consumption).
#[derive(Debug, Clone, PartialEq)]
pub struct SunSpecMeterDto {
    pub manufacturer: String,
    pub model: String,
    pub role: String,
    pub serial: String,
}

/// `read_meter_1_power`'s reply.
///
/// A magnitude, on purpose. SolarEdge cites IEEE 1459-2000 and no source read
/// for the spec states which sign of M_AC_Power means export
/// (`remaining_unknowns`), so the sign does not cross this boundary: a caller
/// has nothing to turn into "exporting" or "importing" by guesswork.
#[derive(Debug, Clone, PartialEq)]
pub struct SunSpecMeterPowerDto {
    pub magnitude_w: Option<f64>,
}

fn malformed(reason: impl Into<String>) -> ProtocolError {
    ProtocolError::MalformedReply(reason.into())
}

/// The one request this module sends: function 0x03 at a named read.
pub fn encode_read(
    read: SunSpecRead,
    transaction_id: u16,
    unit_id: u8,
) -> Result<Vec<u8>, ProtocolError> {
    if unit_id == 0 || unit_id > MAX_UNIT_ID {
        return Err(ProtocolError::ParameterOutOfRange {
            name: "unit_id".to_string(),
            value: f64::from(unit_id),
            min: 1.0,
            max: f64::from(MAX_UNIT_ID),
        });
    }
    let mut out = Vec::with_capacity(12);
    out.extend_from_slice(&transaction_id.to_be_bytes());
    out.extend_from_slice(&[0, 0, 0, 6, unit_id, FUNCTION_READ_HOLDING]);
    out.extend_from_slice(&read.start().to_be_bytes());
    out.extend_from_slice(&read.quantity().to_be_bytes());
    Ok(out)
}

/// How many bytes a reply whose first bytes are `head` will have in total, or
/// `None` until the MBAP length field has arrived. Lets the socket stop
/// reading at the frame's end without knowing what a frame is.
pub fn reply_length(head: &[u8]) -> Option<usize> {
    let length = head.get(4..6)?;
    Some(6 + usize::from(u16::from_be_bytes([length[0], length[1]])))
}

/// The exception code if `reply` is a well-formed Modbus exception answering
/// this transaction. A device refusing a register is a different fact from a
/// device answering garbage: an optional block that is refused is simply
/// absent.
pub fn exception_code(reply: &[u8], transaction_id: u16, unit_id: u8) -> Option<u8> {
    if reply.len() != MBAP_AND_UNIT + 2 || !header_matches(reply, transaction_id, unit_id) {
        return None;
    }
    (reply[7] == FUNCTION_READ_HOLDING | EXCEPTION_FLAG).then_some(reply[8])
}

fn header_matches(reply: &[u8], transaction_id: u16, unit_id: u8) -> bool {
    reply.len() >= MBAP_AND_UNIT
        && reply[..2] == transaction_id.to_be_bytes()
        && reply[2..4] == [0, 0]
        && reply_length(reply) == Some(reply.len())
        && reply[6] == unit_id
}

/// The registers of a reply to `read`, after every check the frame allows.
fn registers(
    reply: &[u8],
    read: SunSpecRead,
    transaction_id: u16,
    unit_id: u8,
) -> Result<Vec<u16>, ProtocolError> {
    if reply.len() < MBAP_AND_UNIT + 2 {
        return Err(ProtocolError::BufferTooShort {
            needed: MBAP_AND_UNIT + 2,
            got: reply.len(),
        });
    }
    if !header_matches(reply, transaction_id, unit_id) {
        return Err(malformed(
            "the MBAP header does not answer this request".to_string(),
        ));
    }
    if let Some(code) = exception_code(reply, transaction_id, unit_id) {
        return Err(malformed(format!(
            "Modbus exception 0x{code:02x} ({})",
            exception_meaning(code)
        )));
    }
    if reply[7] != FUNCTION_READ_HOLDING {
        return Err(malformed(format!(
            "expected function 0x03, got 0x{:02x}",
            reply[7]
        )));
    }
    let expected = usize::from(read.quantity()) * 2;
    if usize::from(reply[8]) != expected || reply.len() != MBAP_AND_UNIT + 2 + expected {
        return Err(malformed(format!(
            "expected {expected} register bytes, got {} in a {} byte reply",
            reply[8],
            reply.len()
        )));
    }
    Ok(reply[MBAP_AND_UNIT + 2..]
        .chunks_exact(2)
        .map(|word| u16::from_be_bytes([word[0], word[1]]))
        .collect())
}

/// `protocol_details.modbus_tcp.exceptions`.
pub fn exception_meaning(code: u8) -> &'static str {
    match code {
        0x01 => "illegal function",
        0x02 => "illegal data address",
        0x03 => "illegal data value",
        0x04 => "server device failure",
        _ => "not named by the spec",
    }
}

/// ASCII, NUL-padded, first character in each register's high byte.
fn string_at(registers: &[u16]) -> String {
    let bytes: Vec<u8> = registers.iter().flat_map(|r| r.to_be_bytes()).collect();
    let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
    String::from_utf8_lossy(&bytes[..end]).trim().to_string()
}

/// A signed power-of-ten scale factor (`-10..=10`); anything else, including
/// the not-implemented sentinel, has no meaning to apply.
fn scale(raw: u16) -> Option<i32> {
    let value = i32::from(raw as i16);
    (-10..=10).contains(&value).then_some(value)
}

fn apply(value: f64, scale: i32) -> f64 {
    // Negative powers divide: 1250 / 100 is 12.5 exactly, where
    // 1250 * 10^-2 picks up a stray digit.
    if scale < 0 {
        value / 10f64.powi(-scale)
    } else {
        value * 10f64.powi(scale)
    }
}

fn scaled_u16(raw: u16, sf: u16) -> Option<f64> {
    if raw == NOT_IMPLEMENTED_U16 {
        return None;
    }
    Some(apply(f64::from(raw), scale(sf)?))
}

fn scaled_i16(raw: u16, sf: u16) -> Option<f64> {
    if raw == NOT_IMPLEMENTED_I16 {
        return None;
    }
    Some(apply(f64::from(raw as i16), scale(sf)?))
}

/// I_AC_Energy_WH x 10^I_AC_Energy_WH_SF.
///
/// The spec disagrees with itself on the scale factor: `payload_formats` says
/// int16, while `register_map` and `remaining_unknowns` report SolarEdge
/// printing it as uint16 and solaredge-modbus-multi reading it unsigned. The
/// two readings agree only on 0..=10, so only those are applied. 0xFFFF is -1
/// under one and "not implemented" under the other, and a lifetime total that
/// is out by a factor of ten is worse than a blank.
fn lifetime_energy(high: u16, low: u16, sf: u16) -> Option<f64> {
    let raw = (u32::from(high) << 16) | u32::from(low);
    if raw == 0 || sf > 10 {
        return None;
    }
    Some(apply(f64::from(raw), i32::from(sf)))
}

/// The spec's `Operating State` entity's `state_mapping`.
fn status_label(code: u16) -> Option<&'static str> {
    Some(match code {
        1 => "Off",
        2 => "Sleeping",
        3 => "Starting",
        4 => "Producing",
        5 => "Throttled",
        6 => "Shutting down",
        7 => "Fault",
        8 => "Standby",
        _ => return None,
    })
}

/// Decode the common block, and insist it is one: the `SunS` marker, model 1,
/// length 65. This is the spec's positive identification, so a device that
/// merely speaks Modbus does not get read as an inverter.
pub fn decode_common(
    reply: &[u8],
    transaction_id: u16,
    unit_id: u8,
) -> Result<SunSpecCommonDto, ProtocolError> {
    let regs = registers(reply, SunSpecRead::CommonBlock, transaction_id, unit_id)?;
    if regs[0] != 0x5375 || regs[1] != 0x6E53 {
        return Err(malformed(
            "register 40000 does not hold the SunS marker".to_string(),
        ));
    }
    if regs[2] != 1 || regs[3] != 65 {
        return Err(malformed(format!(
            "expected common model 1 length 65, got {} length {}",
            regs[2], regs[3]
        )));
    }
    Ok(SunSpecCommonDto {
        manufacturer: string_at(&regs[4..20]),
        model: string_at(&regs[20..36]),
        version: string_at(&regs[44..52]),
        serial: string_at(&regs[52..68]),
        unit_id: regs[68],
    })
}

/// Decode the inverter block. Field offsets are from 40069, per
/// `payload_formats.InverterBlockReply`.
pub fn decode_inverter(
    reply: &[u8],
    transaction_id: u16,
    unit_id: u8,
) -> Result<SunSpecInverterDto, ProtocolError> {
    let r = registers(reply, SunSpecRead::InverterBlock, transaction_id, unit_id)?;
    if !(101..=103).contains(&r[0]) || r[1] != 50 {
        return Err(malformed(format!(
            "expected inverter model 101-103 length 50, got {} length {}",
            r[0], r[1]
        )));
    }
    Ok(SunSpecInverterDto {
        model_id: r[0],
        ac_current_a: scaled_u16(r[2], r[6]),
        ac_voltage_ab_v: scaled_u16(r[7], r[13]),
        ac_voltage_an_v: scaled_u16(r[10], r[13]),
        ac_power_w: scaled_i16(r[14], r[15]),
        ac_frequency_hz: scaled_u16(r[16], r[17]),
        ac_apparent_va: scaled_i16(r[18], r[19]),
        ac_reactive_var: scaled_i16(r[20], r[21]),
        ac_power_factor_percent: scaled_i16(r[22], r[23]),
        lifetime_energy_wh: lifetime_energy(r[24], r[25], r[26]),
        dc_current_a: scaled_u16(r[27], r[28]),
        dc_voltage_v: scaled_u16(r[29], r[30]),
        dc_power_w: scaled_i16(r[31], r[32]),
        heat_sink_c: scaled_i16(r[34], r[37]),
        status_code: r[38],
        status_label: status_label(r[38]).map(str::to_string),
        vendor_status: (r[39] != NOT_IMPLEMENTED_U16).then_some(r[39]),
    })
}

/// Decode meter 1's common block. An `Err` means there is no meter at that
/// address: only enabled meters are present, and on a Synergy inverter 40121
/// holds model 160 instead, so the id check is what keeps a multiple-MPPT
/// block from being read as a meter.
pub fn decode_meter_common(
    reply: &[u8],
    transaction_id: u16,
    unit_id: u8,
) -> Result<SunSpecMeterDto, ProtocolError> {
    let r = registers(reply, SunSpecRead::Meter1Common, transaction_id, unit_id)?;
    if r[0] != 1 || r[1] != 65 {
        return Err(malformed(format!(
            "expected a meter common block (id 1 length 65), got id {} length {}",
            r[0], r[1]
        )));
    }
    Ok(SunSpecMeterDto {
        manufacturer: string_at(&r[2..18]),
        model: string_at(&r[18..34]),
        role: string_at(&r[34..42]),
        serial: string_at(&r[50..66]),
    })
}

/// Decode meter 1's power, keeping only its size; see
/// [`SunSpecMeterPowerDto`].
pub fn decode_meter_power(
    reply: &[u8],
    transaction_id: u16,
    unit_id: u8,
) -> Result<SunSpecMeterPowerDto, ProtocolError> {
    let r = registers(reply, SunSpecRead::Meter1Power, transaction_id, unit_id)?;
    Ok(SunSpecMeterPowerDto {
        magnitude_w: scaled_i16(r[0], r[4]).map(f64::abs),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    const COMMON_REPLY: &str = "00010000008D01038A53756E5300010041536F6C61724564676500000000000000000000000000000000000000000000005345384B0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000303030342E303032302E30303030000030303030303030302D30300000000000000000000000000000000000000000000001";
    const INVERTER_REPLY: &str = "0002000000530103500067003204E201A101A101A0FFFE0FA20FA50F9E090609080905FFFF21CA00001389FFFE21FC0000FF6A000026DEFFFE00BC614E00000497FFFE1D4CFFFF226C0000800011A080008000FFFE00040000";
    const METER_POWER_REPLY: &str = "00060000000D01030AC4A0C4A080008000FFFF";
    const EXCEPTION_REPLY: &str = "000500000003018302";

    fn hex(text: &str) -> Vec<u8> {
        (0..text.len())
            .step_by(2)
            .map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap())
            .collect()
    }

    fn close(actual: Option<f64>, expected: f64) {
        let actual = actual.expect("a value");
        assert!(
            (actual - expected).abs() < 1e-6,
            "{actual} is not {expected}"
        );
    }

    fn spec_text() -> String {
        std::fs::read_to_string(format!(
            "{}/../vendor/protocol-specs/device-specs/devices/solaredge-modbus-tcp.yaml",
            env!("CARGO_MANIFEST_DIR")
        ))
        .unwrap()
    }

    /// Each request against the frame the spec prints for it.
    #[test]
    fn requests_match_the_spec_examples() {
        for (read, transaction, example) in [
            (SunSpecRead::CommonBlock, 1, "00010000000601039C400045"),
            (SunSpecRead::InverterBlock, 2, "00020000000601039C850028"),
            (SunSpecRead::Meter1Common, 3, "00030000000601039CB90043"),
            (SunSpecRead::Meter1Power, 6, "00060000000601039D0E0005"),
        ] {
            assert_eq!(encode_read(read, transaction, 1).unwrap(), hex(example));
        }
    }

    /// The vectors above are copied by hand; this keeps them honest against
    /// the spec's own text, so a refresh that changes a frame fails here.
    #[test]
    fn the_literal_vectors_are_the_ones_the_spec_prints() {
        let text = spec_text();
        for vector in [
            COMMON_REPLY,
            INVERTER_REPLY,
            METER_POWER_REPLY,
            EXCEPTION_REPLY,
        ] {
            assert!(text.contains(vector), "{vector} is not in the spec");
        }
    }

    #[test]
    fn a_unit_id_outside_the_modbus_range_is_refused() {
        assert!(encode_read(SunSpecRead::CommonBlock, 1, 0).is_err());
        assert!(encode_read(SunSpecRead::CommonBlock, 1, 248).is_err());
        assert!(encode_read(SunSpecRead::CommonBlock, 1, 247).is_ok());
    }

    /// Whatever goes in, the function byte is 0x03 and the start address is
    /// in the SunSpec map. 0xF001 (power limit), 0xF100 (commit) and 0xE002
    /// (export limit) cannot come out of this encoder.
    #[test]
    fn every_request_is_function_03_below_the_control_registers() {
        for read in [
            SunSpecRead::CommonBlock,
            SunSpecRead::InverterBlock,
            SunSpecRead::Meter1Common,
            SunSpecRead::Meter1Power,
        ] {
            for unit in [1u8, 2, 247] {
                let frame = encode_read(read, 0xFFFF, unit).unwrap();
                assert_eq!(frame[7], 0x03);
                assert_eq!(frame.len(), 12);
                let start = u16::from_be_bytes([frame[8], frame[9]]);
                assert!((40000..41000).contains(&start), "start {start}");
            }
        }
    }

    #[test]
    fn the_common_block_reply_decodes() {
        let common = decode_common(&hex(COMMON_REPLY), 1, 1).unwrap();
        assert_eq!(common.manufacturer, "SolarEdge");
        assert_eq!(common.model, "SE8K");
        assert_eq!(common.version, "0004.0020.0000");
        assert_eq!(common.serial, "00000000-00");
        assert_eq!(common.unit_id, 1);
    }

    /// Every value `example_notes` states for InverterBlockReply.
    #[test]
    fn the_inverter_block_reply_decodes_with_its_scale_factors() {
        let inverter = decode_inverter(&hex(INVERTER_REPLY), 2, 1).unwrap();
        assert_eq!(inverter.model_id, 103);
        close(inverter.ac_current_a, 12.50);
        close(inverter.ac_voltage_ab_v, 400.2);
        close(inverter.ac_voltage_an_v, 231.0);
        close(inverter.ac_power_w, 8650.0);
        close(inverter.ac_frequency_hz, 50.01);
        close(inverter.ac_apparent_va, 8700.0);
        close(inverter.ac_reactive_var, -150.0);
        close(inverter.ac_power_factor_percent, 99.50);
        close(inverter.lifetime_energy_wh, 12_345_678.0);
        close(inverter.dc_current_a, 11.75);
        close(inverter.dc_voltage_v, 750.0);
        close(inverter.dc_power_w, 8812.0);
        close(inverter.heat_sink_c, 45.12);
        assert_eq!(inverter.status_code, 4);
        assert_eq!(inverter.status_label.as_deref(), Some("Producing"));
        assert_eq!(inverter.vendor_status, Some(0));
    }

    /// -1520.0 W in the spec's vector, and the sign does not survive. The
    /// spec says no source states which sign means export.
    #[test]
    fn meter_power_is_a_magnitude_with_no_direction() {
        let power = decode_meter_power(&hex(METER_POWER_REPLY), 6, 1).unwrap();
        close(power.magnitude_w, 1520.0);
    }

    #[test]
    fn a_meter_common_block_is_recognised_and_a_synergy_block_is_not() {
        let mut registers = vec![0u16; 67];
        registers[0] = 1;
        registers[1] = 65;
        registers[2] = u16::from_be_bytes(*b"So");
        registers[34] = u16::from_be_bytes(*b"Ex");
        let reply = reply_with(3, 1, &registers);
        let meter = decode_meter_common(&reply, 3, 1).unwrap();
        assert_eq!(meter.manufacturer, "So");
        assert_eq!(meter.role, "Ex");

        registers[0] = 160;
        assert!(decode_meter_common(&reply_with(3, 1, &registers), 3, 1).is_err());
    }

    fn reply_with(transaction: u16, unit: u8, registers: &[u16]) -> Vec<u8> {
        let mut out = transaction.to_be_bytes().to_vec();
        let length = 3 + registers.len() * 2;
        out.extend_from_slice(&[0, 0]);
        out.extend_from_slice(&(length as u16).to_be_bytes());
        out.extend_from_slice(&[unit, 3, (registers.len() * 2) as u8]);
        for register in registers {
            out.extend_from_slice(&register.to_be_bytes());
        }
        out
    }

    #[test]
    fn the_exception_reply_is_recognised_and_is_not_data() {
        let reply = hex(EXCEPTION_REPLY);
        assert_eq!(exception_code(&reply, 5, 1), Some(0x02));
        assert_eq!(exception_meaning(0x02), "illegal data address");
        // Another transaction's exception says nothing about this one.
        assert_eq!(exception_code(&reply, 6, 1), None);
        assert!(decode_meter_power(&reply, 5, 1).is_err());
    }

    #[test]
    fn replies_that_answer_something_else_are_refused() {
        let good = hex(INVERTER_REPLY);
        // The wrong transaction, or the wrong unit.
        assert!(decode_inverter(&good, 3, 1).is_err());
        assert!(decode_inverter(&good, 2, 2).is_err());
        // A non-zero protocol id.
        let mut bad = good.clone();
        bad[3] = 1;
        assert!(decode_inverter(&bad, 2, 1).is_err());
        // A length field that disagrees with the frame.
        let mut bad = good.clone();
        bad[5] = 0x52;
        assert!(decode_inverter(&bad, 2, 1).is_err());
        // The wrong function.
        let mut bad = good.clone();
        bad[7] = 0x06;
        assert!(decode_inverter(&bad, 2, 1).is_err());
        // The right frame for a different read.
        assert!(decode_meter_power(&good, 2, 1).is_err());
        // Truncated, and nothing at all.
        assert!(decode_inverter(&good[..40], 2, 1).is_err());
        assert!(decode_inverter(&[], 2, 1).is_err());
        assert!(decode_inverter(&[0xFF; 3], 2, 1).is_err());
    }

    #[test]
    fn a_modbus_device_that_is_not_sunspec_is_not_an_inverter() {
        let mut registers = vec![0u16; 69];
        assert!(decode_common(&reply_with(1, 1, &registers), 1, 1).is_err());
        registers[0] = 0x5375;
        registers[1] = 0x6E53;
        registers[2] = 7;
        assert!(decode_common(&reply_with(1, 1, &registers), 1, 1).is_err());

        let mut inverter = vec![0u16; 40];
        inverter[0] = 201;
        inverter[1] = 50;
        assert!(decode_inverter(&reply_with(2, 1, &inverter), 2, 1).is_err());
    }

    #[test]
    fn not_implemented_sentinels_are_absent_rather_than_numbers() {
        let mut r = hex(INVERTER_REPLY)[9..]
            .chunks_exact(2)
            .map(|w| u16::from_be_bytes([w[0], w[1]]))
            .collect::<Vec<_>>();
        r[2] = 0xFFFF; // I_AC_Current uint16
        r[14] = 0x8000; // I_AC_Power int16
        r[17] = 0x8000; // I_AC_Frequency's scale factor
        r[24] = 0; // acc32 high: 0 with the low word is "not accumulated"
        r[25] = 0;
        r[34] = 0x8000; // heat sink
        r[39] = 0xFFFF; // vendor status
        let inverter = decode_inverter(&reply_with(2, 1, &r), 2, 1).unwrap();
        assert_eq!(inverter.ac_current_a, None);
        assert_eq!(inverter.ac_power_w, None);
        assert_eq!(inverter.ac_frequency_hz, None);
        assert_eq!(inverter.lifetime_energy_wh, None);
        assert_eq!(inverter.heat_sink_c, None);
        assert_eq!(inverter.vendor_status, None);
        // Scale factors outside the SunSpec range have no meaning to apply.
        assert_eq!(scaled_u16(100, 11), None);
        assert_eq!(scaled_u16(100, (-11i16) as u16), None);
    }

    /// The two spec readings of I_AC_Energy_WH_SF agree only from 0 to 10.
    #[test]
    fn the_energy_scale_factor_is_applied_only_where_its_readings_agree() {
        assert_eq!(lifetime_energy(0, 100, 0), Some(100.0));
        assert_eq!(lifetime_energy(0, 100, 3), Some(100_000.0));
        assert_eq!(lifetime_energy(0, 100, 0xFFFF), None);
        assert_eq!(lifetime_energy(0, 100, 0x8000), None);
        assert_eq!(lifetime_energy(0, 0, 0), None);
    }

    #[test]
    fn an_unknown_status_has_a_code_and_no_invented_label() {
        let mut r = vec![0u16; 40];
        r[0] = 101;
        r[1] = 50;
        r[38] = 9;
        let inverter = decode_inverter(&reply_with(2, 1, &r), 2, 1).unwrap();
        assert_eq!(inverter.status_code, 9);
        assert_eq!(inverter.status_label, None);
    }

    /// The status table against the spec's `Operating State` entity.
    #[test]
    fn the_status_labels_are_the_specs_state_mapping() {
        let spec = parse_device_spec(&spec_text()).unwrap();
        let entity = spec
            .entities
            .iter()
            .find(|e| e.name == "Operating State")
            .expect("the entity is declared");
        let text = format!("{:?}", entity.state_mapping);
        for code in 1..=8 {
            let label = status_label(code).unwrap();
            assert!(text.contains(label), "{label} not in {text}");
        }
        assert_eq!(status_label(0), None);
        assert_eq!(status_label(9), None);
    }

    #[test]
    fn reply_length_needs_the_length_field() {
        assert_eq!(reply_length(&[0, 1, 0, 0, 0]), None);
        assert_eq!(reply_length(&hex(EXCEPTION_REPLY)), Some(9));
        assert_eq!(reply_length(&hex(METER_POWER_REPLY)), Some(19));
    }
}

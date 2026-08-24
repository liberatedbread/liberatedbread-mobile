// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Print-job encoder for the GB01/GB02/GT01/YT01/MX-class "cat" mini thermal
//! printers — `protocol_handler: "cat_printer"`
//! (`vendor/protocol-specs/device-specs/devices/cat-printer.yaml`).
//!
//! THE WIRE FORMAT (spec `device.notes` and the UART service notes,
//! CONFIDENCE HIGH upstream — checked against NaitLee/Cat-Printer with
//! rbaron, lisp3r and the vendor iPrint APK corroborating): a BLE UART
//! service (0xAE30) with a TX characteristic (0xAE01) that takes a byte
//! stream of command frames:
//!
//! ```text
//!   51 78 <cmd> 00 <payload_len> 00 <payload…> <crc8(payload)> FF
//! ```
//!
//! CRC-8/SMBUS (poly 0x07, init 0x00, no reflection) over the payload bytes
//! only; payload length is one byte (max 255).
//!
//! THE PRINTING SEQUENCE, exactly the spec's twelve steps:
//!
//! ```text
//!    1. get_device_state  (A3)         7. update_device (A9)
//!    2. start_printing    (A3 00 01)   8. start_lattice (A6, fixed marker)
//!    3. set_dpi_as_200    (A4, 50)     9. draw_bitmap   (A2) per row
//!    4. set_speed         (BD, 32)    10. end_lattice   (A6, fixed marker)
//!    5. set_energy        (AF, 0x3000)11. set_speed(8) + feed_paper(128)
//!    6. apply_energy      (BE)        12. get_device_state (A3)
//! ```
//!
//! Rows are 384 dots = 48 bytes (paper_width for every known model; the
//! spec's `image_upload.max_width` states it) and each bitmap byte is
//! BIT-REVERSED (MSB<->LSB) before transmission, per the spec's BIT REVERSAL
//! note. A narrower canvas is padded on the right with blank paper.
//!
//! 1-BIT POLARITY: a pixel below 50% luma is a printed (black) dot — dark
//! content on paper, the printer's own physics. Bit 1 = dot.
//!
//! The TX characteristic is a stream, so the concatenated frames are cut at
//! the caller's write budget without regard to frame boundaries — the same
//! way the documented clients slice at the MTU. Flow control (the printer's
//! pause/resume notifications on 0xAE02) and the model-specific
//! `problem_feeding` workaround are the transport's and the spec variant
//! table's business respectively; this encoder emits the documented default
//! sequence for the family.
//!
//! SPEC-GAP: the spec carries its whole command set in PROSE — the TX
//! characteristic declares no `commands:` block — so every opcode, fixed
//! payload and default below is transcribed from device.notes rather than
//! read from a command template. Each should become a named command on the
//! 0xAE01 characteristic (`get_device_state`, `set_dpi_as_200`, `set_speed`,
//! `set_energy`, `apply_energy`, `update_device`, `start_lattice`,
//! `end_lattice`, `draw_bitmap`, `feed_paper`) so this module can resolve
//! them by name the way the other handlers do.

use super::image_upload::{
    brightness_mask, is_writable, printhead_row_bytes, validate_rgb_canvas, MIN_PAYLOAD_PER_WRITE,
};
use super::{EncodedFrame, EncodedWrite};
use crate::error::ProtocolError;
use crate::spec::types::{Characteristic, DeviceSpec};

/// `protocol_handler` name this module implements (see the device spec's
/// `protocol_handler` key).
pub const HANDLER_NAME: &str = "cat_printer";

const FRAME_START: [u8; 2] = [0x51, 0x78];
const FRAME_END: u8 = 0xFF;

// Command ids (spec device.notes, COMMANDS).
const CMD_FEED_PAPER: u8 = 0xA1;
const CMD_DRAW_BITMAP: u8 = 0xA2;
const CMD_GET_DEVICE_STATE: u8 = 0xA3;
const CMD_SET_DPI_AS_200: u8 = 0xA4;
const CMD_LATTICE: u8 = 0xA6;
const CMD_UPDATE_DEVICE: u8 = 0xA9;
const CMD_SET_ENERGY: u8 = 0xAF;
const CMD_SET_SPEED: u8 = 0xBD;
const CMD_APPLY_ENERGY: u8 = 0xBE;

/// Lattice marker payloads (spec: "start = AA 55 17 38 44 5F 5F 5F 44 38
/// 2C, end = AA 55 17 00 00 00 00 00 00 00 17").
const LATTICE_START: [u8; 11] = [
    0xAA, 0x55, 0x17, 0x38, 0x44, 0x5F, 0x5F, 0x5F, 0x44, 0x38, 0x2C,
];
const LATTICE_END: [u8; 11] = [
    0xAA, 0x55, 0x17, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x17,
];

/// Spec: "set_dpi_as_200 (0xA4) — send value 50".
const DPI_200_VALUE: u8 = 50;
/// Spec: "set_speed (0xBD) — lower = faster feed, default 32".
const DEFAULT_SPEED: u8 = 32;
/// Spec: "set_energy (0xAF) — thermal strength, 0x0000-0xFFFF, default
/// ~0x3000". Sent little-endian like the protocol's other u16 payloads
/// (retract/feed pixel counts are "uint16 LE").
// SPEC-GAP: the energy field's byte order is not stated; it should be.
const DEFAULT_ENERGY: u16 = 0x3000;
/// Spec step 11: "set_speed(8) + feed_paper(128)".
const FEED_SPEED: u8 = 8;
const FEED_AFTER_PRINT: u16 = 128;
/// The one-byte payload of get_device_state / start_printing (the spec
/// writes the latter's frame prefix as "0xA3 0x00 0x01": command, fixed
/// zero, length 1), apply_energy and update_device.
// SPEC-GAP: the spec states these commands' ids and the payload LENGTH but
// not the byte's value; 0x00 is the neutral value and what get_device_info
// (the one query whose payload the spec does state) uses.
const STATE_PAYLOAD: [u8; 1] = [0x00];
const APPLY_ENERGY_PAYLOAD: [u8; 1] = [0x00];
const UPDATE_DEVICE_PAYLOAD: [u8; 1] = [0x00];

/// Encode one RGB888 canvas as a complete print job on the TX
/// characteristic. Every frame is a full job (the printer keeps no image
/// state between jobs), so `frame_index` changes nothing.
pub fn encode_print_job(
    spec: &DeviceSpec,
    rgb: &[u8],
    width: u32,
    height: u32,
    _frame_index: u32,
    max_payload_per_write: usize,
) -> Result<EncodedFrame, ProtocolError> {
    validate_rgb_canvas(spec, rgb, width, height)?;
    if max_payload_per_write < MIN_PAYLOAD_PER_WRITE {
        return Err(ProtocolError::ImageDimensionsInvalid {
            reason: format!(
                "max_payload_per_write {max_payload_per_write} is below the BLE minimum of \
                 {MIN_PAYLOAD_PER_WRITE}"
            ),
        });
    }
    let tx = resolve_tx_characteristic(spec)?;
    // 384 dots on every known model; the spec's `image_upload.max_width`
    // states it.
    let row_bytes = printhead_row_bytes(spec)?;

    let mut stream = Vec::new();
    let mut packets: u32 = 0;
    let mut emit = |cmd: u8, payload: &[u8]| {
        push_frame(&mut stream, cmd, payload);
        packets += 1;
    };

    // 1-2: refresh state, then start printing (same frame, two steps).
    emit(CMD_GET_DEVICE_STATE, &STATE_PAYLOAD);
    emit(CMD_GET_DEVICE_STATE, &STATE_PAYLOAD);
    // 3-7: quality, speed, energy, apply, update.
    emit(CMD_SET_DPI_AS_200, &[DPI_200_VALUE]);
    emit(CMD_SET_SPEED, &[DEFAULT_SPEED]);
    emit(CMD_SET_ENERGY, &DEFAULT_ENERGY.to_le_bytes());
    emit(CMD_APPLY_ENERGY, &APPLY_ENERGY_PAYLOAD);
    emit(CMD_UPDATE_DEVICE, &UPDATE_DEVICE_PAYLOAD);
    // 8: open the print area.
    emit(CMD_LATTICE, &LATTICE_START);

    // 9: one draw_bitmap per row — dark pixel = dot = bit 1, packed
    // MSB-first then bit-reversed per byte, padded to the paper width.
    let bright = brightness_mask(rgb);
    let w = width as usize;
    let mut row = vec![0u8; row_bytes];
    for y in 0..height as usize {
        row.iter_mut().for_each(|b| *b = 0);
        for x in 0..w {
            if !bright[y * w + x] {
                row[x / 8] |= 0x80 >> (x % 8);
            }
        }
        for b in row.iter_mut() {
            *b = b.reverse_bits();
        }
        emit(CMD_DRAW_BITMAP, &row);
    }

    // 10-12: close the print area, feed the page out, refresh state.
    emit(CMD_LATTICE, &LATTICE_END);
    emit(CMD_SET_SPEED, &[FEED_SPEED]);
    emit(CMD_FEED_PAPER, &FEED_AFTER_PRINT.to_le_bytes());
    emit(CMD_GET_DEVICE_STATE, &STATE_PAYLOAD);

    let writes = stream
        .chunks(max_payload_per_write)
        .map(|part| EncodedWrite {
            characteristic_uuid: tx.uuid.clone(),
            bytes: part.to_vec(),
        })
        .collect();
    Ok(EncodedFrame { writes, packets })
}

/// The TX channel: the single writable characteristic of the service the
/// spec identifies the printer by (`identification.service_uuids`, 0xAE30).
/// The secondary 0xAE3A service also carries a write characteristic, but
/// the spec does not identify the device by it, so it is never a candidate.
fn resolve_tx_characteristic(spec: &DeviceSpec) -> Result<&Characteristic, ProtocolError> {
    let identifying: Vec<&str> = spec
        .device
        .identification
        .as_ref()
        .and_then(|i| i.service_uuids.as_ref())
        .map(|v| v.iter().map(String::as_str).collect())
        .unwrap_or_default();
    let candidates: Vec<&Characteristic> = spec
        .services
        .iter()
        .filter(|s| identifying.iter().any(|u| u.eq_ignore_ascii_case(&s.uuid)))
        .flat_map(|s| &s.characteristics)
        .filter(|c| is_writable(c))
        .collect();
    match candidates.as_slice() {
        [tx] => Ok(tx),
        [] => Err(ProtocolError::ImageUploadUnsupported {
            reason: "spec has no writable characteristic in the service it identifies the \
                     printer by"
                .to_string(),
        }),
        many => Err(ProtocolError::ImageUploadUnsupported {
            reason: format!(
                "spec identifies the printer by a service with {} writable characteristics; \
                 the TX channel is ambiguous",
                many.len()
            ),
        }),
    }
}

/// One command frame: `51 78 cmd 00 len 00 payload crc8 FF`.
fn push_frame(stream: &mut Vec<u8>, cmd: u8, payload: &[u8]) {
    debug_assert!(
        payload.len() <= u8::MAX as usize,
        "payload length is one byte"
    );
    stream.extend_from_slice(&FRAME_START);
    stream.push(cmd);
    stream.push(0x00);
    stream.push(payload.len() as u8);
    stream.push(0x00);
    stream.extend_from_slice(payload);
    stream.push(crc8(payload));
    stream.push(FRAME_END);
}

/// CRC-8/SMBUS: poly 0x07, init 0x00, no reflection, no final xor.
fn crc8(bytes: &[u8]) -> u8 {
    let mut crc = 0u8;
    for &b in bytes {
        crc ^= b;
        for _ in 0..8 {
            crc = if crc & 0x80 != 0 {
                (crc << 1) ^ 0x07
            } else {
                crc << 1
            };
        }
    }
    crc
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::spec::parser::parse_device_spec;

    /// A minimal spec shaped like the vendored `cat-printer.yaml`: the
    /// identifying UART service with TX (write) and RX (notify), the
    /// secondary 0xAE3A service with its own write characteristic as the
    /// decoy, and the feature bounds — nested under `device:` exactly as
    /// the vendored file has them.
    const SPEC_YAML: &str = r#"
device:
  name: "Cat Printer"
  manufacturer: "Unbranded"
  manufacturer_status: "unsupported"
  protocol: "ble"
  category: "printer"
  identification:
    local_name_prefix: "GB"
    service_uuids:
      - "0000ae30-0000-1000-8000-00805f9b34fb"
  features:
    - type: "image_upload"
      max_width: 384
      max_height: 65535
      format: "1bit-bitmap"
  protocol_handler: "cat_printer"
services:
  - uuid: "0000ae30-0000-1000-8000-00805f9b34fb"
    name: "Cat Printer UART Service"
    characteristics:
      - uuid: "0000ae01-0000-1000-8000-00805f9b34fb"
        name: "TX (Client -> Printer)"
        properties: ["write", "write_without_response"]
      - uuid: "0000ae02-0000-1000-8000-00805f9b34fb"
        name: "RX (Printer -> Client)"
        properties: ["notify"]
  - uuid: "0000ae3a-0000-1000-8000-00805f9b34fb"
    name: "Secondary Service (GT01)"
    characteristics:
      - uuid: "0000ae3b-0000-1000-8000-00805f9b34fb"
        name: "AE3B"
        properties: ["write_without_response"]
"#;

    const TX: &str = "0000ae01-0000-1000-8000-00805f9b34fb";

    fn spec() -> DeviceSpec {
        parse_device_spec(SPEC_YAML).unwrap()
    }

    /// An 8x2 canvas: row 0 all black, row 1 alternating black/white from
    /// the left. Black = (0,0,0), white = (255,255,255).
    fn tiny() -> Vec<u8> {
        let mut rgb = vec![0u8; 8 * 2 * 3];
        for x in 0..8 {
            if x % 2 == 1 {
                let i = (8 + x) * 3;
                rgb[i..i + 3].copy_from_slice(&[255, 255, 255]);
            }
        }
        rgb
    }

    fn stream_of(frame: &EncodedFrame) -> Vec<u8> {
        frame
            .writes
            .iter()
            .flat_map(|w| w.bytes.iter().copied())
            .collect()
    }

    /// A 48-byte row with `first` in byte 0 and blank paper after it.
    fn row_with_first(first: u8) -> Vec<u8> {
        let mut r = vec![0u8; 48];
        r[0] = first;
        r
    }

    /// The whole job for the 8x2 canvas, derived frame by frame from the
    /// spec's frame format and twelve-step sequence. CRC-8/SMBUS values
    /// were computed independently (Python, bitwise poly 0x07) and the
    /// lattice/DPI ones agree with the frames the spec's cited clients
    /// publish (`… 32 9E FF`, `… 2C A1 FF`, `… 17 11 FF`):
    ///
    /// - A3 [00] -> crc 00 (steps 1, 2 and 12)
    /// - A4 [32] -> crc 9E;  BD [20] -> crc E0;  AF [00 30] -> crc 90
    /// - BE [00] -> crc 00;  A9 [00] -> crc 00
    /// - A6 lattice start -> crc A1;  A6 lattice end -> crc 11
    /// - A2 row 0: all 8 dots black -> MSB-first FF, bit-reversed FF,
    ///   47 blank bytes -> crc ED
    /// - A2 row 1: dots at even columns -> MSB-first AA, bit-reversed 55
    ///   -> crc A6
    /// - BD [08] -> crc 38;  A1 [80 00] (128 LE) -> crc B6
    #[test]
    fn golden_8x2_print_job() {
        let frame = encode_print_job(&spec(), &tiny(), 8, 2, 0, 509).unwrap();
        assert_eq!(frame.packets, 14, "12 fixed frames + 2 rows");
        assert!(frame.writes.iter().all(|w| w.characteristic_uuid == TX));

        let frame_bytes = |cmd: u8, payload: &[u8], crc: u8| -> Vec<u8> {
            let mut f = vec![0x51, 0x78, cmd, 0x00, payload.len() as u8, 0x00];
            f.extend_from_slice(payload);
            f.push(crc);
            f.push(0xFF);
            f
        };
        let mut expected = Vec::new();
        expected.extend(frame_bytes(0xA3, &[0x00], 0x00)); // 1 get_device_state
        expected.extend(frame_bytes(0xA3, &[0x00], 0x00)); // 2 start_printing
        expected.extend(frame_bytes(0xA4, &[0x32], 0x9E)); // 3 set_dpi_as_200
        expected.extend(frame_bytes(0xBD, &[0x20], 0xE0)); // 4 set_speed 32
        expected.extend(frame_bytes(0xAF, &[0x00, 0x30], 0x90)); // 5 energy
        expected.extend(frame_bytes(0xBE, &[0x00], 0x00)); // 6 apply_energy
        expected.extend(frame_bytes(0xA9, &[0x00], 0x00)); // 7 update_device
        expected.extend(frame_bytes(0xA6, &LATTICE_START, 0xA1)); // 8
        expected.extend(frame_bytes(0xA2, &row_with_first(0xFF), 0xED)); // 9
        expected.extend(frame_bytes(0xA2, &row_with_first(0x55), 0xA6)); // 9
        expected.extend(frame_bytes(0xA6, &LATTICE_END, 0x11)); // 10
        expected.extend(frame_bytes(0xBD, &[0x08], 0x38)); // 11 set_speed 8
        expected.extend(frame_bytes(0xA1, &[0x80, 0x00], 0xB6)); // 11 feed
        expected.extend(frame_bytes(0xA3, &[0x00], 0x00)); // 12
        assert_eq!(stream_of(&frame), expected);
    }

    #[test]
    fn bitmap_bytes_are_bit_reversed_before_transmission() {
        // Only the leftmost dot black: MSB-first 0x80, on the wire 0x01.
        let mut rgb = vec![255u8; 8 * 3];
        rgb[0..3].copy_from_slice(&[0, 0, 0]);
        let frame = encode_print_job(&spec(), &rgb, 8, 1, 0, 509).unwrap();
        let stream = stream_of(&frame);
        let row_frame = stream
            .windows(6)
            .position(|w| w[..3] == [0x51, 0x78, 0xA2])
            .expect("a draw_bitmap frame");
        assert_eq!(stream[row_frame + 6], 0x01);
    }

    #[test]
    fn a_narrow_canvas_is_padded_with_blank_paper() {
        let rgb = vec![0u8; 8 * 3]; // 8 black dots, one row
        let frame = encode_print_job(&spec(), &rgb, 8, 1, 0, 509).unwrap();
        let stream = stream_of(&frame);
        let row_frame = stream
            .windows(6)
            .position(|w| w[..3] == [0x51, 0x78, 0xA2])
            .unwrap();
        assert_eq!(stream[row_frame + 4], 48, "payload length is the full row");
        assert_eq!(&stream[row_frame + 7..row_frame + 6 + 48], &[0u8; 47]);
    }

    #[test]
    fn the_stream_is_cut_at_the_write_budget_without_losing_bytes() {
        let wide = encode_print_job(&spec(), &tiny(), 8, 2, 0, 509).unwrap();
        let narrow = encode_print_job(&spec(), &tiny(), 8, 2, 0, 20).unwrap();
        assert_eq!(stream_of(&wide), stream_of(&narrow));
        assert!(narrow.writes.iter().all(|w| w.bytes.len() <= 20));
        assert!(narrow.writes.len() > wide.writes.len());
        assert_eq!(narrow.packets, wide.packets, "slicing is not framing");
    }

    #[test]
    fn the_secondary_service_write_characteristic_is_never_the_target() {
        let frame = encode_print_job(&spec(), &tiny(), 8, 2, 0, 509).unwrap();
        assert!(frame.writes.iter().all(|w| w.characteristic_uuid == TX));
    }

    #[test]
    fn a_spec_that_identifies_by_no_writable_service_errors_helpfully() {
        let yaml = SPEC_YAML.replace(
            r#"      - "0000ae30-0000-1000-8000-00805f9b34fb""#,
            r#"      - "0000ae3a-0000-1000-8000-00805f9b34fb""#,
        );
        // 0xAE3A has one writable characteristic too, so this resolves to
        // it — prove the choice follows identification, not spec order.
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_print_job(&s, &tiny(), 8, 2, 0, 509).unwrap();
        assert!(frame
            .writes
            .iter()
            .all(|w| w.characteristic_uuid == "0000ae3b-0000-1000-8000-00805f9b34fb"));

        let none = SPEC_YAML.replace(
            r#"      - "0000ae30-0000-1000-8000-00805f9b34fb""#,
            r#"      - "0000ffff-0000-1000-8000-00805f9b34fb""#,
        );
        let s = parse_device_spec(&none).unwrap();
        let err = encode_print_job(&s, &tiny(), 8, 2, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageUploadUnsupported { .. }));
    }

    #[test]
    fn the_row_width_comes_from_the_declared_paper_width() {
        let yaml = SPEC_YAML.replace("max_width: 384", "max_width: 576");
        let s = parse_device_spec(&yaml).unwrap();
        let frame = encode_print_job(&s, &tiny(), 8, 2, 0, 509).unwrap();
        let stream = stream_of(&frame);
        let row_frame = stream
            .windows(6)
            .position(|w| w[..3] == [0x51, 0x78, 0xA2])
            .unwrap();
        assert_eq!(stream[row_frame + 4], 72, "576 dots = 72 bytes per row");
    }

    #[test]
    fn a_canvas_wider_than_the_paper_is_rejected() {
        let err = encode_print_job(&spec(), &vec![0u8; 385 * 3], 385, 1, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn wrong_buffer_length_is_rejected() {
        let err = encode_print_job(&spec(), &[0; 5], 8, 2, 0, 509).unwrap_err();
        assert!(matches!(err, ProtocolError::ImageDimensionsInvalid { .. }));
    }

    #[test]
    fn crc8_matches_the_smbus_check_value() {
        // CRC-8/SMBUS check value for "123456789" is 0xF4.
        assert_eq!(crc8(b"123456789"), 0xF4);
    }
}

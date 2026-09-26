// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Desktop serial ports, exposed to Flutter.
//!
//! A thin surface over [`crate::serial`], which says why this transport is
//! in Rust at all. A port is named by a number from [`serial_open`]; every
//! function exists on every target, and where there is no serial backend
//! they refuse. Dart never calls them there: it picks its serial service by
//! platform first.

use crate::serial;

/// A serial port present on this machine.
#[derive(Debug, Clone)]
pub struct SerialPortInfoDto {
    /// What the port is opened by: `/dev/ttyUSB0`, `/dev/cu.usbserial-110`.
    pub path: String,
    pub vendor_id: Option<u16>,
    pub product_id: Option<u16>,
    pub manufacturer: Option<String>,
    pub product: Option<String>,
}

/// What a read produced.
///
/// A timeout is an answer, not an error: it carries whatever did arrive, and
/// Dart turns it into the same `TimeoutException` its other links raise
/// instead of parsing one out of an error message.
#[derive(Debug, Clone)]
pub struct SerialReadDto {
    pub data: Vec<u8>,
    pub timed_out: bool,
}

/// The serial ports present now.
pub fn serial_list_ports() -> anyhow::Result<Vec<SerialPortInfoDto>> {
    Ok(serial::list()?
        .into_iter()
        .map(|port| SerialPortInfoDto {
            path: port.path,
            vendor_id: port.vendor_id,
            product_id: port.product_id,
            manufacturer: port.manufacturer,
            product: port.product,
        })
        .collect())
}

/// Open `path` at `baud_rate`, 8N1, no flow control, DTR and RTS raised.
/// Answers the handle the other calls take.
pub fn serial_open(path: String, baud_rate: u32) -> anyhow::Result<u32> {
    serial::open(&path, baud_rate)
}

pub fn serial_write(handle: u32, data: Vec<u8>) -> anyhow::Result<()> {
    serial::write(handle, &data)
}

/// Read exactly `len` bytes, giving up after `timeout_ms`.
///
/// Blocks, which is what a non-sync bridge function is for: it runs on the
/// bridge's worker pool, never on the Dart isolate.
pub fn serial_read_exact(handle: u32, len: u32, timeout_ms: u32) -> anyhow::Result<SerialReadDto> {
    let read = serial::read_exact(handle, len as usize, timeout_ms)?;
    Ok(SerialReadDto {
        data: read.data,
        timed_out: read.timed_out,
    })
}

/// Forget anything received and not yet read.
pub fn serial_discard_input(handle: u32) -> anyhow::Result<()> {
    serial::discard_input(handle)
}

/// Close the port. Closing it twice is harmless.
pub fn serial_close(handle: u32) -> anyhow::Result<()> {
    serial::close(handle)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_unopened_handle_is_refused_and_closing_it_is_harmless() {
        assert!(serial_write(u32::MAX, vec![1]).is_err());
        assert!(serial_read_exact(u32::MAX, 1, 10).is_err());
        assert!(serial_discard_input(u32::MAX).is_err());
        assert!(serial_close(u32::MAX).is_ok());
    }
}

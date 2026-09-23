// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
//! Serial ports on the desktop: the one transport in the Rust core.
//!
//! AGENTS.md names the exception and why it exists: on Linux and macOS the
//! way to a serial port without a copyleft runtime library is the
//! `serialport` crate. What stays true of the house split is that nothing
//! here knows what goes over the port. The radio conversation is the Dart
//! programmer's, built from frames `radio_api` computes.
//!
//! Ports are held here and named to Dart by number. A handle Dart could hold
//! directly would be a bridge-opaque type, and a number is simpler to pass,
//! to close, and to reason about: closing drops this registry's reference,
//! and a read still in flight finishes with its own before the port closes.
//!
//! Every function exists on every target so the bindings are the same
//! everywhere; where there is no serial backend they say so.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, OnceLock};

/// A port present on this machine.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PortInfo {
    pub path: String,
    pub vendor_id: Option<u16>,
    pub product_id: Option<u16>,
    pub manufacturer: Option<String>,
    pub product: Option<String>,
}

/// What a read produced: everything that arrived, and whether the deadline
/// passed before all of it did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Read {
    pub data: Vec<u8>,
    pub timed_out: bool,
}

type Shared = Arc<Mutex<imp::Port>>;

fn registry() -> &'static Mutex<HashMap<u32, Shared>> {
    static PORTS: OnceLock<Mutex<HashMap<u32, Shared>>> = OnceLock::new();
    PORTS.get_or_init(Default::default)
}

static NEXT_HANDLE: AtomicU32 = AtomicU32::new(1);

fn unusable() -> anyhow::Error {
    anyhow::anyhow!("the serial port is in an unusable state")
}

fn port(handle: u32) -> anyhow::Result<Shared> {
    registry()
        .lock()
        .map_err(|_| unusable())?
        .get(&handle)
        .cloned()
        .ok_or_else(|| anyhow::anyhow!("the serial port has been closed"))
}

fn with_port<T>(
    handle: u32,
    body: impl FnOnce(&mut imp::Port) -> anyhow::Result<T>,
) -> anyhow::Result<T> {
    let shared = port(handle)?;
    let mut guard = shared.lock().map_err(|_| unusable())?;
    body(&mut guard)
}

/// Whether this build can open serial ports at all.
pub fn supported() -> bool {
    imp::SUPPORTED
}

pub fn list() -> anyhow::Result<Vec<PortInfo>> {
    imp::list()
}

/// Open `path` at `baud_rate`, 8N1, no flow control, DTR and RTS raised.
/// Answers the handle every other call takes.
pub fn open(path: &str, baud_rate: u32) -> anyhow::Result<u32> {
    let port = imp::open(path, baud_rate)?;
    let handle = NEXT_HANDLE.fetch_add(1, Ordering::Relaxed);
    registry()
        .lock()
        .map_err(|_| unusable())?
        .insert(handle, Arc::new(Mutex::new(port)));
    Ok(handle)
}

pub fn write(handle: u32, data: &[u8]) -> anyhow::Result<()> {
    with_port(handle, |p| imp::write(p, data))
}

/// Read exactly `len` bytes, giving up after `timeout_ms`.
pub fn read_exact(handle: u32, len: usize, timeout_ms: u32) -> anyhow::Result<Read> {
    with_port(handle, |p| imp::read_exact(p, len, timeout_ms))
}

/// Forget anything received and not yet read.
pub fn discard_input(handle: u32) -> anyhow::Result<()> {
    with_port(handle, imp::discard_input)
}

/// Close the port. Closing one already closed, or never opened, is harmless.
pub fn close(handle: u32) -> anyhow::Result<()> {
    registry().lock().map_err(|_| unusable())?.remove(&handle);
    Ok(())
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
mod imp {
    use super::{PortInfo, Read};
    use serialport::{
        ClearBuffer, DataBits, FlowControl, Parity, SerialPort, SerialPortType, StopBits,
    };
    use std::io::{ErrorKind, Read as _, Write as _};
    use std::time::{Duration, Instant};

    pub const SUPPORTED: bool = true;

    pub struct Port(Box<dyn SerialPort>);

    /// How long one underlying read may block before the deadline is
    /// checked again.
    const POLL: Duration = Duration::from_millis(50);

    pub fn list() -> anyhow::Result<Vec<PortInfo>> {
        // Without libudev the crate enumerates sysfs, and panics if it is
        // not there — a container, a sandbox. No sysfs means no ports.
        #[cfg(target_os = "linux")]
        if !std::path::Path::new("/sys/class/tty").is_dir() {
            return Ok(Vec::new());
        }
        Ok(serialport::available_ports()?
            .into_iter()
            .map(|port| match port.port_type {
                SerialPortType::UsbPort(usb) => PortInfo {
                    path: port.port_name,
                    vendor_id: Some(usb.vid),
                    product_id: Some(usb.pid),
                    manufacturer: usb.manufacturer,
                    product: usb.product,
                },
                _ => PortInfo {
                    path: port.port_name,
                    vendor_id: None,
                    product_id: None,
                    manufacturer: None,
                    product: None,
                },
            })
            .collect())
    }

    pub fn open(path: &str, baud_rate: u32) -> anyhow::Result<Port> {
        let mut port = serialport::new(path, baud_rate)
            .data_bits(DataBits::Eight)
            .parity(Parity::None)
            .stop_bits(StopBits::One)
            .flow_control(FlowControl::None)
            .timeout(POLL)
            .open()?;
        // Many programming cables power their level shifter from these
        // lines. Not every adapter has them, so a refusal is not an error.
        let _ = port.write_data_terminal_ready(true);
        let _ = port.write_request_to_send(true);
        Ok(Port(port))
    }

    pub fn write(port: &mut Port, data: &[u8]) -> anyhow::Result<()> {
        port.0.write_all(data)?;
        port.0.flush()?;
        Ok(())
    }

    pub fn read_exact(port: &mut Port, len: usize, timeout_ms: u32) -> anyhow::Result<Read> {
        let deadline = Instant::now() + Duration::from_millis(timeout_ms as u64);
        let mut data = vec![0u8; len];
        let mut filled = 0;
        while filled < len {
            let now = Instant::now();
            if now >= deadline {
                data.truncate(filled);
                return Ok(Read {
                    data,
                    timed_out: true,
                });
            }
            port.0.set_timeout((deadline - now).min(POLL))?;
            match port.0.read(&mut data[filled..]) {
                Ok(n) => filled += n,
                Err(e) if matches!(e.kind(), ErrorKind::TimedOut | ErrorKind::Interrupted) => {}
                Err(e) => return Err(e.into()),
            }
        }
        Ok(Read {
            data,
            timed_out: false,
        })
    }

    pub fn discard_input(port: &mut Port) -> anyhow::Result<()> {
        port.0.clear(ClearBuffer::Input)?;
        Ok(())
    }
}

#[cfg(not(any(target_os = "linux", target_os = "macos")))]
mod imp {
    use super::{PortInfo, Read};

    pub const SUPPORTED: bool = false;

    /// Never constructed: [open] refuses first.
    pub struct Port;

    fn unsupported<T>() -> anyhow::Result<T> {
        anyhow::bail!("this platform has no serial ports the app can open")
    }

    pub fn list() -> anyhow::Result<Vec<PortInfo>> {
        Ok(Vec::new())
    }

    pub fn open(_path: &str, _baud_rate: u32) -> anyhow::Result<Port> {
        unsupported()
    }

    pub fn write(_port: &mut Port, _data: &[u8]) -> anyhow::Result<()> {
        unsupported()
    }

    pub fn read_exact(_port: &mut Port, _len: usize, _timeout_ms: u32) -> anyhow::Result<Read> {
        unsupported()
    }

    pub fn discard_input(_port: &mut Port) -> anyhow::Result<()> {
        unsupported()
    }
}

#[cfg(all(test, any(target_os = "linux", target_os = "macos")))]
mod tests {
    use super::*;
    use serialport::{SerialPort, TTYPort};
    use std::io::{Read as _, Write as _};
    use std::time::{Duration, Instant};

    /// A pseudo-terminal pair: the far end plays the radio, and the near end
    /// is opened by path through [open], exactly as a cable would be.
    fn pair() -> (TTYPort, u32) {
        let (mut radio, near) = TTYPort::pair().expect("a pseudo-terminal pair");
        radio.set_timeout(Duration::from_millis(500)).unwrap();
        let path = near.name().expect("the near end has a path");
        let handle = open(&path, 9600).expect("open by path");
        // The pair's own near end stays open until the path is reopened, so
        // the terminal exists throughout; after that ours is the one in use.
        drop(near);
        (radio, handle)
    }

    #[test]
    fn this_platform_says_it_can() {
        assert!(supported());
        assert!(list().is_ok());
    }

    #[test]
    fn what_the_radio_sends_is_read_exactly() {
        let (mut radio, port) = pair();
        radio.write_all(&[1, 2, 3, 4, 5]).unwrap();
        let first = read_exact(port, 3, 1000).unwrap();
        assert_eq!(
            first,
            Read {
                data: vec![1, 2, 3],
                timed_out: false
            }
        );
        assert_eq!(read_exact(port, 2, 1000).unwrap().data, [4, 5]);
        close(port).unwrap();
    }

    #[test]
    fn what_is_written_reaches_the_radio() {
        let (mut radio, port) = pair();
        write(port, &[0x53, 0x00, 0x40, 0x40]).unwrap();
        let mut got = [0u8; 4];
        radio.read_exact(&mut got).unwrap();
        assert_eq!(got, [0x53, 0x00, 0x40, 0x40]);
        close(port).unwrap();
    }

    #[test]
    fn a_silent_radio_times_out_with_what_did_arrive() {
        let (mut radio, port) = pair();
        radio.write_all(&[9]).unwrap();
        let started = Instant::now();
        let read = read_exact(port, 4, 200).unwrap();
        assert!(read.timed_out);
        assert_eq!(read.data, [9]);
        let waited = started.elapsed();
        assert!(waited >= Duration::from_millis(150), "{waited:?}");
        assert!(waited < Duration::from_secs(2), "{waited:?}");
        close(port).unwrap();
    }

    #[test]
    fn a_closed_port_says_so_and_closing_again_is_harmless() {
        let (_radio, port) = pair();
        close(port).unwrap();
        assert!(write(port, &[1]).is_err());
        assert!(read_exact(port, 1, 10).is_err());
        assert!(discard_input(port).is_err());
        assert!(close(port).is_ok());
    }

    #[test]
    fn handles_are_never_reused() {
        let (_a, first) = pair();
        let (_b, second) = pair();
        assert_ne!(first, second);
        close(first).unwrap();
        close(second).unwrap();
    }

    #[test]
    fn a_path_that_is_not_a_port_is_an_error() {
        assert!(open("/definitely/not/a/port", 9600).is_err());
    }

    #[test]
    fn discarding_forgets_what_was_waiting() {
        let (mut radio, port) = pair();
        radio.write_all(&[1, 2, 3]).unwrap();
        radio.flush().unwrap();
        // Give the bytes time to cross the pair before they are thrown away.
        std::thread::sleep(Duration::from_millis(50));
        discard_input(port).unwrap();
        let read = read_exact(port, 1, 100).unwrap();
        assert!(read.timed_out);
        assert!(read.data.is_empty());
        close(port).unwrap();
    }
}

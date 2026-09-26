// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Serial ports on Linux and macOS, through the Rust core.

import 'dart:async';
import 'dart:io' show Platform;
import 'dart:typed_data';

import '../core/log.dart';
import '../src/rust/api/serial_api.dart' as rust;
import 'serial_port_service.dart';

/// Serial ports on the desktop.
///
/// The Rust core opens them (see `rust/src/serial.rs` for why the one
/// transport outside Dart lives there) and names each by a number. This
/// adapts that to [SerialPortService], and turns its timeout flag into the
/// same [TimeoutException] every other link raises.
class DesktopSerialPortService implements SerialPortService {
  @override
  SerialAvailability get availability => const SerialAvailability.supported();

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    final ports = await rust.serialListPorts();
    return [
      for (final port in ports)
        SerialPortInfo(
          id: port.path,
          name: port.path,
          vendorId: port.vendorId,
          productId: port.productId,
          manufacturer: port.manufacturer,
          product: port.product,
        ),
    ];
  }

  @override
  Future<SerialLink> open(SerialPortInfo port, {required int baudRate}) async {
    try {
      return _DesktopLink(
        await rust.serialOpen(path: port.id, baudRate: baudRate),
      );
    } catch (error) {
      Log.radio.warning('could not open ${port.id}', error: error);
      throw SerialPortException(
        openFailureText(port.name, isLinux: Platform.isLinux),
      );
    }
  }

  /// What to tell someone whose cable would not open.
  ///
  /// On Linux the usual cause is not the cable at all: serial devices belong
  /// to a group the desktop user is often not in.
  static String openFailureText(String port, {required bool isLinux}) => isLinux
      ? 'Could not open $port. If it is in use, close whatever has it. '
            'Otherwise your user probably needs to be in the "dialout" '
            'group: add it, then log out and back in.'
      : 'Could not open $port. If another program has it open, close '
            'that program and try again.';
}

class _DesktopLink implements SerialLink {
  final int _handle;

  _DesktopLink(this._handle);

  @override
  Future<void> write(List<int> bytes) =>
      rust.serialWrite(handle: _handle, data: bytes);

  @override
  Future<Uint8List> read(int length, {required Duration timeout}) async {
    final read = await rust.serialReadExact(
      handle: _handle,
      len: length,
      timeoutMs: timeout.inMilliseconds,
    );
    if (read.timedOut) {
      throw TimeoutException('waiting for $length bytes', timeout);
    }
    return read.data;
  }

  @override
  Future<void> discardInput() => rust.serialDiscardInput(handle: _handle);

  @override
  Future<void> close() => rust.serialClose(handle: _handle);
}

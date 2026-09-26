// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A serial port, whichever way the platform reaches one.

import 'dart:async';
import 'package:flutter/foundation.dart';

import '../core/error_text.dart';
import '../core/usb_bridges.dart';

/// A port the app could open.
@immutable
class SerialPortInfo {
  /// What the platform opens it by: a device path on Linux and macOS, the
  /// USB device id on Android. Opaque everywhere above the service.
  final String id;

  /// What the platform calls it — `/dev/ttyUSB0`, `COM3`, a USB device name.
  final String name;

  final int? vendorId;
  final int? productId;

  /// What the device says it is, when it says.
  final String? manufacturer;
  final String? product;

  const SerialPortInfo({
    required this.id,
    required this.name,
    this.vendorId,
    this.productId,
    this.manufacturer,
    this.product,
  });

  UsbBridge? get bridge => usbBridgeFor(vendorId, productId);

  /// The most useful name for the screen: what the device calls itself,
  /// then its chip, then the port.
  String get displayName {
    final own = product?.trim();
    if (own != null && own.isNotEmpty) return own;
    return bridge?.name ?? name;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SerialPortInfo && id == other.id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'SerialPortInfo($id)';
}

/// Whether this platform lets the app open serial ports at all.
@immutable
class SerialAvailability {
  final bool supported;

  /// Why not, when not — written for the person reading the USB tab.
  final String? reason;

  const SerialAvailability.supported() : supported = true, reason = null;

  const SerialAvailability.unsupported(String this.reason) : supported = false;
}

/// A port could not be opened or used.
class SerialPortException implements UserFacingException {
  @override
  final String message;

  const SerialPortException(this.message);

  @override
  String toString() => message;
}

/// An open port: 8N1, no flow control, which is what every radio here uses.
abstract class SerialLink {
  Future<void> write(List<int> bytes);

  /// Exactly [length] bytes. Throws [TimeoutException] if they have not all
  /// arrived within [timeout].
  Future<Uint8List> read(int length, {required Duration timeout});

  /// Forget anything received and not yet read.
  Future<void> discardInput();

  Future<void> close();
}

/// Lists and opens serial ports.
///
/// One interface over three very different backends — Android's USB host
/// stack, the desktop's serial devices through the Rust core, and nothing at
/// all on iOS — so everything above it, the USB tab and the cable driver, is
/// written once.
abstract class SerialPortService {
  SerialAvailability get availability;

  /// The ports present now. Empty, not an error, when there are none.
  Future<List<SerialPortInfo>> listPorts();

  /// Open [port] at [baudRate]. On Android this may first ask the person for
  /// permission to use the device, and throws [SerialPortException] if they
  /// say no.
  Future<SerialLink> open(SerialPortInfo port, {required int baudRate});
}

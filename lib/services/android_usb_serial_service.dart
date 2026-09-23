// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// USB-serial cables on Android, through the USB host stack.

import 'dart:async';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';

import '../core/log.dart';
import 'byte_inbox.dart';
import 'serial_port_service.dart';

/// Serial ports on Android: a programming cable on a USB-OTG adapter.
///
/// Android gives an app no serial device node for a USB cable; the only way
/// in is the USB host API, with a driver for each bridge chip. `usb_serial`
/// carries those drivers (CH34x, CP210x, FTDI, PL2303 and plain CDC-ACM),
/// and this adapts it to [SerialPortService].
///
/// Permission is per device and asked for by the system, the first time a
/// cable is opened after it is plugged in. There is nothing to declare for
/// it in the manifest, and nothing to ask for up front.
class AndroidUsbSerialService implements SerialPortService {
  @override
  SerialAvailability get availability => const SerialAvailability.supported();

  @override
  Future<List<SerialPortInfo>> listPorts() async {
    final devices = await UsbSerial.listDevices();
    return [
      for (final device in devices)
        if (device.deviceId != null)
          SerialPortInfo(
            id: '${device.deviceId}',
            name: device.deviceName,
            vendorId: device.vid,
            productId: device.pid,
            manufacturer: device.manufacturerName,
            product: device.productName,
          ),
    ];
  }

  @override
  Future<SerialLink> open(SerialPortInfo port, {required int baudRate}) async {
    final deviceId = int.tryParse(port.id);
    if (deviceId == null) {
      throw SerialPortException('"${port.name}" is not a USB device.');
    }
    // Raises the system's permission dialog when the app has not been
    // granted this device yet, and answers null if the person says no.
    final usb = await UsbSerial.createFromDeviceId(deviceId);
    if (usb == null) {
      throw const SerialPortException(
          'The cable could not be used. If Android asked for permission, '
          'allow it; if the cable was unplugged, plug it back in and try '
          'again.');
    }
    if (!await usb.open()) {
      throw const SerialPortException(
          'The cable is plugged in but could not be opened. Unplug it, plug '
          'it back in, and try again.');
    }
    await usb.setPortParameters(
      baudRate,
      UsbPort.DATABITS_8,
      UsbPort.STOPBITS_1,
      UsbPort.PARITY_NONE,
    );
    // Many programming cables power their level shifter from these lines,
    // and a desktop serial port raises both on open. Doing the same here is
    // what makes a cable that works with other programmers work here.
    await usb.setDTR(true);
    await usb.setRTS(true);
    return _AndroidLink(usb);
  }
}

class _AndroidLink implements SerialLink {
  final UsbPort _port;
  final ByteInbox _inbox = ByteInbox();
  StreamSubscription<Uint8List>? _input;

  _AndroidLink(this._port) {
    _input = _port.inputStream?.listen(
      _inbox.add,
      onError: (Object error) =>
          Log.radio.warning('USB serial input failed', error: error),
    );
  }

  @override
  Future<void> write(List<int> bytes) => _port.write(Uint8List.fromList(bytes));

  @override
  Future<Uint8List> read(int length, {required Duration timeout}) async =>
      Uint8List.fromList(await _inbox.take(length, timeout));

  @override
  Future<void> discardInput() async => _inbox.clear();

  @override
  Future<void> close() async {
    await _input?.cancel();
    _input = null;
    await _port.close();
  }
}

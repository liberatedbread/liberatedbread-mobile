// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// USB-serial cables on Android, through the USB host stack.

import 'dart:async';
import 'dart:typed_data';

import 'package:usb_serial/usb_serial.dart';

import '../core/log.dart';
import '../core/usb_bridges.dart';
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
///
/// Ports are listed under ids that outlive a replug; see [_identify].
class AndroidUsbSerialService implements SerialPortService {
  @override
  SerialAvailability get availability => const SerialAvailability.supported();

  @override
  Future<List<SerialPortInfo>> listPorts() async => [
    for (final (id, device) in _identify(await UsbSerial.listDevices()))
      SerialPortInfo(
        id: id,
        name: device.deviceName,
        vendorId: device.vid,
        productId: device.pid,
        manufacturer: device.manufacturerName,
        product: device.productName,
      ),
  ];

  @override
  Future<SerialLink> open(SerialPortInfo port, {required int baudRate}) async {
    UsbDevice? device;
    for (final (id, candidate) in _identify(await UsbSerial.listDevices())) {
      if (id == port.id) device = candidate;
    }
    if (device == null) {
      // Not by name: a driver that opens by id alone passes the id as the
      // name, and "usb:1a86:7523" means nothing to anyone.
      throw const SerialPortException(
        'The cable is not plugged in. Plug it in, then try again.',
      );
    }
    // Raises the system's permission dialog when the app has not been
    // granted this device yet, and answers null if the person says no.
    final usb = await UsbSerial.createFromDeviceId(device.deviceId);
    if (usb == null) {
      throw const SerialPortException(
        'The cable could not be used. If Android asked for permission, '
        'allow it; if the cable was unplugged, plug it back in and try '
        'again.',
      );
    }
    if (!await usb.open()) {
      throw const SerialPortException(
        'The cable is plugged in but could not be opened. Unplug it, plug '
        'it back in, and try again.',
      );
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

/// Each device that can be opened, with the id its port is listed under.
///
/// Not Android's device id: Android numbers a device afresh each time it is
/// plugged in, so a radio saved through a cable would be lost the next time
/// the cable went in. The id is what the cable says it is — vendor and
/// product — which is the same every time. Not its serial number either,
/// which Android only reveals once the app has been allowed the device: the
/// id would change the moment the first session was granted.
///
/// Two identical cables plugged in at once share that id, and are told apart
/// by where each is plugged in. That part does not survive a replug, and
/// cannot: nothing else about two identical cables differs.
List<(String, UsbDevice)> _identify(List<UsbDevice> devices) {
  String own(UsbDevice device) {
    final vid = device.vid;
    final pid = device.pid;
    return vid == null || pid == null
        ? 'usb:${device.deviceName}'
        : 'usb:${usbIdLabel(vid, pid)}';
  }

  final openable = [
    for (final device in devices)
      if (device.deviceId != null) device,
  ];
  final shared = <String, int>{};
  for (final device in openable) {
    shared.update(own(device), (n) => n + 1, ifAbsent: () => 1);
  }
  return [
    for (final device in openable)
      (
        shared[own(device)]! > 1
            ? '${own(device)}@${device.deviceName}'
            : own(device),
        device,
      ),
  ];
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

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'serial_port_service.dart';

/// The serial service demo mode uses: one cable, always plugged in.
///
/// Demo mode programs through [MockRadioProgrammer], which never opens a
/// port, so the link here only has to exist — it is what the USB tab lists
/// and hands to the radio screen. Opened anyway, it stays silent, which a
/// real driver reports as a radio that did not answer.
class MockSerialPortService implements SerialPortService {
  static const SerialPortInfo demoCable = SerialPortInfo(
    id: 'demo-cable',
    name: 'Demo programming cable',
    vendorId: 0x1A86,
    productId: 0x7523,
    product: 'Demo programming cable',
  );

  @override
  SerialAvailability get availability => const SerialAvailability.supported();

  @override
  Future<List<SerialPortInfo>> listPorts() async => const [demoCable];

  @override
  Future<SerialLink> open(SerialPortInfo port, {required int baudRate}) async =>
      _SilentLink();
}

class _SilentLink implements SerialLink {
  @override
  Future<void> write(List<int> bytes) async {}

  @override
  Future<Uint8List> read(int length, {required Duration timeout}) =>
      Future.delayed(
        timeout,
        () => throw TimeoutException('demo cable', timeout),
      );

  @override
  Future<void> discardInput() async {}

  @override
  Future<void> close() async {}
}

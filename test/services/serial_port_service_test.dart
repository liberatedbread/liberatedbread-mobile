// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';
import 'package:liberated_bread_mobile/services/mock_serial_port_service.dart';
import 'package:liberated_bread_mobile/services/serial_port_service.dart';
import 'package:liberated_bread_mobile/services/unsupported_serial_port_service.dart';

void main() {
  group('SerialPortInfo', () {
    test('is named by what the device calls itself, then its chip, then '
        'the port', () {
      const own = SerialPortInfo(
        id: '1',
        name: '/dev/ttyUSB0',
        vendorId: 0x1A86,
        productId: 0x7523,
        product: 'K-plug cable',
      );
      expect(own.displayName, 'K-plug cable');

      const chip = SerialPortInfo(
        id: '1',
        name: '/dev/ttyUSB0',
        vendorId: 0x1A86,
        productId: 0x7523,
      );
      expect(chip.displayName, 'WCH CH340');
      expect(chip.bridge?.name, 'WCH CH340');

      const bare = SerialPortInfo(id: '1', name: '/dev/ttyS0', product: '  ');
      expect(bare.displayName, '/dev/ttyS0');
      expect(bare.bridge, isNull);
    });

    test('is identified by its id', () {
      expect(
        const SerialPortInfo(id: 'a', name: 'one'),
        const SerialPortInfo(id: 'a', name: 'two'),
      );
      expect(
        const SerialPortInfo(id: 'a', name: 'x').hashCode,
        const SerialPortInfo(id: 'a', name: 'y').hashCode,
      );
      expect(
        const SerialPortInfo(id: 'a', name: 'x'),
        isNot(const SerialPortInfo(id: 'b', name: 'x')),
      );
    });
  });

  test('a port failure is written for a person to read', () {
    const error = SerialPortException('The cable could not be used.');
    expect(error, isA<UserFacingException>());
    expect(error.toString(), 'The cable could not be used.');
  });

  group('UnsupportedSerialPortService', () {
    const service = UnsupportedSerialPortService(
      UnsupportedSerialPortService.iosReason,
    );

    test('says why, lists nothing, and opens nothing', () async {
      expect(service.availability.supported, isFalse);
      expect(service.availability.reason, contains('iPhone'));
      expect(await service.listPorts(), isEmpty);
      await expectLater(
        service.open(const SerialPortInfo(id: 'x', name: 'x'), baudRate: 9600),
        throwsA(isA<SerialPortException>()),
      );
    });

    test('has a reason for platforms that are not iOS too', () {
      expect(UnsupportedSerialPortService.otherReason, isNotEmpty);
    });
  });

  group('MockSerialPortService', () {
    final service = MockSerialPortService();

    test('always has its demo cable', () async {
      expect(service.availability.supported, isTrue);
      final ports = await service.listPorts();
      expect(ports, [MockSerialPortService.demoCable]);
      expect(ports.single.bridge?.name, 'WCH CH340');
    });

    test('opens a link that stays silent, the way a radio that does not '
        'answer does', () async {
      final link = await service.open(
        MockSerialPortService.demoCable,
        baudRate: 9600,
      );
      await link.write([1, 2, 3]);
      await link.discardInput();
      await expectLater(
        link.read(1, timeout: const Duration(milliseconds: 10)),
        throwsA(isA<TimeoutException>()),
      );
      await link.close();
    });
  });
}

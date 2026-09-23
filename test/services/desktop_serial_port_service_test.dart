// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The desktop backend, through the real native library.
//
// Reading and writing a port is proved in Rust, against a pseudo-terminal
// pair (rust/src/api/serial_api.rs). What this covers is the Dart side of the
// boundary: listing maps across, and a port that will not open says
// something a person can act on.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/desktop_serial_port_service.dart';
import 'package:liberated_bread_mobile/services/serial_port_service.dart';

import '../helpers/host_rust_lib.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late bool rustReady;
  final service = DesktopSerialPortService();

  setUpAll(() async {
    rustReady = await initHostRustLib();
  });

  test('is available', () {
    expect(service.availability.supported, isTrue);
  });

  test('lists ports, or none, without failing', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final ports = await service.listPorts();
    for (final port in ports) {
      expect(port.id, isNotEmpty);
      expect(port.name, port.id, reason: 'a desktop port is named by its path');
    }
  });

  test('a port that will not open says what to do about it', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    await expectLater(
      service.open(
        const SerialPortInfo(id: '/definitely/not/a/port', name: 'nowhere'),
        baudRate: 9600,
      ),
      throwsA(isA<SerialPortException>()
          .having((e) => e.message, 'message', contains('nowhere'))),
    );
  });

  test('on Linux, the advice is the group the port belongs to', () {
    expect(
      DesktopSerialPortService.openFailureText('/dev/ttyUSB0', isLinux: true),
      contains('dialout'),
    );
    expect(
      DesktopSerialPortService.openFailureText('/dev/cu.usbserial-10',
          isLinux: false),
      isNot(contains('dialout')),
    );
  });
}

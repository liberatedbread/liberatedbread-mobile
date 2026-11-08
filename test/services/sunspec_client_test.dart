// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The SolarEdge reader against a fake socket and the real Rust codec: the
// spec's literal frames, a device that answers garbage or nothing, and the
// pin that nothing but function 03 ever goes on the wire.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/sunspec_client.dart';

import '../helpers/host_rust_lib.dart';

const _commonReply =
    '00010000008D01038A53756E5300010041536F6C61724564676500000000000000000000000000000000000000000000005345384B0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000303030342E303032302E30303030000030303030303030302D30300000000000000000000000000000000000000000000001';
const _inverterReply =
    '0002000000530103500067003204E201A101A101A0FFFE0FA20FA50F9E090609080905FFFF21CA00001389FFFE21FC0000FF6A000026DEFFFE00BC614E00000497FFFE1D4CFFFF226C0000800011A080008000FFFE00040000';
const _meterPowerReply = '00060000000D01030AC4A0C4A080008000FFFF';

Uint8List _hex(String text) => Uint8List.fromList([
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
]);

/// Sets a reply's transaction id to the one the request carried.
Uint8List _answering(List<int> request, Uint8List reply) {
  final out = Uint8List.fromList(reply);
  out[0] = request[0];
  out[1] = request[1];
  return out;
}

/// A meter common block with id 1, length 65 and the role "Export+Import".
Uint8List _meterCommonReply() {
  final registers = List<int>.filled(67, 0);
  registers[0] = 1;
  registers[1] = 65;
  final role = 'Export+Import'.codeUnits;
  for (var i = 0; i < role.length; i++) {
    final index = 34 + i ~/ 2;
    registers[index] |= i.isEven ? role[i] << 8 : role[i];
  }
  final data = [
    for (final register in registers) ...[register >> 8, register & 0xff],
  ];
  return Uint8List.fromList([
    0, 0, 0, 0, 0, 3 + data.length, 1, 3, data.length, ...data, //
  ]);
}

class _FakeTransport implements SunSpecTransport {
  final Object? Function(int start, List<int> request) answer;
  final Object? openError;
  final requests = <List<int>>[];
  var opened = 0;
  var closed = 0;

  _FakeTransport(this.answer, {this.openError});

  @override
  Future<void> open(String host, int port, Duration timeout) async {
    opened++;
    if (openError != null) throw openError!;
  }

  @override
  Future<Uint8List> exchange(List<int> request, Duration timeout) async {
    requests.add(List<int>.of(request));
    final start = (request[8] << 8) | request[9];
    final reply = answer(start, request);
    if (reply is Uint8List) return reply;
    throw reply ?? TimeoutException('silent', timeout);
  }

  @override
  Future<void> close() async => closed++;
}

Object? _healthySite(int start, List<int> request) => switch (start) {
  40000 => _answering(request, _hex(_commonReply)),
  40069 => _answering(request, _hex(_inverterReply)),
  40121 => _answering(request, _meterCommonReply()),
  40206 => _answering(request, _hex(_meterPowerReply)),
  _ => null,
};

ModbusSunSpecClient _client(_FakeTransport transport) => ModbusSunSpecClient(
  host: '192.168.1.50',
  port: 1502,
  transportFactory: () => transport,
  gap: Duration.zero,
);

void main() {
  setUpAll(() async {
    if (!await initHostRustLib()) {
      markTestSkipped('host Rust library not available');
    }
  });

  test('reads the inverter from the spec example frames', () async {
    final transport = _FakeTransport(_healthySite);
    final reading = await _client(transport).read();

    expect(reading.common.manufacturer, 'SolarEdge');
    expect(reading.common.model, 'SE8K');
    expect(reading.inverter.acPowerW, 8650);
    expect(reading.inverter.statusLabel, 'Producing');
    expect(reading.inverter.heatSinkC, closeTo(45.12, 1e-6));
    expect(reading.lifetimeEnergyWh, 12345678);
    expect(reading.meter?.role, 'Export+Import');
    // -1520.0 W on the wire. The direction does not survive to here.
    expect(reading.meterPower?.magnitudeW, 1520);
    expect(transport.closed, 1, reason: 'one client at a time, so it lets go');
  });

  test('the first request is the spec example frame', () async {
    final transport = _FakeTransport(_healthySite);
    await _client(transport).read();
    expect(transport.requests.first, _hex('00010000000601039C400045'));
  });

  test('only function 03 goes on the wire, whatever happens', () async {
    for (final site in <Object? Function(int, List<int>)>[
      _healthySite,
      (_, _) => null,
      (_, _) => _hex('DEADBEEF'),
    ]) {
      final transport = _FakeTransport(site);
      final client = _client(transport);
      for (var i = 0; i < 3; i++) {
        await client.read().then((_) {}, onError: (Object _) {});
      }
      for (final request in transport.requests) {
        expect(request[7], 0x03, reason: 'function byte of $request');
        expect(request.length, 12);
        final start = (request[8] << 8) | request[9];
        expect(start, inInclusiveRange(40000, 40999));
      }
    }
  });

  test('a device that answers garbage is an error and not a reading', () async {
    final client = _client(_FakeTransport((_, _) => _hex('DEADBEEFCAFE')));
    await expectLater(
      client.read(),
      throwsA(
        isA<SunSpecException>().having(
          (e) => e.message,
          'message',
          contains('not with SunSpec'),
        ),
      ),
    );
  });

  test('a device that answers nothing is an error, and is let go', () async {
    final transport = _FakeTransport((_, _) => null);
    await expectLater(
      _client(transport).read(),
      throwsA(
        isA<SunSpecException>().having(
          (e) => e.message,
          'message',
          contains('did not answer'),
        ),
      ),
    );
    expect(transport.closed, 1);
  });

  test('an unreachable port says Modbus TCP may be off', () async {
    final transport = _FakeTransport(
      (_, _) => null,
      openError: const SocketException('refused'),
    );
    await expectLater(
      _client(transport).read(),
      throwsA(
        isA<SunSpecException>().having(
          (e) => e.message,
          'message',
          contains('off until it is enabled'),
        ),
      ),
    );
  });

  test('a Modbus exception names what the device said', () async {
    final client = _client(
      _FakeTransport(
        (_, request) => _answering(request, _hex('000500000003018302')),
      ),
    );
    await expectLater(
      client.read(),
      throwsA(
        isA<SunSpecException>().having(
          (e) => e.message,
          'message',
          contains('illegal data address'),
        ),
      ),
    );
  });

  test('another vendor is not read with SolarEdge addresses', () async {
    final other = _hex(_commonReply);
    other[17] = 0x58; // "SolarEdge" no longer.
    final transport = _FakeTransport(
      (start, request) => _answering(request, other),
    );
    await expectLater(
      _client(transport).read(),
      throwsA(
        isA<SunSpecException>().having(
          (e) => e.message,
          'message',
          contains('not SolarEdge'),
        ),
      ),
    );
    expect(transport.requests, hasLength(1));
  });

  test('a silent meter is absent, and is not asked again', () async {
    final transport = _FakeTransport(
      (start, request) => start == 40121 ? null : _healthySite(start, request),
    );
    final client = _client(transport);

    final first = await client.read();
    expect(first.meterPower, isNull);
    expect(first.inverter.acPowerW, 8650, reason: 'the reading survives it');
    final askedFirst = transport.requests.length;

    await client.read();
    final meterAsks = transport.requests
        .where((r) => ((r[8] << 8) | r[9]) == 40121)
        .length;
    expect(meterAsks, 1);
    expect(transport.requests.length, askedFirst + 1, reason: 'inverter only');
  });

  test('a garbage meter reply is absent too', () async {
    final client = _client(
      _FakeTransport(
        (start, request) =>
            start == 40121 ? _hex('00') : _healthySite(start, request),
      ),
    );
    final reading = await client.read();
    expect(reading.meter, isNull);
    expect(reading.meterPower, isNull);
  });

  test('the common block is read once per client', () async {
    final transport = _FakeTransport(_healthySite);
    final client = _client(transport);
    await client.read();
    await client.read();
    final common = transport.requests
        .where((r) => ((r[8] << 8) | r[9]) == 40000)
        .length;
    expect(common, 1);
    expect(transport.opened, 2, reason: 'a fresh connection per read');
  });

  test('the lifetime total never goes backwards on a bad read', () async {
    var bad = false;
    final transport = _FakeTransport((start, request) {
      if (start == 40069 && bad) {
        final reply = _answering(request, _hex(_inverterReply));
        // I_AC_Energy_WH reads 0: "not accumulated".
        reply.setRange(9 + 48, 9 + 52, [0, 0, 0, 0]);
        return reply;
      }
      return _healthySite(start, request);
    });
    final client = _client(transport);
    expect((await client.read()).lifetimeEnergyWh, 12345678);
    bad = true;
    expect((await client.read()).lifetimeEnergyWh, 12345678);
  });

  test('a stale reply from another transaction is refused', () async {
    final client = _client(
      _FakeTransport((start, _) => _hex(_inverterReply)..[1] = 0x77),
    );
    await expectLater(client.read(), throwsA(isA<SunSpecException>()));
  });

  group('the MODBUS_ID TXT key', () {
    test('names the unit, and falls back to 1', () {
      expect(ModbusSunSpecClient.unitIdFromTxt({'MODBUS_ID': '7'}), 7);
      expect(ModbusSunSpecClient.unitIdFromTxt({'MODBUS_ID': '247'}), 247);
      expect(ModbusSunSpecClient.unitIdFromTxt({'MODBUS_ID': '248'}), 1);
      expect(ModbusSunSpecClient.unitIdFromTxt({'MODBUS_ID': '0'}), 1);
      expect(ModbusSunSpecClient.unitIdFromTxt({'MODBUS_ID': 'x'}), 1);
      expect(ModbusSunSpecClient.unitIdFromTxt({}), 1);
    });
  });

  group('the real socket', () {
    late ServerSocket server;
    late List<List<int>> seen;

    setUp(() async {
      seen = [];
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() => server.close());

    test('assembles a reply that arrives in pieces', () async {
      server.listen((socket) {
        socket.listen((request) async {
          seen.add(request);
          final reply = _answering(request, _hex(_meterPowerReply));
          socket.add(reply.sublist(0, 4));
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
          socket.add(reply.sublist(4));
          await socket.flush();
        });
      });
      final transport = SocketSunSpecTransport();
      await transport.open(
        '127.0.0.1',
        server.port,
        const Duration(seconds: 2),
      );
      final request = _hex('00060000000601039D0E0005');
      final reply = await transport.exchange(
        request,
        const Duration(seconds: 2),
      );
      await transport.close();
      expect(reply, _hex(_meterPowerReply));
      expect(seen.single, request);
    });

    test('a silent peer times out', () async {
      server.listen((_) {});
      final transport = SocketSunSpecTransport();
      await transport.open(
        '127.0.0.1',
        server.port,
        const Duration(seconds: 2),
      );
      await expectLater(
        transport.exchange([1, 2, 3], const Duration(milliseconds: 50)),
        throwsA(isA<TimeoutException>()),
      );
      await transport.close();
    });

    test('a peer claiming an absurd length is refused', () async {
      server.listen((socket) {
        socket.listen((_) {
          socket.add([0, 1, 0, 0, 0xff, 0xff, 1, 3]);
        });
      });
      final transport = SocketSunSpecTransport();
      await transport.open(
        '127.0.0.1',
        server.port,
        const Duration(seconds: 2),
      );
      await expectLater(
        transport.exchange([1], const Duration(seconds: 2)),
        throwsA(isA<SunSpecException>()),
      );
      await transport.close();
    });

    test('a peer that hangs up mid-reply is a failure', () async {
      server.listen((socket) {
        socket.listen((_) async {
          socket.add([0, 1]);
          await socket.flush();
          await socket.close();
        });
      });
      final transport = SocketSunSpecTransport();
      await transport.open(
        '127.0.0.1',
        server.port,
        const Duration(seconds: 2),
      );
      await expectLater(
        transport.exchange([1], const Duration(seconds: 2)),
        throwsA(isA<SocketException>()),
      );
      await transport.close();
    });
  });
}

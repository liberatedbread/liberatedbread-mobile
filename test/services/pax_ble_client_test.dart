// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The PAX reader against a fake unit and the real Rust codec. The read
// packets are the ones `pax_vectors` worked with Python `cryptography` for the
// serial ABCD1234 (the spec carries no captured frame). What is pinned: the
// unit answers with temperature and battery, an Era Pro is not touched, a unit
// that answers garbage or nothing is reported, and the only thing ever written
// is the status request on the write characteristic.
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/pax_ble_client.dart';
import 'package:liberated_bread_mobile/services/read_only_ble_session.dart';

import '../fakes/fake_ble_service.dart';
import '../helpers/host_rust_lib.dart';

const _service = '8e320200-64d2-11e6-bdf4-0800200c9a66';
const _read = '8e320201-64d2-11e6-bdf4-0800200c9a66';
const _write = '8e320202-64d2-11e6-bdf4-0800200c9a66';
const _enrollment = '8e320210-64d2-11e6-bdf4-0800200c9a66';
const _dis = '0000180a-0000-1000-8000-00805f9b34fb';
const _serial = '00002a25-0000-1000-8000-00805f9b34fb';

List<int> _hex(String text) => [
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
];

/// ACTUAL_TEMP 185.5 °C and BATTERY 87 %, under ABCD1234's key, IV 5a x 16.
final _temperature = _hex('32602e${'5a' * 16}');
final _battery = _hex('3008${'5a' * 16}');

class _Pax extends FakeBleService {
  final StreamController<List<int>> ready;
  final List<List<int>> answers;

  factory _Pax({
    List<String> services = const [_service, _dis],
    List<List<int>> answers = const [],
    bool notifies = true,
  }) {
    // ignore: close_sinks — lives as long as the fake unit.
    final ready = StreamController<List<int>>.broadcast();
    return _Pax._(ready, services, answers, notifies);
  }

  final bool notifies;
  int _next = 0;

  _Pax._(this.ready, List<String> services, this.answers, this.notifies)
    : super(
        notifyStream: ready.stream,
        servicesToReturn: [
          for (final uuid in services)
            BleDiscoveredService(uuid: uuid, characteristics: const []),
        ],
        readValues: {_serial: ascii.encode('ABCD1234')},
      );

  @override
  Future<List<int>> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) async {
    if (charUuid == _read && answers.isNotEmpty) {
      reads.add((deviceId: deviceId, charUuid: charUuid));
      return answers[_next++ % answers.length];
    }
    return super.readCharacteristic(deviceId, serviceUuid, charUuid);
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    await super.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
    if (notifies) {
      // One "ready" per staged attribute.
      scheduleMicrotask(() => ready.add([0x00]));
      scheduleMicrotask(() => ready.add([0x00]));
    }
  }
}

void main() {
  late bool rustReady;

  setUpAll(() async {
    rustReady = await initHostRustLib();
  });

  PaxBleClient client(_Pax unit) => PaxBleClient(
    ble: unit,
    deviceId: 'pax',
    answerWait: const Duration(milliseconds: 300),
    pollEvery: const Duration(hours: 1),
  );

  test('a PAX 3 reads temperature and battery', () async {
    if (!rustReady) return markTestSkipped('Rust lib not loaded');
    final unit = _Pax(answers: [_temperature, _battery]);
    final reader = client(unit);
    final reading = await reader
        .watch()
        .firstWhere((r) => r.temperatureC != null && r.batteryPercent != null)
        .timeout(const Duration(seconds: 5));
    expect(reading.temperatureC, 185.5);
    expect(reading.batteryPercent, 87);

    // The only write is the status request, ciphertext + 16-byte IV, on the
    // write characteristic. Its plaintext is pinned in Rust.
    expect(unit.writes, isNotEmpty);
    for (final write in unit.writes) {
      expect(write.charUuid, _write);
      expect(write.value, hasLength(9 + 16));
    }
    await reader.close();
    expect(unit.disconnectedIds, ['pax']);
  });

  test(
    'an Era Pro is refused before anything is subscribed or written',
    () async {
      if (!rustReady) return markTestSkipped('Rust lib not loaded');
      final unit = _Pax(services: const [_service, _dis, _enrollment]);
      final reader = client(unit);
      await expectLater(
        reader.watch(),
        emitsError(
          isA<ReadOnlyBleException>().having(
            (e) => e.message,
            'message',
            contains('Era Pro'),
          ),
        ),
      );
      expect(unit.subscriptions, isEmpty);
      expect(unit.writes, isEmpty);
      expect(unit.reads, isEmpty);
    },
  );

  test('a unit that answers garbage is reported, not shown', () async {
    if (!rustReady) return markTestSkipped('Rust lib not loaded');
    final unit = _Pax(answers: [List.filled(20, 0xEE), List.filled(3, 1)]);
    final reader = client(unit);
    await expectLater(
      reader.watch(),
      emitsError(
        isA<ReadOnlyBleException>().having(
          (e) => e.message,
          'message',
          contains('decrypted'),
        ),
      ),
    );
  });

  test('a unit that answers nothing is reported', () async {
    if (!rustReady) return markTestSkipped('Rust lib not loaded');
    final unit = _Pax(notifies: false);
    final reader = client(unit);
    await expectLater(
      reader.watch(),
      emitsError(
        isA<ReadOnlyBleException>().having(
          (e) => e.message,
          'message',
          contains('did not answer'),
        ),
      ),
    );
    expect(unit.reads.where((r) => r.charUuid == _read), isEmpty);
  });
}

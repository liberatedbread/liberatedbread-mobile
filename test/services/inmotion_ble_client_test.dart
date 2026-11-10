// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The InMotion V2 reader against a fake wheel and the real Rust codec, with
// the spec's literal reply frames. Pinned: a V11 is identified and read, a
// legacy wheel is not touched, a wheel that answers garbage or nothing is
// reported, and nothing but the four read requests is ever written.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/inmotion_ble_client.dart';
import 'package:liberated_bread_mobile/services/read_only_ble_session.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/inmotion.dart';

import '../fakes/fake_ble_service.dart';
import '../helpers/host_rust_lib.dart';

const _v2 = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
const _write = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
const _legacy = '0000ffe0-0000-1000-8000-00805f9b34fb';
const _legacyWrite = '0000ffe5-0000-1000-8000-00805f9b34fb';

List<int> _hex(String text) => [
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
];

// The spec's frames (payload_formats examples and test_vectors).
final _carTypeV11 = _hex('aaaa110882010206010201009c');
final _versionsV11Early = _hex(
  'aaaa111d820622080004030f000602214000010110000602230d00010107000001f3',
);
final _realtimeV11Early = _hex(
  'aaaa143184e61eeb0561094a11ae04a004df01402958cbb000ce004a010000d4ff7c1564'
  '1900000000492b00000000000000000000c6',
);
final _totals = _hex(
  'aaaa141991e86c000066191c002db2040064e60000974d050000c7df01a4',
);

/// The four requests, byte for byte the spec's v2_request_* commands.
final _requests = {
  'car type': _hex('aaaa1102020110'),
  'versions': _hex('aaaa1102020617'),
  'real-time': _hex('aaaa14010411'),
  'totals': _hex('aaaa14011104'),
};

enum _Answers { properly, garbage, nothing }

class _Wheel extends FakeBleService {
  final StreamController<List<int>> notifications;
  final _Answers answers;
  final List<int> carType;

  factory _Wheel({
    List<String> services = const [_v2],
    _Answers answers = _Answers.properly,
    List<int>? carType,
  }) {
    // ignore: close_sinks — lives as long as the fake wheel.
    final notifications = StreamController<List<int>>.broadcast();
    return _Wheel._(notifications, services, answers, carType ?? _carTypeV11);
  }

  _Wheel._(
    this.notifications,
    List<String> services,
    this.answers,
    this.carType,
  ) : super(
        notifyStream: notifications.stream,
        servicesToReturn: [
          for (final uuid in services)
            BleDiscoveredService(uuid: uuid, characteristics: const []),
        ],
      );

  bool _same(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    await super.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
    List<int>? reply;
    switch (answers) {
      case _Answers.nothing:
        return;
      case _Answers.garbage:
        reply = [0xAA, 0xAA, 0x14, 0x03, 0x84, 0x01, 0x02, 0x00];
      case _Answers.properly:
        if (_same(value, _requests['car type']!)) reply = carType;
        if (_same(value, _requests['versions']!)) reply = _versionsV11Early;
        if (_same(value, _requests['real-time']!)) reply = _realtimeV11Early;
        if (_same(value, _requests['totals']!)) reply = _totals;
    }
    if (reply == null) return;
    // Split as a 20-byte MTU would.
    for (var i = 0; i < reply.length; i += 20) {
      final part = reply.sublist(
        i,
        i + 20 < reply.length ? i + 20 : reply.length,
      );
      scheduleMicrotask(() => notifications.add(part));
    }
  }
}

void main() {
  late bool rustReady;

  setUpAll(() async {
    rustReady = await initHostRustLib();
  });

  InMotionBleClient client(_Wheel wheel) => InMotionBleClient(
    ble: wheel,
    deviceId: 'wheel',
    answerWait: const Duration(milliseconds: 400),
    tick: const Duration(milliseconds: 5),
  );

  test('a V11 is identified and its telemetry read', () async {
    if (!rustReady) return markTestSkipped('Rust lib not loaded');
    final wheel = _Wheel();
    final reader = client(wheel);
    final reading = await reader
        .watch()
        .firstWhere((r) => r.telemetry != null && r.totals != null)
        .timeout(const Duration(seconds: 5));
    await reader.close();

    expect(reading.model.name, 'V11');
    final t = reading.telemetry!;
    expect(t.layout, InMotionLayout.v11Early);
    expect(t.voltageV, closeTo(79.10, 1e-9));
    expect(t.speedKmh, closeTo(24.01, 1e-9));
    expect(t.batteryPercent, 88);
    expect(t.mosTemperatureC, 27);
    expect(reading.totals!.totalKm, closeTo(278.80, 1e-9));

    // Only the four requests, ever, and only on the V2 write characteristic.
    expect(wheel.writes, isNotEmpty);
    for (final write in wheel.writes) {
      expect(write.charUuid, _write);
      expect(
        _requests.values.any(
          (r) => r.length == write.value.length && wheel._same(r, write.value),
        ),
        isTrue,
        reason: 'wrote ${write.value}',
      );
    }
  });

  test(
    'a legacy wheel is refused before anything is subscribed or written',
    () async {
      if (!rustReady) return markTestSkipped('Rust lib not loaded');
      final wheel = _Wheel(services: const [_legacy, _legacyWrite]);
      await expectLater(
        client(wheel).watch(),
        emitsError(isA<ReadOnlyBleException>()),
      );
      expect(wheel.subscriptions, isEmpty);
      expect(wheel.writes, isEmpty);
    },
  );

  test('a wheel that answers garbage is reported', () async {
    if (!rustReady) return markTestSkipped('Rust lib not loaded');
    final wheel = _Wheel(answers: _Answers.garbage);
    await expectLater(
      client(wheel).watch(),
      emitsError(
        isA<ReadOnlyBleException>().having(
          (e) => e.message,
          'message',
          contains('whole frame'),
        ),
      ),
    );
    expect(
      wheel.writes.every((w) => wheel._same(w.value, _requests['car type']!)),
      isTrue,
    );
  });

  test('a wheel that answers nothing is reported', () async {
    if (!rustReady) return markTestSkipped('Rust lib not loaded');
    final wheel = _Wheel(answers: _Answers.nothing);
    await expectLater(
      client(wheel).watch(),
      emitsError(
        isA<ReadOnlyBleException>().having(
          (e) => e.message,
          'message',
          contains('did not answer'),
        ),
      ),
    );
  });

  test('a model whose layout the spec does not state is not decoded', () async {
    if (!rustReady) return markTestSkipped('Rust lib not loaded');
    // Series 9, type 9: code 99, which the spec does not list. Its checksum
    // is right, so the frame is read and the model refused, not dropped.
    final body = _hex('11088201020909020100');
    final frame = [0xAA, 0xAA, ...body, body.fold<int>(0, (a, b) => a ^ b)];
    final wheel = _Wheel(carType: frame);
    await expectLater(
      client(wheel).watch(),
      emitsThrough(
        emitsError(
          isA<ReadOnlyBleException>().having(
            (e) => e.message,
            'message',
            contains('model 99'),
          ),
        ),
      ),
    );
    expect(
      wheel.writes.every((w) => wheel._same(w.value, _requests['car type']!)),
      isTrue,
    );
  });
}

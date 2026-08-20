// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Unit tests for the Rabbit Air BLE transport: payload chunking at the
// negotiated MTU, notification reassembly, the response timeout, and the
// connection ownership split between connect() and attach(). Driven against
// FakeBleService with the fake codec's faithful framing.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_ble_client.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _serviceUuid = '366048ae-9f36-43cf-8004-010c0c9fa52e';
const _charUuid = '53ef7d7d-c244-42bd-9064-a1569a521ca9';

const _rabbitService = BleDiscoveredService(
  uuid: _serviceUuid,
  characteristics: [
    BleDiscoveredCharacteristic(
      uuid: _charUuid,
      canRead: false,
      canWrite: true,
      canWriteWithResponse: true,
      canNotify: true,
    ),
  ],
);

void main() {
  late StreamController<List<int>> notifications;
  late FakeBleService ble;
  late RabbitAirBleClient client;

  /// The reply the next [RabbitAirBleClient.sendCommand] will reassemble,
  /// framed at [chunkSize] and fed as notifications.
  void answer(List<int> payload, int chunkSize) {
    final framed = [
      payload.length & 0xFF,
      (payload.length >> 8) & 0xFF,
      ...payload
    ];
    for (var i = 0; i < framed.length; i += chunkSize) {
      notifications.add(framed.sublist(
          i, i + chunkSize > framed.length ? framed.length : i + chunkSize));
    }
  }

  void setUpClient({int mtu = 515, Duration? responseTimeout}) {
    notifications = StreamController<List<int>>.broadcast();
    ble = FakeBleService(
      servicesToReturn: const [_rabbitService],
      notifyStream: notifications.stream,
      mtuToReturn: mtu,
    );
    client = RabbitAirBleClient(ble, FakeSpecCodec(),
        responseTimeout: responseTimeout ?? const Duration(milliseconds: 500));
  }

  tearDown(() async {
    await client.disconnect();
    await notifications.close();
  });

  test('connect locates the command characteristic and subscribes', () async {
    setUpClient();
    await client.connect('01');

    expect(ble.connectedIds, ['01']);
    expect(ble.subscriptions, [_charUuid]);
  });

  test('a payload crossing the 510-byte boundary writes in MTU-5 chunks',
      () async {
    setUpClient(mtu: 515);
    await client.connect('01');

    final payload = List<int>.generate(1200, (i) => i % 251);
    final reply = client.sendCommand(payload);
    answer([1, 2, 3], 510);
    expect(await reply, [1, 2, 3]);

    // 1202 framed bytes (2 prefix + 1200 payload) at 510 per write.
    expect(ble.writes.map((w) => w.value.length), [510, 510, 182]);
    expect(ble.writes.first.value.take(2), [1200 & 0xFF, 1200 >> 8]);
  });

  test('a small MTU floors the chunk size instead of breaking framing',
      () async {
    setUpClient(mtu: 23);
    await client.connect('01');

    final payload = List<int>.filled(40, 0xAB);
    final reply = client.sendCommand(payload);
    answer([9], 18);
    await reply;

    // 42 framed bytes at 18 per write.
    expect(ble.writes.map((w) => w.value.length), [18, 18, 6]);
  });

  test('a multi-chunk reply reassembles, skipping only the first prefix',
      () async {
    setUpClient();
    await client.connect('01');

    final expected = List<int>.generate(600, (i) => i % 251);
    final reply = client.sendCommand([1]);
    answer(expected, 510);
    expect(await reply, expected);
  });

  test('a sub-2-byte notification is ignored when a new message is expected',
      () async {
    setUpClient();
    await client.connect('01');

    final reply = client.sendCommand([1]);
    notifications.add([0x2C]); // a lone prefix byte: noise, not a message
    await Future<void>.delayed(Duration.zero);
    answer([7, 7], 510);
    expect(await reply, [7, 7]);
  });

  test('an unanswered command throws after the response window', () async {
    setUpClient(responseTimeout: const Duration(milliseconds: 50));
    await client.connect('01');

    await expectLater(
      client.sendCommand([1]),
      throwsA(isA<RabbitAirBleException>()
          .having((e) => e.message, 'message', contains('did not answer'))),
    );
  });

  test(
      'exchanges serialize: the second request writes after the first '
      'answer lands', () async {
    setUpClient();
    await client.connect('01');

    final first = client.sendCommand([1]);
    final second = client.sendCommand([2]);
    await Future<void>.delayed(Duration.zero);
    expect(ble.writes.length, 1, reason: 'one exchange in flight');
    answer([1], 510);
    await first;
    await Future<void>.delayed(Duration.zero);
    expect(ble.writes.length, 2);
    answer([2], 510);
    expect(await second, [2]);
  });

  test(
      'a device without the command characteristic fails connect and drops '
      'the link it opened', () async {
    notifications = StreamController<List<int>>.broadcast();
    ble = FakeBleService(
      servicesToReturn: const [],
      notifyStream: notifications.stream,
    );
    client = RabbitAirBleClient(ble, FakeSpecCodec());

    await expectLater(
        client.connect('01'), throwsA(isA<RabbitAirBleException>()));
    expect(ble.disconnectedIds, ['01']);
  });

  test(
      'attach borrows the caller\'s connection: disconnect releases only '
      'the subscription', () async {
    setUpClient();
    await client.attach('01', services: const [_rabbitService]);

    expect(ble.connectedIds, isEmpty, reason: 'attach never connects');
    expect(ble.subscriptions, [_charUuid]);

    await client.disconnect();
    expect(ble.disconnectedIds, isEmpty,
        reason: 'the device screen owns the link');
    expect(ble.liveSubscriberCount[_charUuid] ?? 0, 0);
  });
}

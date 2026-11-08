// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The LimitlessLED client against a local fake bridge: a real datagram socket
// on loopback. Nothing here has met hardware. Which bytes a send is made of is
// pinned against the spec's literal frames in
// rust/src/protocol/limitlessled.rs; this is about playing them.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/limitlessled_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

LimitlessledFrameDto _frame(List<int> bytes, int delayAfterMs) =>
    LimitlessledFrameDto(
      bytes: Uint8List.fromList(bytes),
      delayAfterMs: delayAfterMs,
    );

void main() {
  final client = LimitlessledControlClient();

  test('plays the frames in order, as separate datagrams, paced', () async {
    final bridge = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(bridge.close);
    final heard = <(List<int>, DateTime)>[];
    bridge.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = bridge.receive();
      if (datagram != null) heard.add((datagram.data, DateTime.now()));
    });

    await client.send('127.0.0.1', bridge.port, [
      _frame([0x45, 0x00, 0x55], 100),
      _frame([0x40, 0xB0, 0x55], 100),
      _frame([0x45, 0x00, 0x55], 0),
    ]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(heard.map((h) => h.$1).toList(), [
      [0x45, 0x00, 0x55],
      [0x40, 0xB0, 0x55],
      [0x45, 0x00, 0x55],
    ]);
    expect(
      heard[1].$2.difference(heard[0].$2).inMilliseconds,
      greaterThanOrEqualTo(90),
      reason: 'the spec asks for >=100 ms between sends',
    );
  });

  test('a host that is no address is named, not looked up', () async {
    await expectLater(
      client.send('bridge.local', 8899, [
        _frame([0x42, 0x00, 0x55], 0),
      ]),
      throwsA(isA<LimitlessledControlException>()),
    );
  });

  test('returns without waiting for an answer nobody will send', () async {
    final bridge = await RawDatagramSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(bridge.close);

    await client
        .send('127.0.0.1', bridge.port, [
          _frame([0x42, 0x00, 0x55], 0),
        ])
        .timeout(const Duration(seconds: 2));
  });
}

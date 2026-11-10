// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The JuiceNet listener against a fake charger on loopback and the real Rust
// parser: the spec's status line read, garbage and encrypted frames refused,
// a stranger dropped, silence left as silence, and the pin that the listener
// never sends the charger anything.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/juicenet_listener.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/juicenet.dart';

import '../helpers/host_rust_lib.dart';

const _status =
    '0910000000000000000000004242:v09u,s001,F31,u00412974,V2400,'
    'L00004262804,S02,T28,M0024,C0040,m0040,t09,i23,e-0001,f5990,r99,b000,'
    'B0000000,P0,E0004501,A00161,p0996!ZYK:';

/// A charger: a socket that sends and records anything sent back to it.
class _FakeCharger {
  final RawDatagramSocket socket;
  final replies = <List<int>>[];

  _FakeCharger._(this.socket) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d != null) replies.add(d.data);
    });
  }

  static Future<_FakeCharger> start([String address = '127.0.0.1']) async =>
      _FakeCharger._(await RawDatagramSocket.bind(InternetAddress(address), 0));

  void send(List<int> bytes, int port) =>
      socket.send(bytes, InternetAddress.loopbackIPv4, port);

  void close() => socket.close();
}

Future<(JuiceNetListener, List<JuiceNetHeard>)> _listen({
  String? chargerHost = '127.0.0.1',
}) async {
  final listener = JuiceNetListener(
    port: 0,
    chargerHost: chargerHost,
    bind: (port) => RawDatagramSocket.bind(InternetAddress.loopbackIPv4, port),
  );
  await listener.start();
  final heard = <JuiceNetHeard>[];
  listener.heard.listen(heard.add);
  return (listener, heard);
}

/// The port the listener bound (0 asks the OS for one).
int _portOf(JuiceNetListener listener) => listener.boundPort!;

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 200));

void main() {
  setUpAll(() async {
    if (!await initHostRustLib()) {
      markTestSkipped('host Rust library not available');
    }
  });

  test('the spec\'s status line is heard and read, and nothing is sent '
      'back', () async {
    final (listener, heard) = await _listen();
    final charger = await _FakeCharger.start();
    addTearDown(() async {
      charger.close();
      await listener.dispose();
    });

    charger.send(ascii.encode(_status), _portOf(listener));
    await _settle();

    final frame = heard.single.frame;
    expect(frame.kind, JuiceNetFrameKind.status);
    expect(frame.statusText, 'Charging');
    expect(frame.currentAmps, 16.1);
    expect(frame.voltage, 240.0);
    expect(frame.powerWatts, 3864.0);
    expect(frame.offlineLimitAmps, 40);
    // A server answers every status line with a CMD; this listener does not.
    await _settle();
    expect(charger.replies, isEmpty);
  });

  test('garbage, a bad hash and an encrypted frame are refused', () async {
    final (listener, heard) = await _listen();
    final charger = await _FakeCharger.start();
    addTearDown(() async {
      charger.close();
      await listener.dispose();
    });

    charger.send([0xFF, 0x00, 0x13, 0x37], _portOf(listener));
    charger.send(
      ascii.encode(_status.replaceFirst('A00161', 'A00999')),
      _portOf(listener),
    );
    charger.send([
      ...ascii.encode('0910000000000000000000004242:v09e'),
      0x00,
      0xC3,
      0x28,
    ], _portOf(listener));
    await _settle();

    expect(heard.map((h) => h.frame.kind), [
      JuiceNetFrameKind.invalid,
      JuiceNetFrameKind.invalid,
      JuiceNetFrameKind.encrypted,
    ]);
    expect(heard.last.frame.note, contains('cannot be decoded'));
    expect(heard.every((h) => h.frame.currentAmps == null), isTrue);
    expect(charger.replies, isEmpty);
  });

  test('a datagram from another address is dropped', () async {
    final (listener, heard) = await _listen(chargerHost: '127.0.0.2');
    final stranger = await _FakeCharger.start();
    addTearDown(() async {
      stranger.close();
      await listener.dispose();
    });

    stranger.send(ascii.encode(_status), _portOf(listener));
    await _settle();
    expect(heard, isEmpty);
  });

  test('silence is silence: nothing heard, nothing made up', () async {
    final (listener, heard) = await _listen();
    addTearDown(listener.dispose);
    await _settle();
    expect(listener.listening, isTrue);
    expect(heard, isEmpty);
  });

  test('a port already taken is said in words', () async {
    final taken = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(taken.close);
    final listener = JuiceNetListener(
      port: taken.port,
      bind: (port) => RawDatagramSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
        reuseAddress: false,
      ),
    );
    await expectLater(
      listener.start(),
      throwsA(
        isA<JuiceNetException>().having(
          (e) => e.message,
          'message',
          contains('Could not listen on UDP port ${taken.port}'),
        ),
      ),
    );
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The BiSecur reader against a fake gateway and the real Rust codec: a whole
// session, a gateway that answers garbage or nothing, and the pin that no
// frame this client writes can be an impulse.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/bisecur_client.dart';

import '../helpers/host_rust_lib.dart';

const _mac = '54:10:EC:00:00:01';
const _token = 0x1A2B3C4D;
const _transition = 'B800001801086C020000000000000000';
const _password = 'correct horse battery';

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0').toUpperCase()).join();

List<int> _unhex(String text) => [
  for (var i = 0; i < text.length; i += 2)
    int.parse(text.substring(i, i + 2), radix: 16),
];

/// A gateway's frame, per the spec's rule. Built here, independently of the
/// Rust builder, so the two have to agree.
List<int> _frame(int tag, int token, int command, List<int> payload) {
  final length = 9 + payload.length;
  final packet = [
    tag,
    (token >> 24) & 0xff,
    (token >> 16) & 0xff,
    (token >> 8) & 0xff,
    token & 0xff,
    command,
    ...payload,
  ];
  final checksum = (length + packet.fold<int>(0, (a, b) => a + b)) & 0xff;
  final body = [
    0x54, 0x10, 0xEC, 0, 0, 1, //
    0, 0, 0, 0, 0, 6,
    length >> 8, length & 0xff,
    ...packet,
    checksum,
  ];
  final text = _hex(body);
  final transport = ascii.encode(text).fold<int>(0, (a, b) => a + b) & 0xff;
  return ascii.encode(text + _hex([transport]));
}

/// A request as the gateway sees it.
({int tag, int command, List<int> payload}) _parse(List<int> frame) {
  final bytes = _unhex(ascii.decode(frame));
  return (
    tag: bytes[14],
    command: bytes[19],
    payload: bytes.sublist(20, bytes.length - 2),
  );
}

typedef _Reply =
    List<List<int>>? Function(
      ({int tag, int command, List<int> payload}) request,
    );

class _FakeGateway implements BiSecurTransport {
  final _Reply answer;
  final Object? openError;
  final written = <List<int>>[];
  final _chunks = <List<int>>[];
  Completer<void>? _waiter;
  var closed = 0;

  _FakeGateway(this.answer, {this.openError});

  @override
  Future<void> open(String host, int port, Duration timeout) async {
    if (openError != null) throw openError!;
  }

  @override
  Future<void> write(List<int> bytes) async {
    written.add(bytes);
    final replies = answer(_parse(bytes));
    if (replies != null) _chunks.addAll(replies);
    _waiter?.complete();
    _waiter = null;
  }

  @override
  Future<List<int>> read(Duration timeout) async {
    if (_chunks.isEmpty) {
      final waiter = _waiter = Completer<void>();
      await waiter.future.timeout(timeout);
    }
    return _chunks.removeAt(0);
  }

  @override
  Future<void> close() async => closed++;
}

List<List<int>>? _healthy(({int tag, int command, List<int> payload}) r) =>
    switch (r.command) {
      0x10 => [
        _frame(r.tag, 0, 0x90, [9, 0x1A, 0x2B, 0x3C, 0x4D]),
      ],
      0x06 => [
        _frame(
          r.tag,
          _token,
          0x86,
          ascii.encode(
            '[{"id":0,"name":"Garage","ports":[{"id":0,"type":1}]}]',
          ),
        ),
      ],
      0x70 => [_frame(r.tag, _token, 0xF0, _unhex(_transition))],
      _ => null,
    };

BiSecurGatewayClient _client(
  _FakeGateway gateway, {
  Duration timeout = const Duration(seconds: 2),
}) => BiSecurGatewayClient(
  host: '192.168.1.50',
  port: 4000,
  gatewayMac: _mac,
  transportFactory: () => gateway,
  timeout: timeout,
  commandGap: Duration.zero,
  positionGap: Duration.zero,
);

Future<void> _expectFailure(Future<Object?> future, String message) =>
    expectLater(
      future,
      throwsA(
        isA<BiSecurException>()
            .having((e) => e.message, 'message', contains(message))
            .having(
              (e) => e.message,
              'the password stays out of it',
              isNot(contains(_password)),
            ),
      ),
    );

void main() {
  setUpAll(() async {
    if (!await initHostRustLib()) {
      markTestSkipped('host Rust library not available');
    }
  });

  Future<List<BiSecurPortReading>> read(BiSecurGatewayClient client) =>
      client.read(user: 'username', password: _password);

  test('a whole session reads the door from the spec example', () async {
    final gateway = _FakeGateway(_healthy);
    final readings = await read(_client(gateway));

    expect(readings, hasLength(1));
    expect(readings.single.groupName, 'Garage');
    expect(readings.single.port.typeName, 'Impulse');
    final transition = readings.single.transition!;
    expect(transition.positionPercent, 92);
    expect(transition.targetPercent, 0);
    expect(transition.driving, isTrue);
    expect(transition.drivingTowardsClosed, isTrue);
    expect(gateway.closed, 1);
  });

  test('sends login, list, read and logout, and nothing else', () async {
    final gateway = _FakeGateway(_healthy);
    await read(_client(gateway));
    expect(gateway.written.map((f) => _parse(f).command).toList(), [
      0x10,
      0x06,
      0x70,
      0x11,
    ]);
  });

  test('no frame it writes is an impulse, whatever the gateway says', () async {
    for (final answer in <_Reply>[
      _healthy,
      (_) => null,
      (_) => [ascii.encode('garbage')],
      (r) => [
        _frame(r.tag, 0, 0x01, [10]),
      ],
      // A gateway that reports a port, and a port id of 0x33 besides.
      (r) => r.command == 0x06
          ? [
              _frame(
                r.tag,
                _token,
                0x86,
                ascii.encode(
                  '[{"id":51,"name":"x","ports":[{"id":51,"type":1}]}]',
                ),
              ),
            ]
          : _healthy(r),
    ]) {
      final gateway = _FakeGateway(answer);
      final client = _client(
        gateway,
        timeout: const Duration(milliseconds: 60),
      );
      await read(client).then((_) {}, onError: (Object _) {});
      for (final frame in gateway.written) {
        expect(_parse(frame).command, isNot(0x33), reason: 'SET_STATE');
        expect(const [0x10, 0x06, 0x70, 0x11], contains(_parse(frame).command));
      }
    }
  });

  test('skips stale logouts coalesced ahead of the login reply', () async {
    final gateway = _FakeGateway((r) {
      if (r.command != 0x10) return _healthy(r);
      return [
        [
          ..._frame(0xFF, 0, 0x11, const []),
          ..._frame(0xFF, 0, 0x11, const []),
          ..._frame(r.tag, 0, 0x90, [9, 0x1A, 0x2B, 0x3C, 0x4D]),
        ],
      ];
    });
    final readings = await read(_client(gateway));
    expect(readings.single.transition?.positionPercent, 92);
  });

  test('assembles a reply split across reads', () async {
    final gateway = _FakeGateway((r) {
      final replies = _healthy(r);
      if (r.command != 0x70 || replies == null) return replies;
      final whole = replies.single;
      return [whole.sublist(0, 11), whole.sublist(11, 40), whole.sublist(40)];
    });
    final readings = await read(_client(gateway));
    expect(readings.single.transition?.positionPercent, 92);
  });

  test('a refused login says so, and reads no doors', () async {
    final gateway = _FakeGateway(
      (r) => r.command == 0x10
          ? [
              _frame(r.tag, 0, 0x01, [2]),
            ]
          : _healthy(r),
    );
    await _expectFailure(read(_client(gateway)), 'refused that user');
    expect(gateway.written, hasLength(1));
  });

  test('a port with no position is a note, not an error', () async {
    final gateway = _FakeGateway(
      (r) => r.command == 0x70
          ? [
              _frame(r.tag, _token, 0x01, [10]),
            ]
          : _healthy(r),
    );
    final readings = await read(_client(gateway));
    expect(readings.single.transition, isNull);
    expect(readings.single.note, contains('no position'));
    // It still logged out and left.
    expect(_parse(gateway.written.last).command, 0x11);
  });

  test('answers garbage to the login: an error and not a reading', () async {
    final gateway = _FakeGateway((_) => [ascii.encode('!' * 60)]);
    await _expectFailure(read(_client(gateway)), 'not in a form');
    expect(gateway.closed, 1);
  });

  test('answers garbage to a read: logged out, then an error', () async {
    final gateway = _FakeGateway(
      (r) => r.command == 0x70
          ? [
              _frame(r.tag, _token, 0xF0, [1, 2, 3]),
            ]
          : _healthy(r),
    );
    await _expectFailure(read(_client(gateway)), 'not in a form');
    expect(_parse(gateway.written.last).command, 0x11);
  });

  test('a frame with a bad checksum is not a position', () async {
    final gateway = _FakeGateway((r) {
      final replies = _healthy(r);
      if (r.command != 0x70 || replies == null) return replies;
      final bad = List<int>.of(replies.single);
      bad[30] = bad[30] == 0x31 ? 0x32 : 0x31;
      return [bad];
    });
    await _expectFailure(read(_client(gateway)), 'not in a form');
  });

  test('answers nothing: an error, and let go', () async {
    final gateway = _FakeGateway((_) => null);
    await _expectFailure(
      read(_client(gateway, timeout: const Duration(milliseconds: 50))),
      'did not answer',
    );
    expect(gateway.closed, 1);
  });

  test('a read that goes quiet part way still logs out', () async {
    final gateway = _FakeGateway((r) => r.command == 0x70 ? null : _healthy(r));
    await _expectFailure(
      read(_client(gateway, timeout: const Duration(milliseconds: 80))),
      'did not answer',
    );
    expect(_parse(gateway.written.last).command, 0x11);
  });

  test('an unreachable gateway says so', () async {
    final gateway = _FakeGateway(
      (_) => null,
      openError: const SocketException('refused'),
    );
    await _expectFailure(read(_client(gateway)), 'Could not reach');
    expect(gateway.written, isEmpty);
  });

  test('a bad MAC fails cleanly, without sending anything', () async {
    final gateway = _FakeGateway(_healthy);
    final client = BiSecurGatewayClient(
      host: '192.168.1.50',
      port: 4000,
      gatewayMac: 'not-a-mac',
      transportFactory: () => gateway,
      commandGap: Duration.zero,
      positionGap: Duration.zero,
    );
    await _expectFailure(read(client), 'not in a form');
    expect(gateway.written, isEmpty);
  });

  test('the login frame is the only place the password goes', () async {
    final gateway = _FakeGateway(_healthy);
    await read(_client(gateway));
    final holding = gateway.written.where((frame) {
      final payload = _parse(frame).payload;
      return ascii.decode(payload, allowInvalid: true).contains(_password);
    });
    expect(holding, hasLength(1));
    expect(_parse(holding.single).command, 0x10);
  });

  group('the real socket', () {
    late ServerSocket server;

    setUp(() async {
      server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    });

    tearDown(() => server.close());

    test('hands back bytes, and times out on a silent peer', () async {
      server.listen((socket) {
        socket.listen((request) {
          socket.add(request);
        });
      });
      final transport = SocketBiSecurTransport();
      await transport.open(
        '127.0.0.1',
        server.port,
        const Duration(seconds: 2),
      );
      await transport.write([1, 2, 3]);
      expect(await transport.read(const Duration(seconds: 2)), [1, 2, 3]);
      await expectLater(
        transport.read(const Duration(milliseconds: 40)),
        throwsA(isA<TimeoutException>()),
      );
      // The timed-out wait carries over, so a later reply is still seen.
      await transport.write([4]);
      expect(await transport.read(const Duration(seconds: 2)), [4]);
      await transport.close();
    });

    test('a peer that hangs up is a failure', () async {
      server.listen((socket) => unawaited(socket.close()));
      final transport = SocketBiSecurTransport();
      await transport.open(
        '127.0.0.1',
        server.port,
        const Duration(seconds: 2),
      );
      await expectLater(
        transport.read(const Duration(seconds: 2)),
        throwsA(isA<SocketException>()),
      );
      await transport.close();
    });
  });
}

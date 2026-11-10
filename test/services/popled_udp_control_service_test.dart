// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Wi-Fi popled client against a local fake panel: a real datagram socket
// on loopback, through the real Rust codec, so the bytes the fake reads are
// the bytes a panel would. Nothing here has met a Wi-Fi panel; the frame
// bodies are the ones a BLE backpack accepted, and the UDP wrapping (an outer
// u16-LE length, 180-byte pieces) is the spec's word, pinned byte for byte in
// rust/src/protocol/popled_udp.rs.

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/popled_udp_control_service.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';

import '../helpers/host_rust_lib.dart';

/// The panel's side of a frame: `aa 55 ff ff | len | seq | body | sum`.
List<int> _frame(int seq, List<int> body) {
  final declared = body.length + 4;
  final out = [
    0xAA,
    0x55,
    0xFF,
    0xFF,
    declared & 0xFF,
    declared >> 8,
    seq & 0xFF,
    seq >> 8,
    ...body,
  ];
  final sum = out.fold<int>(0, (a, b) => (a + b) & 0xFFFF);
  return [...out, sum & 0xFF, sum >> 8];
}

/// What the spec says a datagram is: a u16-LE length, then that many bytes.
List<int> _datagram(List<int> bytes) => [
  bytes.length & 0xFF,
  bytes.length >> 8,
  ...bytes,
];

/// A frame the fake panel heard, reassembled from its datagrams.
class _Heard {
  final int seq;
  final List<int> body;
  const _Heard(this.seq, this.body);
}

/// A loopback panel. [answer] decides what goes back for each frame heard:
/// a list of datagrams, or nothing.
class _FakePanel {
  final RawDatagramSocket socket;
  final heard = <_Heard>[];
  final datagrams = <List<int>>[];
  List<List<int>> Function(_Heard frame) answer;
  final _pending = <int>[];

  _FakePanel._(this.socket, this.answer) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null) return;
      datagrams.add(d.data);
      // Strip the spec's outer length and reassemble by the frame's own.
      final length = d.data[0] | d.data[1] << 8;
      expect(length, d.data.length - 2, reason: 'the outer length is exact');
      _pending.addAll(d.data.sublist(2));
      if (_pending.length < 6) return;
      final whole = 6 + (_pending[4] | _pending[5] << 8);
      if (_pending.length < whole) return;
      final bytes = _pending.sublist(0, whole);
      _pending.removeRange(0, whole);
      expect(bytes.sublist(0, 4), [0xAA, 0x55, 0xFF, 0xFF]);
      final frame = _Heard(
        bytes[6] | bytes[7] << 8,
        bytes.sublist(8, bytes.length - 2),
      );
      heard.add(frame);
      for (final reply in answer(frame)) {
        socket.send(reply, d.address, d.port);
      }
    });
  }

  static Future<_FakePanel> start(
    List<List<int>> Function(_Heard frame) answer,
  ) async => _FakePanel._(
    await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    answer,
  );

  int get port => socket.port;
  void close() => socket.close();
}

List<List<int>> _ack(_Heard frame, [int status = 0]) => [
  _datagram(_frame(frame.seq, [0x81, 0x82, status])),
];

void main() {
  final codec = RealSpecCodec();
  late final bool rustReady;

  setUpAll(() async {
    rustReady = await initHostRustLib();
  });

  PopledUdpClient client() => PopledUdpClient(
    codec,
    ackTimeout: const Duration(milliseconds: 300),
    attempts: 2,
  );

  bool skip() {
    if (!rustReady) markTestSkipped('Rust lib not loaded');
    return !rustReady;
  }

  test('frames rise from 1, one per command, each acknowledged', () async {
    if (skip()) return;
    final panel = await _FakePanel.start(_ack);
    addTearDown(panel.close);
    final c = client();

    await c.send('127.0.0.1', panel.port, [0xC1, 0x02, 0x06, 0x02, 0x00, 15]);
    await c.send('127.0.0.1', panel.port, [0xC1, 0x02, 0x04, 0x02, 0x00, 0]);

    expect(panel.heard.map((f) => f.seq), [1, 2]);
    expect(panel.heard.first.body, [0xC1, 0x02, 0x06, 0x02, 0x00, 15]);
    // The first datagram whole: the bench's BLE frame behind its length.
    expect(panel.datagrams.first, [
      0x10, 0x00, 0xAA, 0x55, 0xFF, 0xFF, 0x0A, 0x00, 0x01, 0x00, //
      0xC1, 0x02, 0x06, 0x02, 0x00, 0x0F, 0xE2, 0x03,
    ]);
    expect(c.nextSeq, 3);
  });

  test('a long frame goes in 180-byte pieces and is taken whole', () async {
    if (skip()) return;
    final panel = await _FakePanel.start(_ack);
    addTearDown(panel.close);

    final body = List<int>.generate(400, (i) => i & 0xFF);
    await client().send('127.0.0.1', panel.port, body);

    expect(panel.datagrams.map((d) => d.length), [182, 182, 52]);
    expect(panel.heard.single.body, body);
  });

  test('silence is resent with the same sequence, then reported', () async {
    if (skip()) return;
    final panel = await _FakePanel.start((_) => const []);
    addTearDown(panel.close);

    await expectLater(
      client().send('127.0.0.1', panel.port, [0xC1, 0x03, 0x04, 0x00]),
      throwsA(
        isA<PopledUdpException>().having(
          (e) => e.message,
          'message',
          contains('did not answer'),
        ),
      ),
    );
    expect(panel.heard.map((f) => f.seq), [1, 1]);
  });

  test('garbage is waited past, not taken for an answer', () async {
    if (skip()) return;
    final panel = await _FakePanel.start(
      (frame) => [
        [0x01, 0x02, 0x03],
        _datagram([0xAA, 0x55, 0xFF]),
        // Another frame's acknowledgement is not this one's.
        _datagram(_frame(frame.seq + 7, [0x81, 0x82, 0x00])),
        // A bad checksum.
        _datagram([
          ..._frame(frame.seq, [0x81, 0x82, 0x00]).take(10),
          0,
          0,
        ]),
      ],
    );
    addTearDown(panel.close);

    await expectLater(
      client().send('127.0.0.1', panel.port, [0xC1, 0x03, 0x04, 0x00]),
      throwsA(isA<PopledUdpException>()),
    );

    panel.answer = (frame) => [
      [0xDE, 0xAD],
      ..._ack(frame),
    ];
    final reply = await client().send('127.0.0.1', panel.port, [0xC1]);
    expect(reply.ackStatus, 0);
  });

  test('a reply without the outer length is read too', () async {
    if (skip()) return;
    final panel = await _FakePanel.start(
      (frame) => [
        _frame(frame.seq, [0x81, 0x82, 0x00]),
      ],
    );
    addTearDown(panel.close);
    final reply = await client().send('127.0.0.1', panel.port, [0xC1]);
    expect(reply.ackStatus, 0);
  });

  test('a refusal is reported with its status', () async {
    if (skip()) return;
    final panel = await _FakePanel.start((frame) => _ack(frame, 3));
    addTearDown(panel.close);
    await expectLater(
      client().send('127.0.0.1', panel.port, [0xC1]),
      throwsA(
        isA<PopledUdpException>().having(
          (e) => e.message,
          'message',
          contains('status 3'),
        ),
      ),
    );
  });

  test('the panel states its size, split across datagrams', () async {
    if (skip()) return;
    final panel = await _FakePanel.start((frame) {
      final answer = _frame(frame.seq, [
        0x81, 0x83, 0x1B, 0x04, 0x00, 0x40, 0x00, 0x20, //
        ...List.filled(250, 0xEE),
      ]);
      return [
        _datagram(answer.sublist(0, 180)),
        _datagram(answer.sublist(180)),
      ];
    });
    addTearDown(panel.close);

    final size = await client().panelSize('127.0.0.1', panel.port);
    expect(size, (width: 64, height: 32));
    expect(panel.heard.single.body, [0xC1, 0x03, 0x0A, 0x00, 0x1B, 0x00]);
  });

  test('an upload goes body by body, each waiting for its ack', () async {
    if (skip()) return;
    final panel = await _FakePanel.start(_ack);
    addTearDown(panel.close);
    final progress = <int>[];
    final bodies = [
      Uint8List.fromList([1]),
      Uint8List.fromList([2]),
      Uint8List.fromList([3]),
    ];
    await client().sendAll(
      '127.0.0.1',
      panel.port,
      bodies,
      onProgress: (done, total) => progress.add(done),
    );
    expect(panel.heard.map((f) => f.body.single), [1, 2, 3]);
    expect(panel.heard.map((f) => f.seq), [1, 2, 3]);
    expect(progress, [1, 2, 3]);
  });

  test('a host that is no address is named, not looked up', () async {
    await expectLater(
      client().send('panel.local', 9090, [0xC1]),
      throwsA(isA<PopledUdpException>()),
    );
  });
}

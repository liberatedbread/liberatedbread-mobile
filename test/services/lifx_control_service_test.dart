// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/lifx_control_service.dart';

void main() {
  test('send delivers the packet twice (lossy UDP gets two shots)', () async {
    final responder =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final received = <List<int>>[];
    responder.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = responder.receive();
      if (datagram != null) received.add(datagram.data);
    });

    final client = LifxControlClient(port: responder.port);
    await client.send('127.0.0.1', Uint8List.fromList(const [1, 2, 3]));
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(received.length, 2, reason: 'a set is sent twice');
    expect(received.first, const [1, 2, 3]);
    responder.close();
  });

  test('request returns the reply whose sequence byte matches', () async {
    final responder =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    responder.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = responder.receive();
      if (datagram == null) return;
      // Answer with a 40-byte "reply" that echoes the request's sequence in
      // the LIFX header's sequence slot (offset 23), as real firmware does.
      final reply = Uint8List(40);
      reply[23] = datagram.data[23];
      reply[0] = 0xAB; // a marker so we can prove it is our reply
      responder.send(reply, datagram.address, datagram.port);
    });

    final client = LifxControlClient(port: responder.port);
    final seq = client.nextSequence();
    final request = Uint8List(36)..[23] = seq;
    final reply = await client.request(
      '127.0.0.1',
      request,
      sequence: seq,
      timeout: const Duration(milliseconds: 500),
    );

    expect(reply, isNotNull);
    expect(reply![23], seq);
    expect(reply[0], 0xAB);
    responder.close();
  });

  test('request ignores a reply whose sequence does not match', () async {
    final responder =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    responder.listen((event) {
      if (event != RawSocketEvent.read) return;
      final datagram = responder.receive();
      if (datagram == null) return;
      // Reply with the WRONG sequence: a datagram meant for a different
      // request must not satisfy this one.
      final reply = Uint8List(40)..[23] = (datagram.data[23] + 1) & 0xFF;
      responder.send(reply, datagram.address, datagram.port);
    });

    final client = LifxControlClient(port: responder.port);
    final reply = await client.request(
      '127.0.0.1',
      Uint8List(36)..[23] = 9,
      sequence: 9,
      timeout: const Duration(milliseconds: 60),
      retries: 1,
    );
    expect(reply, isNull);
    responder.close();
  });

  test('request returns null after every attempt times out', () async {
    // A bound-but-silent port: the sends land, nothing answers.
    final silent =
        await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
    final client = LifxControlClient(port: silent.port);
    final reply = await client.request(
      '127.0.0.1',
      Uint8List(36)..[23] = 5,
      sequence: 5,
      timeout: const Duration(milliseconds: 40),
      retries: 1,
    );
    expect(reply, isNull);
    silent.close();
  });

  test('nextSequence cycles 1..255 and never yields 0', () {
    final client = LifxControlClient();
    final seqs = [for (var i = 0; i < 256; i++) client.nextSequence()];
    expect(seqs, isNot(contains(0)));
    expect(seqs.first, 1);
    expect(seqs[254], 255);
    expect(seqs[255], 1, reason: 'wraps back to 1 after 255');
  });
}

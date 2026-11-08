// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Yeelight socket client against a local fake lamp: a real ServerSocket on
// loopback, speaking the framing the spec states. Nothing here has met
// hardware. The wire format itself is pinned against the spec's literal frames
// in rust/src/protocol/yeelight.rs.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/services/yeelight_control_service.dart';

import '../fakes/fake_spec_codec.dart';

/// A lamp that reads one line and answers with [replies], in pieces if asked.
Future<({ServerSocket server, Future<String> heard})> _lamp(
  List<List<int>> replies, {
  bool answer = true,
}) async {
  final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final heard = Completer<String>();
  server.listen((socket) {
    final received = <int>[];
    socket.listen((bytes) async {
      received.addAll(bytes);
      if (!received.contains(0x0A) || heard.isCompleted) return;
      heard.complete(utf8.decode(received));
      if (!answer) return;
      for (final reply in replies) {
        socket.add(reply);
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
    }, onError: (Object _) {});
  });
  return (server: server, heard: heard.future);
}

void main() {
  final client = YeelightControlClient(FakeSpecCodec());
  const setPower = YeelightRequestDto(
    json: '{"id":1,"method":"set_power","params":["on","smooth",500]}',
  );
  const getProp = YeelightRequestDto(
    json: '{"id":1,"method":"get_prop","params":["power","bright"]}',
  );

  test('writes one CRLF-terminated line and reads the answer', () async {
    final lamp = await _lamp([utf8.encode('{"id":1,"result":["ok"]}\r\n')]);
    addTearDown(lamp.server.close);

    final reply = await client.send('127.0.0.1', lamp.server.port, setPower);

    expect(await lamp.heard, '${setPower.json}\r\n');
    expect(reply.answersRequest, isTrue);
  });

  test(
    'a pushed notification is read past, not taken for the answer',
    () async {
      final lamp = await _lamp([
        utf8.encode('{"method":"props","params":{"power":"off"}}\r\n'),
        utf8.encode('{"id":1,"result":["on","42"]}\r\n'),
      ]);
      addTearDown(lamp.server.close);

      final reply = await client.send('127.0.0.1', lamp.server.port, getProp);

      expect(reply.fields, {'power': 'on', 'bright': '42'});
    },
  );

  test('an answer split across reads is put back together', () async {
    final line = utf8.encode('{"id":1,"result":["on","42"]}\r\n');
    final lamp = await _lamp([line.sublist(0, 9), line.sublist(9)]);
    addTearDown(lamp.server.close);

    final reply = await client.send('127.0.0.1', lamp.server.port, getProp);

    expect(reply.fields['bright'], '42');
  });

  test('a refusal from the lamp throws its own words', () async {
    final lamp = await _lamp([
      utf8.encode(
        '{"id":1,"error":{"code":-1,"message":"quota exceeded"}}\r\n',
      ),
    ]);
    addTearDown(lamp.server.close);

    await expectLater(
      client.send('127.0.0.1', lamp.server.port, setPower),
      throwsA(
        isA<YeelightControlException>().having(
          (e) => e.message,
          'message',
          contains('quota exceeded'),
        ),
      ),
    );
  });

  test('a port nobody is on names the LAN Control step', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final closedPort = server.port;
    await server.close();

    await expectLater(
      client.send('127.0.0.1', closedPort, setPower),
      throwsA(
        isA<YeelightControlException>().having(
          (e) => e.message,
          'message',
          contains('LAN Control'),
        ),
      ),
    );
  });

  test('its failures are written for the person holding the phone', () {
    expect(
      friendlyErrorText(
        const YeelightControlException('words'),
        fallback: 'generic',
      ),
      'words',
    );
  });

  test('a connection closed without an answer is a failure', () async {
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(server.close);
    server.listen((socket) {
      socket.listen((_) => socket.destroy(), onError: (Object _) {});
    });

    await expectLater(
      client.send('127.0.0.1', server.port, setPower),
      throwsA(isA<YeelightControlException>()),
    );
  });

  test('a lamp that never ends its line is cut off at the cap', () async {
    final endless = List.filled(YeelightControlClient.maxReplyBytes + 1, 0x41);
    final lamp = await _lamp([endless]);
    addTearDown(lamp.server.close);

    await expectLater(
      client.send('127.0.0.1', lamp.server.port, setPower),
      throwsA(isA<YeelightControlException>()),
    );
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/kasa_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

void main() {
  // The fake codec carries the same XOR-autokey cipher and length framing as
  // the Rust codec, so a full encode → exchange → decode cycle runs with no
  // native library.
  final codec = FakeSpecCodec();

  group('KasaControlClient.send', () {
    test('frames the request, and decodes the reply the device sends back',
        () async {
      // What the device would put on the wire in answer.
      const replyJson =
          '{"system":{"set_relay_state":{"err_code":0}}}';
      final replyFrame = await codec.kasaEncodeFrame(json: replyJson);

      List<int>? sawRequest;
      String? sawHost;
      int? sawPort;
      final client = KasaControlClient(
        codec,
        exchange: (host, port, request, timeout) async {
          sawHost = host;
          sawPort = port;
          sawRequest = request;
          return Uint8List.fromList(replyFrame);
        },
      );

      const request = KasaRequestDto(
          json: '{"system":{"set_relay_state":{"state":1}}}');
      final reply = await client.send('10.0.0.5', 9999, request);

      expect(reply, replyJson, reason: 'the decoded reply is returned as-is');
      expect(sawHost, '10.0.0.5');
      expect(sawPort, 9999);
      // The request that went out is the encrypted, length-framed command —
      // decoding it recovers the JSON we asked to send.
      expect(await codec.kasaDecodeFrame(frame: sawRequest!), request.json);
    });

    test('turns a socket failure into a KasaControlException', () async {
      final client = KasaControlClient(
        codec,
        exchange: (host, port, request, timeout) async =>
            throw const SocketException('no route to host'),
      );
      await expectLater(
        client.send('10.0.0.5', 9999,
            const KasaRequestDto(json: '{"system":{"get_sysinfo":null}}')),
        throwsA(isA<KasaControlException>()),
      );
    });

    test('turns a timeout into a KasaControlException', () async {
      final client = KasaControlClient(
        codec,
        exchange: (host, port, request, timeout) async =>
            throw TimeoutException('slow', timeout),
      );
      await expectLater(
        client.send('10.0.0.5', 9999,
            const KasaRequestDto(json: '{"system":{"get_sysinfo":null}}')),
        throwsA(isA<KasaControlException>()),
      );
    });

    test('a truncated reply frame is a KasaControlException, not a crash',
        () async {
      final client = KasaControlClient(
        codec,
        // A frame whose length prefix promises more than arrives.
        exchange: (host, port, request, timeout) async =>
            Uint8List.fromList([0x00, 0x00, 0x00, 0x10, 0xAB]),
      );
      await expectLater(
        client.send('10.0.0.5', 9999,
            const KasaRequestDto(json: '{"system":{"get_sysinfo":null}}')),
        throwsA(isA<KasaControlException>()),
      );
    });
  });

  group('kasaSysinfoFields', () {
    test('lifts the get_sysinfo scalars into name→value pairs', () {
      const reply =
          '{"system":{"get_sysinfo":{"relay_state":1,"alias":"Desk Lamp",'
          '"rssi":-42,"model":"HS100(US)"}}}';
      final fields = kasaSysinfoFields(reply);
      expect(fields['relay_state'], '1');
      expect(fields['alias'], 'Desk Lamp');
      expect(fields['rssi'], '-42');
      expect(fields['model'], 'HS100(US)');
    });

    test('drops nested arrays and objects (a strip\'s children), keeping scalars',
        () {
      const reply =
          '{"system":{"get_sysinfo":{"relay_state":0,"children":[{"state":1}],'
          '"next":{"x":1}}}}';
      final fields = kasaSysinfoFields(reply);
      expect(fields['relay_state'], '0');
      expect(fields.containsKey('children'), isFalse);
      expect(fields.containsKey('next'), isFalse);
    });

    test('a reply that is not a sysinfo answer yields no fields', () {
      expect(kasaSysinfoFields('{"system":{"set_relay_state":{"err_code":0}}}'),
          isEmpty);
      expect(kasaSysinfoFields('not json at all'), isEmpty);
      expect(kasaSysinfoFields('[1,2,3]'), isEmpty);
    });
  });
}

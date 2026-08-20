// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

void main() {
  // The fake codec carries a faithful stand-in for the AES datagram crypto
  // (key-bound ciphertext, wrong key rejects), so a full
  // encrypt → exchange → decrypt cycle runs with no native library. The
  // renderer is configured to emit real cmd numbers — 9 for the time sync, 4
  // for everything else — so the stand-in purifier can dispatch on them.
  final codec = FakeSpecCodec(
    networkRabbitAirRequest: (name, values, requestId, deviceTs) =>
        RabbitAirRequestDto(
            json:
                '{"id":$requestId,"cmd":${name == 'time_sync' ? 9 : 4},"ts":$deviceTs}',
            requestId: requestId),
  );
  const key = '0123456789abcdeffedcba9876543210';
  const otherKey = 'fedcba98765432100123456789abcdef';

  RabbitAirControlClient client({
    RabbitAirExchange? exchange,
  }) =>
      RabbitAirControlClient(codec,
          exchange: exchange ?? (h, p, d, t) async => [], random: Random(7));

  Future<RabbitAirRequestDto> request(RabbitAirControlClient c,
          {String command = 'get_state'}) =>
      codec.renderNetworkRabbitAirStateRequest(
          specYaml: 'yaml',
          stateCommand: command,
          requestId: c.nextRequestId(),
          deviceTs: 100);

  /// A stand-in purifier: decrypts what arrived, answers cmd 9 with a clock
  /// 120 s ahead of the local one and cmd 4 with a canned state, everything
  /// encrypted back under [deviceKey].
  RabbitAirExchange purifier(String deviceKey,
      {void Function(String plaintext)? saw}) {
    return (host, port, datagram, timeout) async {
      final plaintext = await codec.rabbitAirDecryptDatagram(
          userKey: deviceKey, datagram: datagram);
      saw?.call(plaintext);
      final decoded = jsonDecode(plaintext) as Map;
      final id = decoded['id'];
      final reply = decoded['cmd'] == 9
          ? '{"id":$id,"data":{"ts":${DateTime.now().millisecondsSinceEpoch ~/ 1000 + 120}}}'
          : '{"id":$id,"data":{"power":true,"speed":3}}';
      return [
        Uint8List.fromList(await codec.rabbitAirEncryptDatagram(
            userKey: deviceKey, plaintext: reply))
      ];
    };
  }

  group('RabbitAirControlClient.send', () {
    test('encrypts the envelope, and returns the reply that echoes its id',
        () async {
      String? sawPlaintext;
      final c = client(exchange: purifier(key, saw: (p) => sawPlaintext = p));
      final req = await request(c);

      final reply = await c.send('10.0.0.9', 9009, req, userKey: key);

      // What went on the wire is the encrypted rendered envelope — decrypting
      // it recovers exactly the JSON the codec rendered.
      expect(sawPlaintext, req.json);
      final decoded = jsonDecode(reply) as Map;
      expect(decoded['id'], req.requestId);
      expect((decoded['data'] as Map)['power'], isTrue);
    });

    test('ignores datagrams that do not decrypt or echo another id', () async {
      final c = client(exchange: (host, port, datagram, timeout) async {
        final plaintext = await codec.rabbitAirDecryptDatagram(
            userKey: key, datagram: datagram);
        final id = (jsonDecode(plaintext) as Map)['id'];
        return [
          // Another conversation's traffic under ANOTHER key — undecryptable.
          Uint8List.fromList(await codec.rabbitAirEncryptDatagram(
              userKey: otherKey, plaintext: '{"id":$id,"data":{}}')),
          // Ours, but echoing a nonce we did not send.
          Uint8List.fromList(await codec.rabbitAirEncryptDatagram(
              userKey: key, plaintext: '{"id":${id + 1},"data":{}}')),
          // The real answer.
          Uint8List.fromList(await codec.rabbitAirEncryptDatagram(
              userKey: key, plaintext: '{"id":$id,"data":{"power":false}}')),
        ];
      });

      final reply =
          await c.send('10.0.0.9', 9009, await request(c), userKey: key);
      expect((jsonDecode(reply) as Map)['data'], {'power': false});
    });

    test('retries per the vendor discipline, then throws', () async {
      var sends = 0;
      final c = client(exchange: (host, port, datagram, timeout) async {
        sends++;
        return [];
      });
      await expectLater(
        c.send('10.0.0.9', 9009, await request(c), userKey: key),
        throwsA(isA<RabbitAirControlException>()),
      );
      expect(sends, RabbitAirControlClient.attempts);
    });

    test('a malformed stored key fails at the codec, before the wire',
        () async {
      final c = client();
      await expectLater(
        c.send('10.0.0.9', 9009, await request(c), userKey: 'not-hex'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('RabbitAirControlClient.syncClock', () {
    test('learns the offset once and stamps later requests with it', () async {
      var sends = 0;
      final c = client(exchange: (host, port, datagram, timeout) async {
        sends++;
        return purifier(key)(host, port, datagram, timeout);
      });

      await c.syncClock('10.0.0.9', 9009, specYaml: 'yaml', userKey: key);
      expect(sends, 1);

      // The device ts is now the local clock + ~120 s (within a second of
      // slack for the test's own runtime).
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      expect(c.deviceTs('10.0.0.9') - now, closeTo(120, 2));

      // A second sync in the same session asks nothing — once per session.
      await c.syncClock('10.0.0.9', 9009, specYaml: 'yaml', userKey: key);
      expect(sends, 1);
    });

    test('a failed exchange forgets the offset, so the next one re-syncs',
        () async {
      var answer = true;
      var timeSyncs = 0;
      final c = client(exchange: (host, port, datagram, timeout) async {
        if (!answer) return [];
        final plaintext = await codec.rabbitAirDecryptDatagram(
            userKey: key, datagram: datagram);
        if ((jsonDecode(plaintext) as Map)['cmd'] == 9) timeSyncs++;
        return purifier(key)(host, port, datagram, timeout);
      });

      await c.syncClock('10.0.0.9', 9009, specYaml: 'yaml', userKey: key);
      expect(timeSyncs, 1);

      // The device goes silent; the poll fails, and the vendor rule — an
      // error re-creates the socket, a new socket re-syncs — applies.
      answer = false;
      await expectLater(
        c.send('10.0.0.9', 9009, await request(c), userKey: key),
        throwsA(isA<RabbitAirControlException>()),
      );

      answer = true;
      await c.syncClock('10.0.0.9', 9009, specYaml: 'yaml', userKey: key);
      expect(timeSyncs, 2);
    });
  });

  group('rabbitAirStateFields', () {
    test('lifts the reply data object into name→value pairs', () {
      const reply = '{"id":42,"data":{"power":true,"mode":2,"speed":3,'
          '"filter_life":4320,"rssi":-55}}';
      final fields = rabbitAirStateFields(reply);
      expect(fields['power'], 'true');
      expect(fields['mode'], '2');
      expect(fields['speed'], '3');
      expect(fields['filter_life'], '4320');
      expect(fields['rssi'], '-55');
      // The envelope id is matched to the request, never read as state.
      expect(fields.containsKey('id'), isFalse);
    });

    test('an error reply, or one without data, yields no fields', () {
      expect(rabbitAirStateFields('{"id":42,"error":1}'), isEmpty);
      expect(rabbitAirStateFields('{"id":42}'), isEmpty);
      expect(rabbitAirStateFields('not json at all'), isEmpty);
      // error: false is not an error.
      expect(
          rabbitAirStateFields('{"id":1,"error":false,"data":{"power":true}}'),
          {'power': 'true'});
    });
  });

  group('rabbitAirReplyId', () {
    test('reads the echoed id, and nothing else qualifies', () {
      expect(rabbitAirReplyId('{"id":42,"data":{}}'), 42);
      expect(rabbitAirReplyId('{"data":{}}'), isNull);
      expect(rabbitAirReplyId('{"id":"42"}'), isNull);
      expect(rabbitAirReplyId('not json'), isNull);
    });
  });
}

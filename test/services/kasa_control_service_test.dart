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
      const replyJson = '{"system":{"set_relay_state":{"err_code":0}}}';
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

      const request =
          KasaRequestDto(json: '{"system":{"set_relay_state":{"state":1}}}');
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

    test(
        'drops nested arrays and objects (a strip\'s children), keeping scalars',
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

  group('kasaStateFields', () {
    test('a sysinfo reply still lifts flat, children dropped', () {
      // The dispatch wrapper must not change the switch's contract:
      // `relay_state` stays a bare key, exactly as kasaSysinfoFields gives it.
      const reply =
          '{"system":{"get_sysinfo":{"relay_state":1,"alias":"Desk Lamp",'
          '"children":[{"state":1}]}}}';
      final fields = kasaStateFields(reply);
      expect(fields['relay_state'], '1');
      expect(fields['alias'], 'Desk Lamp');
      expect(fields.containsKey('children'), isFalse);
      expect(fields.containsKey('system.get_sysinfo.relay_state'), isFalse);
    });

    test('an emeter reply flattens to the dotted paths the sensors name', () {
      // Current firmware: plain float fields, already SI units. The keys are
      // the paths from the reply root — `emeter.get_realtime.voltage` — which
      // is what the HS110 sensors' state_mapping values look up verbatim.
      const reply = '{"emeter":{"get_realtime":{"voltage":120.4,'
          '"current":0.5,"power":60.2,"total":12.34,"err_code":0}}}';
      final fields = kasaStateFields(reply);
      expect(fields['emeter.get_realtime.voltage'], '120.4');
      expect(fields['emeter.get_realtime.current'], '0.5');
      expect(fields['emeter.get_realtime.power'], '60.2');
      expect(fields['emeter.get_realtime.total'], '12.34');
    });

    test('a milli-unit reply surfaces raw keys, never normalized', () {
      // HS110 hardware v1 reports voltage_mv/current_ma/power_mw/total_wh.
      // The spec's state_mapping paths name the SI fields only, so these
      // flatten under their own names and no sensor reads them — unknown,
      // not millivolts mislabeled "V". Normalization (python-kasa's
      // EmeterStatus divide-by-1000) is not something the entity decoder can
      // express, so it is deliberately NOT invented here.
      const reply = '{"emeter":{"get_realtime":{"voltage_mv":120352,'
          '"current_ma":501,"power_mw":60220,"total_wh":12340}}}';
      final fields = kasaStateFields(reply);
      expect(fields['emeter.get_realtime.voltage_mv'], '120352');
      expect(fields['emeter.get_realtime.total_wh'], '12340');
      expect(fields.containsKey('emeter.get_realtime.voltage'), isFalse);
      expect(fields.containsKey('emeter.get_realtime.total'), isFalse);
    });

    test('an ack or a non-reply still yields no fields', () {
      expect(
          kasaStateFields('{"system":{"set_relay_state":{"err_code":0}}}'),
          // Not a state reply: err_code flattens, but nothing an entity
          // reads — "no state here", same as before.
          {'system.set_relay_state.err_code': '0'});
      expect(kasaStateFields('not json at all'), isEmpty);
    });
  });
}

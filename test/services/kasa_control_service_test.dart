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
    test(
      'frames the request, and decodes the reply the device sends back',
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

        const request = KasaRequestDto(
          json: '{"system":{"set_relay_state":{"state":1}}}',
        );
        final reply = await client.send('10.0.0.5', 9999, request);

        expect(reply, replyJson, reason: 'the decoded reply is returned as-is');
        expect(sawHost, '10.0.0.5');
        expect(sawPort, 9999);
        // The request that went out is the encrypted, length-framed command —
        // decoding it recovers the JSON we asked to send.
        expect(await codec.kasaDecodeFrame(frame: sawRequest!), request.json);
      },
    );

    test('turns a socket failure into a KasaControlException', () async {
      final client = KasaControlClient(
        codec,
        exchange: (host, port, request, timeout) async =>
            throw const SocketException('no route to host'),
      );
      await expectLater(
        client.send(
          '10.0.0.5',
          9999,
          const KasaRequestDto(json: '{"system":{"get_sysinfo":null}}'),
        ),
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
        client.send(
          '10.0.0.5',
          9999,
          const KasaRequestDto(json: '{"system":{"get_sysinfo":null}}'),
        ),
        throwsA(isA<KasaControlException>()),
      );
    });

    test(
      'a truncated reply frame is a KasaControlException, not a crash',
      () async {
        final client = KasaControlClient(
          codec,
          // A frame whose length prefix promises more than arrives.
          exchange: (host, port, request, timeout) async =>
              Uint8List.fromList([0x00, 0x00, 0x00, 0x10, 0xAB]),
        );
        await expectLater(
          client.send(
            '10.0.0.5',
            9999,
            const KasaRequestDto(json: '{"system":{"get_sysinfo":null}}'),
          ),
          throwsA(isA<KasaControlException>()),
        );
      },
    );
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
      'flattens nested objects to dotted keys and lands arrays under their key',
      () {
        // A bulb's light_state must reach the entity mappings as the dotted
        // paths they name (light_state.on_off), and a strip's children array
        // must be visible AT ALL — the spec's state_probe tells a power strip
        // from a plug by that key's presence. Bare top-level scalars keep the
        // switch's contract unchanged.
        const reply =
            '{"system":{"get_sysinfo":{"relay_state":0,"children":[{"state":1}],'
            '"light_state":{"on_off":1,"dft_on_state":{"brightness":40}}}}}';
        final fields = kasaSysinfoFields(reply);
        expect(fields['relay_state'], '0');
        expect(fields['children'], '[{"state":1}]');
        expect(fields['light_state.on_off'], '1');
        expect(fields['light_state.dft_on_state.brightness'], '40');
        expect(
          fields.containsKey('light_state'),
          isFalse,
          reason: 'an object flattens to its members, not to a blob',
        );
      },
    );

    test('a reply that is not a sysinfo answer yields no fields', () {
      expect(
        kasaSysinfoFields('{"system":{"set_relay_state":{"err_code":0}}}'),
        isEmpty,
      );
      expect(kasaSysinfoFields('not json at all'), isEmpty);
      expect(kasaSysinfoFields('[1,2,3]'), isEmpty);
    });
  });

  group('kasaStateFields', () {
    test(
      'a sysinfo reply still lifts from the sysinfo object, never the root',
      () {
        // The dispatch wrapper must not change the switch's contract:
        // `relay_state` stays a bare key, exactly as kasaSysinfoFields gives it
        // (with the children array landing under its own key for the probe).
        const reply =
            '{"system":{"get_sysinfo":{"relay_state":1,"alias":"Desk Lamp",'
            '"children":[{"state":1}]}}}';
        final fields = kasaStateFields(reply);
        expect(fields['relay_state'], '1');
        expect(fields['alias'], 'Desk Lamp');
        expect(fields['children'], '[{"state":1}]');
        expect(fields.containsKey('system.get_sysinfo.relay_state'), isFalse);
      },
    );

    test('an emeter reply flattens to the dotted paths the sensors name', () {
      // Current firmware: plain float fields, already SI units. The keys are
      // the paths from the reply root — `emeter.get_realtime.voltage` — which
      // is what the HS110 sensors' state_mapping values look up verbatim.
      const reply =
          '{"emeter":{"get_realtime":{"voltage":120.4,'
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
      const reply =
          '{"emeter":{"get_realtime":{"voltage_mv":120352,'
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
        {'system.set_relay_state.err_code': '0'},
      );
      expect(kasaStateFields('not json at all'), isEmpty);
    });
  });

  group('readKasaReply', () {
    test('reads exactly the frame the prefix announced', () async {
      final frame = <int>[0, 0, 0, 3, 1, 2, 3];
      // Split across chunks, the way a socket delivers them, plus trailing
      // bytes that belong to nothing: the read stops at the announced length.
      final reply = await readKasaReply(
        Stream<List<int>>.fromIterable([
          frame.sublist(0, 2),
          frame.sublist(2),
          const [9, 9, 9],
        ]),
        '10.0.0.9',
        9999,
      );
      expect(reply, [0, 0, 0, 3, 1, 2, 3]);
    });

    test('a device-announced length past the cap is refused', () async {
      // R-189. `FF FF FF FF` is a four-gigabyte read, named by the device: the
      // prefix is the DEVICE's claim, so an unchecked `needed` is an
      // allocation something on the LAN sizes. Checked before it becomes a
      // read target, not after the buffer has grown into it.
      await expectLater(
        readKasaReply(
          Stream<List<int>>.fromIterable([
            const [0xFF, 0xFF, 0xFF, 0xFF],
          ]),
          '10.0.0.9',
          9999,
        ),
        throwsA(
          isA<KasaControlException>().having(
            (e) => e.message,
            'message',
            contains('announced a 4294967295-byte reply'),
          ),
        ),
      );
    });

    test(
      'bytes past the cap are refused even if the prefix lied low',
      () async {
        // A short frame announced, then a flood: the second guard is what stops
        // a host that overruns the length it gave.
        final chunks = <List<int>>[
          const [0, 0, 0, 4],
          List<int>.filled(KasaControlClient.maxReplyBytes + 8, 0x41),
        ];
        await expectLater(
          readKasaReply(
            Stream<List<int>>.fromIterable(chunks),
            '10.0.0.9',
            9999,
          ),
          throwsA(
            isA<KasaControlException>().having(
              (e) => e.message,
              'message',
              contains('refusing to buffer further'),
            ),
          ),
        );
      },
    );
  });
}

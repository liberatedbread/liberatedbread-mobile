// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Philips purifier client against a fake CoAP server on loopback and the
// real Rust codec: a sync, a status read, a write under the next counter, and
// a purifier that answers garbage, the wrong token, a refusal, or nothing.
// The fake parses CoAP itself, so the two sides have to agree.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha256;
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/philips_air_control_service.dart';

import '../helpers/host_rust_lib.dart';

/// The spec's vectors (philips-air-coap.yaml, protocol_details.envelope).
const _powerOnEnvelope =
    '6D2C0F4242DC07095A0FD80857F2C25E4749F7D3B84FA8794A4D02BAF6FCE775D051287A'
    '17D6854ECBE9E7EBC48F4486FAC90226CA971AA4D8EE11EFB80125C336939E589AABE1F7'
    '49F00DE11C320D728E6BDE643057E1015B0507AF0BCD5D3EB000E606AE74578655D9911C'
    '45BDB504C14E03768205949AF0E74AE2BDD214D41563C9BF';
const _statusEnvelope =
    '0000A0B1B149D927CD9AA69B551A3172AED0B55A76A2EAE0478B53751801717DBF570C73'
    '046D9EDEDCEEF67C24F240CDBCFFDC8C1BC8376ED41E7128E2583245259842946EF8756C'
    '377926A2F81D1F488D34B04C0DDE42B2AD6840E4185D0A432284730972B0A10234F8331B'
    '84CD56F79BA50113EC9DD9A679691548552CFB940F008D2625E54CE7D70DD2AC7B0DBC4C'
    'ECEDB2C1241643F6F78E220CF4327DB4C39CBB38E84A90316DAADC8E3DE77FF669BC4591'
    'DC7CC52A76920816BD63317D740905DB8D41FC94C2889CE04CC670DA2C2B17E53447BBE3'
    '98732784AB5D53BE43666CB3EA2EBE2B9946212379419109364CD08004C00053E6A2CBC0'
    'F2B423029D18C1288D20D1E06D6987BE4F6B5E5DDEF0541C02438EBE4B49F5E08B48FEFB'
    '2876EFAF12976D38AED35AA099675F2B541FB74F806B69614A14D49DD1F4F4C4C9302011'
    '0F06FC4EC909015BC80082A7FEB02EDC33D0EE18BCF241EB724E34BAE2D3CE03F091A830'
    'BEE90663C04E7B08D189F3F1F2D3BE507C3D5CF69D4A75C675F19B241C3213D652E56433'
    '544900FE2FE14B355FC39CAC931017DB0D7617AE234ABEE5FFA63E94EF36D1E0A432B088'
    'E53CCE7DEEDEB57AF289EA849FC14A624678563F';

String get _specYaml => File(
  'vendor/protocol-specs/device-specs/devices/philips-air-coap.yaml',
).readAsStringSync();

/// One request as the fake reads it.
class _Request {
  final int type;
  final int code;
  final int messageId;
  final List<int> token;
  final String path;
  final int? observe;
  final String payload;
  _Request(
    this.type,
    this.code,
    this.messageId,
    this.token,
    this.path,
    this.observe,
    this.payload,
  );
}

_Request _parse(List<int> d) {
  final tkl = d[0] & 0x0F;
  final token = d.sublist(4, 4 + tkl);
  var at = 4 + tkl;
  var number = 0;
  final path = <String>[];
  int? observe;
  var payload = '';
  int ext(int nibble) {
    if (nibble == 13) return d[at++] + 13;
    if (nibble == 14) {
      final v = (d[at] << 8 | d[at + 1]) + 269;
      at += 2;
      return v;
    }
    return nibble;
  }

  while (at < d.length) {
    final head = d[at++];
    if (head == 0xFF) {
      payload = ascii.decode(d.sublist(at));
      break;
    }
    number += ext(head >> 4);
    final length = ext(head & 0x0F);
    final value = d.sublist(at, at + length);
    at += length;
    if (number == 11) path.add(ascii.decode(value));
    if (number == 6) observe = value.fold<int>(0, (a, b) => a << 8 | b);
  }
  return _Request(
    (d[0] >> 4) & 3,
    d[1],
    d[2] << 8 | d[3],
    token,
    '/${path.join('/')}',
    observe,
    payload,
  );
}

/// A reply: [type] 1 NON, 0 CON, 2 ACK; code 2.05 unless told.
List<int> _reply(
  _Request to,
  String payload, {
  int type = 1,
  int code = 0x45,
  List<int>? token,
  int messageId = 0x4242,
}) {
  final t = token ?? to.token;
  return [
    0x40 | type << 4 | t.length,
    code,
    messageId >> 8,
    messageId & 0xFF,
    ...t,
    if (payload.isNotEmpty) ...[0xFF, ...ascii.encode(payload)],
  ];
}

typedef _Answer = List<List<int>> Function(_Request request);

class _FakePurifier {
  final RawDatagramSocket socket;
  final _Answer answer;
  final requests = <_Request>[];
  final raw = <List<int>>[];

  _FakePurifier._(this.socket, this.answer) {
    socket.listen((event) {
      if (event != RawSocketEvent.read) return;
      final d = socket.receive();
      if (d == null) return;
      raw.add(d.data);
      if (d.data.length == 4) return; // an ACK or a Reset owed to us
      final request = _parse(d.data);
      requests.add(request);
      for (final reply in answer(request)) {
        socket.send(reply, d.address, d.port);
      }
    });
  }

  static Future<_FakePurifier> start(_Answer answer) async => _FakePurifier._(
    await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0),
    answer,
  );

  int get port => socket.port;
  void close() => socket.close();
}

/// A healthy purifier: sync answers 6D2C0F41, status the spec's capture,
/// control success.
List<List<int>> _healthy(_Request r) => switch (r.path) {
  '/sys/dev/sync' => [_reply(r, '6D2C0F41')],
  '/sys/dev/status' when r.observe == 0 => [_reply(r, _statusEnvelope)],
  '/sys/dev/status' => [],
  '/sys/dev/control' => [_reply(r, '{"status":"success"}')],
  _ => [],
};

PhilipsAirControlClient _client() =>
    PhilipsAirControlClient(timeout: const Duration(milliseconds: 400));

void main() {
  setUpAll(() async {
    if (!await initHostRustLib()) {
      markTestSkipped('host Rust library not available');
    }
  });

  late _FakePurifier purifier;
  tearDown(() => purifier.close());

  test('a status read syncs, reads, decrypts and lets go', () async {
    purifier = await _FakePurifier.start(_healthy);
    final fields = await _client().readStatus('127.0.0.1', purifier.port);

    expect(fields['state.reported.modelid'], 'AC2729/10');
    expect(fields['state.reported.pwr'], '1');
    expect(fields['state.reported.pm25'], '7');
    expect(fields['state.reported.cl'], 'false');
    final paths = purifier.requests.map((r) => r.path).toList();
    expect(paths.first, '/sys/dev/sync');
    final sync = purifier.requests.first;
    expect(sync.type, 1, reason: 'NON, as every client sends');
    expect(sync.code, 0x02);
    expect(sync.payload, matches(RegExp(r'^[0-9A-F]{8}$')));
    final read = purifier.requests[1];
    expect((read.code, read.observe), (0x01, 0));
    // Deregistration on the same token (RFC 7641), fire and forget.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(purifier.requests.last.observe, 1);
    expect(purifier.requests.last.token, read.token);
  });

  test('a write goes under the synced counter plus one, byte for byte the '
      "spec's vector", () async {
    purifier = await _FakePurifier.start(_healthy);
    await _client().sendCommand(
      '127.0.0.1',
      purifier.port,
      specYaml: _specYaml,
      commandName: 'power_on',
      values: const {},
    );
    final write = purifier.requests.last;
    expect(write.path, '/sys/dev/control');
    expect(write.payload, _powerOnEnvelope);
    // The trailer, checked independently of the Rust digest.
    final body = write.payload.substring(0, write.payload.length - 64);
    expect(
      write.payload.substring(write.payload.length - 64),
      sha256.convert(ascii.encode(body)).toString().toUpperCase(),
    );
  });

  test('a confirmable reply is acknowledged and a stranger is reset', () async {
    purifier = await _FakePurifier.start(
      (r) => switch (r.path) {
        '/sys/dev/sync' => [
          _reply(r, '00000001', type: 0, token: [9, 9], messageId: 0x0101),
          _reply(r, '6D2C0F41', type: 0, messageId: 0x0202),
        ],
        _ => _healthy(r),
      },
    );
    await _client().readStatus('127.0.0.1', purifier.port);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    final owed = purifier.raw.where((d) => d.length == 4).toList();
    expect(
      owed,
      containsAll([
        [0x70, 0x00, 0x01, 0x01],
        [0x60, 0x00, 0x02, 0x02],
      ]),
    );
  });

  test('a value outside the spec\'s list is refused before anything is '
      'sent', () async {
    purifier = await _FakePurifier.start(_healthy);
    await expectLater(
      _client().sendCommand(
        '127.0.0.1',
        purifier.port,
        specYaml: _specYaml,
        commandName: 'set_mode',
        values: const {'mode': 'P", "pwr": "0'},
      ),
      throwsA(isA<PhilipsAirException>()),
    );
    expect(purifier.requests, isEmpty);
  });

  test('a refused write is reported and not retried', () async {
    purifier = await _FakePurifier.start(
      (r) => r.path == '/sys/dev/control'
          ? [_reply(r, '{"status":"failed"}')]
          : _healthy(r),
    );
    await expectLater(
      _client().sendCommand(
        '127.0.0.1',
        purifier.port,
        specYaml: _specYaml,
        commandName: 'power_off',
        values: const {},
      ),
      throwsA(
        isA<PhilipsAirException>().having(
          (e) => e.message,
          'message',
          contains('did not accept'),
        ),
      ),
    );
    expect(
      purifier.requests.where((r) => r.path == '/sys/dev/control'),
      hasLength(1),
    );
  });

  test('a silent purifier times out with the firmware caveat', () async {
    purifier = await _FakePurifier.start((_) => []);
    await expectLater(
      _client().readStatus('127.0.0.1', purifier.port),
      throwsA(
        isA<PhilipsAirException>().having(
          (e) => e.message,
          'message',
          allOf(contains('did not answer'), contains('firmware')),
        ),
      ),
    );
  });

  test('garbage and other tokens are passed over, not read', () async {
    purifier = await _FakePurifier.start(
      (r) => [
        utf8.encode('not coap at all'),
        [0xFF, 0x00],
        _reply(r, '6D2C0F41', token: [1, 2, 3, 4, 5]),
      ],
    );
    await expectLater(
      _client().readStatus('127.0.0.1', purifier.port),
      throwsA(
        isA<PhilipsAirException>().having(
          (e) => e.message,
          'message',
          contains('did not answer'),
        ),
      ),
    );
  });

  test(
    'a sync answered with something other than a counter is refused',
    () async {
      purifier = await _FakePurifier.start(
        (r) => [_reply(r, '<html>hello</html>')],
      );
      await expectLater(
        _client().readStatus('127.0.0.1', purifier.port),
        throwsA(
          isA<PhilipsAirException>().having(
            (e) => e.message,
            'message',
            contains('not a counter'),
          ),
        ),
      );
    },
  );

  test('a status that is not a valid envelope is refused', () async {
    final tampered =
        '${_statusEnvelope.substring(0, 20)}0'
        '${_statusEnvelope.substring(21)}';
    purifier = await _FakePurifier.start(
      (r) => r.path == '/sys/dev/status' && r.observe == 0
          ? [_reply(r, tampered)]
          : _healthy(r),
    );
    await expectLater(
      _client().readStatus('127.0.0.1', purifier.port),
      throwsA(
        isA<PhilipsAirException>().having(
          (e) => e.message,
          'message',
          contains('cannot read'),
        ),
      ),
    );
  });

  test('an error code is a refusal, not a reading', () async {
    purifier = await _FakePurifier.start(
      (r) => r.path == '/sys/dev/status'
          ? [_reply(r, '', code: 0x84)]
          : _healthy(r),
    );
    await expectLater(
      _client().readStatus('127.0.0.1', purifier.port),
      throwsA(
        isA<PhilipsAirException>().having(
          (e) => e.message,
          'message',
          contains('4.04'),
        ),
      ),
    );
  });
}

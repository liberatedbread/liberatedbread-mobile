// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The AirPort status reader against a fake base station on loopback. The
// fake builds and checks ACP headers, CFB0 plists, the server side of SRP-6a
// and the PBKDF2 session keys itself, so the client and it have to agree;
// only the AES-CTR keystream is the Rust codec's on both sides (it is checked
// against NIST SP 800-38A in the Rust tests). Also: a wrong password,
// garbage, silence, and the pin that nothing written is a write.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/acp_status_client.dart';
import 'package:liberated_bread_mobile/src/rust/api/readonly_api.dart'
    show acpCtrApply;

import '../helpers/host_rust_lib.dart';

const _password = 'example-owner-pw';

final _n = BigInt.parse(
  '9DEF3CAFB939277AB1F12A8617A47BBBDBA51DF499AC4C80BEEEA961'
  '4B19CC4D5F4F5F556E27CBDE51C6A94BE4607A291558903BA0D0F843'
  '80B655BB9A22E8DCDF028A7CEC67F0D08134B1C8B97989149B609E0B'
  'E3BAB63D47548381DBC5B1FC764E3F4B53DD9DA1158BFD3E2B9C8CF5'
  '6EDF019539349627DB2FD53D24B7C48665772E437D6C7F8CE442734A'
  'F7CCB7AE837C264AE3A9BEB87F8A2FE9B8B5292E5A021FFF5E91479E'
  '8CE7A28C2442C6F315180F93499A234DCF76E3FED135F9BB',
  radix: 16,
);
final _g = BigInt.two;

Uint8List _sha1(List<List<int>> parts) =>
    Uint8List.fromList(sha1.convert(parts.expand((p) => p).toList()).bytes);

Uint8List _pad(BigInt v, [int len = 192]) {
  final hex = v.toRadixString(16).padLeft(len * 2, '0');
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

BigInt _int(List<int> bytes) =>
    bytes.fold(BigInt.zero, (acc, b) => (acc << 8) | BigInt.from(b));

int _adler(List<int> data) {
  var a = 1, b = 0;
  for (final byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return (b << 16) | a;
}

void _put32(Uint8List h, int at, int v) =>
    h.buffer.asByteData().setUint32(at, v & 0xFFFFFFFF);

int _get32(List<int> h, int at) =>
    Uint8List.fromList(h).buffer.asByteData().getInt32(at);

/// A reply header as a base station writes it (flags 5, as node-acp's
/// emulator does).
List<int> _reply(int command, List<int>? body, {int error = 0}) {
  final h = Uint8List(128);
  h.setAll(0, ascii.encode('acpp'));
  _put32(h, 4, 0x00030001);
  _put32(h, 12, body == null ? 1 : _adler(body));
  _put32(h, 16, body == null ? -1 : body.length);
  _put32(h, 20, 5);
  _put32(h, 28, command);
  _put32(h, 32, error);
  _put32(h, 8, _adler(h));
  return [...h, ...?body];
}

/// CFB0 {key: data, ...}, the only shape the fake sends.
List<int> _plist(Map<String, List<int>> dict) => [
  ...ascii.encode('CFB0'),
  0xD0,
  for (final e in dict.entries) ...[
    0x70,
    ...utf8.encode(e.key),
    0,
    if (e.value.length < 15)
      0x40 | e.value.length
    else ...[
      0x4F,
      0x11,
      e.value.length >> 8,
      e.value.length & 0xFF,
    ],
    ...e.value,
  ],
  0,
  ...ascii.encode('END!'),
];

/// Read a client plist of string keys to data or 1-byte ints.
Map<String, Object> _readPlist(List<int> bytes) {
  expect(ascii.decode(bytes.sublist(0, 4)), 'CFB0');
  var at = 5;
  final out = <String, Object>{};
  int readInt() {
    final width = 1 << (bytes[at++] & 0x0F);
    final v = _int(bytes.sublist(at, at + width)).toInt();
    at += width;
    return v;
  }

  while (bytes[at] != 0) {
    expect(bytes[at++], 0x70);
    final end = bytes.indexOf(0, at);
    final key = utf8.decode(bytes.sublist(at, end));
    at = end + 1;
    final marker = bytes[at];
    if (marker >> 4 == 1) {
      out[key] = readInt();
    } else if (marker >> 4 == 4) {
      at++;
      final length = marker == 0x4F ? readInt() : marker & 0x0F;
      out[key] = bytes.sublist(at, at + length);
      at += length;
    } else if (marker == 0x70) {
      at++;
      final e = bytes.indexOf(0, at);
      out[key] = utf8.decode(bytes.sublist(at, e));
      at = e + 1;
    } else {
      fail('unexpected marker $marker');
    }
  }
  return out;
}

Uint8List _hmac(List<int> key, List<int> data) =>
    Uint8List.fromList(Hmac(sha1, key).convert(data).bytes);

Uint8List _pbkdf2(List<int> k, List<int> salt, int iterations) {
  var u = _hmac(k, [...salt, 0, 0, 0, 1]);
  final t = Uint8List.fromList(u);
  for (var i = 1; i < iterations; i++) {
    u = _hmac(k, u);
    for (var j = 0; j < t.length; j++) {
      t[j] ^= u[j];
    }
  }
  return Uint8List.fromList(t.sublist(0, 16));
}

List<int> _hex(String s) => [
  for (var i = 0; i < s.length; i += 2)
    int.parse(s.substring(i, i + 2), radix: 16),
];

List<int> _element(String name, List<int> value, {int flags = 0}) => [
  ...ascii.encode(name),
  0, 0, 0, flags, //
  0, 0, 0, value.length,
  ...value,
];

enum _Mode { healthy, wrongPassword, garbage, silent, forgedProof }

/// A base station on loopback: SRP as the server, then the status read.
class _FakeBase {
  final ServerSocket server;
  final _Mode mode;
  final String password;
  final commands = <int>[];
  final keyFields = <List<int>>[];

  _FakeBase._(this.server, this.mode, this.password) {
    server.listen(_serve);
  }

  static Future<_FakeBase> start(
    _Mode mode, {
    String password = _password,
  }) async => _FakeBase._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    mode,
    password,
  );

  int get port => server.port;
  Future<void> close() => server.close();

  Future<void> _serve(Socket socket) async {
    final buffer = <int>[];
    final incoming = StreamIterator(socket);
    Uint8List? clientKey, clientIv, serverKey, serverIv;
    var inOffset = 0, outOffset = 0;
    Future<List<int>> take(int n) async {
      while (buffer.length < n) {
        if (!await incoming.moveNext()) throw const SocketException('closed');
        var chunk = incoming.current.toList();
        if (clientKey != null) {
          chunk = acpCtrApply(
            key: clientKey,
            iv: clientIv!,
            offset: BigInt.from(inOffset),
            data: chunk,
          );
          inOffset += chunk.length;
        }
        buffer.addAll(chunk);
      }
      final out = buffer.sublist(0, n);
      buffer.removeRange(0, n);
      return out;
    }

    void send(List<int> bytes) {
      if (serverKey != null) {
        socket.add(
          acpCtrApply(
            key: serverKey,
            iv: serverIv!,
            offset: BigInt.from(outOffset),
            data: bytes,
          ),
        );
        outOffset += bytes.length;
      } else {
        socket.add(bytes);
      }
    }

    Future<(List<int>, List<int>)> request() async {
      final header = await take(128);
      expect(ascii.decode(header.sublist(0, 4)), 'acpp');
      final check = List<int>.of(header)..setRange(8, 12, [0, 0, 0, 0]);
      expect(_get32(header, 8) & 0xFFFFFFFF, _adler(check));
      commands.add(_get32(header, 28));
      keyFields.add(header.sublist(48, 80));
      final size = _get32(header, 16);
      final body = size > 0 ? await take(size) : <int>[];
      expect(_get32(header, 12) & 0xFFFFFFFF, _adler(body));
      return (header, body);
    }

    try {
      if (mode == _Mode.silent) {
        await take(1 << 20);
        return;
      }
      if (mode == _Mode.garbage) {
        await take(1);
        socket.add(List.generate(300, (i) => (i * 37) & 0xFF));
        await socket.flush();
        await take(1 << 20);
        return;
      }
      final (_, start) = await request();
      final hello = _readPlist(start);
      expect(hello, {'state': 1, 'username': 'admin'});

      final salt = List.generate(16, (i) => i + 1);
      final x = _int(
        _sha1([
          salt,
          _sha1([utf8.encode('admin:$password')]),
        ]),
      );
      final v = _g.modPow(x, _n);
      final k = _int(_sha1([_pad(_n), _pad(_g)]));
      final b = _int(List.filled(32, 0x5A));
      final bPub = (k * v + _g.modPow(b, _n)) % _n;
      send(
        _reply(
          0x1A,
          _plist({
            'salt': salt,
            'generator': [2],
            'publicKey': _pad(bPub),
            'modulus': _pad(_n),
          }),
        ),
      );
      await socket.flush();

      final (_, stage3) = await request();
      final m = _readPlist(stage3);
      expect(m['state'], 3);
      final aBytes = m['publicKey']! as List<int>;
      final aPub = _int(aBytes);
      final u = _int(_sha1([_pad(aPub), _pad(bPub)]));
      final s = (aPub * v.modPow(u, _n)).modPow(b, _n);
      final key = _sha1([_pad(s)]);
      final hn = _sha1([_pad(_n)]);
      final hg = _sha1([
        [2],
      ]);
      final m1 = _sha1([
        [for (var i = 0; i < 20; i++) hn[i] ^ hg[i]],
        _sha1([utf8.encode('admin')]),
        salt,
        _pad(aPub),
        _pad(bPub),
        key,
      ]);
      if (mode == _Mode.wrongPassword ||
          !const ListEquality().equals(m1, m['response']! as List<int>)) {
        send(_reply(0x1A, null, error: -6754));
        await socket.flush();
        return;
      }
      final m2 = mode == _Mode.forgedProof
          ? List.filled(20, 0)
          : _sha1([_pad(aPub), m1, key]);
      final sIv = List.generate(16, (i) => 0xA0 + i);
      send(_reply(0x1A, _plist({'response': m2, 'iv': sIv})));
      await socket.flush();

      clientKey = _pbkdf2(key, _hex('F072FA3F66B410A135FAE8E6D1D43D5F'), 5);
      clientIv = Uint8List.fromList(m['iv']! as List<int>);
      serverKey = _pbkdf2(key, _hex('BD0682C9FE79325BC73655F4174B996C'), 7);
      serverIv = Uint8List.fromList(sIv);

      final (header, body) = await request();
      expect(_get32(header, 28), 0x14);
      final names = [
        for (var i = 0; i < body.length; i += 16)
          ascii.decode(body.sublist(i, i + 4)),
      ];
      expect(names, ['syNm', 'syVs', 'syAP', 'syUT', 'raNm']);
      final status = [
        ..._element('syNm', utf8.encode('Example Base')),
        ..._element('syVs', utf8.encode('7.9.1')),
        ..._element('syAP', [0, 0, 0, 120]),
        ..._element('syUT', [0, 1, 0x51, 0x80]),
        ..._element('raNm', [0xFF, 0xFF, 0xFF, 0xF6], flags: 1),
        ..._element('\x00\x00\x00\x00', [0, 0, 0, 0]),
      ];
      // Split across writes: the client must read to the end marker.
      final reply = _reply(0x14, null);
      send(reply);
      await socket.flush();
      send(status.sublist(0, 20));
      await socket.flush();
      send(status.sublist(20));
      await socket.flush();
    } on Object {
      // The client hung up; the test reads what it got.
    } finally {
      await socket.close();
    }
  }
}

class ListEquality {
  const ListEquality();
  bool equals(List<int> a, List<int> b) =>
      a.length == b.length &&
      Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
}

AcpStatusClient _client(_FakeBase base) => AcpStatusClient(
  host: '127.0.0.1',
  port: base.port,
  timeout: const Duration(milliseconds: 1500),
);

Matcher _says(String text) => throwsA(
  isA<AcpException>()
      .having((e) => e.message, 'message', contains(text))
      .having(
        (e) => e.message,
        'the password stays out of it',
        isNot(contains(_password)),
      ),
);

void main() {
  setUpAll(() async {
    if (!await initHostRustLib()) {
      markTestSkipped('host Rust library not available');
    }
  });

  late _FakeBase base;
  tearDown(() => base.close());

  test('SRP, then one encrypted status read', () async {
    base = await _FakeBase.start(_Mode.healthy);
    final status = await _client(base).read(password: _password);

    expect(status.name, 'Example Base');
    expect(status.firmware, '7.9.1');
    expect(status.productId, 120);
    expect(status.productName, 'AirPort Extreme 802.11ac');
    expect(status.uptimeSeconds, 86400);
    expect(status.wifiName, isNull);
    expect(status.unavailable.single, startsWith('raNm'));
    // Two AUTHENTICATEs, one GET_PROPERTY, and nothing else: never a
    // SET_PROPERTY (0x15), which is also how a reboot or reset is sent.
    expect(base.commands, [0x1A, 0x1A, 0x14]);
    // AUTHENTICATE carries the empty password's key; the read after SRP an
    // all-zero one. The legacy password key is never on the wire.
    expect(
      base.keyFields.first,
      _hex('0e39f805c401554f0cac857d868ab5173e09c835f431657f3c9cb56d969aa507'),
    );
    expect(base.keyFields.last, List.filled(32, 0));
  });

  test('a wrong password is said as such', () async {
    base = await _FakeBase.start(_Mode.healthy, password: 'something else');
    await expectLater(
      _client(base).read(password: _password),
      _says('refused that password'),
    );
    expect(base.commands, [0x1A, 0x1A]);
  });

  test(
    'a base station that cannot prove it knows the password is refused',
    () async {
      base = await _FakeBase.start(_Mode.forgedProof);
      await expectLater(
        _client(base).read(password: _password),
        _says('proof does not match'),
      );
      expect(base.commands, [0x1A, 0x1A], reason: 'no read after a bad proof');
    },
  );

  test('garbage is refused', () async {
    base = await _FakeBase.start(_Mode.garbage);
    await expectLater(
      _client(base).read(password: _password),
      _says('not in a way this app accepts'),
    );
  });

  test('silence times out', () async {
    base = await _FakeBase.start(_Mode.silent);
    await expectLater(
      _client(base).read(password: _password),
      _says('did not answer in time'),
    );
  });

  test('nothing listening is unreachable', () async {
    base = await _FakeBase.start(_Mode.silent);
    final port = base.port;
    await base.close();
    await expectLater(
      AcpStatusClient(
        host: '127.0.0.1',
        port: port,
        timeout: const Duration(milliseconds: 500),
      ).read(password: _password),
      _says('Could not reach'),
    );
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The HT-W01 settings client against a fake camera on loopback and the real
// Rust codec. The fake checks every frame's envelope and CRC itself, so the
// two have to agree. Also: garbage, silence, an unreachable camera, a value
// refused before connecting, and the pin that no frame written is the
// reset, the restart, the Wi-Fi channel or the distance.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/ht_w01_client.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/ht_w01.dart';

import '../helpers/host_rust_lib.dart';

int _crc(List<int> data) {
  var crc = 0;
  for (final byte in data) {
    crc ^= byte << 8;
    for (var i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}

List<int> _frame(int type, List<int> data) {
  final total = 25 + data.length;
  final length = total - 3;
  final out = [
    0xFB,
    length & 0xFF,
    (length >> 8) & 0xFF,
    0,
    0,
    type,
    ...List.filled(17, 0),
    ...data,
  ];
  final crc = _crc(out.sublist(1));
  return [...out, crc & 0xFF, crc >> 8];
}

/// The spec's literal set_palette frame (white hot).
const _setPaletteWhiteHot =
    'fb 18 00 00 00 34 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00 '
    '01 01 43 a0';

List<int> _hex(String s) => [
  for (final b in s.split(' ')) int.parse(b, radix: 16),
];

enum _Mode { healthy, garbage, silent }

class _FakeCamera {
  final ServerSocket server;
  final _Mode mode;
  final frames = <List<int>>[];
  var connections = 0;

  _FakeCamera._(this.server, this.mode) {
    server.listen(_serve);
  }

  static Future<_FakeCamera> start(_Mode mode) async => _FakeCamera._(
    await ServerSocket.bind(InternetAddress.loopbackIPv4, 0),
    mode,
  );

  int get port => server.port;
  Future<void> close() => server.close();

  Future<void> _serve(Socket socket) async {
    connections++;
    final buffer = <int>[];
    try {
      await for (final chunk in socket) {
        buffer.addAll(chunk);
        while (buffer.length >= 5) {
          expect(buffer.first, 0xFB);
          final total =
              (buffer[1] | buffer[2] << 8 | buffer[3] << 16 | buffer[4] << 24) +
              3;
          if (buffer.length < total) break;
          final frame = buffer.sublist(0, total);
          buffer.removeRange(0, total);
          expect(
            frame[total - 2] | frame[total - 1] << 8,
            _crc(frame.sublist(1, total - 2)),
          );
          frames.add(frame);
          final type = frame[5];
          final data = frame.sublist(23, total - 2);
          switch (mode) {
            case _Mode.silent:
              break;
            case _Mode.garbage:
              socket.add([0x13, 0x37, 0xFB, 0x00, 0xFF, 0x42, 0x42]);
            case _Mode.healthy:
              if (type == 0x31) {
                socket.add(_frame(0x31, data));
              } else if (type == 0x33) {
                final value = switch (data.first) {
                  0x01 => 4,
                  0x03 => 1,
                  0x04 => 95,
                  _ => 0,
                };
                // A stray byte first: the client must resync.
                socket.add([
                  0x00,
                  ..._frame(0x33, [data.first, value]),
                ]);
              } else {
                socket.add(_frame(type, [0x00]));
              }
          }
        }
      }
    } on Object {
      // The client hung up.
    }
  }
}

HtW01CameraClient _client(_FakeCamera camera) => HtW01CameraClient(
  host: '127.0.0.1',
  port: camera.port,
  timeout: const Duration(milliseconds: 400),
);

/// No frame may be the reset (ACTION 0x00), the restart (ACTION 0x02), the
/// Wi-Fi channel (SET 0x11) or the distance (0x08).
void _expectNothingForbidden(List<List<int>> frames) {
  for (final f in frames) {
    final type = f[5];
    final first = f[23];
    expect(type == 0x35 && (first == 0x00 || first == 0x02), isFalse);
    expect(type == 0x34 && (first == 0x11 || first == 0x08), isFalse);
    expect(type == 0x33 && first == 0x08, isFalse);
  }
}

void main() {
  setUpAll(() async {
    if (!await initHostRustLib()) {
      markTestSkipped('host Rust library not available');
    }
  });

  late _FakeCamera camera;
  tearDown(() async {
    _expectNothingForbidden(camera.frames);
    await camera.close();
  });

  test('reads palette, range and emissivity after a heartbeat', () async {
    camera = await _FakeCamera.start(_Mode.healthy);
    final settings = await _client(camera).readSettings();
    expect(settings.palette, 4);
    expect(settings.range, HtW01Range.small);
    expect(settings.emissivityHundredths, 95);
    expect(settings.answered, 3);
    expect(camera.frames.first[5], 0x31, reason: 'opens with the heartbeat');
    expect(camera.frames.first[23], 1);
  });

  test(
    'a palette write is the spec\'s literal frame, and is answered',
    () async {
      camera = await _FakeCamera.start(_Mode.healthy);
      final ack = await _client(camera).setPalette(1);
      expect(ack.answered, isTrue);
      expect(camera.frames.last, _hex(_setPaletteWhiteHot));
    },
  );

  test('a value outside the spec\'s list never connects', () async {
    camera = await _FakeCamera.start(_Mode.healthy);
    await expectLater(
      _client(camera).setPalette(2),
      throwsA(isA<HtW01Exception>()),
    );
    await expectLater(
      _client(camera).setEmissivity(101),
      throwsA(isA<HtW01Exception>()),
    );
    expect(camera.connections, 0);
  });

  test('garbage is passed over and the read reports no answer', () async {
    camera = await _FakeCamera.start(_Mode.garbage);
    await expectLater(
      _client(camera).readSettings(),
      throwsA(
        isA<HtW01Exception>().having(
          (e) => e.message,
          'message',
          contains('answered none'),
        ),
      ),
    );
  });

  test('silence: a read fails, a write reports no acknowledgement', () async {
    camera = await _FakeCamera.start(_Mode.silent);
    await expectLater(
      _client(camera).readSettings(),
      throwsA(isA<HtW01Exception>()),
    );
    final ack = await _client(camera).refreshShutter();
    expect(ack.answered, isFalse);
    expect(camera.frames.last[5], 0x35);
    expect(camera.frames.last[23], 0x01, reason: 'RefreshShutter only');
  });

  test('an unreachable camera names the Wi-Fi step', () async {
    camera = await _FakeCamera.start(_Mode.silent);
    final port = camera.port;
    await camera.close();
    await expectLater(
      HtW01CameraClient(
        host: '127.0.0.1',
        port: port,
        timeout: const Duration(milliseconds: 300),
      ).readSettings(),
      throwsA(
        isA<HtW01Exception>().having(
          (e) => e.message,
          'message',
          contains('HT-W01 Wi-Fi'),
        ),
      ),
    );
  });
}

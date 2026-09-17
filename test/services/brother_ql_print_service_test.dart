// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/brother_ql_print_service.dart';

void main() {
  late ServerSocket server;
  final received = <int>[];
  List<int>? replyWith;

  setUp(() async {
    received.clear();
    replyWith = null;
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      socket.listen((chunk) {
        received.addAll(chunk);
        final reply = replyWith;
        if (reply != null) {
          socket.add(reply);
          unawaited(socket.flush());
        }
      });
    });
  });

  tearDown(() async {
    await server.close();
  });

  const service = BrotherQlPrintService(
    connectTimeout: Duration(seconds: 2),
    statusReadTimeout: Duration(milliseconds: 400),
  );

  test(
    'send writes the payload and closes without reading by default',
    () async {
      final result = await service.send(
        server.address.address,
        server.port,
        const [1, 2, 3, 4],
      );
      // The server may still be draining; give it a beat.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(result, isA<BrotherQlSendOk>());
      expect((result as BrotherQlSendOk).statusReply, isNull);
      expect(received, [1, 2, 3, 4]);
    },
  );

  test('readStatus returns the 32-byte reply the printer sends', () async {
    replyWith = List<int>.generate(32, (i) => i);
    final result = await service.send(
      server.address.address,
      server.port,
      const [0x1B, 0x69, 0x53],
      readStatus: true,
    );
    expect(result, isA<BrotherQlSendOk>());
    final reply = (result as BrotherQlSendOk).statusReply;
    expect(reply, isNotNull);
    expect(reply, hasLength(32));
    expect(reply, equals(Uint8List.fromList(replyWith!)));
  });

  test('readStatus resolves to null when the printer stays silent', () async {
    // Server accepts but never replies; the read window elapses.
    final result = await service.send(
      server.address.address,
      server.port,
      const [0x1B, 0x69, 0x53],
      readStatus: true,
    );
    expect(result, isA<BrotherQlSendOk>());
    expect((result as BrotherQlSendOk).statusReply, isNull);
  });

  test('a refused connection is a typed failure, not a throw', () async {
    final port = server.port; // capture before closing (port throws after)
    await server.close(); // nothing is listening on that port now
    final result = await service.send(
      InternetAddress.loopbackIPv4.address,
      port,
      const [1, 2, 3],
    );
    expect(result, isA<BrotherQlSendFailed>());
    // Re-bind so tearDown's close() has a live server (harmless if it fails).
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  });
}

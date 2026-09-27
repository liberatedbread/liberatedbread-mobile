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

  /// Scripts the printer's answer, run once on the first chunk it receives —
  /// for replies that arrive split, overlong, or short and then closed.
  Future<void> Function(Socket socket)? onRequest;

  /// Completes when the client's connection has been fully read and closed,
  /// so a payload check waits on the server rather than on a guessed sleep.
  late Completer<void> serverDone;

  setUp(() async {
    received.clear();
    replyWith = null;
    onRequest = null;
    serverDone = Completer<void>();
    server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((socket) {
      var answered = false;
      socket.listen(
        (chunk) {
          received.addAll(chunk);
          final reply = replyWith;
          if (reply != null) {
            socket.add(reply);
            unawaited(socket.flush());
          }
          final script = onRequest;
          if (script != null && !answered) {
            answered = true;
            unawaited(script(socket));
          }
        },
        onDone: () {
          if (!serverDone.isCompleted) serverDone.complete();
        },
        onError: (Object _) {
          if (!serverDone.isCompleted) serverDone.complete();
        },
      );
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
      // Wait for the server to see the close, not a fixed 50 ms: under load
      // the loopback read could land after the sleep and `received` read [].
      await serverDone.future.timeout(const Duration(seconds: 2));
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

  group('readStatus reply shapes', () {
    // _readStatus accumulates chunks until it holds 32 bytes, keeps only the
    // first 32 of a longer reply, and gives null when the printer closes
    // short. Only a single 32-byte chunk was ever tested.
    // A long read window, so "returned well inside it" can only mean the
    // close or the 32nd byte ended the read — with margin for a loaded runner.
    const patient = BrotherQlPrintService(
      connectTimeout: Duration(seconds: 2),
      statusReadTimeout: Duration(seconds: 10),
    );

    Future<Uint8List?> status() async {
      final result = await patient.send(
        server.address.address,
        server.port,
        const [0x1B, 0x69, 0x53],
        readStatus: true,
      );
      expect(result, isA<BrotherQlSendOk>());
      return (result as BrotherQlSendOk).statusReply;
    }

    final full = List<int>.generate(40, (i) => i);

    test('a reply split across two segments is reassembled', () async {
      onRequest = (socket) async {
        socket.add(full.sublist(0, 20));
        await socket.flush();
        await Future<void>.delayed(const Duration(milliseconds: 10));
        socket.add(full.sublist(20, 32));
        await socket.flush();
      };
      expect(await status(), equals(full.sublist(0, 32)));
    });

    test('a reply longer than 32 bytes yields its first 32', () async {
      onRequest = (socket) async {
        socket.add(full);
        await socket.flush();
      };
      expect(await status(), equals(full.sublist(0, 32)));
    });

    test('a short reply followed by a close is null, at once', () async {
      onRequest = (socket) async {
        socket.add(full.sublist(0, 10));
        await socket.flush();
        await socket.close();
      };
      final stopwatch = Stopwatch()..start();
      expect(await status(), isNull);
      expect(
        stopwatch.elapsed,
        lessThan(const Duration(seconds: 5)),
        reason: 'the close ended the read, not the 10 s timer',
      );
    });
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

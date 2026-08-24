// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The polled Roomba adapters' lifecycle: what `close` ends, and what a slow
// server does to a fixed-interval poll. Both rules are invisible in normal
// use and both bite exactly when the far end is having a bad day, which is
// when the robot screen matters most.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/rest980_client.dart';
import 'package:liberated_bread_mobile/services/roomba_controller.dart';

import '../fakes/fake_spec_codec.dart';

/// A rest980 whose every state call takes [latency] and is counted.
({Rest980Client client, List<DateTime> calls}) slowRest980(Duration latency) {
  final calls = <DateTime>[];
  final client = Rest980Client(
    codec: FakeSpecCodec(),
    client: MockClient((request) async {
      calls.add(DateTime.now());
      await Future<void>.delayed(latency);
      return http.Response('{"cleanMissionStatus":{"phase":"run"}}', 200);
    }),
  );
  return (client: client, calls: calls);
}

void main() {
  test('close ends the state stream, not just the polling', () async {
    // The interface offers only `close`, and the device screen calls exactly
    // that on dispose. When `close` merely stopped the timer and left the
    // broadcast stream open, the stream was never closed by anybody: the
    // `dispose` that would have done it had no callers.
    final rest = slowRest980(Duration.zero);
    final controller =
        Rest980Controller(client: rest.client, baseUrl: 'http://10.0.0.5');

    var done = false;
    controller.state.listen((_) {}, onError: (_) {}, onDone: () => done = true);

    await controller.connect();
    await controller.close();
    await Future<void>.delayed(Duration.zero);

    expect(done, isTrue,
        reason: 'listeners must learn the controller is spent');
  });

  test('close is safe to call twice', () async {
    final rest = slowRest980(Duration.zero);
    final controller =
        Rest980Controller(client: rest.client, baseUrl: 'http://10.0.0.5');
    await controller.connect();
    await controller.close();
    await expectLater(controller.close(), completes);
  });

  test('a poll slower than the interval does not stack requests', () {
    // rest980 in front of a busy robot can answer slower than the two-second
    // tick. Unguarded, every tick queued another request and the slowest
    // reply decided the displayed state.
    fakeAsync((async) {
      final rest = slowRest980(const Duration(seconds: 7));
      final controller =
          Rest980Controller(client: rest.client, baseUrl: 'http://10.0.0.5');
      controller.state.listen((_) {}, onError: (_) {});

      unawaited(controller.connect());
      async.elapse(const Duration(seconds: 1));
      expect(rest.calls, hasLength(1), reason: 'the seed read');

      // Three ticks pass while that first read is still on the wire.
      async.elapse(const Duration(seconds: 6));
      expect(rest.calls, hasLength(1),
          reason: 'ticks during an in-flight poll are skipped, not queued');

      // Once it lands, the next tick polls again.
      async.elapse(const Duration(seconds: 3));
      expect(rest.calls, hasLength(2));

      unawaited(controller.close());
      async.flushTimers();
    });
  });
}

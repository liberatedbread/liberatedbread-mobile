// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/stop_signal.dart';

void main() {
  group('StopSignal', () {
    test('sleep returns false when the duration elapses first', () {
      fakeAsync((async) {
        final signal = StopSignal();
        bool? result;
        signal.sleep(const Duration(seconds: 5)).then((v) => result = v);

        async.elapse(const Duration(seconds: 4));
        expect(result, isNull, reason: 'the wait is not over yet');

        async.elapse(const Duration(seconds: 1));
        expect(result, isFalse);
        expect(signal.stopped, isFalse);
      });
    });

    test('sleep returns true as soon as stop lands mid-wait', () {
      fakeAsync((async) {
        final signal = StopSignal();
        bool? result;
        signal.sleep(const Duration(seconds: 30)).then((v) => result = v);

        async.elapse(const Duration(seconds: 1));
        signal.stop();
        async.flushMicrotasks();

        expect(result, isTrue, reason: 'the stop cut the wait short');
      });
    });

    // R-079: Future.any abandons the loser, it does not cancel it. A stop one
    // second into a thirty-second backoff used to leave the thirty-second
    // Timer armed for the other twenty-nine.
    test('a stop leaves no timer pending', () {
      fakeAsync((async) {
        final signal = StopSignal();
        signal.sleep(const Duration(seconds: 30));

        async.elapse(const Duration(seconds: 1));
        signal.stop();
        async.flushMicrotasks();

        expect(async.pendingTimers, isEmpty);
      });
    });

    test('an elapsed sleep leaves no timer pending either', () {
      fakeAsync((async) {
        StopSignal().sleep(const Duration(seconds: 5));
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(async.pendingTimers, isEmpty);
      });
    });

    test('sleep on an already-stopped signal arms no timer at all', () {
      fakeAsync((async) {
        final signal = StopSignal()..stop();
        bool? result;
        signal.sleep(const Duration(hours: 1)).then((v) => result = v);

        expect(async.pendingTimers, isEmpty);
        async.flushMicrotasks();
        expect(result, isTrue);
      });
    });

    test('stop is idempotent and whenStopped completes once', () async {
      final signal = StopSignal();
      var completions = 0;
      unawaited(signal.whenStopped.then((_) => completions++));

      expect(signal.stopped, isFalse);
      signal.stop();
      signal.stop();
      await signal.whenStopped;

      expect(signal.stopped, isTrue);
      expect(completions, 1);
    });
  });
}

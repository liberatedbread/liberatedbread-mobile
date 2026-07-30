// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/log.dart';

/// A stack trace with a stable, asserted-on rendering.
class _FakeStack implements StackTrace {
  @override
  String toString() => '#0      first (file.dart:1:2)\n'
      '#1      second (file.dart:3:4)';
}

/// An error whose toString spans lines, to exercise the block rendering.
class _MultiLineError implements Exception {
  @override
  String toString() => 'BrokeBadly\n  caused by: something else';
}

/// Capture whatever reaches the console, so "the sink replaces console output"
/// is an assertion rather than a claim. Also keeps the default throttled
/// [debugPrint] (and its timer) out of tests that log without a sink.
List<String> _captureConsole() {
  final printed = <String>[];
  final original = debugPrint;
  debugPrint =
      (String? message, {int? wrapWidth}) => printed.add(message ?? '');
  addTearDown(() => debugPrint = original);
  return printed;
}

void main() {
  setUp(Log.reset);
  tearDown(Log.reset);

  group('levels', () {
    test('everything at or above minLevel is emitted', () {
      final records = Log.captureRecords();
      Log.minLevel = LogLevel.debug;

      Log.ble.debug('d');
      Log.ble.info('i');
      Log.ble.warning('w');
      Log.ble.error('e');

      expect(records.map((r) => r.level), [
        LogLevel.debug,
        LogLevel.info,
        LogLevel.warning,
        LogLevel.error,
      ]);
    });

    test('anything below minLevel is dropped', () {
      final records = Log.captureRecords();
      Log.minLevel = LogLevel.warning;

      Log.ble.debug('dropped');
      Log.ble.info('dropped');
      Log.ble.warning('kept');
      Log.ble.error('kept');

      expect(records.map((r) => r.message), ['kept', 'kept']);
    });

    test('the severity order is debug < info < warning < error', () {
      expect(
        LogLevel.values,
        [LogLevel.debug, LogLevel.info, LogLevel.warning, LogLevel.error],
      );
    });
  });

  group('release gating', () {
    // kReleaseMode is a compile-time constant and is always false under
    // `flutter test`, so the rule is tested through its pure form.
    test('a release build never emits below the floor', () {
      for (final level in LogLevel.values) {
        expect(
          Log.clampToReleaseFloor(level, releaseMode: true).index,
          greaterThanOrEqualTo(Log.releaseFloor.index),
          reason: '$level must be clamped in a release build',
        );
      }
    });

    test('a release build still emits warnings and errors', () {
      expect(
        Log.clampToReleaseFloor(LogLevel.debug, releaseMode: true),
        LogLevel.warning,
      );
      expect(
        Log.clampToReleaseFloor(LogLevel.error, releaseMode: true),
        LogLevel.error,
      );
    });

    test('a non-release build honours the configured level', () {
      for (final level in LogLevel.values) {
        expect(Log.clampToReleaseFloor(level, releaseMode: false), level);
      }
    });

    test('verbose logging cannot be turned back on in a release build', () {
      // The floor is applied to the *configured* value, so setting minLevel
      // low at runtime cannot re-enable debug output in a shipped build.
      expect(
        Log.clampToReleaseFloor(LogLevel.debug, releaseMode: true).index,
        greaterThan(LogLevel.debug.index),
      );
    });
  });

  group('records', () {
    test('carry their category', () {
      final records = Log.captureRecords();

      Log.ble.info('a');
      Log.spec.info('b');
      Log.ha.info('c');
      Log.packs.info('d');
      Log.app.info('e');
      Log.ui.info('f');

      expect(
        records.map((r) => r.category),
        ['ble', 'spec', 'ha', 'packs', 'app', 'ui'],
      );
    });

    test('the category set is fixed', () {
      // Logger's constructor is private, so a call site cannot invent a tag
      // ('BLE', 'bluetooth', a typo) and split the output. This pins the set.
      expect(
        Log.categories.map((c) => c.category),
        ['ble', 'spec', 'ha', 'packs', 'app', 'ui'],
      );
    });

    test('carry an error and a stack trace', () {
      final records = Log.captureRecords();
      final error = StateError('boom');
      final stack = _FakeStack();

      Log.ha.error('failed', error: error, stackTrace: stack);

      expect(records, hasLength(1));
      expect(records.single.error, same(error));
      expect(records.single.stackTrace, same(stack));
      expect(records.single.level, LogLevel.error);
    });

    test('an error may ride along on a warning or a debug line', () {
      final records = Log.captureRecords();
      final error = StateError('swallowed');

      Log.ble.warning('degraded', error: error);
      Log.ble.debug('best effort', error: error);

      expect(records.map((r) => r.error), [error, error]);
    });

    test('carry a timestamp', () {
      final records = Log.captureRecords();
      final before = DateTime.now();

      Log.app.info('now');

      expect(records.single.time.isBefore(before), isFalse);
    });
  });

  group('rendering', () {
    LogRecord record(
      LogLevel level, {
      Object? error,
      StackTrace? stackTrace,
      String category = 'ble',
    }) =>
        LogRecord(
          time: DateTime(2026, 7, 30, 14, 2, 11, 482),
          level: level,
          category: category,
          message: 'scan started',
          error: error,
          stackTrace: stackTrace,
        );

    test('shows the time, the level and the category', () {
      expect(record(LogLevel.info).format(),
          '14:02:11.482 INFO  [ble] scan started');
      expect(record(LogLevel.debug).format(),
          '14:02:11.482 DEBUG [ble] scan started');
      expect(record(LogLevel.warning).format(),
          '14:02:11.482 WARN  [ble] scan started');
      expect(record(LogLevel.error).format(),
          '14:02:11.482 ERROR [ble] scan started');
    });

    test('keeps a single-line error on the same line', () {
      expect(
        record(LogLevel.warning, error: StateError('nope')).format(),
        '14:02:11.482 WARN  [ble] scan started: Bad state: nope',
      );
    });

    test('breaks a multi-line error onto indented lines', () {
      expect(
        record(LogLevel.error, error: _MultiLineError()).format(),
        '14:02:11.482 ERROR [ble] scan started\n'
        '  BrokeBadly\n'
        '    caused by: something else',
      );
    });

    test('indents a stack trace under its line', () {
      expect(
        record(LogLevel.error, error: 'boom', stackTrace: _FakeStack())
            .format(),
        '14:02:11.482 ERROR [ble] scan started: boom\n'
        '  #0      first (file.dart:1:2)\n'
        '  #1      second (file.dart:3:4)',
      );
    });

    test('formats the time zero-padded to milliseconds', () {
      expect(formatLogTime(DateTime(2026, 1, 2, 3, 4, 5, 6)), '03:04:05.006');
      expect(
          formatLogTime(DateTime(2026, 1, 2, 23, 59, 59, 999)), '23:59:59.999');
    });
  });

  group('output plumbing', () {
    test('without a sink, the formatted line goes to the console', () {
      final printed = _captureConsole();

      Log.ble.info('scan started');

      expect(printed, hasLength(1));
      expect(printed.single, contains('INFO  [ble] scan started'));
    });

    test('a sink replaces console output, so tests stay quiet', () {
      final printed = _captureConsole();
      final records = Log.captureRecords();

      Log.ble.info('scan started');

      expect(records, hasLength(1));
      expect(printed, isEmpty);
    });

    test('reset() restores the shipped defaults', () {
      Log.captureRecords();
      Log.minLevel = LogLevel.error;

      Log.reset();

      expect(Log.sink, isNull);
      expect(Log.minLevel, kDebugMode ? LogLevel.debug : LogLevel.info);
    });

    test('a filtered-out line reaches neither sink nor console', () {
      final printed = _captureConsole();
      Log.minLevel = LogLevel.error;

      Log.ble.info('dropped');

      expect(printed, isEmpty);
    });
  });

  group('redaction', () {
    test('redact replaces a secret with a fixed marker', () {
      const token = 'eyJhbGciOiJIUzI1NiJ9.super-secret-token.sig';
      expect(redact(token), '<redacted>');
      expect(redact(token), isNot(contains('secret')));
      // Not even the length leaks: every secret renders identically.
      expect(redact('x'), redact(token));
    });

    test('redact distinguishes absent from present', () {
      expect(redact(null), '<none>');
      expect(redact('anything'), '<redacted>');
    });

    test('redactAll masks every occurrence in free text', () {
      const token = 'super-secret-token';
      const text = 'auth failed for $token (retrying with $token)';

      final safe = redactAll(text, [token]);

      expect(safe, isNot(contains('super-secret-token')));
      expect(safe, 'auth failed for <redacted> (retrying with <redacted>)');
    });

    test('redactAll masks several secrets and skips null/empty ones', () {
      final safe = redactAll('t=tok w=hook', ['tok', 'hook', null, '']);

      expect(safe, 't=<redacted> w=<redacted>');
    });

    test('errorType gives the type without the value', () {
      // The motivating case: FormatException.toString() quotes a window of its
      // source, which for a corrupt HA config blob is token material.
      Object thrown;
      try {
        throw const FormatException(
            'Unterminated string', '{"token":"super-secret-token', 28);
      } catch (e) {
        thrown = e;
      }

      expect('$thrown', contains('super-secret-token')); // the hazard is real
      expect(errorType(thrown), 'FormatException'); // and this is the way out
      expect(errorType(thrown), isNot(contains('secret')));
      expect(errorType(null), 'null');
    });

    test('logSafeUrl drops credentials, query and fragment', () {
      final url = Uri.parse(
          'https://user:hunter2@example.com/packs/pack.json?token=abc#frag');

      final safe = logSafeUrl(url);

      expect(safe, 'https://example.com/packs/pack.json');
      expect(safe, isNot(contains('hunter2')));
      expect(safe, isNot(contains('abc')));
    });

    test('logSafeUrl keeps a non-default port, which is diagnostic', () {
      expect(logSafeUrl(Uri.parse('http://ha.local:8123/api/x')),
          'http://ha.local:8123/api/x');
    });
  });
}

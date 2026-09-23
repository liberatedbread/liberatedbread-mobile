// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/log.dart';

/// A stack trace with a stable, asserted-on rendering.
class _FakeStack implements StackTrace {
  @override
  String toString() =>
      '#0      first (file.dart:1:2)\n'
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
  debugPrint = (String? message, {int? wrapWidth}) =>
      printed.add(message ?? '');
  addTearDown(() => debugPrint = original);
  return printed;
}

void main() {
  group('registered secrets', () {
    late LogBuffer buffer;
    setUp(() {
      Log.reset();
      // This file's other groups run without a buffer; these need one.
      Log.buffer = buffer = LogBuffer();
    });
    tearDown(Log.clearSecrets);

    test('are redacted from the message and the error, at dispatch', () {
      // The Diagnostics screen exports Log.buffer verbatim, and main.dart's
      // uncaught-error hooks forward every error's toString() into it: a
      // FormatException quoting the credential JSON it choked on, a
      // ClientException with a token in its URL. A secret the app holds is
      // registered by the store that loaded it and cut out of every record
      // from then on, wherever in the record it appears.
      Log.registerSecret('hunter2-token');
      Log.app.error(
        'request failed for token hunter2-token',
        error: const FormatException('bad json: {"token":"hunter2-token"}'),
      );

      final text = buffer.records.map((r) => r.format()).join('\n');
      expect(text, isNot(contains('hunter2-token')));
      expect(text, contains('<redacted>'));
      expect(text, contains('bad json'), reason: 'only the secret goes');
    });

    test('an empty or null secret registers nothing', () {
      Log.registerSecret(null);
      Log.registerSecret('');
      Log.app.info('plain');
      expect(buffer.records.last.message, 'plain');
    });
  });

  // `Log.reset()` deliberately does NOT reset `defaultSink` — it is the thing
  // reset restores TO. So the tests below that install one have to put back
  // what the suite's own flutter_test_config set, or every test after them
  // runs with the console on.
  late LogSink? suiteDefaultSink;
  setUp(() {
    suiteDefaultSink = Log.defaultSink;
    Log.reset();
  });
  tearDown(() {
    Log.defaultSink = suiteDefaultSink;
    Log.reset();
  });

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
      expect(LogLevel.values, [
        LogLevel.debug,
        LogLevel.info,
        LogLevel.warning,
        LogLevel.error,
      ]);
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

    test('an explicit category Capture is honoured in a release build', () {
      // The diagnostics screen's per-category chip is CONSENT — a person, one
      // category, until the process ends. Clamping it made the chip render
      // selected while recording nothing, in the one build the feature exists
      // for: a field session on a release install.
      Log.setCategoryLevel(Log.ble, LogLevel.debug);
      addTearDown(() => Log.setCategoryLevel(Log.ble, null));
      expect(
        Log.effectiveLevelIn(Log.ble.category, releaseMode: true),
        LogLevel.debug,
      );
      // The GLOBAL level stays floored: only the explicit override is exempt.
      expect(
        Log.effectiveLevelIn(Log.net.category, releaseMode: true).index,
        greaterThanOrEqualTo(Log.releaseFloor.index),
      );
    });
  });

  group('records', () {
    test('carry their category', () {
      final records = Log.captureRecords();

      Log.ble.info('a');
      Log.spec.info('b');
      Log.ha.info('c');
      Log.net.info('d');
      Log.adopt.info('d2');
      Log.hub.info('e');
      Log.packs.info('f');
      Log.ads.info('g');
      Log.app.info('h');
      Log.ui.info('i');

      expect(records.map((r) => r.category), [
        'ble',
        'spec',
        'ha',
        'net',
        'adopt',
        'hub',
        'packs',
        'ads',
        'app',
        'ui',
      ]);
    });

    test('the category set is fixed', () {
      // Logger's constructor is private, so a call site cannot invent a tag
      // ('BLE', 'bluetooth', a typo) and split the output. This pins the set.
      expect(Log.categories.map((c) => c.category), [
        'ble',
        'spec',
        'ha',
        'net',
        'adopt',
        'hub',
        'packs',
        'ads',
        'app',
        'ui',
      ]);
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
    }) => LogRecord(
      time: DateTime(2026, 7, 30, 14, 2, 11, 482),
      level: level,
      category: category,
      message: 'scan started',
      error: error,
      stackTrace: stackTrace,
    );

    test('shows the time, the level and the category', () {
      expect(
        record(LogLevel.info).format(),
        '14:02:11.482 INFO  [ble] scan started',
      );
      expect(
        record(LogLevel.debug).format(),
        '14:02:11.482 DEBUG [ble] scan started',
      );
      expect(
        record(LogLevel.warning).format(),
        '14:02:11.482 WARN  [ble] scan started',
      );
      expect(
        record(LogLevel.error).format(),
        '14:02:11.482 ERROR [ble] scan started',
      );
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
        record(
          LogLevel.error,
          error: 'boom',
          stackTrace: _FakeStack(),
        ).format(),
        '14:02:11.482 ERROR [ble] scan started: boom\n'
        '  #0      first (file.dart:1:2)\n'
        '  #1      second (file.dart:3:4)',
      );
    });

    test('formats the time zero-padded to milliseconds', () {
      expect(formatLogTime(DateTime(2026, 1, 2, 3, 4, 5, 6)), '03:04:05.006');
      expect(
        formatLogTime(DateTime(2026, 1, 2, 23, 59, 59, 999)),
        '23:59:59.999',
      );
    });
  });

  group('output plumbing', () {
    test('without a sink, the formatted line goes to the console', () {
      final printed = _captureConsole();
      // The app's configuration. Under `flutter test` the default sink is the
      // discarding one this suite installs (see test/flutter_test_config.dart),
      // so the console path has to be asked for explicitly to be tested.
      Log.defaultSink = null;
      Log.sink = null;

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
      Log.setCategoryLevel(Log.net, LogLevel.debug);

      Log.reset();

      expect(Log.sink, same(Log.defaultSink));
      expect(Log.minLevel, kDebugMode ? LogLevel.debug : LogLevel.info);
      expect(Log.categoryLevel(Log.net), isNull);
    });

    test('reset() restores the installed default, not null', () {
      // The hook the test suite depends on: any tearDown(Log.reset) must not
      // turn the console back on for every test that runs after it.
      final swallowed = <LogRecord>[];
      Log.defaultSink = swallowed.add;
      Log.captureRecords();

      Log.reset();
      Log.ble.info('after reset');

      expect(swallowed.single.message, 'after reset');
    });

    test('a filtered-out line reaches neither sink nor console', () {
      final printed = _captureConsole();
      Log.minLevel = LogLevel.error;

      Log.ble.info('dropped');

      expect(printed, isEmpty);
    });
  });

  group('per-category levels', () {
    test('one category can be turned up while the rest stay quiet', () {
      // The knob that used to not exist: during a hardware session `net` at
      // debug is the diagnosis, and `debug` everywhere buries it under nine
      // other categories.
      final records = Log.captureRecords();
      Log.minLevel = LogLevel.info;
      Log.setCategoryLevel(Log.net, LogLevel.debug);

      Log.net.debug('datagram from 10.0.0.4');
      Log.ads.debug('config fetch returned HTTP 400');
      Log.ble.info('scan started');

      expect(records.map((r) => r.message), [
        'datagram from 10.0.0.4',
        'scan started',
      ]);
    });

    test('a category can also be turned DOWN below the global level', () {
      final records = Log.captureRecords();
      Log.minLevel = LogLevel.debug;
      Log.setCategoryLevel(Log.ads, LogLevel.warning);

      Log.ads.debug('config fetch returned HTTP 400');
      Log.ads.warning('banner config unreadable');
      Log.ble.debug('kept');

      expect(records.map((r) => r.message), [
        'banner config unreadable',
        'kept',
      ]);
    });

    test('clearing an override returns the category to minLevel', () {
      final records = Log.captureRecords();
      Log.minLevel = LogLevel.info;
      Log.setCategoryLevel(Log.net, LogLevel.debug);
      Log.setCategoryLevel(Log.net, null);

      Log.net.debug('dropped');

      expect(Log.categoryLevel(Log.net), isNull);
      expect(records, isEmpty);
    });

    test('a category turned DOWN is honoured in a release build too', () {
      // R-077: the test here was called "the release floor still applies to a
      // category override", set no override, and asserted the global rule —
      // so it named the opposite of what ships and could not have noticed
      // either behaviour change. The override-is-exempt direction is already
      // covered under "release gating"; what nothing covered is the other
      // direction, which is the one that could quietly re-enable output: a
      // category turned DOWN must stay down, and must not be raised back to
      // the floor by it.
      Log.minLevel = LogLevel.debug;
      Log.setCategoryLevel(Log.net, LogLevel.error);
      addTearDown(() => Log.setCategoryLevel(Log.net, null));

      expect(
        Log.effectiveLevelIn(Log.net.category, releaseMode: true),
        LogLevel.error,
        reason: 'quieter than the floor stays quieter than the floor',
      );
      expect(
        Log.effectiveLevelIn(Log.net.category, releaseMode: false),
        LogLevel.error,
      );
      // …while a category with no override follows the floored global.
      expect(
        Log.effectiveLevelIn(Log.ble.category, releaseMode: true),
        LogLevel.warning,
      );
    });

    test('isEnabled answers for the category, not the global level', () {
      Log.minLevel = LogLevel.info;
      Log.setCategoryLevel(Log.net, LogLevel.debug);

      expect(Log.net.isEnabled(LogLevel.debug), isTrue);
      expect(Log.ble.isEnabled(LogLevel.debug), isFalse);
      expect(Log.ble.isEnabled(LogLevel.warning), isTrue);
    });
  });

  group('timed', () {
    test('logs the elapsed time and returns the value', () async {
      final records = Log.captureRecords();
      Log.minLevel = LogLevel.debug;

      final result = await Log.net.timed('mDNS probe', () async => 7);

      expect(result, 7);
      expect(records.single.level, LogLevel.debug);
      expect(records.single.category, 'net');
      expect(records.single.message, startsWith('mDNS probe took '));
    });

    test('a failure is logged with its elapsed time and rethrown', () async {
      // The timing line must survive the throw: "it failed" and "it took nine
      // seconds to fail" are different diagnoses, and the second one is the
      // one that says the socket was hanging.
      final records = Log.captureRecords();
      Log.minLevel = LogLevel.debug;

      await expectLater(
        Log.net.timed('mDNS probe', () async => throw StateError('no route')),
        throwsA(isA<StateError>()),
      );

      expect(records.single.level, LogLevel.warning);
      expect(records.single.message, startsWith('mDNS probe failed after '));
      expect(records.single.error, isA<StateError>());
    });

    test('the level is the caller\'s to choose', () async {
      final records = Log.captureRecords();
      await Log.adopt.timed('join poll', () async {}, level: LogLevel.info);
      expect(records.single.level, LogLevel.info);
    });
  });

  group('formatElapsed', () {
    test('sub-second durations read in milliseconds', () {
      // 140ms and 12.0s should be visibly different at a glance, which "0.1s"
      // and "12.0s" are not.
      expect(formatElapsed(const Duration(milliseconds: 140)), '140ms');
      expect(formatElapsed(Duration.zero), '0ms');
      expect(formatElapsed(const Duration(milliseconds: 999)), '999ms');
    });

    test('a second and over reads in seconds, to one decimal', () {
      expect(formatElapsed(const Duration(milliseconds: 1000)), '1.0s');
      expect(formatElapsed(const Duration(milliseconds: 1249)), '1.2s');
      expect(formatElapsed(const Duration(seconds: 12)), '12.0s');
    });
  });

  group('logFields', () {
    test('renders key=value in the order given', () {
      expect(
        logFields({'name': 'Wemo', 'firmware': '2.00', 'port': 49153}),
        'name=Wemo firmware=2.00 port=49153',
      );
    });

    test('an absent value is marked, never rendered as empty', () {
      // "firmware=" reads as "the device said its firmware is the empty
      // string", which is a different fact from "the device did not say".
      expect(logFields({'firmware': null}), 'firmware=<none>');
      expect(logFields({'rtos': null}, absent: '<absent>'), 'rtos=<absent>');
      expect(logFields({'firmware': ''}), 'firmware=');
    });

    test('a secret is the caller\'s to redact first', () {
      expect(logFields({'token': redact('s3cret')}), 'token=<redacted>');
    });
  });

  group('LogBuffer', () {
    LogRecord record(String message) => LogRecord(
      time: DateTime(2026, 1, 2, 14, 2, 11, 482),
      level: LogLevel.info,
      category: 'ble',
      message: message,
    );

    test('keeps records oldest-first', () {
      final buffer = LogBuffer(capacity: 10)
        ..add(record('first'))
        ..add(record('second'));
      expect(buffer.records.map((r) => r.message), ['first', 'second']);
    });

    test('drops the oldest past capacity', () {
      // A long session must not grow without limit; a scan alone emits tens of
      // lines.
      final buffer = LogBuffer(capacity: 3);
      for (var i = 0; i < 5; i++) {
        buffer.add(record('line $i'));
      }
      expect(buffer.length, 3);
      expect(buffer.records.map((r) => r.message), [
        'line 2',
        'line 3',
        'line 4',
      ]);
    });

    test('export renders one record per line, newest last', () {
      final buffer = LogBuffer()
        ..add(record('first'))
        ..add(record('second'));
      expect(
        buffer.export(),
        '14:02:11.482 INFO  [ble] first\n14:02:11.482 INFO  [ble] second',
      );
    });

    test('export narrows by level and category', () {
      // So a bug report carries the thirty lines someone was looking at rather
      // than five hundred, which is the difference between read and skimmed.
      final buffer = LogBuffer()
        ..add(
          LogRecord(
            time: DateTime(2026),
            level: LogLevel.debug,
            category: 'ble',
            message: 'chatter',
          ),
        )
        ..add(
          LogRecord(
            time: DateTime(2026),
            level: LogLevel.warning,
            category: 'ble',
            message: 'kept',
          ),
        )
        ..add(
          LogRecord(
            time: DateTime(2026),
            level: LogLevel.error,
            category: 'net',
            message: 'other category',
          ),
        );

      final exported = buffer.export(
        minLevel: LogLevel.warning,
        categories: {'ble'},
      );

      expect(exported, contains('kept'));
      expect(exported, isNot(contains('chatter')));
      expect(exported, isNot(contains('other category')));
    });

    test('the buffer observes output rather than replacing it', () {
      // A record reaches the buffer whether it went to the console, a test's
      // capture list, or nowhere: what the buffer answers is "what just
      // happened", and a build routing its output elsewhere still needs that.
      final buffer = LogBuffer();
      Log.buffer = buffer;
      addTearDown(() => Log.buffer = null);
      final records = Log.captureRecords();

      Log.ble.info('scan started');

      expect(records, hasLength(1));
      expect(buffer.records.single.message, 'scan started');
    });

    test('a filtered-out line does not reach the buffer either', () {
      final buffer = LogBuffer();
      Log.buffer = buffer;
      addTearDown(() => Log.buffer = null);
      Log.minLevel = LogLevel.error;

      Log.ble.info('dropped');

      expect(buffer.records, isEmpty);
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
          'Unterminated string',
          '{"token":"super-secret-token',
          28,
        );
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
        'https://user:hunter2@example.com/packs/pack.json?token=abc#frag',
      );

      final safe = logSafeUrl(url);

      expect(safe, 'https://example.com/packs/pack.json');
      expect(safe, isNot(contains('hunter2')));
      expect(safe, isNot(contains('abc')));
    });

    test('logSafeUrl keeps a non-default port, which is diagnostic', () {
      expect(
        logSafeUrl(Uri.parse('http://ha.local:8123/api/x')),
        'http://ha.local:8123/api/x',
      );
    });
  });
}

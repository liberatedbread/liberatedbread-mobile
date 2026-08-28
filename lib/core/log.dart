// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Structured logging, sized for one job: a developer watching a console while
// the app runs (`flutter run -d linux`, or on a device) and needing to see what
// it is doing without attaching a debugger.

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Severity, ordered least to most severe. [index] is the ordering key.
enum LogLevel {
  debug('DEBUG', 500),
  info('INFO', 800),
  warning('WARN', 900),
  error('ERROR', 1000);

  const LogLevel(this.label, this.developerLevel);

  /// Name shown in console output.
  final String label;

  /// The equivalent `package:logging` level, which is what `dart:developer`'s
  /// `log()` and the DevTools logging view expect (FINE/INFO/WARNING/SEVERE).
  final int developerLevel;
}

/// One emitted log line, before it is rendered.
///
/// Handed to [Log.sink] so tests can assert on the structure (level, category,
/// error, stack) instead of scraping formatted text.
@immutable
class LogRecord {
  final DateTime time;
  final LogLevel level;
  final String category;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  const LogRecord({
    required this.time,
    required this.level,
    required this.category,
    required this.message,
    this.error,
    this.stackTrace,
  });

  /// The console rendering: `14:02:11.482 INFO  [ble] scan started`.
  ///
  /// Time-of-day (not a full date) because this is read live, next to the
  /// action that produced it; milliseconds because BLE and flush timing is
  /// exactly what you are squinting at.
  ///
  /// A single-line [error] is appended inline, keeping one event on one line —
  /// which is what makes a console scannable. A multi-line error and any
  /// [stackTrace] go to indented continuation lines instead, so the block still
  /// reads as one event.
  String format() {
    final buffer = StringBuffer()
      ..write(formatLogTime(time))
      ..write(' ')
      ..write(level.label.padRight(5))
      ..write(' [')
      ..write(category)
      ..write('] ')
      ..write(message);
    final errorText = error?.toString().trimRight();
    if (errorText != null && errorText.isNotEmpty) {
      buffer.write(errorText.contains('\n')
          ? '\n${_indent(errorText)}'
          : ': $errorText');
    }
    final stack = stackTrace?.toString().trimRight();
    if (stack != null && stack.isNotEmpty) buffer.write('\n${_indent(stack)}');
    return buffer.toString();
  }

  static String _indent(String text) => '  ${text.replaceAll('\n', '\n  ')}';

  @override
  String toString() => format();
}

/// `HH:mm:ss.SSS` in local time, without pulling in a date-formatting package.
String formatLogTime(DateTime time) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
      '.${time.millisecond.toString().padLeft(3, '0')}';
}

/// Where emitted records go. See [Log.sink].
typedef LogSink = void Function(LogRecord record);

/// A logger for one category. Instances are the [Log] constants — the
/// constructor is private precisely so a tag cannot be invented at a call site
/// and drift ('ble' vs 'BLE' vs 'bluetooth'), which is what makes the output
/// filterable at all.
class Logger {
  final String category;

  const Logger._(this.category);

  /// Fine-grained detail, on only in debug builds by default.
  void debug(String message, {Object? error, StackTrace? stackTrace}) =>
      _emit(LogLevel.debug, message, error: error, stackTrace: stackTrace);

  /// A normal, noteworthy lifecycle event — scan started, pack installed.
  void info(String message, {Object? error, StackTrace? stackTrace}) =>
      _emit(LogLevel.info, message, error: error, stackTrace: stackTrace);

  /// Something went wrong but the app degraded gracefully.
  void warning(String message, {Object? error, StackTrace? stackTrace}) =>
      _emit(LogLevel.warning, message, error: error, stackTrace: stackTrace);

  /// Something went wrong that the developer needs to see.
  void error(String message, {Object? error, StackTrace? stackTrace}) =>
      _emit(LogLevel.error, message, error: error, stackTrace: stackTrace);

  /// Whether a call at [level] would be emitted for this category right now.
  ///
  /// For the one case the level check cannot cover: a message whose *argument*
  /// is expensive to compute (a hex dump of a notify payload, a JSON re-encode
  /// for readability). The threshold below suppresses the emit, not the
  /// interpolation the caller already did, so a caller doing real work to build
  /// a string should ask first.
  bool isEnabled(LogLevel level) =>
      level.index >= Log.effectiveLevelFor(category).index;

  /// Run [body], and log how long it took.
  ///
  /// The pattern this replaces is hand-rolled in the adoption service and
  /// nowhere else, which is the problem: "how long did the probe take" is the
  /// first question about every network exchange in this app and only one of
  /// them can answer it. A failure is logged too, at [LogLevel.warning] with
  /// its elapsed time, and then rethrown — the caller's error handling is
  /// unchanged, and the timing line is not lost to the throw.
  ///
  /// The clock starts before [body] is called and stops when its future
  /// completes, so it measures what a person waited for rather than what the
  /// CPU did.
  Future<T> timed<T>(
    String what,
    Future<T> Function() body, {
    LogLevel level = LogLevel.debug,
  }) async {
    final watch = Stopwatch()..start();
    try {
      final result = await body();
      _emit(level, '$what took ${formatElapsed(watch.elapsed)}');
      return result;
    } catch (e) {
      _emit(LogLevel.warning,
          '$what failed after ${formatElapsed(watch.elapsed)}',
          error: e);
      rethrow;
    }
  }

  void _emit(
    LogLevel level,
    String message, {
    Object? error,
    StackTrace? stackTrace,
  }) {
    // Filter before building anything, so a suppressed level costs one
    // comparison. (The message string itself is still built by the caller's
    // interpolation — hence the rule against logging in tight loops, and
    // [isEnabled] for the cases where the argument is the expensive part.)
    if (!isEnabled(level)) return;
    Log._dispatch(LogRecord(
      time: DateTime.now(),
      level: level,
      category: category,
      message: message,
      error: error,
      stackTrace: stackTrace,
    ));
  }
}

/// A duration as `1.2s`, or `840ms` below a second.
///
/// One spelling, because these are read by eye next to each other: a probe
/// that answered in 140ms and one that took 12.0s should be visibly different
/// at a glance, which `0.1s` and `12.0s` are not.
String formatElapsed(Duration elapsed) {
  final ms = elapsed.inMilliseconds;
  return ms < 1000 ? '${ms}ms' : '${(ms / 1000).toStringAsFixed(1)}s';
}

/// `key=value` pairs in the order given: `name=Wemo firmware=2.00 rtos=<none>`.
///
/// The convention several call sites already write by hand. Worth one helper
/// because the rendering of an ABSENT value is the part that matters and the
/// part that drifts: a field printed as empty (`firmware=`) reads as "the
/// device said its firmware is the empty string", which is a different fact
/// from "the device did not say". [absent] is what null renders as.
///
/// Values are rendered with `toString()` and are the caller's responsibility:
/// pass a secret through [redact] before it gets here.
String logFields(Map<String, Object?> fields, {String absent = '<none>'}) =>
    fields.entries.map((e) => '${e.key}=${e.value ?? absent}').join(' ');

/// The app's loggers, level threshold, and output plumbing.
///
/// ## Why `debugPrint` for the console AND `dart:developer` for the structure
///
/// `dart:developer`'s `log()` is the "proper" structured call — it carries a
/// level, a name, an error and a stack trace, and DevTools' Logging view
/// renders all of it. What it does NOT do is reach a terminal: its records go
/// to the VM service `Logging` stream, and if nothing is listening they are
/// dropped. `flutter run` listens to the `Extension` and `Isolate` streams, not
/// `Logging`, so a `developer.log()`-only facade is invisible in exactly the
/// place this logging exists to serve — the desktop iteration console.
///
/// So both, deliberately: [LogRecord.format] goes to the console via
/// [debugPrint] (goes to stdout, which `flutter run` pipes through; works on
/// every platform including web, unlike `dart:io`'s stdout; rate-limited so a
/// chatty notify characteristic cannot get lines dropped by Android's logcat;
/// and `avoid_print` bans the alternative), and the same record goes to
/// `developer.log()` for DevTools. There is no double-printing, because
/// `developer.log()` never writes to stdout.
///
/// ## Secrets
///
/// The Home Assistant long-lived token and webhook id are secrets (see
/// `SecureSettingsStore`). They must never reach a log — not a device's logcat,
/// not a CI transcript, not a screen-shared terminal. Two rules, both load
/// bearing:
///
///  1. Never log a whole config/DTO/JSON blob that contains one. Log named
///     fields, and pass secret ones through [redact].
///  2. Never interpolate an exception that may have been *handed* the secret.
///     `FormatException.toString()` embeds a window of its source string, so
///     `'$e'` after a failed `jsonDecode` of the stored HA config prints part
///     of the token. Use [errorType] there.
class Log {
  Log._();

  /// BLE adapter, scanning, connection and GATT lifecycle.
  static const Logger ble = Logger._('ble');

  /// Device-spec parsing and matching.
  static const Logger spec = Logger._('spec');

  /// Home Assistant config, registration and sensor forwarding.
  static const Logger ha = Logger._('ha');

  /// Local-network discovery: mDNS, SSDP, and the multicast lock.
  static const Logger net = Logger._('net');

  /// Putting a factory-reset device onto the home network: the setup-AP probe,
  /// the credential sweep and the join poll. Its own category (not `net`)
  /// because adoption is the one flow whose diagnosis needs the whole
  /// conversation in order — probe, GetApList, each ConnectHomeNetwork variant,
  /// each status poll — and `net` is where the ambient discovery chatter lives,
  /// which is exactly what a reader has to filter out. NOTE: the Wi-Fi
  /// passphrase being handed over is a secret; these lines carry its length and
  /// never its value, and never a rendered request body (which embeds the
  /// encrypted blob).
  static const Logger adopt = Logger._('adopt');

  /// Hub pairing, TLS trust decisions, and control transport. Its own
  /// category (not `net`) because its lines are the audit trail of trust:
  /// "pinned", "pin mismatch", "fell back to http" are the ones a security
  /// review greps for. NOTE: requests to a Hue bridge embed the credential
  /// in the path, so hub lines never carry a path.
  static const Logger hub = Logger._('hub');

  /// Spec-pack download, validation, install and cache.
  static const Logger packs = Logger._('packs');

  /// Ad-banner config fetch and cache.
  static const Logger ads = Logger._('ads');

  /// App startup and process-wide concerns.
  static const Logger app = Logger._('app');

  /// A user-visible operation failed and the UI showed fallback text.
  static const Logger ui = Logger._('ui');

  /// Every category, for tests and for documenting the filterable set.
  static const List<Logger> categories = [
    ble,
    spec,
    ha,
    net,
    adopt,
    hub,
    packs,
    ads,
    app,
    ui
  ];

  /// Release builds never emit below this, whatever [minLevel] says. Verbose
  /// logging shipping to users is a privacy and performance problem, so the
  /// floor is applied structurally rather than by asking call sites to behave.
  /// Warnings and errors survive: they are what a bug report needs.
  static const LogLevel releaseFloor = LogLevel.warning;

  static LogLevel get _defaultMinLevel =>
      kDebugMode ? LogLevel.debug : LogLevel.info;

  /// Lowest level a call site may emit: everything in debug builds,
  /// [LogLevel.info] and up otherwise. Raising it is honoured everywhere;
  /// lowering it is honoured only down to [releaseFloor] in a release build.
  static LogLevel minLevel = _defaultMinLevel;

  /// [minLevel] after the release floor is applied.
  static LogLevel get effectiveMinLevel =>
      clampToReleaseFloor(minLevel, releaseMode: kReleaseMode);

  /// The floor rule as a pure function, so it can be tested for the release
  /// case — `kReleaseMode` is a compile-time constant and is always false
  /// under `flutter test`.
  @visibleForTesting
  static LogLevel clampToReleaseFloor(
    LogLevel level, {
    required bool releaseMode,
  }) =>
      releaseMode && level.index < releaseFloor.index ? releaseFloor : level;

  /// Per-category thresholds, overriding [minLevel] where present.
  static final Map<String, LogLevel> _categoryLevels = {};

  /// Turn one category up or down without touching the others.
  ///
  /// The threshold used to be a single knob, and the two useful positions were
  /// both wrong during a hardware session: `info` hides the datagram-level
  /// detail that is the whole diagnosis, and `debug` buries it under the
  /// unrelated chatter of nine other categories. Passing `null` clears the
  /// override and returns the category to [minLevel].
  ///
  /// The release floor does NOT apply to these: the override is set by a
  /// person, on the diagnostics screen, for one named category, and lives
  /// only until the process ends — that is consent to capture, not verbose
  /// logging shipping silently, which is what the floor exists to stop. It
  /// used to be clamped anyway, which made the screen's promise ("record its
  /// finest detail, whatever the level above says") a silent no-op in the
  /// one build the feature exists for: a field session on a release install,
  /// where the chip rendered selected and nothing was recorded.
  static void setCategoryLevel(Logger logger, LogLevel? level) {
    if (level == null) {
      _categoryLevels.remove(logger.category);
    } else {
      _categoryLevels[logger.category] = level;
    }
  }

  /// The override in force for [logger], or null when it follows [minLevel].
  static LogLevel? categoryLevel(Logger logger) =>
      _categoryLevels[logger.category];

  /// The threshold a call in [category] is actually filtered against.
  static LogLevel effectiveLevelFor(String category) =>
      effectiveLevelIn(category, releaseMode: kReleaseMode);

  /// The threshold rule as a pure function, testable for the release case
  /// the same way [clampToReleaseFloor] is. An explicit category override is
  /// honoured as set — see [setCategoryLevel] for why the floor does not
  /// apply to it; the global [minLevel] is still floored.
  @visibleForTesting
  static LogLevel effectiveLevelIn(
    String category, {
    required bool releaseMode,
  }) {
    final override = _categoryLevels[category];
    if (override != null) return override;
    return clampToReleaseFloor(minLevel, releaseMode: releaseMode);
  }

  /// The last few hundred records, for the in-app diagnostics view and the
  /// text a bug report carries. Null disables recording entirely.
  ///
  /// Separate from [sink], which REPLACES the output; this observes it. A
  /// record reaches the buffer whether it went to the console, to a test's
  /// capture list, or nowhere — because what the buffer is for is answering
  /// "what just happened" after the fact, and a build that routes its output
  /// somewhere else has not stopped needing that answer.
  static LogBuffer? buffer = LogBuffer();

  /// Test hook. When set, records go here INSTEAD of the console and DevTools,
  /// which keeps test output clean and assertions structural. Install it with
  /// [captureRecords] and undo it with [reset].
  @visibleForTesting
  static LogSink? sink = defaultSink;

  /// What [reset] restores [sink] to.
  ///
  /// Null in the app — records go to the console. `test/flutter_test_config.dart`
  /// sets it to a discarding sink, which is what keeps a thousand app log lines
  /// out of every test run; without this hook a `tearDown(Log.reset)` in any one
  /// test would turn the console back on for every test after it.
  @visibleForTesting
  static LogSink? defaultSink;

  /// Route records into the returned (initially empty) list.
  @visibleForTesting
  static List<LogRecord> captureRecords() {
    final records = <LogRecord>[];
    sink = records.add;
    return records;
  }

  /// Restore the shipped defaults. Call from `tearDown`.
  @visibleForTesting
  static void reset() {
    sink = defaultSink;
    minLevel = _defaultMinLevel;
    _categoryLevels.clear();
    buffer?.clear();
  }

  static void _dispatch(LogRecord record) {
    buffer?.add(record);
    final installed = sink;
    if (installed != null) {
      installed(record);
      return;
    }
    debugPrint(record.format());
    developer.log(
      record.message,
      time: record.time,
      level: record.level.developerLevel,
      name: record.category,
      error: record.error,
      stackTrace: record.stackTrace,
    );
  }
}

/// The most recent records, kept in memory so the app can show what just
/// happened and a bug report can carry it.
///
/// This exists because [debugPrint] reaches a desktop console and nothing
/// else. The failures this app is actually about — a device that answers
/// discovery and refuses control, a scan that comes back empty on a segment
/// that provably has robots on it — happen on somebody's phone, on their LAN,
/// and every line explaining why has been going nowhere.
///
/// Bounded and oldest-dropped: a scan emits tens of lines and a long session
/// would otherwise grow without limit. [capacity] is records, not bytes, which
/// is the unit a reader thinks in.
class LogBuffer {
  final int capacity;
  final List<LogRecord> _records = [];

  LogBuffer({this.capacity = 500}) : assert(capacity > 0);

  /// Oldest first — reading order, and the order [export] writes.
  List<LogRecord> get records => List.unmodifiable(_records);

  int get length => _records.length;

  void add(LogRecord record) {
    _records.add(record);
    if (_records.length > capacity) {
      _records.removeRange(0, _records.length - capacity);
    }
  }

  void clear() => _records.clear();

  /// The buffer as text, one record per line (plus indented continuation lines
  /// for a stack trace), newest LAST.
  ///
  /// [minLevel] and [categories] narrow it the same way the viewer's filters
  /// do, so what someone copies is what they were looking at rather than
  /// everything — a report of thirty relevant lines gets read, and one of five
  /// hundred does not.
  String export({LogLevel? minLevel, Set<String>? categories}) => _records
      .where((r) => minLevel == null || r.level.index >= minLevel.index)
      .where((r) => categories == null || categories.contains(r.category))
      .map((r) => r.format())
      .join('\n');
}

/// What a redacted secret renders as.
const String redactedText = '<redacted>';

/// Renders a secret's *presence* without its value: `<redacted>` when there is
/// one, `<none>` when there isn't.
///
/// "Is a token even stored?" is the diagnostically useful bit, and it is the
/// only bit that is safe to say.
String redact(Object? secret) => secret == null ? '<none>' : redactedText;

/// Masks every occurrence of each of [secrets] inside [text].
///
/// For the case where a message is assembled from something that may have had
/// a secret spliced into it (a URL with a token query parameter, a server
/// response echoing a header). Null and empty secrets are skipped — an empty
/// one would otherwise match at every position.
String redactAll(String text, Iterable<String?> secrets) {
  var out = text;
  for (final secret in secrets) {
    if (secret == null || secret.isEmpty) continue;
    out = out.replaceAll(secret, redactedText);
  }
  return out;
}

/// [uri] reduced to scheme, host, port and path — the part worth logging.
///
/// A URL is the other place a credential hides in plain sight: `userInfo`
/// (`https://user:pass@host/`) and query parameters (`?token=...`) both travel
/// in one, and a user-supplied URL (the spec-pack manifest) can carry either.
String logSafeUrl(Uri uri) => Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: uri.path,
    ).toString();

/// The runtime type of [error] and nothing else.
///
/// For logging a failure whose *value* may embed secret input. The motivating
/// case: `jsonDecode` of the stored HA config throws a [FormatException] whose
/// `toString()` quotes a window of the source — i.e. part of the long-lived
/// access token. The type still says what went wrong; the message cannot be
/// trusted not to say too much.
String errorType(Object? error) =>
    error == null ? 'null' : error.runtimeType.toString();

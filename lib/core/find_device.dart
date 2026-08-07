// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

// Pure logic behind the Find Device view: RSSI tracking/smoothing, the
// distance guess derived from it, and detection of "make the device
// noticeable" actions (beep / blink) from a matched spec or the standard
// Immediate Alert service. Kept free of I/O so it can be unit-tested
// exhaustively.

import 'dart:math' as math;

import '../models/ble_discovered_service.dart';
import '../services/spec_codec.dart';
import 'hex.dart';

/// Assumed RSSI at 1 m, in dBm. Advertised BLE beacons calibrate this per
/// device; generic peripherals don't, so this is the widely used default.
const double kDefaultMeasuredPower = -59;

/// Log-distance path-loss exponent: 2.0 is free space, 3.0+ a cluttered
/// building. 2.5 splits the difference for "indoors, some furniture".
const double kDefaultPathLossExponent = 2.5;

/// Guess the distance to a device from its RSSI via the log-distance
/// path-loss model: `d = 10 ^ ((measuredPower - rssi) / (10 * n))`.
///
/// The result is a *rough hint*, not a measurement — walls, bodies, and
/// antenna orientation shift RSSI by more than the model's whole signal.
/// Callers must present it as approximate (see [formatApproxDistance]).
double estimateDistanceMeters(
  double rssi, {
  double measuredPower = kDefaultMeasuredPower,
  double pathLossExponent = kDefaultPathLossExponent,
}) =>
    math.pow(10, (measuredPower - rssi) / (10 * pathLossExponent)).toDouble();

/// Render a distance guess honestly: one decimal under 10 m, whole meters to
/// 20 m, and a flat "20+ m" beyond — the model has no meaningful resolution
/// out there, and printing "43.7 m" would claim precision it doesn't have.
String formatApproxDistance(double meters) {
  if (meters >= 20) return '20+ m';
  if (meters >= 10) return '≈ ${meters.round()} m';
  return '≈ ${meters.toStringAsFixed(1)} m';
}

/// Qualitative bucket for a distance guess. Buckets are what the guess is
/// actually good for — "same room or not" survives the model's error bars
/// where "3.2 m" does not.
String proximityLabel(double meters) {
  if (meters < 0.7) return 'Right here';
  if (meters < 2.5) return 'Very close';
  if (meters < 6) return 'Same room';
  if (meters < 15) return 'Nearby';
  return 'Far away';
}

/// Map an RSSI to 0..1 for gauges: -100 dBm (about the BLE sensitivity
/// floor) is 0, -30 dBm (touching the antenna) is 1.
double signalFraction(double rssi) => ((rssi + 100) / 70).clamp(0.0, 1.0);

/// Direction the signal is moving, for hot/cold guidance.
enum RssiTrend { closer, farther, steady }

/// Accumulates RSSI samples for one find session: latest/extremes for the
/// raw readout, an exponential moving average that feeds the distance guess
/// (a single raw RSSI jumps several dBm between reads), and a bounded
/// history for the sparkline.
class RssiTracker {
  /// Smoothing factor for the moving average. 0.35 follows a genuine move
  /// within ~3 samples while flattening single-sample jitter.
  static const double emaAlpha = 0.35;

  /// Raw samples kept for the sparkline/trend. ~30 seconds at one read per
  /// second — enough to see a walk's effect without unbounded growth.
  static const int historyCapacity = 30;

  /// Newest samples considered by [trend].
  static const int trendWindow = 8;

  /// dBm the halves of the trend window must differ by before the trend
  /// leaves [RssiTrend.steady] — below this, it's indistinguishable from
  /// standing-still jitter.
  static const double trendThresholdDbm = 2.0;

  final List<int> _history = [];
  double? _smoothed;
  int? _min;
  int? _max;
  int _count = 0;

  /// Record one raw RSSI reading.
  void add(int rssi) {
    _count += 1;
    _history.add(rssi);
    if (_history.length > historyCapacity) _history.removeAt(0);
    final prev = _smoothed;
    _smoothed = prev == null
        ? rssi.toDouble()
        : emaAlpha * rssi + (1 - emaAlpha) * prev;
    _min = _min == null ? rssi : math.min(_min!, rssi);
    _max = _max == null ? rssi : math.max(_max!, rssi);
  }

  bool get hasSamples => _count > 0;
  int get sampleCount => _count;
  int? get latest => _history.isEmpty ? null : _history.last;
  double? get smoothed => _smoothed;

  /// Weakest reading seen this session (most negative dBm).
  int? get weakest => _min;

  /// Strongest reading seen this session (least negative dBm).
  int? get strongest => _max;

  /// Recent raw samples, oldest first, capped at [historyCapacity].
  List<int> get history => List.unmodifiable(_history);

  /// Distance guess from the smoothed RSSI, or null before the first sample.
  double? get estimatedDistanceMeters {
    final s = _smoothed;
    return s == null ? null : estimateDistanceMeters(s);
  }

  /// Compare the older and newer halves of the recent window. Averaging
  /// halves (rather than first-vs-last) keeps one outlier sample from
  /// flipping the arrow the user is steering by.
  RssiTrend get trend {
    final window = _history.length <= trendWindow
        ? _history
        : _history.sublist(_history.length - trendWindow);
    if (window.length < 4) return RssiTrend.steady;
    final half = window.length ~/ 2;
    final olderAvg = window.take(half).reduce((a, b) => a + b) / half;
    final newerAvg =
        window.skip(half).reduce((a, b) => a + b) / (window.length - half);
    final delta = newerAvg - olderAvg;
    if (delta >= trendThresholdDbm) return RssiTrend.closer;
    if (delta <= -trendThresholdDbm) return RssiTrend.farther;
    return RssiTrend.steady;
  }
}

/// What an alert action does on the device, for icon/grouping choices.
enum FindAlertKind { sound, flash, alert }

/// One "make the device noticeable" action the Find view can offer: either a
/// spec-declared command (encoded through the codec) or a raw write to the
/// standard Immediate Alert characteristic.
class FindAlertAction {
  final FindAlertKind kind;
  final String label;
  final String serviceUuid;
  final String charUuid;

  /// Spec command to encode and write; set together with [specYaml].
  final String? commandName;

  /// Spec YAML the command encodes against; set together with [commandName].
  final String? specYaml;

  /// Raw bytes to write, when the action doesn't come from a spec command
  /// (the standard Immediate Alert level).
  final List<int>? bytes;

  /// Raw bytes that stop the alert, when the device supports stopping it.
  final List<int>? stopBytes;

  const FindAlertAction({
    required this.kind,
    required this.label,
    required this.serviceUuid,
    required this.charUuid,
    this.commandName,
    this.specYaml,
    this.bytes,
    this.stopBytes,
  });
}

/// Standard Immediate Alert service (0x1802) and its Alert Level
/// characteristic (0x2A06) — the SIG-defined "make yourself noticeable"
/// mechanism used by key finders and fitness bands. Writing 2 requests the
/// high alert (buzzer and/or LED, device's choice); 0 stops it.
const String immediateAlertServiceUuid = '00001802-0000-1000-8000-00805f9b34fb';
const String alertLevelCharUuid = '00002a06-0000-1000-8000-00805f9b34fb';
const int _highAlertLevel = 0x02;
const int _noAlertLevel = 0x00;

// Command-name tokens that mark a spec command as an alert trigger. Matching
// is on whole `_`-separated tokens, not substrings, so `ring` can't hide in
// `bring`. The token lists were calibrated against the vendored spec
// catalogue — e.g. bare `play`/`music` are NOT sound tokens because the
// catalogue uses them for LED effect players (`play_program`, `music_start`),
// and `identify` is excluded because the OBD2 spec's `identify` is a version
// query, not a locator flash.
const Set<String> _soundTokens = {
  'beep', 'buzz', 'buzzer', 'chime', 'ring', 'siren', 'tone', 'whistle',
  'sound', 'alarm', //
};
const Set<String> _flashTokens = {'blink', 'flash', 'strobe'};
const Set<String> _findTokens = {'find', 'locate', 'alert'};

/// Tokens that mean the command STOPS or mutes an alert (`silence_alarm`)
/// rather than raising one — offering those as "make it noticeable" buttons
/// would do the opposite of what the label promises.
const Set<String> _negatingTokens = {
  'off', 'stop', 'silence', 'mute', 'disable', 'cancel', 'end', 'exit',
  'clear', //
};

/// Tokens that mark a command as far too dangerous to hide behind a find
/// button even when a positive token also matches (`flash_firmware` contains
/// `flash`; it must never be one tap away).
const Set<String> _dangerTokens = {
  'firmware', 'ota', 'dfu', 'boot', 'bootloader', 'factory', 'reset', 'erase',
  'format', 'unpair', 'password', //
};

/// Classify a spec command name as an alert trigger, or null when it isn't
/// one. Exposed for tests; [detectAlertActions] applies it to full specs.
FindAlertKind? classifyAlertCommand(String commandName) {
  final tokens = commandName
      .toLowerCase()
      .split(RegExp(r'[_\-\s]+'))
      .where((t) => t.isNotEmpty)
      .toSet();
  if (tokens.any(_dangerTokens.contains)) return null;
  if (tokens.any(_negatingTokens.contains)) return null;
  // Find-me style commands often also name the mechanism ("alarm", "buzz");
  // the find kind wins because that's the user intent they encode.
  if (tokens.any(_findTokens.contains)) return FindAlertKind.alert;
  if (tokens.any(_soundTokens.contains)) return FindAlertKind.sound;
  if (tokens.any(_flashTokens.contains)) return FindAlertKind.flash;
  return null;
}

/// Detect every alert action this device supports, from two sources:
///
/// 1. **Spec commands** — fixed, encodable commands whose name says they make
///    the device beep/blink (see [classifyAlertCommand]). Detection is
///    transport-agnostic: it reads the spec, so it lights up for any protocol
///    a spec describes — today's BLE devices now, Wi-Fi devices once the app
///    grows a Wi-Fi transport. The command's characteristic must also have
///    been *discovered* on this device (writable), because a spec may
///    describe a bigger variant than the unit in front of us.
/// 2. **The standard Immediate Alert service**, when discovery found it with
///    a writable Alert Level — no spec needed. Skipped when a spec command
///    already targets that characteristic (the spec knows the device's
///    dialect better than the generic profile does).
List<FindAlertAction> detectAlertActions({
  DeviceSpecDto? spec,
  String? specYaml,
  required List<BleDiscoveredService> services,
}) {
  final actions = <FindAlertAction>[];

  // Writable discovered characteristics, keyed by normalized UUID pair.
  final writable = <String, ({String serviceUuid, String charUuid})>{};
  for (final service in services) {
    for (final char in service.characteristics) {
      if (!char.canWrite) continue;
      writable[normalizeUuid(char.uuid)] =
          (serviceUuid: service.uuid, charUuid: char.uuid);
    }
  }

  if (spec != null && specYaml != null) {
    for (final specService in spec.services) {
      for (final specChar in specService.characteristics) {
        final discovered = writable[normalizeUuid(specChar.uuid)];
        if (discovered == null) continue;
        for (final command in specChar.commands) {
          // Only parameterless commands: a find button must be a single tap,
          // and defaulting parameters would send values the spec author never
          // blessed as "the alert".
          if (!command.isFixed || !command.isEncodable) continue;
          final kind = classifyAlertCommand(command.name);
          if (kind == null) continue;
          actions.add(FindAlertAction(
            kind: kind,
            label: humanLabelForCommand(command.name),
            serviceUuid: discovered.serviceUuid,
            charUuid: discovered.charUuid,
            commandName: command.name,
            specYaml: specYaml,
          ));
        }
      }
    }
  }

  final alertLevel = writable[alertLevelCharUuid];
  final specCoversAlertLevel =
      actions.any((a) => normalizeUuid(a.charUuid) == alertLevelCharUuid);
  if (alertLevel != null && !specCoversAlertLevel) {
    actions.add(FindAlertAction(
      kind: FindAlertKind.alert,
      label: 'Ring alert',
      serviceUuid: alertLevel.serviceUuid,
      charUuid: alertLevel.charUuid,
      bytes: const [_highAlertLevel],
      stopBytes: const [_noAlertLevel],
    ));
  }

  return actions;
}

/// `find_me` → `Find me`, `blink_led` → `Blink LED`. The all-caps fixups
/// cover initialisms common in command names that plain sentence-casing
/// would render as words.
String humanLabelForCommand(String raw) {
  final words = raw
      .split(RegExp(r'[_\-\s]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => const {'led': 'LED', 'rgb': 'RGB'}[w.toLowerCase()] ?? w)
      .toList();
  if (words.isEmpty) return raw;
  final joined = words.join(' ');
  return joined[0].toUpperCase() + joined.substring(1);
}

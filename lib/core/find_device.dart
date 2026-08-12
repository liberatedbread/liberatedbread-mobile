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
import 'value_format.dart';

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
///
/// Both boundaries are tested on the *rounded* value rather than the raw one,
/// so a distance never renders in a band it doesn't belong to: 9.96 would
/// print "≈ 10.0 m" (a decimal above the decimal cutoff) and 19.7 would print
/// "≈ 20 m" — indistinguishable from the "20+ m" cap that exists precisely to
/// say "no resolution here", so a dBm of jitter would flip the headline
/// between a precise-looking number and the cap.
String formatApproxDistance(double meters) {
  if (meters.round() >= 20) return '20+ m';
  if (double.parse(meters.toStringAsFixed(1)) >= 10) {
    return '≈ ${meters.round()} m';
  }
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

/// RSSI reduced to a four-step strength band, 1 (weakest) to 4.
///
/// Two callers, and they must agree: it is what the scan list's signal meter
/// draws, and what that list SORTS by. Ordering on the raw dBm looks more
/// precise and is worse — a continuous scan reports a device many times a
/// second and the reading wanders several dB while nothing moves, so two rows
/// within a few dB of each other trade places continuously and a tap lands on
/// whichever one arrived last. Ordering by band, and settling ties by
/// something that does not move, keeps the list still enough to touch.
///
/// The bands are wide for the same reason [proximityLabel]'s are: 10 dB is
/// about the resolution this measurement honestly has indoors.
int signalBars(int rssi) {
  if (rssi >= -60) return 4;
  if (rssi >= -70) return 3;
  if (rssi >= -80) return 2;
  return 1;
}

/// Direction the signal is moving, for hot/cold guidance. [unknown] means
/// too few samples to say — distinct from [steady], which is a real verdict
/// ("you are standing still") the UI must not fabricate from two readings.
enum RssiTrend { closer, farther, steady, unknown }

/// Plausible RSSI range for a live BLE link, in dBm. A connected peripheral
/// reads somewhere between about -100 (sensitivity floor) and -20 (touching
/// the antenna); 0 and the SIG's 127 "RSSI unavailable" sentinel are not
/// signal strengths.
const int kMinPlausibleRssi = -127;
const int kMaxPlausibleRssi = -1;

/// Whether [rssi] can be a real reading rather than a backend's stand-in for
/// "no value".
///
/// This is not defensive padding: flutter_blue_plus_linux answers `readRssi`
/// from BlueZ's cached advertisement property and reports `success: true`
/// with `rssi: 0` when that property is absent (which it is for a connected
/// peripheral that stopped advertising), and the Android/Darwin plugins
/// forward a controller-reported 127 with a success status. Both would
/// otherwise render as a confident "≈ 0.0 m / Right here" that never
/// resolves, because a successful read resets the failure counter.
bool isPlausibleRssi(int rssi) =>
    rssi >= kMinPlausibleRssi && rssi <= kMaxPlausibleRssi;

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

  /// Forget every sample, returning the tracker to its just-constructed
  /// state. Called when polling restarts after a signal loss: the readings
  /// either side of that gap describe different places (and possibly minutes
  /// apart), so blending them would show a pre-loss distance as if live and
  /// point the trend arrow the wrong way while the user walks.
  void reset() {
    _history.clear();
    _smoothed = null;
    _min = null;
    _max = null;
    _count = 0;
  }

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
    if (window.length < 4) return RssiTrend.unknown;
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

// FALLBACK ONLY, for specs that do not declare `locate`.
//
// A spec command can now say outright that it is a locator, and
// [classifyAlertCommand] reads that first — see [locateAlertKind]. Everything
// below is what happens when nobody said: guess from the name.
//
// The guess is kept because spec packs update on their own schedule and the
// declaration is new, but it is a poor substitute and the size of these lists
// is the evidence. Across the 350 BLE commands in the vendored catalogue the
// positive tokens match three, and four of the six sets below exist purely to
// take matches away again — `set_flash_count` configures, `silence_alarm`
// negates, `get_alarm_mode` queries, `flash_firmware` must never be one tap
// from a user. A declared `locate` needs none of that machinery, because the
// author knows which of those their command is.
//
// Matching is on whole `_`-separated tokens, not substrings, so `ring` can't
// hide in `bring`. The token lists were calibrated against the vendored spec
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

/// Tokens that mark a command as a settings/status QUERY, e.g. a
/// `get_alarm_mode` whose `alarm` token describes what is being *read back*
/// rather than an alert being raised. Pressing such a command would quietly
/// fetch state instead of making the device noticeable.
///
/// Checked AFTER [_findTokens] on purpose: a name that says both ("find" and
/// "status") is a locator that happens to mention a query word, and the find
/// intent is the one the author encoded.
const Set<String> _queryTokens = {
  'get', 'query', 'read', 'request', 'status', 'check', 'poll', 'report',
  'fetch', //
};

/// Tokens that mark a command as *configuring* an alert rather than raising
/// one (`set_alarm`, `alarm_enable`, `set_flash_count`). These write
/// persistent device settings, so surfacing them under "make it noticeable"
/// would silently reconfigure the device instead of locating it.
const Set<String> _configureTokens = {
  'set', 'config', 'configure', 'mode', 'level', 'threshold', 'enable',
  'default', 'duration', 'count', 'speed', 'color', 'colour', 'brightness', //
};

/// Tokens that mark a command as far too dangerous to hide behind a find
/// button even when a positive token also matches (`flash_firmware` contains
/// `flash`; it must never be one tap away).
const Set<String> _dangerTokens = {
  'firmware', 'ota', 'dfu', 'boot', 'bootloader', 'factory', 'reset', 'erase',
  'format', 'unpair', 'password', //
};

/// The kind a spec's own `locate` declaration names, or null when the command
/// does not declare one (or names a value this build does not know).
///
/// `both` becomes [FindAlertKind.alert] — the same "device's choice of buzzer
/// and/or LED" the SIG's high alert level means, which is why the two share a
/// kind rather than each having their own.
FindAlertKind? locateAlertKind(String? locate) => switch (locate) {
      'sound' => FindAlertKind.sound,
      'flash' => FindAlertKind.flash,
      'both' => FindAlertKind.alert,
      _ => null,
    };

/// Classify a spec command as an alert trigger, or null when it isn't one.
///
/// [locate] is the command's own declaration and settles it outright when
/// present: the spec author knows whether `blink_led` locates the device or
/// `set_mode` (whose mode 2 is "blink") configures it, and no amount of
/// reading the name can. Only when nothing was declared does this fall back to
/// [classifyAlertCommandByName].
///
/// Exposed for tests; [detectAlertActions] applies it to full specs.
FindAlertKind? classifyAlertCommand(String commandName, {String? locate}) {
  // The one thing a declaration does not get to override. A `locate` on a
  // command whose name says `firmware`/`dfu`/`erase` is either a mistake or a
  // hostile spec pack, and the cost of being wrong is asymmetric: refusing a
  // real locator loses a convenience button, honouring a fake one puts a
  // firmware wipe one tap away with no confirmation. The schema forbids
  // `locate` on an `advanced` command, but a third-party pack is not obliged
  // to have run the schema.
  if (_tokensOf(commandName).any(_dangerTokens.contains)) return null;
  return locateAlertKind(locate) ?? classifyAlertCommandByName(commandName);
}

/// A command name split into whole `_`/`-`/space-separated tokens.
Set<String> _tokensOf(String commandName) => commandName
    .toLowerCase()
    .split(RegExp(r'[_\-\s]+'))
    .where((t) => t.isNotEmpty)
    .toSet();

/// The name-based guess. See the token lists above for why it is a fallback
/// rather than the rule.
FindAlertKind? classifyAlertCommandByName(String commandName) {
  final tokens = _tokensOf(commandName);
  if (tokens.any(_dangerTokens.contains)) return null;
  if (tokens.any(_negatingTokens.contains)) return null;
  // Find-me style commands often also name the mechanism ("alarm", "buzz")
  // or a query word ("find_status"); the find kind wins because that's the
  // user intent they encode. Checked BEFORE the query/configure filters so
  // those can't veto an explicit locator.
  if (tokens.any(_findTokens.contains)) return FindAlertKind.alert;
  if (tokens.any(_queryTokens.contains)) return null;
  if (tokens.any(_configureTokens.contains)) return null;
  if (tokens.any(_soundTokens.contains)) return FindAlertKind.sound;
  if (tokens.any(_flashTokens.contains)) return FindAlertKind.flash;
  return null;
}

/// Detect every alert action this device supports, from two sources:
///
/// 1. **Spec commands** — fixed, encodable commands the spec declares as
///    locators, or failing that whose name says they make the device
///    beep/blink (see [classifyAlertCommand]). The command's
///    characteristic must also have been *discovered* on this device
///    (writable), because a spec may describe a bigger variant than the unit
///    in front of us. This resolves against GATT endpoints, so it is BLE-only:
///    a Wi-Fi spec's `http_endpoints`/`mqtt_topics` do not cross the FFI at
///    all today, and lighting these buttons up for one would need both that
///    and a transport-neutral endpoint type here.
/// 2. **The standard Immediate Alert service**, when discovery found it with
///    a writable Alert Level — no spec needed. Skipped when a spec command
///    already targets that characteristic (the spec knows the device's
///    dialect better than the generic profile does).
/// The normalized `service|characteristic` key both write-admission maps use.
String discoveredPairKey(String serviceUuid, String charUuid) =>
    '${normalizeUuid(serviceUuid)}|${normalizeUuid(charUuid)}';

/// Writable discovered characteristics, keyed by the normalized
/// service|characteristic UUID pair. The pair matters: the same
/// characteristic UUID can appear under several services (vendor channels
/// reuse 0xFFE1-style UUIDs), and an action must write to the service the
/// spec — or the standard profile — actually names, not whichever duplicate
/// discovery happened to list last. Shared by [detectAlertActions] and the
/// group write path so the admission rule cannot drift between them.
Map<String, ({String serviceUuid, String charUuid})> discoveredWritablePairs(
  List<BleDiscoveredService> services,
) {
  final writable = <String, ({String serviceUuid, String charUuid})>{};
  for (final service in services) {
    for (final char in service.characteristics) {
      if (!char.canWrite) continue;
      writable[discoveredPairKey(service.uuid, char.uuid)] =
          (serviceUuid: service.uuid, charUuid: char.uuid);
    }
  }
  return writable;
}

List<FindAlertAction> detectAlertActions({
  DeviceSpecDto? spec,
  String? specYaml,
  required List<BleDiscoveredService> services,
}) {
  final actions = <FindAlertAction>[];

  final writable = discoveredWritablePairs(services);

  if (spec != null && specYaml != null) {
    for (final specService in spec.services) {
      for (final specChar in specService.characteristics) {
        final discovered =
            writable[discoveredPairKey(specService.uuid, specChar.uuid)];
        if (discovered == null) continue;
        for (final command in specChar.commands) {
          // Only parameterless commands: a find button must be a single tap,
          // and defaulting parameters would send values the spec author never
          // blessed as "the alert".
          if (!command.isFixed || !command.isEncodable) continue;
          final kind =
              classifyAlertCommand(command.name, locate: command.locate);
          if (kind == null) continue;
          actions.add(FindAlertAction(
            kind: kind,
            label: humanizeName(command.name),
            serviceUuid: discovered.serviceUuid,
            charUuid: discovered.charUuid,
            commandName: command.name,
            specYaml: specYaml,
          ));
        }
      }
    }
  }

  // Only the Alert Level under the Immediate Alert service itself: 0x2A06
  // hanging off some unrelated service is not the standard profile, and
  // writing alert levels there would hit an unknown endpoint.
  final alertLevel = writable[
      discoveredPairKey(immediateAlertServiceUuid, alertLevelCharUuid)];
  final specCoversAlertLevel = actions.any((a) =>
      discoveredPairKey(a.serviceUuid, a.charUuid) ==
      discoveredPairKey(immediateAlertServiceUuid, alertLevelCharUuid));
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

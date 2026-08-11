// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

// Helpers for rendering typed device-spec controls and decoded values.

/// Initialisms that plain sentence-casing would render as words. Kept here so
/// every surface spells a command the same way — a label that reads "Blink
/// LED" on one screen and "Blink led" on another looks like two commands.
const Map<String, String> _initialisms = {
  'led': 'LED',
  'rgb': 'RGB',
  'uuid': 'UUID',
  'mtu': 'MTU',
  'id': 'ID',
};

/// Turn a spec identifier like `set_brightness` into a human label
/// `Set brightness`, fixing up initialisms (`blink_led` → `Blink LED`).
String humanizeName(String raw) {
  final words = raw
      .split(RegExp(r'[_\-\s]+'))
      .where((w) => w.isNotEmpty)
      .map((w) => _initialisms[w.toLowerCase()] ?? w)
      .toList();
  if (words.isEmpty) return raw;
  final joined = words.join(' ');
  return joined[0].toUpperCase() + joined.substring(1);
}

/// Inclusive numeric range for a spec value type. Honors the explicit bounds
/// from the spec when present, otherwise falls back to the natural range of the
/// type. Unknown types fall back to a single byte (0..255).
///
/// The returned range is always well-ordered (`min < max`). Specs may be loaded
/// from untrusted remote packs, so a malformed or degenerate bound (`min >= max`,
/// e.g. min > max, or both equal) is rejected in favor of the type's natural
/// range rather than being passed through — otherwise Slider/clamp callers would
/// assert or divide by zero on a zero-width range.
({double min, double max}) rangeFor(
    String valueType, double? min, double? max) {
  final typeRange = switch (valueType) {
    'bool' => (min: 0.0, max: 1.0),
    'uint8' => (min: 0.0, max: 255.0),
    'uint16' => (min: 0.0, max: 65535.0),
    'uint32' => (min: 0.0, max: 4294967295.0),
    'int8' => (min: -128.0, max: 127.0),
    'int16' => (min: -32768.0, max: 32767.0),
    'int32' => (min: -2147483648.0, max: 2147483647.0),
    _ => (min: 0.0, max: 255.0),
  };
  final resolvedMin = min ?? typeRange.min;
  final resolvedMax = max ?? typeRange.max;
  // A degenerate/inverted range from a malformed spec falls back to the type's
  // natural range, which is guaranteed well-ordered.
  if (resolvedMin >= resolvedMax) return typeRange;
  return (min: resolvedMin, max: resolvedMax);
}

/// Most discrete stops a slider is given before it reads better as a
/// continuous one. Also a ceiling on what a spec can ask the UI to build: a
/// `uint32` setpoint stepped by 1 would otherwise request 4.3 billion
/// divisions.
const int maxSliderDivisions = 255;

/// Slider divisions for an integer range, or null for a degenerate range or one
/// wide enough that a continuous slider reads better.
int? divisionsFor(double min, double max) => divisionsForStep(min, max, 1);

/// Slider divisions for `min..max` in increments of [step] — the device's real
/// resolution, so the control can only land on values it can actually hold.
///
/// Null for a degenerate range, a non-positive step, or a stop count past
/// [maxSliderDivisions]; the caller then gets a continuous slider, which is
/// the honest rendering when the steps are finer than the screen.
int? divisionsForStep(double min, double max, double step) {
  if (!step.isFinite || step <= 0) return null;
  final span = max - min;
  if (!span.isFinite || span <= 0) return null;
  final count = (span / step).round();
  if (count <= 0 || count > maxSliderDivisions) return null;
  return count;
}

/// [value] snapped to the nearest `min + n * step`, clamped to `[min, max]`.
///
/// A slider under [maxSliderDivisions] stops snaps through its divisions; a
/// wider range renders continuous, and without this its drag lands on values
/// the device cannot hold — the card would label 523.4 while the write path
/// rounds to 523, so the value shown and the value stored disagree. Snapping
/// the drag keeps the display honest for any range width. Values that cannot
/// be snapped (non-finite input or step) pass through unchanged.
double snapToStep(double value, double min, double max, double step) {
  if (!value.isFinite || !step.isFinite || step <= 0) return value;
  if (!min.isFinite || !max.isFinite || max <= min) return value;
  final snapped = min + ((value - min) / step).round() * step;
  return snapped.clamp(min, max);
}

/// The display-space value for a raw parameter value, given the spec's
/// presentation transform: `display = raw * scale + valueOffset`.
///
/// A spec's `min`/`max` bound the RAW wire value (what the encoder validates
/// against), while `scale`/`valueOffset`/`unit` are presentation metadata —
/// a treadmill speed is wire-units with `scale: 0.1`, `unit: km/h`, and the
/// user thinks in km/h. Null scale/offset mean the identity transform, so
/// callers can pass DTO fields straight through.
double displayValueFor(double raw, double? scale, double? valueOffset) =>
    raw * (scale ?? 1) + (valueOffset ?? 0);

/// The inverse of [displayValueFor]: the raw value a display-space choice
/// encodes to.
///
/// A zero scale has no inverse (every raw value collapses to one display
/// value); a spec declaring one is malformed, and callers must guard rather
/// than divide by it.
double rawValueFor(double display, double? scale, double? valueOffset) =>
    (display - (valueOffset ?? 0)) / (scale ?? 1);

/// How many fraction digits a step of [step] needs to print without loss:
/// 0.5 steps show "56.5", 0.01 steps "3.14", whole steps "60". Used wherever
/// a control labels values snapped to that step, so the text neither implies
/// a precision the control cannot land on nor hides one it can. Non-positive
/// or non-finite steps format as whole numbers.
int decimalsForStep(double step) {
  if (!step.isFinite || step <= 0) return 0;
  var decimals = 0;
  var scaled = step;
  while (decimals < 6 && (scaled - scaled.roundToDouble()).abs() > 1e-9) {
    scaled *= 10;
    decimals++;
  }
  return decimals;
}

/// A well-ordered `[min, max]` for a setpoint slider, or null when the spec
/// does not bound the value usably.
///
/// Specs load from arbitrary remote pack URLs and the Rust parser validates
/// command *parameter* bounds, not entity `min`/`max` — so an inverted or
/// degenerate pair reaches the UI intact. It must not reach `Slider`, whose
/// `min <= max` is an assert, or `num.clamp`, which throws on an inverted
/// range. Returning null drops the caller to its unbounded control instead,
/// which says "we cannot draw a range for this" rather than crashing the
/// panel. Same philosophy as [rangeFor], one layer up.
///
/// An inverted pair is not only a hostile-spec case: an entity may declare
/// `min` alone in decoded units while the fallback `max` comes from the bound
/// field's raw type range mapped through a scale below 1, which lands the two
/// on opposite sides.
({double min, double max})? setpointRange(double? min, double? max) {
  if (min == null || max == null) return null;
  if (!min.isFinite || !max.isFinite || min >= max) return null;
  return (min: min, max: max);
}

/// Whether [valueType] is a numeric spec type a slider can honestly input.
/// `string`/`bytes` (and any unrecognized type) have no meaningful numeric
/// range, so controls for them must not pretend a 0..255 slider is valid.
bool isNumericValueType(String valueType) => switch (valueType) {
      'uint8' || 'uint16' || 'uint32' || 'int8' || 'int16' || 'int32' => true,
      _ => false,
    };

/// Display text for one entry of an enumerated `allowed` parameter:
/// `"Label (value)"` when the spec pairs a label with the value, or just the
/// raw value otherwise. Keeping the wire value visible next to the label
/// means the picker never hides what will actually be sent to the device.
///
/// [value] is `Object` because allowed values cross the FFI as
/// flutter_rust_bridge's `Int64List`, whose elements are [BigInt]; both
/// [BigInt] and [int] render the same way here. A null or empty label falls
/// back to the raw value.
String allowedEntryLabel(String? label, Object value) =>
    (label == null || label.isEmpty) ? '$value' : '$label ($value)';

/// A short, glanceable span: `"12s"`, `"4m"`, `"2h"`.
///
/// Deliberately coarser than a clock and blunter than [relativeTime] in
/// saved_devices_screen.dart, whose smallest step is "Just now" — useless for a
/// scan list, where the interesting question is whether a device went quiet
/// twenty seconds ago or twenty minutes ago. Sub-second spans round up to
/// `"0s"` rather than being written out in milliseconds; nothing here is
/// measuring anything that fast.
String shortAge(Duration age) {
  if (age.inMinutes < 1) return '${age.inSeconds.clamp(0, 59)}s';
  if (age.inHours < 1) return '${age.inMinutes}m';
  if (age.inDays < 1) return '${age.inHours}h';
  return '${age.inDays}d';
}

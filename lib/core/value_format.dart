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

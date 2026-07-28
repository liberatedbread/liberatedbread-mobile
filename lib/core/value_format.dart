// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

// Helpers for rendering typed device-spec controls and decoded values.

/// Turn a spec identifier like `set_brightness` into a human label
/// `Set brightness`.
String humanizeName(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[_\-]+'), ' ').trim();
  if (cleaned.isEmpty) return raw;
  return cleaned[0].toUpperCase() + cleaned.substring(1);
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

/// Slider divisions for an integer range, or null for a degenerate range or one
/// wide enough (> 255 steps) that a continuous slider reads better.
int? divisionsFor(double min, double max) {
  final span = (max - min).round();
  if (span <= 0 || span > 255) return null;
  return span;
}

/// Whether [valueType] is a numeric spec type a slider can honestly input.
/// `string`/`bytes` (and any unrecognized type) have no meaningful numeric
/// range, so controls for them must not pretend a 0..255 slider is valid.
bool isNumericValueType(String valueType) => switch (valueType) {
      'uint8' || 'uint16' || 'uint32' || 'int8' || 'int16' || 'int32' => true,
      _ => false,
    };

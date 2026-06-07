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
({double min, double max}) rangeFor(
    String valueType, double? min, double? max) {
  final typeRange = switch (valueType) {
    'bool' => (min: 0.0, max: 1.0),
    'uint8' => (min: 0.0, max: 255.0),
    'uint16' => (min: 0.0, max: 65535.0),
    'int8' => (min: -128.0, max: 127.0),
    'int16' => (min: -32768.0, max: 32767.0),
    _ => (min: 0.0, max: 255.0),
  };
  return (min: min ?? typeRange.min, max: max ?? typeRange.max);
}

/// Slider divisions for an integer range, or null for a degenerate range or one
/// wide enough (> 255 steps) that a continuous slider reads better.
int? divisionsFor(double min, double max) {
  final span = (max - min).round();
  if (span <= 0 || span > 255) return null;
  return span;
}

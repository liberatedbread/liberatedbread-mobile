// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

/// How a spec's unit is spelled to a reader.
///
/// The catalogue writes units as data, not as prose: a temperature field says
/// `C`, because the same string has to compare equal to the `unit_values`
/// table a device's own unit setting maps into (`{0x46: 'F', default: 'C'}`).
/// A person reading a thermometer expects `21.4 °C`, so the degree sign is put
/// back here — in the UI, where presentation belongs — rather than in the
/// spec, where it would break the comparison the tables depend on.
///
/// Only spellings whose meaning is unambiguous are translated. Anything the
/// table does not know passes through untouched: a unit this app has never
/// seen is still the spec's answer, and showing it verbatim beats hiding it.
library;

/// Spellings that differ between the catalogue's data form and a reader's.
///
/// Keyed lower-case; the value is what a person should see. Kept small and
/// literal — this is not a unit-conversion table, and nothing here changes a
/// magnitude.
const Map<String, String> _displaySpellings = {
  'c': '°C',
  'degc': '°C',
  'f': '°F',
  'degf': '°F',
  'lux': 'lx',
  'percent': '%',
  'pct': '%',
};

/// [unit] as it should appear beside a value, or null when the spec named
/// none. An empty or whitespace-only unit reads as "none", not as a unit.
String? displayUnit(String? unit) {
  if (unit == null) return null;
  final trimmed = unit.trim();
  if (trimmed.isEmpty) return null;
  return _displaySpellings[trimmed.toLowerCase()] ?? trimmed;
}

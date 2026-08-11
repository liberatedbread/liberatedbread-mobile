// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Is this reading good, fair, or poor — and is that worth saying out loud?
//
// A sensor device's whole product is a handful of numbers, and most of them
// mean nothing without a scale to stand on: nobody knows offhand whether
// 130 Bq/m³ of radon is a shrug or a ventilation project. The bands here turn
// the readings the catalogue actually produces into a three-word verdict, for
// the metrics where a healthy range is established — and stay silent for the
// ones where it is not. A temperature has no universal "good" (comfort is
// preference, not health), so a temperature gets no verdict; inventing one
// would teach users to ignore the verdicts that are real.
//
// Bands are keyed on the entity's `device_class` plus the displayed unit, the
// same two fields the spec schema says an entity must be identifiable by.
// The unit is load-bearing, not decorative: a VOC band in ppb applied to a
// VOC reading in µg/m³ would be off by the molar mass, so a class with the
// wrong unit gets no verdict rather than a wrong one.

import 'package:flutter/material.dart';

/// Verdict for a reading whose healthy range is established.
enum SensorReadingLevel { good, fair, poor }

/// The verdict for one live reading, or null when there is nothing honest to
/// say — an unbanded quantity, a missing value, or a unit the band does not
/// hold in.
///
/// Threshold sources, deliberately boring and checkable:
/// - Radon (Bq/m³): fair at 100, poor at 150. WHO's reference level is
///   100 Bq/m³; 100/150 are also the yellow/red defaults Airthings ships on
///   the Wave family (capture-verified in the vendored spec's
///   `griffin_ui_settings` notes), and the US EPA action level (4 pCi/L)
///   is ≈148. Matched on the unit alone: radon has no device class in the
///   Home Assistant vocabulary, and matching by unit also keeps older
///   catalogue copies honest — one mislabeled radon as a VOC class, and
///   Bq/m³ must never be read against a ppb band.
/// - CO₂ (ppm): fair at 800, poor at 1000 — Airthings' shipped defaults;
///   1000 ppm is also the conventional ventilation guideline ceiling.
/// - VOC (ppb): fair at 250, poor at 2000 — Airthings' shipped defaults.
/// - Humidity (%): good 30–60, fair 25–30 and 60–70, poor outside —
///   Airthings' shipped defaults (25/30/60/70), and the usual comfort/mold
///   guidance band.
/// - PM2.5 (µg/m³): fair at 10, poor at 25. WHO's 2021 guidelines sit at
///   5 annual / 15 daily; 10/25 is the common consumer banding (Airthings
///   among them) between those anchors.
/// - PM10 (µg/m³): fair at 20, poor at 50, by the same construction
///   (WHO 2021: 15 annual / 45 daily).
/// - Battery (%): fair at 20, poor at 10 — the usual OS warning rungs.
SensorReadingLevel? sensorReadingLevel({
  String? deviceClass,
  String? unit,
  double? value,
}) {
  if (value == null || !value.isFinite) return null;
  final klass = deviceClass?.trim().toLowerCase();
  final u = unit?.trim().toLowerCase();

  // Radon first, and by unit: Bq/m³ is a radioactivity concentration, which
  // pins the quantity regardless of what class a spec did or did not claim.
  if (u == 'bq/m³' || u == 'bq/m3') {
    return _lowIsGood(value, fairAt: 100, poorAt: 150);
  }

  switch (klass) {
    case 'carbon_dioxide':
      if (u != 'ppm') return null;
      return _lowIsGood(value, fairAt: 800, poorAt: 1000);
    case 'volatile_organic_compounds' || 'volatile_organic_compounds_parts':
      if (u != 'ppb') return null;
      return _lowIsGood(value, fairAt: 250, poorAt: 2000);
    case 'humidity':
      if (u != '%' && u != '%rh') return null;
      if (value < 25 || value > 70) return SensorReadingLevel.poor;
      if (value < 30 || value > 60) return SensorReadingLevel.fair;
      return SensorReadingLevel.good;
    case 'pm25':
      if (!_isMicrogramsPerCubicMetre(u)) return null;
      return _lowIsGood(value, fairAt: 10, poorAt: 25);
    case 'pm10':
      if (!_isMicrogramsPerCubicMetre(u)) return null;
      return _lowIsGood(value, fairAt: 20, poorAt: 50);
    case 'battery':
      if (u != '%') return null;
      if (value <= 10) return SensorReadingLevel.poor;
      if (value <= 20) return SensorReadingLevel.fair;
      return SensorReadingLevel.good;
    default:
      return null;
  }
}

/// Whether [level] on this reading deserves a visible verdict.
///
/// The air-quality metrics show every level: "Good" is the reassurance those
/// readings exist to give, and its absence is what makes "Poor" land. Battery
/// is the opposite — a full battery needs no praise, so only the warning
/// levels surface and a healthy battery stays a plain number.
bool sensorLevelVisible({
  String? deviceClass,
  required SensorReadingLevel level,
}) {
  if (deviceClass?.trim().toLowerCase() == 'battery') {
    return level != SensorReadingLevel.good;
  }
  return true;
}

/// The one-word verdict a card prints.
String sensorReadingLevelLabel(SensorReadingLevel level) => switch (level) {
      SensorReadingLevel.good => 'Good',
      SensorReadingLevel.fair => 'Fair',
      SensorReadingLevel.poor => 'Poor',
    };

/// Chip colors for a verdict, per theme brightness.
///
/// Hand-picked rather than pulled from the Material scheme: M3 has no
/// success/warning roles, and the app's brand seeds (bread orange, blush)
/// would land "Good" somewhere between pink and gold. Every pair holds at
/// least ~6.5:1 foreground-on-background contrast in both brightnesses,
/// comfortably above the 4.5:1 WCAG floor for small text.
({Color background, Color foreground}) sensorReadingLevelColors(
  SensorReadingLevel level,
  Brightness brightness,
) {
  final dark = brightness == Brightness.dark;
  return switch (level) {
    SensorReadingLevel.good => dark
        ? (
            background: const Color(0xFF243D28),
            foreground: const Color(0xFF9FD6A0)
          )
        : (
            background: const Color(0xFFD9EAD5),
            foreground: const Color(0xFF1E5323)
          ),
    SensorReadingLevel.fair => dark
        ? (
            background: const Color(0xFF453A0C),
            foreground: const Color(0xFFE6C868)
          )
        : (
            background: const Color(0xFFF6E8C0),
            foreground: const Color(0xFF5F4700)
          ),
    SensorReadingLevel.poor => dark
        ? (
            background: const Color(0xFF4C2320),
            foreground: const Color(0xFFF2B8B5)
          )
        : (
            background: const Color(0xFFF6DAD6),
            foreground: const Color(0xFF8C1D18)
          ),
  };
}

SensorReadingLevel _lowIsGood(
  double value, {
  required double fairAt,
  required double poorAt,
}) {
  if (value >= poorAt) return SensorReadingLevel.poor;
  if (value >= fairAt) return SensorReadingLevel.fair;
  return SensorReadingLevel.good;
}

/// The spellings of µg/m³ the catalogue and Home Assistant use between them.
bool _isMicrogramsPerCubicMetre(String? unit) => switch (unit) {
      'µg/m³' || 'µg/m3' || 'μg/m³' || 'μg/m3' || 'ug/m³' || 'ug/m3' => true,
      _ => false,
    };

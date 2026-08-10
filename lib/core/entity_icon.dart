// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Which glyph goes beside a spec-declared entity?

import 'package:flutter/material.dart';

import '../src/rust/api/device_api.dart';
import 'icons/appliance_glyphs.dart';
import 'icons/remote_glyphs.dart';
import 'icons/sensor_glyphs.dart';

/// Material glyphs for the `mdi:` names the catalogue asks for.
///
/// The spec speaks Material Design Icons, which is Home Assistant's icon set
/// and the one the whole upstream vocabulary is written against. This app
/// ships Flutter's Material Icons and no MDI font, so the two have to be
/// translated. That translation is the only thing these tables do: the spec
/// still decides *which* icon an entity gets, and a table says what that icon
/// looks like in the font we have.
///
/// The tables live one per device domain under `icons/`, and this is the only
/// line that knows about all of them. They were one map, which made this the
/// file every device branch had to edit — an air-quality branch and a TV
/// branch appending to the same twenty lines and conflicting on every rebase,
/// over entries that could never disagree. Splitting them means two such
/// branches touch disjoint files, and this merge moves once per new file
/// rather than once per glyph. `icons/README.md` says how to add one.
///
/// Deliberately not exhaustive — MDI has around 7,000 names and pulling in the
/// font to cover them would be about 1 MB for a handful of entities. An
/// unmapped name falls through to [_byDeviceClass], which is the same answer
/// the app gave before the spec could ask for anything, so a new `icon:`
/// upstream degrades to the old behaviour rather than to a blank.
const Map<String, IconData> _mdiGlyphs = {
  ...sensorGlyphs,
  ...applianceGlyphs,
  ...remoteGlyphs,
};

/// The fallback that predates entity icons: what a reading's `device_class`
/// implies. Still the answer for the overwhelming majority of entities, since
/// stating an icon is only worth it when the device class does not already
/// say the right thing.
IconData? _byDeviceClass(String? deviceClass, IconData? fallback) =>
    switch (deviceClass) {
      'temperature' => Icons.thermostat,
      'battery' => Icons.battery_full,
      'humidity' || 'moisture' => Icons.water_drop_outlined,
      // Home Assistant spells barometric readings both ways; Airthings'
      // pressure entity says `atmospheric_pressure` and was falling to the
      // anonymous sensor glyph.
      'pressure' || 'atmospheric_pressure' => Icons.speed,
      'signal_strength' => Icons.signal_cellular_alt,
      'carbon_dioxide' => Icons.co2,
      // Air-quality readings (the Airthings family: radon rides under the
      // VOC-parts class upstream, CO₂ under its own).
      'volatile_organic_compounds' ||
      'volatile_organic_compounds_parts' =>
        Icons.science_outlined,
      'pm1' || 'pm25' || 'pm10' => Icons.grain,
      'illuminance' => Icons.light_mode_outlined,
      _ => fallback,
    };

/// The icon to draw for [entity].
///
/// Resolution order is the order of specificity: the spec's own `icon` wins
/// because it is the author's statement about this exact entity, `device_class`
/// answers next because it is a statement about the *kind* of reading, and
/// [fallback] is the honest last resort.
///
/// [fallback] is the caller's "I know nothing about this one" glyph, and it
/// differs by surface: a reading with nothing else to say for itself is a
/// sensor, while a control with nothing else to say for itself is a knob. Only
/// the last step varies — a spec that names an icon gets it on every card.
///
/// Never throws and never returns null: an icon is decoration, and losing a
/// reading over one would be a poor trade.
IconData entityIcon(EntityDto entity, {IconData fallback = Icons.sensors}) =>
    entityIconFor(
        icon: entity.icon,
        deviceClass: entity.deviceClass,
        fallback: fallback)!;

/// [entityIcon] for callers holding the fields rather than a BLE [EntityDto] —
/// the network entity DTO carries the same `icon`/`device_class` pair under a
/// different type, and the resolution rule must not fork by transport.
///
/// Returns null (rather than [fallback]) when nothing resolves and no
/// [fallback] is given, so a caller that would rather show no glyph than a
/// generic one can tell the difference.
IconData? entityIconFor({
  String? icon,
  String? deviceClass,
  IconData? fallback,
}) {
  final declared = icon?.trim().toLowerCase();
  if (declared != null && declared.isNotEmpty) {
    final glyph = _mdiGlyphs[declared];
    if (glyph != null) return glyph;
  }
  return _byDeviceClass(deviceClass, fallback);
}

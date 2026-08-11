// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Which glyph goes beside a spec-declared entity?

import 'package:flutter/material.dart';

import '../src/rust/api/device_api.dart';

/// Material glyphs for the `mdi:` names the catalogue asks for.
///
/// The spec speaks Material Design Icons, which is Home Assistant's icon set
/// and the one the whole upstream vocabulary is written against. This app
/// ships Flutter's Material Icons and no MDI font, so the two have to be
/// translated. That translation is the only thing this table does: the spec
/// still decides *which* icon an entity gets, and this says what that icon
/// looks like in the font we have.
///
/// It is deliberately not exhaustive — MDI has around 7,000 names and pulling
/// in the font to cover them would be about 1 MB for a handful of entities. An
/// unmapped name falls through to [_byDeviceClass], which is the same answer
/// the app gave before the spec could ask for anything, so a new `icon:`
/// upstream degrades to the old behaviour rather than to a blank.
const Map<String, IconData> _mdiGlyphs = {
  'mdi:heat-wave': Icons.waves,
  'mdi:thermometer': Icons.thermostat,
  'mdi:battery': Icons.battery_full,
  'mdi:water-percent': Icons.water_drop_outlined,
  'mdi:gauge': Icons.speed,
  'mdi:lightbulb': Icons.lightbulb_outline,
  'mdi:fan': Icons.air_outlined,
  'mdi:power-plug': Icons.power_outlined,
  'mdi:radiator': Icons.thermostat_auto,
  'mdi:signal': Icons.signal_cellular_alt,
  // Material ships no radiation glyph, so radon gets the diffuse-particles
  // one — a gas hanging in the air, which is the true picture anyway.
  'mdi:radioactive': Icons.blur_on,
  'mdi:molecule-co2': Icons.co2,
  'mdi:water-thermometer': Icons.dew_point,
  // Airthings' ambient light reports raw counts, not lux, so its entity
  // carries an icon instead of an `illuminance` device class — same glyph
  // that class would have implied.
  'mdi:brightness-5': Icons.light_mode_outlined,
  // The remote-control vocabulary, added with the Roku spec's buttons.
  'mdi:power': Icons.power_settings_new,
  'mdi:power-off': Icons.power_off,
  'mdi:arrow-u-left-top': Icons.undo,
  'mdi:home': Icons.home_outlined,
  'mdi:chevron-up': Icons.keyboard_arrow_up,
  'mdi:chevron-down': Icons.keyboard_arrow_down,
  'mdi:chevron-left': Icons.keyboard_arrow_left,
  'mdi:chevron-right': Icons.keyboard_arrow_right,
  'mdi:replay': Icons.replay,
  // The medical asterisk is the one asterisk in the Material font, and an
  // asterisk is exactly what Roku's Options key looks like.
  'mdi:asterisk': Icons.emergency,
  'mdi:rewind': Icons.fast_rewind,
  'mdi:play-pause': Icons.play_arrow,
  'mdi:fast-forward': Icons.fast_forward,
  'mdi:volume-plus': Icons.volume_up,
  'mdi:volume-minus': Icons.volume_down,
  'mdi:volume-mute': Icons.volume_off,
  'mdi:chevron-double-up': Icons.keyboard_double_arrow_up,
  'mdi:chevron-double-down': Icons.keyboard_double_arrow_down,
  'mdi:magnify': Icons.search,
  'mdi:remote': Icons.settings_remote,
  'mdi:hdmi-port': Icons.settings_input_hdmi,
  'mdi:video-input-component': Icons.settings_input_component,
  'mdi:antenna': Icons.settings_input_antenna,
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
      'pressure' || 'atmospheric_pressure' => Icons.speed,
      'signal_strength' => Icons.signal_cellular_alt,
      'carbon_dioxide' => Icons.co2,
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

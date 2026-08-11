// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Glyphs for readings: environment, air quality, power. See README.md in this
// directory for why the tables are split by device domain.

import 'package:flutter/material.dart';

/// MDI names the sensor half of the catalogue asks for.
const Map<String, IconData> sensorGlyphs = {
  'mdi:heat-wave': Icons.waves,
  'mdi:thermometer': Icons.thermostat,
  'mdi:battery': Icons.battery_full,
  'mdi:water-percent': Icons.water_drop_outlined,
  'mdi:gauge': Icons.speed,
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
};

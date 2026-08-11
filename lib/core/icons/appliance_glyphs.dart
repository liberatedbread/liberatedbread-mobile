// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Glyphs for things that switch, heat, blow or light up. See README.md in
// this directory for why the tables are split by device domain.

import 'package:flutter/material.dart';

/// MDI names the lighting, plug and climate half of the catalogue asks for.
const Map<String, IconData> applianceGlyphs = {
  'mdi:lightbulb': Icons.lightbulb_outline,
  'mdi:fan': Icons.air_outlined,
  'mdi:power-plug': Icons.power_outlined,
  'mdi:radiator': Icons.thermostat_auto,
};

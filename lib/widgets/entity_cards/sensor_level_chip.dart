// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../../core/sensor_reading_level.dart';

/// The one-word verdict on a reading, colored by band — "Fair" where a bare
/// "934 ppm" answers a question nobody asked.
///
/// Shared presentation: the BLE sensor card and the network sensor row both
/// draw this chip, so one reading cannot wear two verdict styles depending
/// on how its device happened to connect.
class SensorLevelChip extends StatelessWidget {
  final SensorReadingLevel level;

  const SensorLevelChip({super.key, required this.level});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = sensorReadingLevelColors(level, theme.brightness);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: colors.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        sensorReadingLevelLabel(level),
        style: theme.textTheme.labelSmall?.copyWith(
          color: colors.foreground,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../../core/health_reference.dart';
import '../../core/sensor_reading_level.dart';
import '../../core/web_link.dart';
import '../../models/health_measurement_plan.dart';

class HealthReferenceGuidance extends StatelessWidget {
  final HealthMeasurementKind kind;
  final HealthReferenceRow nih;
  final HealthReferenceRow? manufacturer;
  final LinkLauncher launcher;

  const HealthReferenceGuidance({
    super.key,
    required this.kind,
    required this.nih,
    this.manufacturer,
    this.launcher = launchExternally,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Reference categories',
          style: text.labelMedium?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        _CategoryLine(source: 'NIH', row: nih),
        if (manufacturer != null)
          _CategoryLine(source: 'Beurer', row: manufacturer!),
        TextButton.icon(
          style: TextButton.styleFrom(
            minimumSize: const Size(0, 44),
            padding: EdgeInsets.zero,
          ),
          onPressed: () => showHealthReferenceSheet(
            context,
            kind: kind,
            includeBeurer: manufacturer != null,
            launcher: launcher,
          ),
          icon: const Icon(Icons.open_in_new, size: 17),
          label: const Text('Ranges & sources'),
        ),
        Text(
          'These are general categories from the linked sources, not a '
          'diagnosis or your personal target. Contact your healthcare '
          'provider for ranges that make sense for you and your condition.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _CategoryLine extends StatelessWidget {
  final String source;
  final HealthReferenceRow row;

  const _CategoryLine({required this.source, required this.row});

  @override
  Widget build(BuildContext context) {
    final colors = switch (row.tone) {
      HealthReferenceTone.normal => sensorReadingLevelColors(
        SensorReadingLevel.good,
        Theme.of(context).brightness,
      ),
      HealthReferenceTone.caution => sensorReadingLevelColors(
        SensorReadingLevel.fair,
        Theme.of(context).brightness,
      ),
      HealthReferenceTone.warning ||
      HealthReferenceTone.critical => sensorReadingLevelColors(
        SensorReadingLevel.poor,
        Theme.of(context).brightness,
      ),
      HealthReferenceTone.neutral => (
        background: Theme.of(context).colorScheme.surfaceContainerHighest,
        foreground: Theme.of(context).colorScheme.onSurfaceVariant,
      ),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 58,
            child: Text(
              '$source:',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: colors.background,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                row.label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.foreground,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

Future<void> showHealthReferenceSheet(
  BuildContext context, {
  required HealthMeasurementKind kind,
  required bool includeBeurer,
  LinkLauncher launcher = launchExternally,
}) {
  final pulse = kind == HealthMeasurementKind.pulseOximeter;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (context) {
      final text = Theme.of(context).textTheme;
      final scheme = Theme.of(context).colorScheme;
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                pulse
                    ? 'Pulse-oximetry references'
                    : 'Blood-pressure references',
                style: text.headlineSmall,
              ),
              const SizedBox(height: 8),
              Text(
                'The app keeps these source scales separate because their '
                'thresholds and labels are not identical. A category describes '
                'the cited table, not your diagnosis or treatment target.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 20),
              _SourceSection(
                title: pulse
                    ? 'NIH · Pulse Oximetry (StatPearls)'
                    : 'NIH/NHLBI · What Is High Blood Pressure?',
                url: pulse ? nihPulseOximetryUrl : nihBloodPressureUrl,
                rows: pulse ? oxygenNihRows : bloodPressureNihRows,
                launcher: launcher,
              ),
              if (includeBeurer) ...[
                const SizedBox(height: 20),
                _SourceSection(
                  title: pulse
                      ? 'Beurer PO60 instructions · section 11'
                      : 'Beurer Premium 800 instructions · Risk Classification',
                  url: pulse ? beurerPo60ManualUrl : beurerBm92ManualUrl,
                  rows: pulse ? oxygenBeurerRows : bloodPressureBeurerRows,
                  launcher: launcher,
                ),
              ] else ...[
                const SizedBox(height: 16),
                Text(
                  'No verified companion-app reference bands are available for '
                  'this device. Only the public NIH scale is shown.',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 20),
              Text(
                'Contact your healthcare provider for ranges that make sense '
                'for you and your condition. Do not start, stop or change '
                'medication or oxygen based on this app. Device readings can '
                'be affected by measurement conditions and device accuracy.',
                style: text.bodyMedium,
              ),
              if (!pulse) ...[
                const SizedBox(height: 12),
                Text(
                  'NHLBI says to contact your provider immediately for readings '
                  'in its hypertensive crisis row. Do not wait on this app when '
                  'you have severe or concerning symptoms.',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
              if (pulse && includeBeurer) ...[
                const SizedBox(height: 12),
                Text(
                  'Beurer excludes some pre-existing conditions and altitudes '
                  'above 1500 metres from its table, and recommends urgent '
                  'medical attention in its critical range. Follow the '
                  'instructions for your own device and care plan.',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _SourceSection extends StatelessWidget {
  final String title;
  final String url;
  final List<HealthReferenceRow> rows;
  final LinkLauncher launcher;

  const _SourceSection({
    required this.title,
    required this.url,
    required this.rows,
    required this.launcher,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: scheme.outlineVariant),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              for (var index = 0; index < rows.length; index++)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: index == 0
                        ? null
                        : Border(top: BorderSide(color: scheme.outlineVariant)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: Text(rows[index].label)),
                      const SizedBox(width: 12),
                      Flexible(
                        child: Text(
                          rows[index].range,
                          textAlign: TextAlign.end,
                          style: text.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
            onPressed: () => openWebLink(context, url, launcher: launcher),
            icon: const Icon(Icons.open_in_new, size: 17),
            label: const Text('Open public source'),
          ),
        ),
      ],
    );
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../core/entity_icon.dart';
import '../services/spec_codec.dart';
import 'entity_value.dart';

/// A live reading declared by a spec's `entities:` block.
///
/// This is the payoff of spec-driven rendering: the spec says "Internal
/// Temperature, device_class temperature, unit F, read it from characteristic
/// X", and this widget turns that into a labelled reading without any
/// device-specific code. Adding a device becomes a spec refresh, not an app
/// change.
///
/// The read/notify/decode plumbing lives in [EntityValueBuilder], shared with
/// the control cards; this widget owns only the sensor presentation.
class EntitySensorCard extends StatelessWidget {
  final String deviceId;
  final String serviceUuid;
  final EntityDto entity;
  final String specYaml;

  const EntitySensorCard({
    super.key,
    required this.deviceId,
    required this.serviceUuid,
    required this.entity,
    required this.specYaml,
  });

  /// The spec's `icon` when it names one this build can draw, else what the
  /// `device_class` implies. See [entityIcon] — the choice lives there so the
  /// sensor card and the setpoint control cannot disagree about one entity.
  IconData get _icon => entityIcon(entity);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return EntityValueBuilder(
      deviceId: deviceId,
      serviceUuid: serviceUuid,
      entity: entity,
      specYaml: specYaml,
      builder: (context, value) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: scheme.outlineVariant),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(_icon, color: scheme.onSecondaryContainer, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entity.name,
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (entity.canNotify)
                        Tooltip(
                          message: 'Updates live',
                          child: Icon(Icons.bolt,
                              size: 16, color: scheme.onSurfaceVariant),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _buildValue(value, scheme, text),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildValue(
      EntityLiveValue value, ColorScheme scheme, TextTheme text) {
    switch (value.status) {
      case EntityValueStatus.unavailable:
        // An entity whose characteristic has no `format:` block can't be
        // decoded. Say so plainly instead of reading bytes we can't
        // interpret: it's a gap in the spec, and reporting it is more useful
        // than a blank tile.
        return Text(
          'No format block in the spec yet, so this reading cannot be '
          'decoded.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        );
      case EntityValueStatus.loading:
        return Row(
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: scheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 8),
            Text('Reading...',
                style:
                    text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ],
        );
      case EntityValueStatus.error:
        return Text(
          value.error ?? 'Could not read this value.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        );
      case EntityValueStatus.live:
        final mappingError = value.primaryError;
        if (mappingError != null) {
          return Text(
            mappingError,
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              value.display ?? '--',
              style: text.headlineSmall?.copyWith(
                fontWeight: FontWeight.w700,
                // Tabular figures keep a live-updating reading from shifting
                // width digit by digit.
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            if (value.unit != null) ...[
              const SizedBox(width: 4),
              Text(
                value.unit!,
                style:
                    text.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ],
        );
    }
  }
}

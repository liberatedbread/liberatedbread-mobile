// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../services/spec_codec.dart';
import 'entity_value.dart';

/// A live on/off reading declared by a spec's `binary_sensor` entity.
///
/// The spec carries the judgement rules, not just the bytes: ember's charging
/// base is "on" when a status byte equals `state_mapping.on_value`, and a
/// plain bool field speaks for itself. [EntityLiveValue.isOn] applies those
/// rules; this widget only presents the verdict.
class BinarySensorCard extends StatelessWidget {
  final String deviceId;
  final String serviceUuid;
  final EntityDto entity;
  final String specYaml;

  const BinarySensorCard({
    super.key,
    required this.deviceId,
    required this.serviceUuid,
    required this.entity,
    required this.specYaml,
  });

  /// What "on" and "off" mean for this sensor, worded by device_class when
  /// one is declared. `problem` inverts the visual emphasis: "on" is the bad
  /// state.
  (String, String) get _labels => switch (entity.deviceClass) {
        'problem' => ('Problem', 'OK'),
        'running' => ('Running', 'Stopped'),
        'battery_charging' => ('Charging', 'Not charging'),
        _ => ('On', 'Off'),
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return EntityValueBuilder(
      deviceId: deviceId,
      serviceUuid: serviceUuid,
      entity: entity,
      specYaml: specYaml,
      builder: (context, value) {
        final isOn = value.isOn;
        final isProblem = entity.deviceClass == 'problem';
        final active = isOn == true;
        final iconColor = active
            ? (isProblem ? scheme.error : scheme.primary)
            : scheme.onSurfaceVariant;

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  active
                      ? (isProblem
                          ? Icons.warning_amber_rounded
                          : Icons.check_circle)
                      : Icons.circle_outlined,
                  color: active ? iconColor : scheme.onSecondaryContainer,
                  size: 22,
                ),
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
                    _buildState(value, isOn, scheme, text),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildState(
    EntityLiveValue value,
    bool? isOn,
    ColorScheme scheme,
    TextTheme text,
  ) {
    switch (value.status) {
      case EntityValueStatus.unavailable:
        return Text(
          'No format block in the spec yet, so this state cannot be decoded.',
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
          value.error ?? 'Could not read this state.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        );
      case EntityValueStatus.live:
        if (isOn == null) {
          return Text(
            value.primaryError ??
                'The decoded value has no on/off interpretation.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          );
        }
        final (onLabel, offLabel) = _labels;
        return Text(
          isOn ? onLabel : offLabel,
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        );
    }
  }
}

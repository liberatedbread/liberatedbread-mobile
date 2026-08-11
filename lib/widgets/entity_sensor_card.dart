// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../core/entity_icon.dart';
import '../core/sensor_reading_level.dart';
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
/// Readings whose healthy range is established (radon, CO₂, VOC, humidity,
/// particulates, battery — see [sensorReadingLevel]) also carry a one-word
/// verdict chip, because "934 ppm" answers a question nobody asked while
/// "Fair" answers the one everybody did. Quantities with no honest band show
/// the number alone.
///
/// Two layouts share all of that logic:
/// - the default full-width row, used when a reading stands alone;
/// - a [compact] tile for the readings grid, where a sensor device's whole
///   suite is visible at once instead of a scroll of banners.
///
/// The read/notify/decode plumbing lives in [EntityValueBuilder], shared with
/// the control cards; this widget owns only the sensor presentation.
class EntitySensorCard extends StatelessWidget {
  final String deviceId;
  final String serviceUuid;
  final EntityDto entity;
  final String specYaml;

  /// Grid-tile layout: icon on top, reading below, sized to sit two or three
  /// abreast. The default is the full-width row.
  final bool compact;

  const EntitySensorCard({
    super.key,
    required this.deviceId,
    required this.serviceUuid,
    required this.entity,
    required this.specYaml,
    this.compact = false,
  });

  /// The spec's `icon` when it names one this build can draw, else what the
  /// `device_class` implies. See [entityIcon] — the choice lives there so the
  /// sensor card and the setpoint control cannot disagree about one entity.
  IconData get _icon => entityIcon(entity);

  /// The verdict to chip onto this reading, or null when there is nothing
  /// honest to say (no established band, no live value, or a level the
  /// reading's class keeps quiet — a healthy battery).
  SensorReadingLevel? _visibleLevel(EntityLiveValue value) {
    if (value.status != EntityValueStatus.live) return null;
    final level = sensorReadingLevel(
      deviceClass: entity.deviceClass,
      unit: value.unit,
      value: value.decodedNumber,
    );
    if (level == null) return null;
    final visible =
        sensorLevelVisible(deviceClass: entity.deviceClass, level: level);
    return visible ? level : null;
  }

  @override
  Widget build(BuildContext context) {
    return EntityValueBuilder(
      deviceId: deviceId,
      serviceUuid: serviceUuid,
      entity: entity,
      specYaml: specYaml,
      builder: (context, value) =>
          compact ? _tile(context, value) : _row(context, value),
    );
  }

  /// The full-width layout: icon beside the reading.
  Widget _row(BuildContext context, EntityLiveValue value) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final level = _visibleLevel(value);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: _cardDecoration(scheme),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _iconBox(scheme, size: 44, iconSize: 22),
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
                    if (entity.canNotify) _liveBolt(scheme, size: 16),
                  ],
                ),
                const SizedBox(height: 6),
                if (value.status == EntityValueStatus.live &&
                    value.primaryError == null)
                  Row(
                    children: [
                      Expanded(child: _reading(value, scheme, text)),
                      if (level != null) ...[
                        const SizedBox(width: 8),
                        _LevelChip(level: level),
                      ],
                    ],
                  )
                else
                  _statusContent(value, scheme, text),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The grid-tile layout: icon above the reading, verdict chip at the foot.
  Widget _tile(BuildContext context, EntityLiveValue value) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final level = _visibleLevel(value);

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: _cardDecoration(scheme),
      // `spaceBetween` rather than a Spacer: when the grid stretches the
      // tiles of a row to one height it pins the verdict chip to the foot so
      // chips line up across the row, and in an unbounded column (a lone
      // tile, a test harness) it degrades to hugging the content — where a
      // Spacer's flex would be an error.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _iconBox(scheme, size: 36, iconSize: 19),
                  const Spacer(),
                  if (entity.canNotify) _liveBolt(scheme, size: 14),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                entity.name,
                style: text.labelMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              if (value.status == EntityValueStatus.live &&
                  value.primaryError == null)
                _reading(value, scheme, text)
              else
                _statusContent(value, scheme, text),
            ],
          ),
          if (level != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: _LevelChip(level: level),
            ),
        ],
      ),
    );
  }

  BoxDecoration _cardDecoration(ColorScheme scheme) => BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      );

  Widget _iconBox(ColorScheme scheme,
          {required double size, required double iconSize}) =>
      Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: scheme.secondaryContainer,
          borderRadius: BorderRadius.circular(size * 0.3),
        ),
        child: Icon(_icon, color: scheme.onSecondaryContainer, size: iconSize),
      );

  Widget _liveBolt(ColorScheme scheme, {required double size}) => Tooltip(
        message: 'Updates live',
        child: Icon(Icons.bolt, size: size, color: scheme.onSurfaceVariant),
      );

  /// The decoded value with its unit, for a live reading.
  Widget _reading(EntityLiveValue value, ColorScheme scheme, TextTheme text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Flexible(
          child: Text(
            value.display ?? '--',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: text.headlineSmall?.copyWith(
              fontWeight: FontWeight.w700,
              // Tabular figures keep a live-updating reading from shifting
              // width digit by digit.
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
        if (value.unit != null) ...[
          const SizedBox(width: 4),
          Text(
            value.unit!,
            style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }

  /// Everything that is not a clean live reading: pending, failed, or a spec
  /// gap, said in words rather than left as a blank tile.
  Widget _statusContent(
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
        // Reached only with a mapping problem — a spec bug worth showing
        // verbatim, distinct from a transport error.
        return Text(
          value.primaryError ?? 'Could not read this value.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        );
    }
  }
}

/// The one-word verdict, colored by band.
class _LevelChip extends StatelessWidget {
  final SensorReadingLevel level;

  const _LevelChip({required this.level});

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

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:math' as math;

import 'package:flutter/material.dart';

class MeasurementTrendSeries {
  final String label;
  final List<double> values;
  final Color? color;

  const MeasurementTrendSeries({
    required this.label,
    required this.values,
    this.color,
  });
}

class MeasurementTrendChart extends StatelessWidget {
  final String title;
  final String unit;
  final List<MeasurementTrendSeries> series;

  const MeasurementTrendChart({
    super.key,
    required this.title,
    required this.unit,
    required this.series,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final values = series.expand((item) => item.values).toList();
    final minimum = values.reduce(math.min);
    final maximum = values.reduce(math.max);
    final semantic = series
        .map(
          (item) =>
              '${item.label}: ${item.values.map(_number).join(', ')} $unit',
        )
        .join('. ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: text.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
        Text(
          'Recorded values · oldest to newest',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        const SizedBox(height: 6),
        Semantics(
          label: '$title. $semantic',
          child: SizedBox(
            height: 88,
            width: double.infinity,
            child: CustomPaint(
              painter: _TrendPainter(
                series: [
                  for (var index = 0; index < series.length; index++)
                    (
                      values: series[index].values,
                      color:
                          series[index].color ??
                          switch (index) {
                            0 => scheme.primary,
                            1 => scheme.tertiary,
                            _ => scheme.secondary,
                          },
                    ),
                ],
                minimum: minimum,
                maximum: maximum,
                grid: scheme.outlineVariant,
              ),
            ),
          ),
        ),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            for (var index = 0; index < series.length; index++)
              Text(
                '${series[index].label}: ${_number(series[index].values.first)} '
                '→ ${_number(series[index].values.last)} $unit',
                style: text.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            Text(
              'Scale ${_number(minimum)}–${_number(maximum)} $unit',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }
}

class _TrendPainter extends CustomPainter {
  final List<({List<double> values, Color color})> series;
  final double minimum;
  final double maximum;
  final Color grid;

  const _TrendPainter({
    required this.series,
    required this.minimum,
    required this.maximum,
    required this.grid,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final fraction in [0.0, 0.5, 1.0]) {
      final y = size.height * fraction;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
    final span = maximum - minimum;
    Offset point(double value, int index, int count) {
      final x = count <= 1 ? size.width / 2 : index * size.width / (count - 1);
      final normalized = span == 0 ? 0.5 : (value - minimum) / span;
      return Offset(x, size.height * (1 - normalized));
    }

    for (final item in series) {
      final paint = Paint()
        ..color = item.color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (var index = 0; index < item.values.length; index++) {
        final at = point(item.values[index], index, item.values.length);
        if (index == 0) {
          path.moveTo(at.dx, at.dy);
        } else {
          path.lineTo(at.dx, at.dy);
        }
      }
      canvas.drawPath(path, paint);
      for (var index = 0; index < item.values.length; index++) {
        canvas.drawCircle(
          point(item.values[index], index, item.values.length),
          3,
          Paint()..color = item.color,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_TrendPainter oldDelegate) =>
      oldDelegate.series != series ||
      oldDelegate.minimum != minimum ||
      oldDelegate.maximum != maximum ||
      oldDelegate.grid != grid;
}

String _number(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

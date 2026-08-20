// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// A power-strip pictogram — a strip body with a row of outlets and a cord —
/// for a multi-outlet smart plug (a TP-Link HS300 and friends), which a single
/// toggle glyph does not describe. Material has no power-strip icon, so it is
/// drawn. Filled in [color] so it works on either theme.
class PowerStripIcon extends StatelessWidget {
  final double size;
  final Color color;

  const PowerStripIcon({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _PowerStripPainter(color)),
      );
}

class _PowerStripPainter extends CustomPainter {
  final Color color;
  const _PowerStripPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.05
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // The cord: from the left end, down and out to a small plug head.
    final cord = Path()
      ..moveTo(s * 0.16, s * 0.52)
      ..cubicTo(s * 0.06, s * 0.58, s * 0.06, s * 0.78, s * 0.16, s * 0.84);
    canvas.drawPath(cord, stroke);
    // The plug head at the cord's end.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(s * 0.20, s * 0.85),
            width: s * 0.12,
            height: s * 0.09),
        Radius.circular(s * 0.02),
      ),
      fill,
    );

    // The strip body, with four outlets punched out so it reads as a strip and
    // not a plain bar. saveLayer + clear cuts them cleanly whatever is behind.
    final body = RRect.fromRectAndRadius(
      Rect.fromLTRB(s * 0.14, s * 0.30, s * 0.90, s * 0.56),
      Radius.circular(s * 0.07),
    );
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawRRect(body, fill);
    final hole = Paint()..blendMode = BlendMode.clear;
    for (var i = 0; i < 4; i++) {
      final cxo = s * (0.245 + i * 0.18);
      // Two short slots per outlet — the universal "socket" mark.
      for (final dx in [-s * 0.028, s * 0.028]) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
                center: Offset(cxo + dx, s * 0.43),
                width: s * 0.022,
                height: s * 0.10),
            Radius.circular(s * 0.011),
          ),
          hole,
        );
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_PowerStripPainter old) => old.color != color;
}

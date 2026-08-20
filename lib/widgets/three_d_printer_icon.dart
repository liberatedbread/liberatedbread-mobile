// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// A 3D-printer pictogram — a cartesian portal frame with a gantry-mounted
/// extruder over a print bed — for a fused-filament printer (a Snapmaker U1 and
/// friends). Material's `print` glyph draws a flat office printer, which reads
/// as the wrong machine entirely, and Material has no 3D-printer icon, so it is
/// drawn. Stroked frame + filled carriage in [color] so it works on either
/// theme.
class ThreeDPrinterIcon extends StatelessWidget {
  final double size;
  final Color color;

  const ThreeDPrinterIcon({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _ThreeDPrinterPainter(color)),
      );
}

class _ThreeDPrinterPainter extends CustomPainter {
  final Color color;
  const _ThreeDPrinterPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.06
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // The portal frame: two uprights joined by the top gantry beam, the
    // silhouette that says "cartesian 3D printer" and not "office printer".
    final frame = Path()
      ..moveTo(s * 0.22, s * 0.72)
      ..lineTo(s * 0.22, s * 0.24)
      ..lineTo(s * 0.78, s * 0.24)
      ..lineTo(s * 0.78, s * 0.72);
    canvas.drawPath(frame, stroke);

    // The extruder carriage hanging from the gantry, with a nozzle tapering to
    // a point over the bed — the moving head.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
            center: Offset(s * 0.50, s * 0.36),
            width: s * 0.24,
            height: s * 0.14),
        Radius.circular(s * 0.03),
      ),
      fill,
    );
    final nozzle = Path()
      ..moveTo(s * 0.44, s * 0.43)
      ..lineTo(s * 0.56, s * 0.43)
      ..lineTo(s * 0.50, s * 0.51)
      ..close();
    canvas.drawPath(nozzle, fill);

    // The print bed: a solid platform the frame straddles.
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTRB(s * 0.14, s * 0.70, s * 0.86, s * 0.78),
        Radius.circular(s * 0.03),
      ),
      fill,
    );
  }

  @override
  bool shouldRepaint(_ThreeDPrinterPainter old) => old.color != color;
}

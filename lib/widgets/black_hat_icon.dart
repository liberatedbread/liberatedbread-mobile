// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// A fedora silhouette — the "black hat" — for a device the catalogue flags as
/// outright malicious (a `security_advisory` of severity `malicious`, e.g. a
/// card skimmer). Material has no hat glyph, so this is drawn.
///
/// Named for the symbol, not the paint: it is filled in [color] (the caller
/// passes the theme's error colour) so it stays visible and reads as danger on
/// both light and dark backgrounds, where a literally-black shape would vanish.
class BlackHatIcon extends StatelessWidget {
  final double size;
  final Color color;

  const BlackHatIcon({super.key, required this.size, required this.color});

  @override
  Widget build(BuildContext context) => SizedBox.square(
        dimension: size,
        child: CustomPaint(painter: _BlackHatPainter(color)),
      );
}

class _BlackHatPainter extends CustomPainter {
  final Color color;
  const _BlackHatPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    final cx = size.width / 2;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // The brim: a wide, flat ellipse low on the glyph.
    final brim = Rect.fromCenter(
      center: Offset(cx, s * 0.70),
      width: s * 0.94,
      height: s * 0.24,
    );

    // The crown: a rounded dome rising from the brim, a touch wider at its
    // base than its top, the way a fedora sits.
    final crown = Path()
      ..moveTo(cx - s * 0.27, s * 0.64)
      ..lineTo(cx - s * 0.22, s * 0.34)
      ..quadraticBezierTo(cx - s * 0.20, s * 0.22, cx, s * 0.22)
      ..quadraticBezierTo(cx + s * 0.20, s * 0.22, cx + s * 0.22, s * 0.34)
      ..lineTo(cx + s * 0.27, s * 0.64)
      ..close();

    // Draw the hat on its own layer so the band can be punched out of it (a
    // clear stroke) rather than painted over — that reads as a hat, not a lump,
    // and works whatever the background colour behind the glyph is.
    canvas.saveLayer(Offset.zero & size, Paint());
    canvas.drawOval(brim, fill);
    canvas.drawPath(crown, fill);
    final band = Paint()
      ..blendMode = BlendMode.clear
      ..style = PaintingStyle.stroke
      ..strokeWidth = s * 0.055
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(cx - s * 0.245, s * 0.605),
      Offset(cx + s * 0.245, s * 0.605),
      band,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_BlackHatPainter old) => old.color != color;
}

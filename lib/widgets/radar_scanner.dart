// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:math' as math;

import 'package:flutter/material.dart';

/// The scan-screen hero: a Bluetooth glyph inside a ring that sweeps while a
/// scan is running and rests when it isn't.
///
/// Motion is the status indicator here — a sweeping ring reads as "looking"
/// without a caption. When [scanning] is false the ring settles into a static
/// track so the same component covers the idle state instead of swapping in a
/// different widget and shifting the layout.
///
/// Respects `MediaQuery.disableAnimations` (the platform reduce-motion
/// setting): the sweep is replaced by a still ring rather than spinning
/// indefinitely for users who asked the system to stop moving things.
class RadarScanner extends StatefulWidget {
  final bool scanning;
  final double size;

  const RadarScanner({super.key, required this.scanning, this.size = 208});

  @override
  State<RadarScanner> createState() => _RadarScannerState();
}

class _RadarScannerState extends State<RadarScanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1600),
  );

  @override
  void initState() {
    super.initState();
    if (widget.scanning) _controller.repeat();
  }

  @override
  void didUpdateWidget(RadarScanner old) {
    super.didUpdateWidget(old);
    if (widget.scanning == old.scanning) return;
    if (widget.scanning) {
      _controller.repeat();
    } else {
      // Settle to the top of the sweep instead of freezing mid-rotation.
      _controller.animateTo(1, duration: const Duration(milliseconds: 240));
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final sweeping = widget.scanning && !reduceMotion;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: _RadarPainter(
              progress: sweeping ? _controller.value : 0,
              sweeping: sweeping,
              // A low-alpha outline reads as a hairline track; the raw
              // outlineVariant is too warm and muddies the hero.
              track: scheme.outlineVariant.withValues(alpha: 0.45),
              accent: scheme.secondary,
              glow: scheme.secondary.withValues(alpha: 0.35),
            ),
            child: child,
          );
        },
        // The glyph is passed as `child` so it isn't rebuilt on every frame.
        child: Center(
          child: Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: scheme.onSurface,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.bluetooth,
              color: scheme.surface,
              size: 30,
            ),
          ),
        ),
      ),
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double progress;
  final bool sweeping;
  final Color track;
  final Color accent;
  final Color glow;

  _RadarPainter({
    required this.progress,
    required this.sweeping,
    required this.track,
    required this.accent,
    required this.glow,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 12;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Track: a thin ring that stays visible when idle so the layout never
    // jumps between states.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..color = track,
    );

    if (!sweeping) return;

    // Blurred halo *on the ring itself* — a filled circle here would paint a
    // solid disc rather than a glow.
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..color = glow
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    // Leading arc, drawn with a gradient that fades out behind the head so the
    // sweep reads directionally.
    const arcLength = math.pi * 0.85;
    final start = progress * 2 * math.pi - math.pi / 2;
    canvas.drawArc(
      rect,
      start,
      arcLength,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeCap = StrokeCap.round
        ..shader = SweepGradient(
          startAngle: start,
          endAngle: start + arcLength,
          colors: [accent.withValues(alpha: 0), accent],
          transform: GradientRotation(start),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_RadarPainter old) =>
      old.progress != progress ||
      old.sweeping != sweeping ||
      old.accent != accent ||
      old.track != track;
}

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
///
/// Drawn as two layers so the sweep costs a transform per frame, not a blur.
/// The track and its blurred halo never move: they sit in their own
/// [RepaintBoundary] under a painter that repaints only when its colours
/// change, so the Gaussian blur is rasterised once per theme rather than
/// once per frame. The arc is painted once at the top of the ring, in its
/// own boundary, and a [RotationTransition] driven straight by the ticker
/// turns that cached layer — the ambient scan runs with no timeout, and on a
/// ProMotion iPhone this used to be a fresh blur pass 120 times a second for
/// as long as the Nearby tab was open.
class RadarScanner extends StatefulWidget {
  final bool scanning;
  final double size;

  const RadarScanner({super.key, required this.scanning, this.size = 208});

  @override
  State<RadarScanner> createState() => _RadarScannerState();
}

class _RadarScannerState extends State<RadarScanner>
    with SingleTickerProviderStateMixin {
  // Created in initState, not lazily: a controller first touched in
  // dispose() (a scanner that never swept) would mint its ticker during
  // teardown, which the ticker provider refuses.
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    );
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
      child: Stack(
        fit: StackFit.expand,
        children: [
          // The still layer: track and halo. Rasterised once and reused for
          // every frame of the sweep — nothing in it depends on the ticker.
          RepaintBoundary(
            child: CustomPaint(
              painter: RadarTrackPainter(
                sweeping: sweeping,
                // A low-alpha outline reads as a hairline track; the raw
                // outlineVariant is too warm and muddies the hero.
                track: scheme.outlineVariant.withValues(alpha: 0.45),
                glow: scheme.secondary.withValues(alpha: 0.35),
              ),
            ),
          ),
          // The moving layer: the arc, painted once at the top and turned by
          // the ticker. RotationTransition listens to the controller itself,
          // so a tick rebuilds nothing — it re-composites one cached layer.
          if (sweeping)
            RotationTransition(
              turns: _controller,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: RadarArcPainter(accent: scheme.secondary),
                ),
              ),
            ),
          Center(
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: scheme.onSurface,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.bluetooth, color: scheme.surface, size: 30),
            ),
          ),
        ],
      ),
    );
  }
}

/// The ring's inset from the widget's edge; shared by both painters so the
/// arc sits exactly on the track it sweeps.
const double _ringInset = 12;

/// The still layer: the thin track that is always visible, and — while
/// sweeping — the blurred halo on the ring. Repaints only when a colour or
/// the sweeping flag changes, never per frame.
@visibleForTesting
class RadarTrackPainter extends CustomPainter {
  final bool sweeping;
  final Color track;
  final Color glow;

  /// How many times any instance has painted — the test's evidence that the
  /// blur is not being re-run per frame.
  @visibleForTesting
  static int debugPaintCount = 0;

  RadarTrackPainter({
    required this.sweeping,
    required this.track,
    required this.glow,
  });

  @override
  void paint(Canvas canvas, Size size) {
    debugPaintCount++;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - _ringInset;

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
  }

  @override
  bool shouldRepaint(RadarTrackPainter old) =>
      old.sweeping != sweeping || old.track != track || old.glow != glow;
}

/// The moving layer: the leading arc, painted once with its head at the top
/// of the ring. The sweep is the [RotationTransition] above turning this
/// layer, so the painter itself has no notion of progress and repaints only
/// when the accent colour changes.
@visibleForTesting
class RadarArcPainter extends CustomPainter {
  final Color accent;

  /// See [RadarTrackPainter.debugPaintCount].
  @visibleForTesting
  static int debugPaintCount = 0;

  RadarArcPainter({required this.accent});

  @override
  void paint(Canvas canvas, Size size) {
    debugPaintCount++;
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - _ringInset;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // Drawn with a gradient that fades out behind the head so the sweep
    // reads directionally. The head sits at 12 o'clock; rotation does the
    // rest.
    const arcLength = math.pi * 0.85;
    const start = -math.pi / 2;
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
          transform: const GradientRotation(start),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(RadarArcPainter old) => old.accent != accent;
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// F-026: the radar's blurred halo used to be repainted on every tick of the
// sweep — a Gaussian blur 120 times a second, for the whole of an ambient
// scan that has no timeout. The halo now lives in a static layer that paints
// once, and the sweep is a rotation of a cached arc layer.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/widgets/radar_scanner.dart';

void main() {
  test('the sweep gradient is rotated exactly once', () {
    // R-125. The ramp was placed by `startAngle`/`endAngle` AND turned again
    // by a `GradientRotation(startAngle)`, so the fade sat a quarter of the
    // ring behind the arc it belongs to: solid tail, half-transparent head.
    // `drawArc` and `SweepGradient` measure in the same frame, so the angles
    // alone are the whole placement.
    final painter = RadarArcPainter(accent: const Color(0xFF00FF00));
    final gradient = painter.sweepGradient;

    expect(
      gradient.transform,
      isNull,
      reason: 'the angles already place the ramp; a rotation doubles it',
    );
    expect(gradient.startAngle, RadarArcPainter.arcStart);
    expect(
      gradient.endAngle,
      RadarArcPainter.arcStart + RadarArcPainter.arcLength,
    );
    // Transparent at the tail, solid at the head — the direction the sweep
    // reads in.
    expect(gradient.colors.first.a, 0);
    expect(gradient.colors.last.a, 1);
  });

  setUp(() {
    RadarTrackPainter.debugPaintCount = 0;
    RadarArcPainter.debugPaintCount = 0;
  });

  /// The sweep's own RotationTransition — Material widgets carry theirs.
  final sweep = find.descendant(
    of: find.byType(RadarScanner),
    matching: find.byType(RotationTransition),
  );

  Future<void> pumpRadar(
    WidgetTester tester, {
    required bool scanning,
    bool reduceMotion = false,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Center(child: RadarScanner(scanning: scanning)),
          ),
        ),
      ),
    );
  }

  testWidgets('the sweep never repaints the blurred layer', (tester) async {
    await pumpRadar(tester, scanning: true);
    expect(RadarTrackPainter.debugPaintCount, 1);
    expect(RadarArcPainter.debugPaintCount, 1);
    expect(sweep, findsOneWidget);

    // Two full turns of the 1600 ms sweep, frame by frame.
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }

    expect(
      RadarTrackPainter.debugPaintCount,
      1,
      reason: 'the track + halo layer must be rasterised once, not per frame',
    );
    expect(
      RadarArcPainter.debugPaintCount,
      1,
      reason: 'the arc is a cached layer the RotationTransition turns',
    );

    // And the painters themselves say so: an identical successor is no
    // reason to repaint.
    final track = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<RadarTrackPainter>()
        .single;
    expect(
      track.shouldRepaint(
        RadarTrackPainter(
          sweeping: track.sweeping,
          track: track.track,
          glow: track.glow,
        ),
      ),
      isFalse,
    );
    final arc = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<RadarArcPainter>()
        .single;
    expect(arc.shouldRepaint(RadarArcPainter(accent: arc.accent)), isFalse);
  });

  testWidgets('stopping the scan drops the arc and settles the halo', (
    tester,
  ) async {
    await pumpRadar(tester, scanning: true);
    await pumpRadar(tester, scanning: false);
    await tester.pump(const Duration(milliseconds: 300));

    expect(sweep, findsNothing);
    // The static layer repainted exactly once more — sweeping changed, so
    // the halo goes — and then held still through the settle animation.
    expect(RadarTrackPainter.debugPaintCount, 2);
    expect(find.byIcon(Icons.bluetooth), findsOneWidget);
  });

  testWidgets('reduce-motion shows a still ring with no sweep', (tester) async {
    await pumpRadar(tester, scanning: true, reduceMotion: true);
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    expect(sweep, findsNothing);
    expect(RadarArcPainter.debugPaintCount, 0);
    expect(RadarTrackPainter.debugPaintCount, 1);
  });
}

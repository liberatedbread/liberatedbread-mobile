// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The label composer: type, preview, print — and the job that reaches the
// target is exactly the previewed raster at the head's width.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/print_label_screen.dart';
import 'package:liberated_bread_mobile/services/print/print_target.dart';

import '../fakes/fake_spec_codec.dart';

class _RecordingTarget implements LabelPrintTarget {
  final PrintOutcome outcome;
  _RecordingTarget([this.outcome = const PrintOk()]);

  final prints = <({int width, int height, int copies, Uint8List rgb})>[];

  @override
  String get name => 'Test printer';

  @override
  LabelGeometry get geometry =>
      const LabelGeometry(widthDots: 200, dpi: 203, mediaName: '25mm roll');

  @override
  Future<PrintOutcome> printMono(
    Uint8List rgb,
    int width,
    int height, {
    int copies = 1,
  }) async {
    prints.add((width: width, height: height, copies: copies, rgb: rgb));
    return outcome;
  }
}

Future<void> _pump(WidgetTester tester, LabelPrintTarget target) async {
  // Tall enough that the whole composer, Print button included, is built.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [specCodecProvider.overrideWithValue(FakeSpecCodec())],
      child: MaterialApp(home: PrintLabelScreen(target: target)),
    ),
  );
}

/// Let the debounced render (a timer, then real async image work) finish.
Future<void> _settleRender(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
}

void main() {
  testWidgets('printing sends the previewed raster at the head width', (
    tester,
  ) async {
    final target = _RecordingTarget();
    await _pump(tester, target);
    expect(find.text('Test printer · 25mm roll'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('label-line-0')), 'Oats');
    await _settleRender(tester);
    await tester.tap(find.byIcon(Icons.add).last); // two copies
    await tester.pump();

    await tester.ensureVisible(find.text('Print'));
    await tester.tap(find.text('Print'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(target.prints, hasLength(1));
    final job = target.prints.single;
    expect(job.width, 200);
    expect(job.copies, 2);
    expect(job.rgb.length, job.width * job.height * 3);
    expect(job.rgb.any((b) => b == 0), isTrue, reason: 'the text is black');
    expect(find.text('2 labels sent.'), findsOneWidget);
  });

  testWidgets('an empty label cannot be printed', (tester) async {
    final target = _RecordingTarget();
    await _pump(tester, target);
    await _settleRender(tester);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Print'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a failed print says why and keeps the label', (tester) async {
    final target = _RecordingTarget(
      const PrintFailed('Printer is out of labels.'),
    );
    await _pump(tester, target);
    await tester.enterText(find.byKey(const ValueKey('label-line-0')), 'Rye');
    await _settleRender(tester);
    await tester.ensureVisible(find.text('Print'));
    await tester.tap(find.text('Print'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(find.text('Printer is out of labels.'), findsOneWidget);
    expect(find.text('Rye'), findsOneWidget);
  });
}

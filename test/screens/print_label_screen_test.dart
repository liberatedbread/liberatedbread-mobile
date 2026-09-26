// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The label composer: type, preview, print — and the job that reaches the
// target is exactly the previewed raster at the head's width.
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/print_label_screen.dart';
import 'package:liberated_bread_mobile/services/print/os_print_service.dart';
import 'package:liberated_bread_mobile/services/print/photo_source.dart';
import 'package:liberated_bread_mobile/services/print/print_target.dart';

import '../fakes/fake_os_print_service.dart';
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

class _FakePhotos implements PhotoSource {
  final Uint8List? photo;
  _FakePhotos(this.photo);
  int picks = 0;

  @override
  bool get canUseCamera => false;

  @override
  Future<Uint8List?> pick({required bool camera}) async {
    picks++;
    return photo;
  }

  /// What the file dialog returns; the photo when unset.
  Uint8List? file;

  @override
  Future<Uint8List?> pickFile() async => file ?? photo;
}

/// A 40x20 PNG: black left half, white right half.
Future<Uint8List> _png() async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 40, 20),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  canvas.drawRect(
    const Rect.fromLTWH(0, 0, 20, 20),
    Paint()..color = const Color(0xFF000000),
  );
  final image = await recorder.endRecording().toImage(40, 20);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  image.dispose();
  return data!.buffer.asUint8List();
}

Future<void> _pump(
  WidgetTester tester,
  LabelPrintTarget target, {
  PhotoSource? photos,
  OsPrintService? osPrint,
}) async {
  // Tall enough that the whole composer, Print button included, is built.
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        specCodecProvider.overrideWithValue(FakeSpecCodec()),
        if (photos != null) photoSourceProvider.overrideWithValue(photos),
        if (osPrint != null) osPrintServiceProvider.overrideWithValue(osPrint),
      ],
      child: MaterialApp(home: PrintLabelScreen(target: target)),
    ),
  );
}

/// Let the debounced render (a timer, then real async image work — a photo
/// decode takes a few round trips) finish.
Future<void> _settleRender(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 200));
  for (var i = 0; i < 8; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
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

  testWidgets('a chosen photo prints at the head width', (tester) async {
    final png = (await tester.runAsync(_png))!;
    final photos = _FakePhotos(png);
    final target = _RecordingTarget();
    await _pump(tester, target, photos: photos);

    await tester.tap(find.text('Photo'));
    await tester.pump();
    // No camera on this fake platform.
    expect(find.text('Take a photo'), findsNothing);
    await tester.tap(find.text('Choose a photo'));
    await tester.pump();
    await _settleRender(tester);

    await tester.ensureVisible(find.text('Print'));
    await tester.tap(find.text('Print'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(photos.picks, 1);
    final job = target.prints.single;
    expect(job.width, 200);
    // 40x20 scaled to 200 across keeps its 2:1 aspect.
    expect(job.height, 100);
    expect(job.rgb.any((b) => b == 0), isTrue);
  });

  testWidgets('photo mode cannot print until a photo is chosen', (
    tester,
  ) async {
    await _pump(tester, _RecordingTarget(), photos: _FakePhotos(null));
    await tester.tap(find.text('Photo'));
    await tester.pump();
    await tester.tap(find.text('Choose a photo'));
    await _settleRender(tester);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('Print'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('a label can go to a regular printer at its true size', (
    tester,
  ) async {
    final osPrint = FakeOsPrintService();
    final target = _RecordingTarget();
    await _pump(tester, target, osPrint: osPrint);
    await tester.enterText(find.byKey(const ValueKey('label-line-0')), 'Jar');
    await _settleRender(tester);

    await tester.tap(find.byTooltip('Print on a regular printer'));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(osPrint.jobs.single.name, 'Label');
    expect(target.prints, isEmpty, reason: 'not sent to the label printer');
  });

  testWidgets('a PDF becomes its first page, at the printer resolution', (
    tester,
  ) async {
    final png = (await tester.runAsync(_png))!;
    final photos = _FakePhotos(null)
      ..file = Uint8List.fromList('%PDF-1.7 fake'.codeUnits);
    final osPrint = FakeOsPrintService(pages: [png]);
    final target = _RecordingTarget();
    await _pump(tester, target, photos: photos, osPrint: osPrint);

    await tester.tap(find.text('Photo'));
    await tester.pump();
    await tester.tap(find.text('Open a file'));
    await tester.pump();
    await _settleRender(tester);

    expect(osPrint.rasterized.single.dpi, 203);
    await tester.ensureVisible(find.text('Print'));
    await tester.tap(find.text('Print'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    expect(target.prints.single.width, 200);
  });
}

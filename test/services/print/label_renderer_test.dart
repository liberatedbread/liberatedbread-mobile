// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// renderLabel: the composer's pixels, in head coordinates at the printer's
// real width — the one dimension a label printer will not negotiate.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/print/label_content.dart';
import 'package:liberated_bread_mobile/services/print/label_renderer.dart';
import 'package:liberated_bread_mobile/services/print/print_target.dart';

int _dark(Uint8List rgba) {
  var n = 0;
  for (var i = 0; i < rgba.length; i += 4) {
    if (rgba[i] < 128 && rgba[i + 3] > 128) n++;
  }
  return n;
}

bool _whiteAt(RenderedLabel l, int x, int y) {
  final i = (y * l.width + x) * 4;
  return l.rgba[i] > 200 && l.rgba[i + 1] > 200 && l.rgba[i + 2] > 200;
}

const _brother62 = LabelGeometry(widthDots: 696, dpi: 300);
const _d11 = LabelGeometry(widthDots: 96, dpi: 203, lengthDots: 240);

void main() {
  testWidgets('a continuous label is the head width, sized by its content', (
    tester,
  ) async {
    final label = (await tester.runAsync(
      () => renderLabel(const LabelContent(lines: ['Flour']), _brother62),
    ))!;
    expect(label.width, 696);
    expect(label.rgba.length, label.width * label.height * 4);
    expect(label.height, greaterThan(20));
    expect(label.height, lessThan(300));
    expect(_dark(label.rgba), greaterThan(0));
    // The margin is paper.
    expect(_whiteAt(label, 0, 0), isTrue);
    expect(_whiteAt(label, label.width - 1, label.height - 1), isTrue);
  });

  testWidgets('a die-cut label keeps its length whatever the content', (
    tester,
  ) async {
    final label = (await tester.runAsync(
      () => renderLabel(
        const LabelContent(
          lines: ['A very long line that cannot fit across twelve mm'],
        ),
        _d11,
      ),
    ))!;
    expect(label.width, 96);
    expect(label.height, 240);
    expect(_dark(label.rgba), greaterThan(0));
  });

  testWidgets('along the tape, the free dimension is the feed', (tester) async {
    final label = (await tester.runAsync(
      () => renderLabel(
        const LabelContent(lines: ['Kitchen shelf'], alongTape: true),
        const LabelGeometry(widthDots: 96, dpi: 203),
      ),
    ))!;
    expect(label.width, 96);
    // The words run down the tape, so the label is longer than it is wide.
    expect(label.height, greaterThan(label.width));
  });

  testWidgets('a QR code prints beside the text', (tester) async {
    final withQr = (await tester.runAsync(
      () => renderLabel(
        const LabelContent(lines: ['Plug'], qrData: 'https://example.com/x'),
        _brother62,
      ),
    ))!;
    final without = (await tester.runAsync(
      () => renderLabel(const LabelContent(lines: ['Plug']), _brother62),
    ))!;
    expect(_dark(withQr.rgba), greaterThan(_dark(without.rgba)));
  });

  testWidgets('an empty label is blank paper', (tester) async {
    final label = (await tester.runAsync(
      () => renderLabel(const LabelContent(), _d11),
    ))!;
    expect(_dark(label.rgba), 0);
  });

  test('the date is printed as the last line, blanks are dropped', () {
    const content = LabelContent(
      lines: ['  Rye  ', '', ' '],
      dateLine: 'Sep 26, 2026',
    );
    expect(content.printedLines, ['Rye', 'Sep 26, 2026']);
    expect(const LabelContent(lines: ['', '']).isEmpty, isTrue);
  });

  test('fitsInQr refuses what no QR version can hold', () {
    expect(fitsInQr('hello'), isTrue);
    expect(fitsInQr('x' * 5000), isFalse);
  });
}

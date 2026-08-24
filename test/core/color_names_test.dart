// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The swatch rows are sixteen coloured circles with no text: obvious to look
// at, and to a screen reader sixteen identical unlabelled buttons. These are
// the names it reads out, so they are worth pinning — a wrong one is worse
// than none, because it is confidently wrong.

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/color_names.dart';

void main() {
  test('the shipped swatch row gets sensible names', () {
    // Exactly the preset list both light cards carry, in order.
    const swatches = <int>[
      0xFFFFFFFF, 0xFFFFE4B5, 0xFFFF0000, 0xFFFF6600, //
      0xFFFFAA00, 0xFFFFFF00, 0xFFAAFF00, 0xFF00FF00,
      0xFF00FFAA, 0xFF00FFFF, 0xFF00AAFF, 0xFF0000FF,
      0xFF6600FF, 0xFFAA00FF, 0xFFFF00FF, 0xFFFF0066,
    ];
    final names = [for (final c in swatches) colorSwatchName(Color(c))];

    expect(names.first, 'White');
    expect(names[1], 'Warm white',
        reason: 'not "orange" — nobody calls it that');
    expect(names[2], 'Red');
    expect(names[7], 'Green');
    expect(names[9], 'Cyan');
    expect(names[11], 'Blue');

    // Every swatch gets a name, and no two adjacent swatches share one —
    // a row where three buttons all announce "blue" is no better labelled
    // than a row of none.
    expect(names.any((n) => n.isEmpty), isFalse);
    for (var i = 1; i < names.length; i++) {
      expect(names[i], isNot(names[i - 1]),
          reason: 'swatch $i reads the same as its neighbour');
    }
  });

  test('greys are named by lightness, not by whatever hue survives rounding',
      () {
    expect(colorSwatchName(const Color(0xFF000000)), 'Black');
    expect(colorSwatchName(const Color(0xFF808080)), 'Grey');
    expect(colorSwatchName(const Color(0xFFCCCCCC)), 'Light grey');
  });
}

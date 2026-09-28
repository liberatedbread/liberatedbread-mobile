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
import 'package:liberated_bread_mobile/widgets/light_swatches.dart';

void main() {
  test('the shipped swatch row gets sensible names', () {
    // The list both light cards carry, not a copy of it: a hand-kept copy
    // went on checking the old row after the cards' row changed.
    final names = [for (final c in lightSwatches) colorSwatchName(c)];

    // The primaries are pinned by colour, so a reordered row still checks
    // each one — and each must actually be offered.
    const pinned = <int, String>{
      0xFFFFFFFF: 'White',
      0xFFFFE4B5: 'Warm white', // not "orange" — nobody calls it that
      0xFFFF0000: 'Red',
      0xFF00FF00: 'Green',
      0xFF00FFFF: 'Cyan',
      0xFF0000FF: 'Blue',
    };
    for (final MapEntry(key: argb, value: name) in pinned.entries) {
      expect(lightSwatches, contains(Color(argb)));
      expect(colorSwatchName(Color(argb)), name);
    }

    // Every swatch gets a name, and no two adjacent swatches share one —
    // a row where three buttons all announce "blue" is no better labelled
    // than a row of none.
    expect(names.any((n) => n.isEmpty), isFalse);
    for (var i = 1; i < names.length; i++) {
      expect(
        names[i],
        isNot(names[i - 1]),
        reason: 'swatch $i reads the same as its neighbour',
      );
    }
  });

  test(
    'greys are named by lightness, not by whatever hue survives rounding',
    () {
      expect(colorSwatchName(const Color(0xFF000000)), 'Black');
      expect(colorSwatchName(const Color(0xFF808080)), 'Grey');
      expect(colorSwatchName(const Color(0xFFCCCCCC)), 'Light grey');
    },
  );
}

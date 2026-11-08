// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/pride_flags.dart';

({int r, int g, int b}) _pixel(List<int> rgb, int width, int x, int y) {
  final at = (y * width + x) * 3;
  return (r: rgb[at], g: rgb[at + 1], b: rgb[at + 2]);
}

void main() {
  group('renderPrideFlag', () {
    test('fills exactly width x height pixels, for every flag and shape', () {
      for (final flag in prideFlags) {
        for (final (w, h) in [(64, 64), (96, 16), (8, 1), (1, 8), (20, 20)]) {
          expect(
            renderPrideFlag(flag, w, h).length,
            w * h * 3,
            reason: flag.name,
          );
        }
      }
    });

    test('every stripe of the rainbow shows on a tall enough panel', () {
      final flag = prideFlags.first;
      final rgb = renderPrideFlag(flag, 64, 64);
      final seen = {for (var y = 0; y < 64; y++) _pixel(rgb, 64, 32, y)};
      expect(seen, flag.stripes.toSet());
    });

    test('stripes are in flag order from the top', () {
      final flag = prideFlags.first;
      final rgb = renderPrideFlag(flag, 6, 6);
      for (var y = 0; y < 6; y++) {
        expect(_pixel(rgb, 6, 3, y), flag.stripes[y]);
      }
    });

    test('a short panel still draws without running off the stripes', () {
      for (final flag in prideFlags) {
        expect(() => renderPrideFlag(flag, 4, 2), returnsNormally);
      }
    });

    test('chevrons nest from the hoist and leave the fly to the stripes', () {
      final progress = prideFlags.firstWhere((f) => f.chevrons.isNotEmpty);
      final rgb = renderPrideFlag(progress, 64, 64);
      // Innermost at the point's root, in the middle of the hoist.
      expect(_pixel(rgb, 64, 0, 32), progress.chevrons.last);
      // The fly end is just the rainbow.
      expect(_pixel(rgb, 64, 63, 0), progress.stripes.first);
      expect(_pixel(rgb, 64, 63, 63), progress.stripes.last);
      // All of them appear along the middle row.
      final middle = {for (var x = 0; x < 64; x++) _pixel(rgb, 64, x, 32)};
      expect(middle, containsAll(progress.chevrons));
    });
  });

  test('neighbours in the alternation are different flags, and it wraps', () {
    for (var i = 0; i < prideFlags.length; i++) {
      expect(prideFlagAt(i).name, isNot(prideFlagAt(i + 1).name));
    }
    expect(prideFlagAt(prideFlags.length), same(prideFlags.first));
  });

  test('rainbow colours are the whole rainbow, then wrap', () {
    expect(
      {for (var i = 0; i < 6; i++) prideColorAt(i)}.length,
      prideRainbowColors.length,
    );
    expect(prideColorAt(6), prideColorAt(0));
  });

  group('renderRainbowGradient', () {
    test('runs along the long side of a strip', () {
      final rgb = renderRainbowGradient(60, 1);
      expect(rgb.length, 180);
      expect(_pixel(rgb, 60, 0, 0), prideRainbowColors.first);
      expect(_pixel(rgb, 60, 59, 0), prideRainbowColors.last);
      expect({
        for (var x = 0; x < 60; x++) _pixel(rgb, 60, x, 0),
      }, prideRainbowColors.toSet());
    });

    test('and down a tall one', () {
      final rgb = renderRainbowGradient(1, 60);
      expect(_pixel(rgb, 1, 0, 0), prideRainbowColors.first);
      expect(_pixel(rgb, 1, 0, 59), prideRainbowColors.last);
    });
  });
}

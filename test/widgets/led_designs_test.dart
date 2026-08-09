// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/widgets/led_designs.dart';

int _distinctColors(Uint8List rgb) {
  final seen = <int>{};
  for (var i = 0; i < rgb.length; i += 3) {
    seen.add((rgb[i] << 16) | (rgb[i + 1] << 8) | rgb[i + 2]);
  }
  return seen.length;
}

void main() {
  group('defaultDesigns', () {
    test('offers the expected presets including a pride animation', () {
      final designs = defaultDesigns(20, 20);
      expect(
        designs.map((d) => d.name),
        containsAll(<String>[
          'Trans flag',
          'Pride flag',
          'Lesbian flag',
          'Canadian flag',
          'Professor Timbit',
          'Pride animation',
        ]),
      );
      final anim = designs.firstWhere((d) => d.name == 'Pride animation');
      expect(anim.animation, isTrue);
      expect(anim.frames, hasLength(3),
          reason: 'rotates trans -> pride -> lesbian');
      // Only the animation is multi-frame.
      for (final d in designs.where((d) => d.name != 'Pride animation')) {
        expect(d.frames, hasLength(1));
        expect(d.animation, isFalse);
      }
    });

    test('every frame is RGB888 for the canvas and within the 16-colour limit',
        () {
      for (final (w, h) in const [(20, 20), (16, 16), (25, 50), (7, 3)]) {
        for (final d in defaultDesigns(w, h)) {
          for (final frame in d.frames) {
            expect(frame.length, w * h * 3,
                reason: '${d.name} at ${w}x$h must fill the canvas');
            expect(_distinctColors(frame), lessThanOrEqualTo(16),
                reason: '${d.name} at ${w}x$h must fit the palette');
          }
        }
      }
    });

    test('flags scale to any size with the right stripe colours', () {
      // Trans flag: top row light blue, middle row white.
      final trans = defaultDesigns(4, 5).first.frames.first;
      expect(trans.sublist(0, 3), [0x5B, 0xCE, 0xFA]);
      const midRow = (5 ~/ 2) * 4 * 3;
      expect(trans.sublist(midRow, midRow + 3), [0xFF, 0xFF, 0xFF]);
    });

    test('the dog is exact at 20x20 and scales elsewhere', () {
      final at20 = defaultDesigns(20, 20)
          .firstWhere((d) => d.name == 'Professor Timbit')
          .frames
          .first;
      expect(at20.length, 20 * 20 * 3);
      final at10 = defaultDesigns(10, 10)
          .firstWhere((d) => d.name == 'Professor Timbit')
          .frames
          .first;
      expect(at10.length, 10 * 10 * 3);
    });
  });
}

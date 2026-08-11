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

List<int> _pixel(Uint8List rgb, int width, int x, int y) {
  final i = (y * width + x) * 3;
  return [rgb[i], rgb[i + 1], rgb[i + 2]];
}

void main() {
  group('defaultDesigns', () {
    test('offers no presets — and builds nothing — on an unbounded canvas', () {
      // A receipt printer declares a 65535-tall roll: one preset frame would
      // be ~18 MiB and the animations many times that. The menu is omitted
      // rather than allowed to allocate, and the whole design list is empty so
      // nothing is ever built.
      expect(designsFitCanvas(96, 65535), isFalse);
      expect(defaultDesigns(96, 65535), isEmpty);
      // The largest real display (255x255) is well under the budget.
      expect(designsFitCanvas(255, 255), isTrue);
      expect(defaultDesigns(255, 255), isNotEmpty);
      // Degenerate canvases offer nothing either.
      expect(defaultDesigns(0, 20), isEmpty);
    });

    test(
        'offers every procedural preset at a normal size, plus both animations',
        () {
      final designs = defaultDesigns(20, 20);
      expect(
        designs.map((d) => d.name),
        containsAll(<String>[
          'Trans flag',
          'Pride flag',
          'Lesbian flag',
          'Bi flag',
          'Pan flag',
          'Nonbinary flag',
          'Ace flag',
          'American flag',
          'American flag (in distress)',
          'Pride animation',
          'Star animation',
        ]),
      );
      final pride = designs.firstWhere((d) => d.name == 'Pride animation');
      expect(pride.animation, isTrue);
      expect(pride.buildFrames(), hasLength(7),
          reason: 'rotates through all seven pride flags');
      final stars = designs.firstWhere((d) => d.name == 'Star animation');
      expect(stars.animation, isTrue);
      expect(stars.buildFrames(), hasLength(4));
      // Only the animations are multi-frame.
      for (final d in designs.where((d) => !d.animation)) {
        expect(d.buildFrames(), hasLength(1), reason: d.name);
      }
    });

    test('raster designs appear only on canvases with enough pixels', () {
      Iterable<String> namesAt(int w, int h) =>
          defaultDesigns(w, h).map((d) => d.name);

      // The 20x20 curtain gets neither raster image: scaled that small they
      // are noise, not pictures.
      expect(namesAt(20, 20), isNot(contains('Canadian flag')));
      expect(namesAt(20, 20), isNot(contains('Professor Timbit')));

      // From 31x62 (either orientation) the maple leaf resolves; the Timbit
      // portrait still does not.
      for (final (w, h) in const [(31, 62), (62, 31), (40, 70)]) {
        expect(namesAt(w, h),
            containsAll(['Canadian flag', 'Canadian flag (in distress)']),
            reason: '${w}x$h');
        expect(namesAt(w, h), isNot(contains('Professor Timbit')),
            reason: '${w}x$h');
      }
      expect(namesAt(30, 62), isNot(contains('Canadian flag')),
          reason: 'one pixel short of the threshold');

      // A 64x64 panel has room for everything.
      expect(
          namesAt(64, 64),
          containsAll([
            'Canadian flag',
            'Canadian flag (in distress)',
            'Professor Timbit'
          ]));
      expect(namesAt(63, 64), isNot(contains('Professor Timbit')),
          reason: 'the portrait needs 64 on its short side too');
    });

    test('every frame is RGB888 for the canvas and within the 16-colour limit',
        () {
      for (final (w, h) in const [
        (20, 20),
        (16, 16),
        (25, 50),
        (7, 3),
        (31, 62),
        (64, 64),
        (96, 16),
      ]) {
        for (final d in defaultDesigns(w, h)) {
          for (final frame in d.buildFrames()) {
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
      final trans = defaultDesigns(4, 5).first.buildFrames().first;
      expect(trans.sublist(0, 3), [0x5B, 0xCE, 0xFA]);
      const midRow = (5 ~/ 2) * 4 * 3;
      expect(trans.sublist(midRow, midRow + 3), [0xFF, 0xFF, 0xFF]);
    });

    test('the bi flag renders its 2:1:2 proportions', () {
      // 10 rows: magenta on 0-3, lavender on 4-5, blue on 6-9.
      final bi = defaultDesigns(3, 10)
          .firstWhere((d) => d.name == 'Bi flag')
          .buildFrames()
          .first;
      expect(_pixel(bi, 3, 0, 0), [0xD6, 0x02, 0x70]);
      expect(_pixel(bi, 3, 0, 3), [0xD6, 0x02, 0x70]);
      expect(_pixel(bi, 3, 0, 4), [0x9B, 0x4F, 0x96]);
      expect(_pixel(bi, 3, 0, 5), [0x9B, 0x4F, 0x96]);
      expect(_pixel(bi, 3, 0, 6), [0x00, 0x38, 0xA8]);
      expect(_pixel(bi, 3, 0, 9), [0x00, 0x38, 0xA8]);
    });

    test('the American flag has its canton, stripes and stars', () {
      const w = 65, h = 39;
      final flag = defaultDesigns(w, h)
          .firstWhere((d) => d.name == 'American flag')
          .buildFrames()
          .first;
      const red = [0xB2, 0x22, 0x34];
      const blue = [0x3C, 0x3B, 0x6E];
      // Canton top-left; first stripe red outside it; last stripe red.
      expect(_pixel(flag, w, 0, 0), blue);
      expect(_pixel(flag, w, w - 1, 0), red);
      expect(_pixel(flag, w, 0, h - 1), red);
      // Stars: the canton is not solid blue.
      final cantonColors = <List<int>>{};
      for (var y = 0; y < h * 7 ~/ 13; y++) {
        for (var x = 0; x < w * 2 ~/ 5; x++) {
          cantonColors.add(_pixel(flag, w, x, y));
        }
      }
      expect(
          cantonColors.map((c) => c.join(',')).toSet().length, greaterThan(1),
          reason: 'a canton with room for stars must show them');
    });

    test('the distress variant is the flag rotated 180 degrees', () {
      const w = 65, h = 39;
      final designs = defaultDesigns(w, h);
      final regular = designs
          .firstWhere((d) => d.name == 'American flag')
          .buildFrames()
          .first;
      final distress = designs
          .firstWhere((d) => d.name == 'American flag (in distress)')
          .buildFrames()
          .first;
      for (final (x, y) in const [(0, 0), (12, 7), (64, 38), (30, 20)]) {
        expect(
          _pixel(distress, w, w - 1 - x, h - 1 - y),
          _pixel(regular, w, x, y),
          reason: 'pixel ($x,$y) must land rotated, not mirrored',
        );
      }
    });

    test('the star animation twinkles deterministically', () {
      final a = defaultDesigns(32, 32)
          .firstWhere((d) => d.name == 'Star animation')
          .buildFrames();
      final b = defaultDesigns(32, 32)
          .firstWhere((d) => d.name == 'Star animation')
          .buildFrames();
      for (var i = 0; i < a.length; i++) {
        expect(a[i], b[i],
            reason: 'the same canvas must always yield the same sky');
      }
      // Some stars are lit in every frame, and the frames differ from one
      // another — a shimmer, not a static image or synchronized blink.
      for (final frame in a) {
        expect(frame.any((byte) => byte != 0), isTrue,
            reason: 'every frame has lit stars');
      }
      expect(a[0], isNot(equals(a[1])));
      expect(a[1], isNot(equals(a[2])));
    });

    test('the dog is offered from 64x64 up and scales to the canvas', () {
      final at64 = defaultDesigns(64, 64)
          .firstWhere((d) => d.name == 'Professor Timbit')
          .buildFrames()
          .first;
      expect(at64.length, 64 * 64 * 3);
      final at100 = defaultDesigns(100, 128)
          .firstWhere((d) => d.name == 'Professor Timbit')
          .buildFrames()
          .first;
      expect(at100.length, 100 * 128 * 3);
    });
  });

  group('canvasReaches', () {
    test('is orientation-agnostic', () {
      expect(canvasReaches(31, 62, 31, 62), isTrue);
      expect(canvasReaches(62, 31, 31, 62), isTrue);
      expect(canvasReaches(62, 30, 31, 62), isFalse);
      expect(canvasReaches(30, 62, 31, 62), isFalse);
      expect(canvasReaches(100, 100, 64, 64), isTrue);
    });
  });
}

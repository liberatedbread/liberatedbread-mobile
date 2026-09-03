// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Guards the launch screen against reverting to Flutter's placeholder.
//
// The template ships three 1x1-pixel PNGs and a hard-coded white background,
// and that is what the app booted to for its whole life: a blank white flash
// with no branding, in dark mode too. Nothing catches it, because a 1x1 image
// is a perfectly valid image — the build succeeds, the storyboard renders, and
// the only symptom is a first impression nobody looks at twice.
//
// Two properties matter, and the pixel one is the one that silently regresses:
// re-running any icon-generation tool that also writes LaunchImage will put
// placeholders back.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const String _imageSet = 'ios/Runner/Assets.xcassets/LaunchImage.imageset';
const String _storyboard = 'ios/Runner/Base.lproj/LaunchScreen.storyboard';

/// Width and height from a PNG's IHDR, which is always the first chunk.
///
/// Byte 8-15 are the chunk length and type; 16-23 are two big-endian uint32s.
/// Enough for "is this a placeholder", with no image package to depend on.
({int width, int height}) _pngSize(File file) {
  final bytes = file.readAsBytesSync();
  if (bytes.length < 24) {
    fail('${file.path} is ${bytes.length} bytes — not a PNG.');
  }
  int be32(int at) =>
      (bytes[at] << 24) | (bytes[at + 1] << 16) | (bytes[at + 2] << 8) |
      bytes[at + 3];
  return (width: be32(16), height: be32(20));
}

void main() {
  group('iOS launch screen is the app, not the template', () {
    test('the launch images are real artwork, not 1x1 placeholders', () {
      final dir = Directory(_imageSet);
      expect(
        dir.existsSync(),
        isTrue,
        reason: '$_imageSet is missing; the storyboard references a '
            'LaunchImage that would not resolve.',
      );

      final pngs = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.png'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));

      expect(pngs, hasLength(3),
          reason: 'Expected LaunchImage at 1x, 2x and 3x in $_imageSet.');

      for (final png in pngs) {
        final size = _pngSize(png);
        expect(
          size.width,
          greaterThan(1),
          reason: '${png.path} is ${size.width}x${size.height}. Flutter\'s '
              'template ships 1x1 placeholders, so the app boots to a blank '
              'flash with no branding. Regenerate from the app icon, e.g.\n'
              '  sips -Z 128 (1x) / 256 (2x) / 384 (3x) from '
              'AppIcon.appiconset/Icon-App-1024x1024@1x.png\n'
              'An icon-generation tool that also writes LaunchImage will put '
              'the placeholders back, which is what this test is for.',
        );
        expect(size.width, size.height,
            reason: '${png.path} should be square like the app mark.');
      }

      // 1x/2x/3x have to actually differ in scale, or the @3x device gets a
      // blurry upscale of the @1x asset.
      final widths = pngs.map((p) => _pngSize(p).width).toList();
      expect(
        widths.toSet(),
        hasLength(3),
        reason: 'The three LaunchImage assets are all $widths — they must be '
            'genuinely 1x, 2x and 3x renditions, not the same file copied.',
      );
    });

    test('the background follows the system appearance', () {
      final xml = readRepoFile(
        _storyboard,
        consequence: 'Without the launch storyboard iOS shows a black screen '
            'while the app starts.',
      );

      expect(
        xml,
        contains('systemBackgroundColor'),
        reason: 'The launch screen background must be '
            'systemBackgroundColor in $_storyboard. Flutter\'s template '
            'hard-codes white (red="1" green="1" blue="1"), which flashes a '
            'bright rectangle on every cold start in dark mode — the one '
            'moment the user has not asked for anything yet.',
      );
      expect(
        xml,
        isNot(contains('red="1" green="1" blue="1"')),
        reason: 'A hard-coded white background is back in $_storyboard.',
      );
    });
  });
}

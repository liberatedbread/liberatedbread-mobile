// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Linux app icon is a contract with no manifest to hold it together.
//
// Every other platform declares its icons somewhere the toolchain reads: an
// asset catalogue, a mipmap bucket, a web manifest. GTK has none of that, so
// the icon only appears if FIVE files agree on one list of sizes:
//
//   tool/branding/generate_icons.mjs      renders linux/resources/app_icon_<n>.png
//   linux/CMakeLists.txt                  copies that directory into the bundle
//   linux/my_application.cc               loads them BY NAME at startup
//   scripts/verify_linux_bundle.sh        asserts the built bundle has them
//   scripts/install-linux-desktop-entry.sh installs them for Wayland
//
// Nothing in a build fails when they drift. The loader logs a g_debug line for
// a file it cannot find and carries on, so dropping a size from the generator
// leaves a green build, a working app, and a window that renders a downscaled
// smear in the taskbar — discovered by looking at a desktop, which CI does not
// have and which nobody does on the commit that broke it.
//
// So this is a Dart test that reads C++, JavaScript, CMake and shell. That is
// unusual, and it is the point: this is the only place in the repo where all
// five lists are visible at once, and `flutter test` is the one command every
// contributor already runs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Sizes parsed out of a source file, in the order they appear.
List<int> _sizesIn(String source, RegExp pattern, String what) {
  final match = pattern.firstMatch(source);
  expect(match, isNotNull,
      reason: 'Could not find $what — it was renamed or removed, and this '
          'test can no longer check it. Fix the pattern in this test.');
  return RegExp(r'\d+')
      .allMatches(match!.group(1)!)
      .map((m) => int.parse(m.group(0)!))
      .toList();
}

String _read(String path) {
  final file = File(path);
  expect(file.existsSync(), isTrue, reason: '$path must exist');
  return file.readAsStringSync();
}

void main() {
  // The list itself. Changing the shipped sizes means changing this line and
  // then the five files below — which is the whole reason the test exists.
  const expected = [16, 24, 32, 48, 64, 128, 256];

  test('every Linux icon size is on disk and is a real PNG', () {
    for (final size in expected) {
      final file = File('linux/resources/app_icon_$size.png');
      expect(file.existsSync(), isTrue,
          reason: 'linux/resources/app_icon_$size.png is missing. Regenerate '
              'with: cd tool/branding && npm run icons');

      // PNG magic. Catches a placeholder, a truncated write, or a file that a
      // conversion step left as something else entirely.
      final bytes = file.readAsBytesSync();
      expect(bytes.length, greaterThan(100),
          reason: 'app_icon_$size.png is too small to be a real icon');
      expect(bytes.take(8).toList(),
          [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A],
          reason: 'app_icon_$size.png is not a PNG');

      // Dimensions live in the IHDR chunk: big-endian width then height at
      // byte 16. Asserting them catches the failure that matters most here —
      // a file named for one size holding another, which GTK would happily
      // load and then scale, defeating the point of shipping seven of them.
      int be32(int offset) =>
          (bytes[offset] << 24) |
          (bytes[offset + 1] << 16) |
          (bytes[offset + 2] << 8) |
          bytes[offset + 3];
      expect(be32(16), size,
          reason: 'app_icon_$size.png is not ${size}px wide');
      expect(be32(20), size,
          reason: 'app_icon_$size.png is not ${size}px tall');
    }
  });

  test('the icon generator renders exactly those sizes', () {
    final source = _read('tool/branding/generate_icons.mjs');
    final sizes = _sizesIn(
      source,
      RegExp(r'const LINUX = \[([^\]]*)\]'),
      'the LINUX size list in generate_icons.mjs',
    );
    expect(sizes, expected);

    // The output path is half the contract; my_application.cc reads these
    // names literally.
    expect(source, contains("const LINUX_DIR = 'linux/resources'"),
        reason: 'The generator must write to linux/resources/ — CMake copies '
            'that exact directory into the bundle.');
    expect(source, contains(r'app_icon_${size}.png'),
        reason: 'The generated file name must stay app_icon_<size>.png');
  });

  test('the GTK runner loads exactly those sizes', () {
    final sizes = _sizesIn(
      _read('linux/my_application.cc'),
      RegExp(r'kAppIconSizes\[\] = \{([^}]*)\}'),
      'kAppIconSizes in my_application.cc',
    );
    expect(sizes, expected,
        reason: 'my_application.cc asks for sizes the generator does not '
            'render (or ignores ones it does). A size it cannot find is '
            'skipped silently at runtime.');
  });

  test('CMake copies the icons into the bundle', () {
    final cmake = _read('linux/CMakeLists.txt');
    expect(
      cmake.contains(RegExp(
          r'install\(DIRECTORY "\$\{CMAKE_CURRENT_SOURCE_DIR\}/resources"')),
      isTrue,
      reason: 'linux/CMakeLists.txt no longer installs linux/resources/. '
          'Without it the bundle ships no icons and the loader finds nothing. '
          'This is exactly how `flutter create` regenerating the scaffold '
          'would break it — the same way it resets APPLICATION_ID.',
    );
  });

  test('the bundle verifier and the desktop-entry installer agree', () {
    for (final script in const [
      'scripts/verify_linux_bundle.sh',
      'scripts/install-linux-desktop-entry.sh',
    ]) {
      final sizes = _sizesIn(
        _read(script),
        RegExp(r'ICON_SIZES=\(([^)]*)\)'),
        'ICON_SIZES in $script',
      );
      expect(sizes, expected, reason: '$script checks the wrong sizes');
    }
  });

  // Not a size, but the other half of "the icon actually shows up": a Wayland
  // compositor draws no window icon at all and matches the surface's app_id
  // against an installed .desktop file instead. The process name set here IS
  // that app_id, and the installer names its entry after the same string.
  test('the Wayland app_id matches the desktop entry it is installed under',
      () {
    expect(_read('linux/main.cc'), contains('g_set_prgname(APPLICATION_ID)'),
        reason: 'Without this the Wayland app_id is the binary name, which '
            'matches no .desktop file, and the alt-tab switcher shows a '
            'generic icon however many PNGs the app loads.');

    const appId = 'ca.pigscanfly.liberatedbread';
    expect(_read('linux/CMakeLists.txt'),
        contains('set(APPLICATION_ID "$appId")'));
    expect(_read('scripts/install-linux-desktop-entry.sh'),
        contains('APP_ID="$appId"'));
  });
}

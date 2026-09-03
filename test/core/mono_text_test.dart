// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Guards the one property that makes monospaced text actually monospaced on
// Apple platforms: a fallback list.
//
// `fontFamily: 'monospace'` is an Android alias. It resolves through
// /system/etc/fonts.xml there and matches nothing at all on iOS or macOS,
// where CoreText then hands back the default proportional face. Nothing
// throws, nothing logs, and the text still appears — it is simply no longer
// aligned, in the exact places the app shows hex dumps and credentials that
// people read aloud and retype.
//
// That is why this is a lint-shaped test rather than a widget test: the
// failure is invisible at runtime on the platform that has it, so the only
// reliable moment to catch it is when someone writes the bare string again.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/mono_text.dart';

/// Everything under lib/, minus the file that legitimately defines the alias.
Iterable<File> _libDartFiles() sync* {
  final lib = Directory('lib');
  if (!lib.existsSync()) {
    fail('lib/ not found — run this from the repository root.');
  }
  for (final entity in lib.listSync(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    if (entity.path.endsWith('core/mono_text.dart')) continue;
    // Generated bridge bindings are never hand-written and never style text.
    if (entity.path.contains('lib/src/rust/')) continue;
    yield entity;
  }
}

void main() {
  group('monospaced text survives the trip to iOS', () {
    test('the shared style names a family Apple platforms actually have', () {
      expect(
        monoTextStyle.fontFamilyFallback,
        isNotNull,
        reason: 'monoTextStyle must carry a fontFamilyFallback list. Without '
            "one, `fontFamily: 'monospace'` matches no font on iOS or macOS "
            'and Flutter silently substitutes the default proportional face.',
      );
      expect(
        monoTextStyle.fontFamilyFallback,
        contains('Menlo'),
        reason: 'The fallback list must include a font that exists on Apple '
            'platforms. Menlo has shipped since iOS 4 and macOS 10.6; without '
            'it the hex dumps in raw_characteristic_widget.dart and the BLID '
            'and password in roomba_adoption_screen.dart lose their column '
            'alignment on exactly the platform where they are read aloud.',
      );
    });

    test('the extension keeps the rest of a theme style intact', () {
      const base = TextStyle(fontSize: 17, fontWeight: FontWeight.w600);
      final mono = base.monospaced;
      expect(mono.fontSize, 17);
      expect(mono.fontWeight, FontWeight.w600);
      expect(mono.fontFamilyFallback, contains('Menlo'));
    });

    test('no lib/ file writes a bare monospace family', () {
      final offenders = <String>[];
      for (final file in _libDartFiles()) {
        final lines = file.readAsLinesSync();
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains("fontFamily: 'monospace'")) continue;
          // A fallback on the same or the next line is the correct form.
          final window = [
            lines[i],
            if (i + 1 < lines.length) lines[i + 1],
            if (i + 2 < lines.length) lines[i + 2],
          ].join(' ');
          if (window.contains('fontFamilyFallback')) continue;
          offenders.add('${file.path}:${i + 1}');
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: "These lines set fontFamily: 'monospace' with no "
            'fontFamilyFallback, so the text renders in the default '
            'proportional face on iOS and macOS:\n  ${offenders.join('\n  ')}\n'
            'Use monoTextStyle / monoTextStyleOf() from lib/core/mono_text.dart, '
            'or `.monospaced` on an existing style.',
      );
    });
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/theme.dart';

/// `#RRGGBB`, matching how the palette is written in brand.json.
String _hex(Color color) {
  // ignore: deprecated_member_use — .value is the stable 32-bit ARGB accessor
  // across the Flutter versions this project supports.
  final rgb = color.toARGB32() & 0xFFFFFF;
  return '#${rgb.toRadixString(16).toUpperCase().padLeft(6, '0')}';
}

/// WCAG 2.1 relative luminance.
double _luminance(Color c) {
  double channel(int v) {
    final s = v / 255.0;
    return s <= 0.03928
        ? s / 12.92
        : math.pow((s + 0.055) / 1.055, 2.4) as double;
  }

  // ignore: deprecated_member_use
  return 0.2126 * channel(c.red) +
      // ignore: deprecated_member_use
      0.7152 * channel(c.green) +
      // ignore: deprecated_member_use
      0.0722 * channel(c.blue);
}

/// WCAG 2.1 contrast ratio between two opaque colours, 1.0 to 21.0.
double _contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  // The palette is duplicated out of Dart by necessity: the icon generator, the
  // Android adaptive-icon background and the web manifest can't read Dart
  // constants. brand.json is the source of truth for those, so this test is
  // what stops the app theme from quietly drifting away from the shipped icons.
  // If this fails: reconcile lib/core/theme.dart with tool/branding/brand.json,
  // then re-run `npm run icons` in tool/branding. See docs/BRANDING.md.
  test('theme constants match tool/branding/brand.json', () {
    final file = File('tool/branding/brand.json');
    expect(file.existsSync(), isTrue,
        reason: 'brand.json is the palette source of truth; it must exist');

    final brand = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

    expect(_hex(LiberatedBreadTheme.teal), brand['teal']);
    expect(_hex(LiberatedBreadTheme.tealDark), brand['tealDark']);
    expect(_hex(LiberatedBreadTheme.breadOrange), brand['breadOrange']);
  });

  test('brand.json carries every colour the icon generator needs', () {
    final brand = jsonDecode(
      File('tool/branding/brand.json').readAsStringSync(),
    ) as Map<String, dynamic>;

    for (final key in ['teal', 'tealDark', 'breadOrange', 'crust', 'face']) {
      expect(brand[key], isA<String>(), reason: '$key must be defined');
      expect(brand[key] as String, matches(RegExp(r'^#[0-9A-Fa-f]{6}$')),
          reason: '$key must be a #RRGGBB hex string');
    }
  });

  // Both brand colours are light enough that white-on-brand lands at ~2.4:1,
  // under even the 3:1 WCAG floor for UI graphics. These guard the two
  // highest-traffic branded surfaces so a future palette change can't quietly
  // reintroduce unreadable chrome.
  group('brand surfaces meet WCAG contrast', () {
    const minimum = 4.5; // AA for normal text; 3:1 is the floor for UI graphics

    test('ink is the mascot face colour from brand.json', () {
      final brand = jsonDecode(
        File('tool/branding/brand.json').readAsStringSync(),
      ) as Map<String, dynamic>;
      expect(_hex(LiberatedBreadTheme.ink), brand['face']);
    });

    test('app bar foreground contrasts with its fill in both themes', () {
      for (final theme in [
        LiberatedBreadTheme.light,
        LiberatedBreadTheme.dark
      ]) {
        final bar = theme.appBarTheme;
        final ratio = _contrast(bar.foregroundColor!, bar.backgroundColor!);
        expect(ratio, greaterThanOrEqualTo(minimum),
            reason: 'app bar ${bar.foregroundColor} on ${bar.backgroundColor} '
                'is ${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('scan FAB foreground contrasts with the bread-orange fill', () {
      for (final theme in [
        LiberatedBreadTheme.light,
        LiberatedBreadTheme.dark
      ]) {
        final fab = theme.floatingActionButtonTheme;
        final ratio = _contrast(fab.foregroundColor!, fab.backgroundColor!);
        expect(ratio, greaterThanOrEqualTo(minimum),
            reason: 'FAB ${fab.foregroundColor} on ${fab.backgroundColor} '
                'is ${ratio.toStringAsFixed(2)}:1');
      }
    });

    test('onBrand flips to white once a background is dark enough', () {
      expect(LiberatedBreadTheme.onBrand(LiberatedBreadTheme.teal),
          LiberatedBreadTheme.ink);
      expect(LiberatedBreadTheme.onBrand(LiberatedBreadTheme.breadOrange),
          LiberatedBreadTheme.ink);
      expect(LiberatedBreadTheme.onBrand(LiberatedBreadTheme.tealDark),
          Colors.white);
    });
  });

  test('the brand background drives the Android adaptive-icon layer', () {
    final brand = jsonDecode(
      File('tool/branding/brand.json').readAsStringSync(),
    ) as Map<String, dynamic>;
    final xml = File(
      'android/app/src/main/res/values/ic_launcher_background.xml',
    ).readAsStringSync();

    expect(xml, contains(brand['teal'] as String),
        reason: 'run `npm run icons` in tool/branding to re-sync');
  });

  // The splash and the adaptive-icon background both point at the generated
  // colour resource instead of repeating the hex, which is what lets a palette
  // change reach them without a manual edit. Hardcoding a colour back into
  // either file would silently break that.
  test('android splash follows the generated brand background', () {
    for (final path in [
      'android/app/src/main/res/drawable/launch_background.xml',
      'android/app/src/main/res/drawable-v21/launch_background.xml',
    ]) {
      final xml = File(path).readAsStringSync();
      expect(xml, contains('@color/ic_launcher_background'),
          reason: '$path should reference the generated brand colour so the '
              'cold-start splash matches the app bar');
      expect(xml, isNot(contains('@android:color/white')),
          reason: '$path still flashes stock white on cold start');
    }
  });
}

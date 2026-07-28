// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// Liberated Bread brand theme.
///
/// The palette is taken straight from the mascot: a warm goldenrod "bread"
/// orange for the primary brand colour and the logo's turquoise as the accent,
/// sat on top of a Material 3 scheme so every colour role stays contrast-safe.
/// The secondary role is pinned to a teal-seeded scheme so its
/// container/on-container pair (used by cards like `TailscaleSuggestionCard`)
/// keeps guaranteed contrast.
///
/// These constants are mirrored in `tool/branding/brand.json`, which also
/// drives the generated app icons and the Android/web chrome colours.
/// `test/core/brand_test.dart` fails if the two drift apart, so change both
/// together and re-run the icon generator — see `docs/BRANDING.md`.
class LiberatedBreadTheme {
  LiberatedBreadTheme._();

  /// Goldenrod "bread" orange — the mascot body and the wordmark.
  static const Color breadOrange = Color(0xFFE8963C);

  /// Logo turquoise — the background the bread flexes on.
  static const Color teal = Color(0xFF2FB9BF);

  /// A deeper teal for the dark-theme app bar so it doesn't glare.
  static const Color tealDark = Color(0xFF14595C);

  /// The mascot's near-black warm brown, used for foregrounds on the light
  /// brand colours instead of pure black — same legibility, less harsh.
  static const Color ink = Color(0xFF3A2410);

  /// A foreground that stays legible on [background].
  ///
  /// Both brand colours are far too light for white text: white sits at
  /// 2.38:1 on the turquoise and 2.37:1 on the bread orange, under even the
  /// 3:1 WCAG floor for UI graphics. [ink] reaches 6.1:1 on both. Deriving the
  /// choice from luminance rather than hardcoding it also keeps this correct
  /// if the palette in `tool/branding/brand.json` changes later.
  static Color onBrand(Color background) =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark
          ? Colors.white
          : ink;

  static final ThemeData light = _build(Brightness.light);
  static final ThemeData dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final barColor = isDark ? tealDark : teal;
    final base = ColorScheme.fromSeed(
      seedColor: breadOrange,
      brightness: brightness,
    );
    // Pull the secondary role (and its container pair) from a teal-seeded
    // scheme so the logo turquoise shows up as a proper, contrast-checked accent
    // rather than a one-off hardcoded colour.
    final tealSeed = ColorScheme.fromSeed(
      seedColor: teal,
      brightness: brightness,
    );
    final scheme = base.copyWith(
      secondary: tealSeed.primary,
      onSecondary: tealSeed.onPrimary,
      secondaryContainer: tealSeed.primaryContainer,
      onSecondaryContainer: tealSeed.onPrimaryContainer,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      // A turquoise top bar echoes the logo background; bread-orange drives the
      // primary call-to-action (the scan FAB). Foregrounds are derived from the
      // fill via [onBrand] so both stay above the WCAG contrast floor.
      appBarTheme: AppBarTheme(
        backgroundColor: barColor,
        foregroundColor: onBrand(barColor),
        elevation: 0,
        centerTitle: false,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: breadOrange,
        foregroundColor: onBrand(breadOrange),
      ),
    );
  }
}

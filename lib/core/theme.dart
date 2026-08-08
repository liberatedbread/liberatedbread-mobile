// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// Liberated Bread brand theme.
///
/// The palette is taken straight from the mascot: a warm goldenrod "bread"
/// orange for the primary brand colour and the logo's blush pink as the accent,
/// sat on top of a Material 3 scheme so every colour role stays contrast-safe.
/// The secondary role is pinned to a blush-seeded scheme so its
/// container/on-container pair (used by cards like `TailscaleSuggestionCard`)
/// keeps guaranteed contrast.
///
/// These constants are mirrored in `tool/branding/brand.json`, which also
/// drives the generated app icons and the Android/web chrome colours.
/// `test/core/brand_test.dart` fails if the two drift apart, so change both
/// together and re-run the icon generator — see `docs/BRANDING.md`.
class LiberatedBreadTheme {
  LiberatedBreadTheme._();

  /// Goldenrod "bread" orange — the mascot's lit crust.
  static const Color breadOrange = Color(0xFFEF900A);

  /// Logo blush — the background the bread flexes on.
  static const Color blush = Color(0xFFEBA1C6);

  /// A deeper blush for the dark-theme app bar so it doesn't glare. Same hue
  /// as [blush] with its lightness roughly halved, which is the relationship
  /// the previous palette's dark accent had to its light one.
  static const Color blushDeep = Color(0xFF9E1D5D);

  /// The mascot's near-black navy, the colour it is outlined in. Used for
  /// foregrounds on the light brand colours instead of pure black — same
  /// legibility, less harsh.
  static const Color ink = Color(0xFF112545);

  /// A foreground that stays legible on [background].
  ///
  /// Both brand colours are far too light for white text: white sits at
  /// 2.01:1 on the blush and 2.42:1 on the bread orange, under even the
  /// 3:1 WCAG floor for UI graphics. [ink] reaches 7.60:1 and 6.30:1. Deriving
  /// the choice from luminance rather than hardcoding it also keeps this
  /// correct if the palette in `tool/branding/brand.json` changes later.
  static Color onBrand(Color background) =>
      ThemeData.estimateBrightnessForColor(background) == Brightness.dark
          ? Colors.white
          : ink;

  static final ThemeData light = _build(Brightness.light);
  static final ThemeData dark = _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final base = ColorScheme.fromSeed(
      seedColor: breadOrange,
      brightness: brightness,
    );
    // Pull the secondary role (and its container pair) from a blush-seeded
    // scheme so the logo pink shows up as a proper, contrast-checked accent
    // rather than a one-off hardcoded colour.
    final blushSeed = ColorScheme.fromSeed(
      seedColor: blush,
      brightness: brightness,
    );
    final scheme = base.copyWith(
      secondary: blushSeed.primary,
      onSecondary: blushSeed.onPrimary,
      secondaryContainer: blushSeed.primaryContainer,
      onSecondaryContainer: blushSeed.onPrimaryContainer,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      // The top bar sits flush with the page surface rather than carrying a
      // blush fill: with the content surfaces doing the work, a coloured bar
      // competed with the device cards for attention. The brand still leads
      // through the bread-orange scan FAB and the blush accents (radar
      // sweep, signal meters, status dots). Foreground is derived from the fill
      // via [onBrand], so it stays above the WCAG contrast floor in both
      // brightnesses — `brand_test.dart` enforces that ratio.
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: onBrand(scheme.surface),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: breadOrange,
        foregroundColor: onBrand(breadOrange),
      ),
    );
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// The monospace family list to use anywhere byte columns, hex, or credentials
/// are shown.
///
/// `fontFamily: 'monospace'` on its own is an ANDROID-ONLY alias. Android
/// resolves it through `/system/etc/fonts.xml`, which maps the name to Droid
/// Sans Mono; Apple platforms have no font by that name at all, so CoreText
/// finds nothing and Flutter falls back to the default proportional face. The
/// text still renders, which is why this survived: it just silently stops
/// being monospaced on exactly the platform where it is being read aloud or
/// retyped.
///
/// That matters in the places this is used. A hex dump whose columns do not
/// line up is materially harder to compare against a spec, and a Roomba BLID
/// or password in a proportional face is where `0` versus `O` and `l` versus
/// `1` stop being distinguishable — and those are read off the screen and
/// typed into something else by hand.
///
/// `fontFamilyFallback` is the fix: Flutter walks the list in order, so
/// Android still gets its alias from `fontFamily` and Apple platforms land on
/// Menlo (present since iOS 4 / OS X 10.6). Courier New and Courier are there
/// for anything that has neither, and `monospace` repeats at the end because
/// some Linux fontconfig setups expose it as a real family rather than an
/// alias.
///
/// Bundling a font would also work and would pin the exact glyphs, at the cost
/// of ~200 KB in an app whose bundle is already 7 MB of device specs. The
/// system faces are good enough for hex.
const List<String> monoFontFallback = <String>[
  'Menlo',
  'Courier New',
  'Courier',
  'monospace',
];

/// A [TextStyle] that is actually monospaced on every platform the app ships
/// to.
///
/// Prefer this over writing `fontFamily: 'monospace'` by hand;
/// `test/core/mono_text_test.dart` fails the build if a bare one reappears in
/// `lib/`.
const TextStyle monoTextStyle = TextStyle(
  fontFamily: 'monospace',
  fontFamilyFallback: monoFontFallback,
);

/// [monoTextStyle] at a given size, for the call sites that set one.
TextStyle monoTextStyleOf({double? fontSize, Color? color}) =>
    monoTextStyle.copyWith(fontSize: fontSize, color: color);

/// Make an existing style monospaced, keeping everything else about it.
///
/// For the `Theme.of(context).textTheme...` call sites, where the size and
/// weight come from the theme and only the family should change.
extension MonospacedTextStyle on TextStyle {
  TextStyle get monospaced => copyWith(
        fontFamily: 'monospace',
        fontFamilyFallback: monoFontFallback,
      );
}

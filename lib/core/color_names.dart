// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:ui';

/// A name for one of the preset swatches, for people who cannot see it.
///
/// The colour pickers are a row of coloured circles with no text anywhere:
/// visually obvious, and to a screen reader a row of identical unlabelled
/// buttons. There is no way to choose among them by ear.
///
/// Named by hue rather than by hex, because "reddish orange" is what a
/// person is choosing and "FF6600" is not. The swatch lists are fixed and
/// small (sixteen presets, shared by the BLE and network cards), so this
/// classifies rather than enumerates: any colour a future list adds still
/// gets an honest name.
String colorSwatchName(Color color) {
  final r = color.r, g = color.g, b = color.b;
  final max = [r, g, b].reduce((a, b) => a > b ? a : b);
  final min = [r, g, b].reduce((a, b) => a < b ? a : b);
  final delta = max - min;

  // Near-greys first: hue is meaningless once the channels converge, and
  // "white" is the first swatch in every list.
  if (delta < 0.08) {
    if (max > 0.9) return 'White';
    if (max < 0.1) return 'Black';
    // 0.7, not 0.5: mid-grey (0x808080) sits a hair above half and calling
    // it light is the kind of small wrongness that makes a label useless.
    return max > 0.7 ? 'Light grey' : 'Grey';
  }

  // Hue in degrees, the usual piecewise formula.
  double hue;
  if (max == r) {
    hue = 60 * (((g - b) / delta) % 6);
  } else if (max == g) {
    hue = 60 * (((b - r) / delta) + 2);
  } else {
    hue = 60 * (((r - g) / delta) + 4);
  }
  if (hue < 0) hue += 360;

  final name = switch (hue) {
    < 15 || >= 345 => 'Red',
    // Orange and amber are split because the shipped row carries both
    // (0xFF6600 and 0xFFAA00) and two neighbours announcing the same word
    // are no better labelled than none.
    < 32 => 'Orange',
    < 50 => 'Amber',
    < 70 => 'Yellow',
    < 100 => 'Yellow green',
    < 150 => 'Green',
    < 175 => 'Spring green',
    < 200 => 'Cyan',
    < 230 => 'Azure',
    < 255 => 'Blue',
    // 264 and 280 are both in the shipped row, so violet splits too.
    < 272 => 'Violet',
    < 292 => 'Purple',
    < 320 => 'Magenta',
    _ => 'Pink',
  };

  // The warm off-white every list carries as its second swatch reads as a
  // pale orange by hue alone, which is not what anyone would call it.
  if (min > 0.6 && delta < 0.35) return 'Warm white';
  return name;
}

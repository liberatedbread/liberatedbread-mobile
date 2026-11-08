// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// What a group's pride mode puts on its devices: flags, as plain RGB888
// canvases any panel's encoder takes, and the rainbow in the two other forms a
// light can show it — a gradient along an addressable string, and one colour
// each for lights that hold only one.

import 'dart:typed_data';

/// One colour, as the 0–255 channels every encoder and light command takes.
typedef Rgb = ({int r, int g, int b});

Rgb _hex(int v) => (r: (v >> 16) & 0xFF, g: (v >> 8) & 0xFF, b: v & 0xFF);

/// A flag: horizontal [stripes] of equal height (repeat a colour for a wider
/// band), optionally with [chevrons] coming in from the hoist, outermost
/// first.
class PrideFlag {
  final String name;
  final List<Rgb> stripes;
  final List<Rgb> chevrons;

  const PrideFlag(this.name, this.stripes, {this.chevrons = const []});
}

final List<Rgb> _rainbowStripes = [
  _hex(0xE40303),
  _hex(0xFF8C00),
  _hex(0xFFED00),
  _hex(0x008026),
  _hex(0x004DFF),
  _hex(0x750787),
];

/// The flags, in the order they alternate: the rainbow first, and with
/// neighbours that look different at a glance on a low-resolution panel.
final List<PrideFlag> prideFlags = [
  PrideFlag('Rainbow', _rainbowStripes),
  PrideFlag('Transgender', [
    _hex(0x5BCEFA),
    _hex(0xF5A9B8),
    _hex(0xFFFFFF),
    _hex(0xF5A9B8),
    _hex(0x5BCEFA),
  ]),
  PrideFlag(
    'Progress',
    _rainbowStripes,
    chevrons: [
      _hex(0x000000),
      _hex(0x784F17),
      _hex(0x5BCEFA),
      _hex(0xF5A9B8),
      _hex(0xFFFFFF),
    ],
  ),
  PrideFlag('Bisexual', [
    _hex(0xD60270),
    _hex(0xD60270),
    _hex(0x9B4F96),
    _hex(0x0038A8),
    _hex(0x0038A8),
  ]),
  PrideFlag('Lesbian', [
    _hex(0xD52D00),
    _hex(0xFF9A56),
    _hex(0xFFFFFF),
    _hex(0xD362A4),
    _hex(0xA30262),
  ]),
  PrideFlag('Pansexual', [_hex(0xFF218C), _hex(0xFFD800), _hex(0x21B1FF)]),
  PrideFlag('Non-binary', [
    _hex(0xFCF434),
    _hex(0xFFFFFF),
    _hex(0x9C59D1),
    _hex(0x2C2C2C),
  ]),
  PrideFlag('Asexual', [
    _hex(0x000000),
    _hex(0xA3A3A3),
    _hex(0xFFFFFF),
    _hex(0x800080),
  ]),
];

/// The flag at [position] in the alternation, wrapping.
PrideFlag prideFlagAt(int position) => prideFlags[position % prideFlags.length];

/// The colours of a single-colour light's turn. Brighter than the flag's
/// stripes: a stripe is chosen to read beside its neighbours on a screen,
/// and a bulb's "#008026" is just a dim green.
const List<Rgb> prideRainbowColors = [
  (r: 255, g: 0, b: 0),
  (r: 255, g: 96, b: 0),
  (r: 255, g: 216, b: 0),
  (r: 0, g: 255, b: 0),
  (r: 0, g: 64, b: 255),
  (r: 148, g: 0, b: 255),
];

/// The colour at [position], wrapping.
Rgb prideColorAt(int position) =>
    prideRainbowColors[position % prideRainbowColors.length];

/// [flag] as a row-major RGB888 canvas.
///
/// Rows are divided exactly, so a short panel still shows every stripe it has
/// room for rather than rounding one away at the bottom. Chevrons are nested
/// points on the hoist, the outermost starting from the corners.
Uint8List renderPrideFlag(PrideFlag flag, int width, int height) {
  final out = Uint8List(width * height * 3);
  final mid = (height - 1) / 2;
  final chevrons = flag.chevrons.length;
  final band = chevrons == 0 ? 1.0 : height / 2 / chevrons;
  for (var y = 0; y < height; y++) {
    final stripe = flag.stripes[y * flag.stripes.length ~/ height];
    final fromMiddle = (y - mid).abs();
    for (var x = 0; x < width; x++) {
      // How many chevrons in from the innermost this pixel is.
      final layer = (x + fromMiddle) ~/ band;
      final color = layer < chevrons
          ? flag.chevrons[chevrons - 1 - layer]
          : stripe;
      final at = (y * width + x) * 3;
      out[at] = color.r;
      out[at + 1] = color.g;
      out[at + 2] = color.b;
    }
  }
  return out;
}

/// The rainbow as a row-major RGB888 canvas: bands along the longer side, so a
/// string of lights laid out as a one-pixel-tall canvas (or a curtain of them)
/// shows every colour rather than one colour per row.
Uint8List renderRainbowGradient(int width, int height) {
  final out = Uint8List(width * height * 3);
  final horizontal = width >= height;
  final length = horizontal ? width : height;
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final along = horizontal ? x : y;
      final color =
          prideRainbowColors[along * prideRainbowColors.length ~/ length];
      final at = (y * width + x) * 3;
      out[at] = color.r;
      out[at + 1] = color.g;
      out[at + 2] = color.b;
    }
  }
  return out;
}

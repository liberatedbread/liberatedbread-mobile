// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:convert';
import 'dart:typed_data';

/// A ready-made picture (or animation) the user can drop onto the canvas.
///
/// [frames] are RGB888 buffers sized to the canvas the design was built for;
/// an animation has more than one. Every frame stays within the 16-colour
/// TUTU palette limit so it encodes without quantization.
class LedDesign {
  const LedDesign(this.name, this.frames, {this.animation = false});

  final String name;
  final List<Uint8List> frames;
  final bool animation;
}

/// True when a `width`x`height` canvas offers at least `a`x`b` pixels in
/// EITHER orientation — a 31x62 curtain and a 62x31 panel have the same
/// pixels to spend on a design, and which way the device hangs is not the
/// design's business. Pure for tests.
bool canvasReaches(int width, int height, int a, int b) {
  final shortSide = width < height ? width : height;
  final longSide = width < height ? height : width;
  final reqShort = a < b ? a : b;
  final reqLong = a < b ? b : a;
  return shortSide >= reqShort && longSide >= reqLong;
}

/// Smallest canvas (either orientation) on which the scaled Canadian flag
/// still reads as a maple leaf rather than red noise.
const (int, int) canadianFlagMinCanvas = (31, 62);

/// Smallest canvas for the Timbit photo — a 16-colour portrait needs more
/// pixels than a two-colour flag before it stops being abstract art.
const (int, int) timbitMinCanvas = (64, 64);

/// The presets offered in the editor, generated for a `width`x`height` canvas.
///
/// This list serves EVERY display device the specs declare, not one curtain:
/// the canvas size arrives from the matched spec (fixed panels) or the
/// device's own report, and everything procedural — the stripe flags, the US
/// flag, the animations — is drawn fresh at that size, so any resolution gets
/// crisp output. The two raster images are nearest-scaled from their sources
/// and appear only on canvases with enough pixels to keep them recognizable
/// (thresholds above); a low-res panel simply gets a shorter list instead of
/// a mush of pixels.
///
/// Country flags come in a "regular" and an "in distress" (upside-down)
/// variant — a flag flown inverted is the signal of dire distress, and some
/// occasions call for it.
List<LedDesign> defaultDesigns(int width, int height) {
  final trans = _stripes(width, height, _transStripes);
  final pride = _stripes(width, height, _prideStripes);
  final lesbian = _stripes(width, height, _lesbianStripes);
  final bi = _stripes(width, height, _biStripes);
  final pan = _stripes(width, height, _panStripes);
  final nonbinary = _stripes(width, height, _nonbinaryStripes);
  final ace = _stripes(width, height, _aceStripes);
  final american = _americanFlag(width, height);

  final designs = <LedDesign>[
    LedDesign('Trans flag', [trans]),
    LedDesign('Pride flag', [pride]),
    LedDesign('Lesbian flag', [lesbian]),
    LedDesign('Bi flag', [bi]),
    LedDesign('Pan flag', [pan]),
    LedDesign('Nonbinary flag', [nonbinary]),
    LedDesign('Ace flag', [ace]),
    LedDesign('American flag', [american]),
    LedDesign(
        'American flag (in distress)', [_rotated180(american, width, height)]),
  ];

  if (canvasReaches(
      width, height, canadianFlagMinCanvas.$1, canadianFlagMinCanvas.$2)) {
    final canadian = _scaled(_canadian20, 20, 20, width, height);
    designs
      ..add(LedDesign('Canadian flag', [canadian]))
      ..add(LedDesign('Canadian flag (in distress)',
          [_rotated180(canadian, width, height)]));
  }
  if (canvasReaches(width, height, timbitMinCanvas.$1, timbitMinCanvas.$2)) {
    designs.add(LedDesign(
        'Professor Timbit', [_scaled(_timbit20, 20, 20, width, height)]));
  }

  designs
    // Rotates through the pride flags — one on-device animation frame each.
    ..add(LedDesign(
        'Pride animation', [trans, pride, lesbian, bi, pan, nonbinary, ace],
        animation: true))
    ..add(LedDesign('Star animation', _starTwinkle(width, height),
        animation: true));
  return designs;
}

// ── flag palettes (RGB triplets, top stripe first) ──────────────────────────
const _transStripes = <List<int>>[
  [0x5B, 0xCE, 0xFA],
  [0xF5, 0xA9, 0xB8],
  [0xFF, 0xFF, 0xFF],
  [0xF5, 0xA9, 0xB8],
  [0x5B, 0xCE, 0xFA],
];
const _prideStripes = <List<int>>[
  [0xE4, 0x03, 0x03],
  [0xFF, 0x8C, 0x00],
  [0xFF, 0xED, 0x00],
  [0x00, 0x80, 0x26],
  [0x24, 0x40, 0x8E],
  [0x73, 0x29, 0x82],
];
// 2018 five-stripe community lesbian flag.
const _lesbianStripes = <List<int>>[
  [0xD5, 0x2D, 0x00],
  [0xEF, 0x76, 0x27],
  [0xFF, 0xFF, 0xFF],
  [0xD1, 0x62, 0xA4],
  [0xA3, 0x02, 0x62],
];
// Bi flag: magenta / lavender / royal blue in 2:1:2 proportion. The band
// mapper divides rows equally, so the proportion is expressed by repeating
// the wider colours — five equal bands render 2:1:2 exactly.
const _biStripes = <List<int>>[
  [0xD6, 0x02, 0x70],
  [0xD6, 0x02, 0x70],
  [0x9B, 0x4F, 0x96],
  [0x00, 0x38, 0xA8],
  [0x00, 0x38, 0xA8],
];
const _panStripes = <List<int>>[
  [0xFF, 0x21, 0x8C],
  [0xFF, 0xD8, 0x00],
  [0x21, 0xB1, 0xFF],
];
const _nonbinaryStripes = <List<int>>[
  [0xFC, 0xF4, 0x34],
  [0xFF, 0xFF, 0xFF],
  [0x9C, 0x59, 0xD1],
  [0x2C, 0x2C, 0x2C],
];
const _aceStripes = <List<int>>[
  [0x00, 0x00, 0x00],
  [0xA3, 0xA3, 0xA3],
  [0xFF, 0xFF, 0xFF],
  [0x80, 0x00, 0x80],
];

/// The US flag, drawn procedurally so any panel gets the best rendition its
/// pixels allow: 13 red/white stripes (the band mapper folds them onto fewer
/// rows on short panels, always starting red at the top), an Old Glory Blue
/// canton over the top-left — 7/13 of the height, 2/5 of the width — and
/// white star-dots on the official 9-row staggered grid wherever the canton
/// has room to place them. On a canton too small for distinct dots the stars
/// are left out rather than smeared into noise; the stripes and canton alone
/// still read as the flag. Four colours total, well inside the palette.
Uint8List _americanFlag(int width, int height) {
  const red = [0xB2, 0x22, 0x34];
  const white = [0xFF, 0xFF, 0xFF];
  const blue = [0x3C, 0x3B, 0x6E];

  final out = Uint8List(width * height * 3);
  final cantonH = (height * 7 / 13).round().clamp(1, height);
  final cantonW = (width * 2 / 5).round().clamp(1, width);

  void set(int x, int y, List<int> c) {
    final i = (y * width + x) * 3;
    out[i] = c[0];
    out[i + 1] = c[1];
    out[i + 2] = c[2];
  }

  for (var y = 0; y < height; y++) {
    final stripe = (y * 13) ~/ height;
    final stripeColor = stripe.isEven ? red : white;
    for (var x = 0; x < width; x++) {
      set(x, y, x < cantonW && y < cantonH ? blue : stripeColor);
    }
  }

  // Star grid: 9 rows alternating 6 and 5 stars, offset rows centred. Each
  // star becomes one pixel at its grid position scaled into the canton. Skip
  // entirely when adjacent stars would land on the same pixel (canton
  // narrower than ~7 px), because a solid white canton is not a star field.
  if (cantonW >= 7 && cantonH >= 5) {
    for (var row = 0; row < 9; row++) {
      final starsInRow = row.isEven ? 6 : 5;
      final y = ((row + 0.5) * cantonH / 9).floor().clamp(0, cantonH - 1);
      for (var col = 0; col < starsInRow; col++) {
        final offset = row.isEven ? 0.5 : 1.0;
        final x =
            ((col + offset) * cantonW / 6.5).floor().clamp(0, cantonW - 1);
        set(x, y, white);
      }
    }
  }
  return out;
}

/// The frame rotated 180° — a flag flown upside down, the signal of dire
/// distress. A rotation rather than a vertical flip: flipping would mirror
/// the canton to the wrong side, which is a backwards flag, not an inverted
/// one.
Uint8List _rotated180(Uint8List src, int width, int height) {
  final out = Uint8List(src.length);
  final pixels = width * height;
  for (var i = 0; i < pixels; i++) {
    final j = pixels - 1 - i;
    out[j * 3] = src[i * 3];
    out[j * 3 + 1] = src[i * 3 + 1];
    out[j * 3 + 2] = src[i * 3 + 2];
  }
  return out;
}

/// A twinkling starfield: a deterministic scatter of stars over black, each
/// star cycling off -> dim -> bright -> dim at its own phase across four
/// frames, so the field shimmers instead of blinking in unison.
///
/// Positions and phases come from a pixel-coordinate hash rather than a
/// random generator: the same canvas always yields the same sky, which keeps
/// the design reproducible in tests and stable for the user across reopens
/// (a preset that redraws itself differently every time reads as broken).
/// Four colours — black, warm white, dim grey, gold — well inside the
/// palette.
List<Uint8List> _starTwinkle(int width, int height) {
  const off = [0x00, 0x00, 0x00];
  const dim = [0x55, 0x55, 0x66];
  const bright = [0xFF, 0xFF, 0xF0];
  const gold = [0xFF, 0xD7, 0x6E];

  int hash(int x, int y) {
    var h = x * 73856093 ^ y * 19349663;
    h = (h ^ (h >> 13)) * 0x5bd1e995;
    return (h ^ (h >> 15)) & 0x7fffffff;
  }

  final frames = <Uint8List>[];
  for (var f = 0; f < 4; f++) {
    final out = Uint8List(width * height * 3);
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final h = hash(x, y);
        // ~1 pixel in 9 is a star; the rest stay black (LEDs off).
        if (h % 9 != 0) continue;
        final phase = (h ~/ 9) % 4;
        // 0 at the star's own phase, 1/3 one step away, 2 opposite.
        final distance = (f - phase).abs() % 4;
        final wave = distance > 2 ? 4 - distance : distance;
        final isGold = (h ~/ 36) % 5 == 0;
        final color = switch (wave) {
          0 => isGold ? gold : bright,
          1 => dim,
          _ => off,
        };
        if (identical(color, off)) continue;
        final i = (y * width + x) * 3;
        out[i] = color[0];
        out[i + 1] = color[1];
        out[i + 2] = color[2];
      }
    }
    frames.add(out);
  }
  return frames;
}

/// Fill a `width`x`height` canvas with equal horizontal stripes. A row maps to
/// its stripe by `row * count / height`, so uneven divisions distribute the
/// remainder across the bottom stripes rather than dropping any.
Uint8List _stripes(int width, int height, List<List<int>> colors) {
  final out = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    final band = (y * colors.length) ~/ height;
    final c = colors[band];
    for (var x = 0; x < width; x++) {
      final i = (y * width + x) * 3;
      out[i] = c[0];
      out[i + 1] = c[1];
      out[i + 2] = c[2];
    }
  }
  return out;
}

/// Nearest-neighbour scale an RGB888 source to `width`x`height`. Nearest keeps
/// the palette intact (it only ever copies existing pixels), so a scaled image
/// still fits the 16-colour limit.
Uint8List _scaled(
  Uint8List src,
  int srcWidth,
  int srcHeight,
  int width,
  int height,
) {
  if (width == srcWidth && height == srcHeight) {
    return Uint8List.fromList(src);
  }
  final out = Uint8List(width * height * 3);
  for (var y = 0; y < height; y++) {
    final sy =
        height == 0 ? 0 : (y * srcHeight ~/ height).clamp(0, srcHeight - 1);
    for (var x = 0; x < width; x++) {
      final sx =
          width == 0 ? 0 : (x * srcWidth ~/ width).clamp(0, srcWidth - 1);
      final from = (sy * srcWidth + sx) * 3;
      final to = (y * width + x) * 3;
      out[to] = src[from];
      out[to + 1] = src[from + 1];
      out[to + 2] = src[from + 2];
    }
  }
  return out;
}

// ── 20x20 source images (RGB888), quantized to <=16 colours ─────────────────
// Canadian flag: red 1:2:1 vertical bands with a red maple leaf (2 colours).
final Uint8List _canadian20 = base64Decode(
  '/wAA/wAA/wAA/wAA/wAA/////////////////////////////////////////wAA/wAA/wAA/wAA'
  '/wAA/wAA/wAA/wAA/wAA/wAA/////////////////////////////////////////wAA/wAA/wAA'
  '/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////////////////////////////////wAA/wAA'
  '/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////////////////////////////////wAA'
  '/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////wAA/wAA/wAA/wAA/////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////wAA/wAA/wAA/wAA/////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////wAA/wAA/wAA/////////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////wAA/wAA/wAA/wAA/////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////wAA/wAA/wAA/wAA/wAA/wAA/////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////wAA/wAA/wAA/wAA/wAA/wAA/////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////wAA/wAA/wAA/wAA/////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////wAA/wAA/wAA/wAA/wAA/wAA/////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////wAA/////wAA/wAA/////wAA/////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////////wAA/wAA/////////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////////wAA/wAA/////////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////////////wAA/////////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////////////////////////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////////////////////////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////////////////////////////////'
  'wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/wAA/////////////////////////////////////////'
  'wAA/wAA/wAA/wAA/wAA',
);

// Professor Timbit, quantized to 16 colours.
final Uint8List _timbit20 = base64Decode(
  'JyMbJyMbTEEwTEEwZ1VCbGVXVU5Dg3Rig3Rig3RiTEEwVU5DZ1VCJyMbopOAg3Rig3RiZ1VCopOA'
  'opOAZ1VCJyMbJyMbJyMbVU5DVU5DZ1VCiIFzc3Fvg3RiTEEwTEEwZ1VCTEEwg3RiTEEwtaqYg3Ri'
  'y76qiIFzTEEwJyMbJyMbJyMbTEEwVU5DZ1VCVU5DVU5DopOAbGVXVU5DVU5DTEEwVU5DTEEwg3Ri'
  'bGVXy76qbGVXTEEwJyMbJyMbJyMbTEEwTEEwVU5DZ1VCZ1VCbGVXtaqY3t/ataqYg3RiTEEwTEEw'
  'Z1VCg3RiopOATEEwbGVXc3FviIFzVU5Dc3FvjouCc3FvZ1VCZ1VCopOAy76q3t/a1M7EZ1VCTEEw'
  'Z1VCZ1VCjouCpaKbjouCbGVXjouCc3Fvc3FviIFzc3FvbGVXg3Rig3Rig3RiZ1VC3t/avLmwZ1VC'
  'TEEwVU5DZ1VCZ1VCc3Fvc3FvTEEwg3Ric3Fvc3FviIFzjouCpaKbtaqYbGVXg3Ri1M7EvLmwJyMb'
  'taqYiIFzTEEwTEEwg3RipaKbjouCTEEwbGVXtaqYvLmwpaKbopOApaKbopOAg3Riy76q1M7EpaKb'
  'JyMbiIFzopOAopOAg3RiVU5DVU5Dc3FvTEEwbGVXtaqYpaKbpaKbpaKbtaqYtaqYy76qtaqYy76q'
  'paKbbGVXiIFzg3RiopOAtaqYg3RiJyMbJyMbTEEwbGVXpaKbpaKbiIFzjouCy76qtaqYy76qy76q'
  '1M7Ey76qtaqYopOAopOAopOAopOAopOATEEwJyMbVU5DZ1VCopOAjouCiIFzjouCy76qy76qy76q'
  '1M7E1M7Ey76qvLmwtaqYvLmwtaqYopOAiIFzbGVXJyMbZ1VCTEEwc3FviIFziIFztaqY1M7Ey76q'
  '1M7E3t/a3t/a1M7E1M7Ey76q1M7E1M7EopOAg3RibGVXVU5Dg3RiTEEwbGVXc3FviIFztaqY3t/a'
  '1M7E1M7E3t/a3t/a1M7E3t/a3t/a1M7E1M7EtaqYiIFzbGVXVU5Dg3RiTEEwVU5Dc3FvjouCopOA'
  '3t/a3t/a1M7E3t/a1M7E3t/a3t/a3t/avLmwvLmwvLmwtaqYc3FvVU5DjouCZ1VCVU5Dc3FvopOA'
  'vLmw3t/a3t/avLmw1M7EvLmwvLmw1M7E1M7EpaKbvLmwvLmw1M7EjouCbGVXiIFziIFzc3FviIFz'
  'paKb1M7E3t/a1M7EvLmw1M7EvLmwjouCpaKbvLmwpaKbtaqYvLmw1M7EpaKbbGVXjouCiIFzjouC'
  'jouCjouC3t/a3t/avLmw1M7EvLmwopOAZ1VCjouCvLmwtaqYvLmwvLmwvLmwpaKbbGVXjouCjouC'
  'iIFzpaKbjouC3t/a3t/apaKbvLmwvLmwjouCVU5DjouCvLmwvLmwvLmwvLmwvLmwpaKbbGVXjouC'
  'paKbiIFzc3FvpaKb3t/a1M7EVU5DpaKbpaKbc3FvTEEwiIFzpaKbpaKbvLmwvLmwvLmwjouCiIFz'
  'jouCpaKbpaKbc3FvvLmw3t/ajouCTEEwiIFzc3FvTEEwJyMbVU5Dc3Fvc3FvpaKb1M7E1M7Ec3Fv'
  'bGVX',
);

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

/// The presets offered in the editor, generated for a `width`x`height` canvas.
///
/// Flags are drawn procedurally so they stay crisp at any panel size; the
/// Canadian flag and the dog are 20x20 source images nearest-scaled to fit.
List<LedDesign> defaultDesigns(int width, int height) {
  final trans = _stripes(width, height, _transStripes);
  final pride = _stripes(width, height, _prideStripes);
  final lesbian = _stripes(width, height, _lesbianStripes);
  return [
    LedDesign('Trans flag', [trans]),
    LedDesign('Pride flag', [pride]),
    LedDesign('Lesbian flag', [lesbian]),
    LedDesign('Canadian flag', [_scaled(_canadian20, 20, 20, width, height)]),
    LedDesign('Professor Timbit', [_scaled(_timbit20, 20, 20, width, height)]),
    // Rotates through the three pride flags — one on-device animation frame each.
    LedDesign('Pride animation', [trans, pride, lesbian], animation: true),
  ];
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
    final sy = height == 0 ? 0 : (y * srcHeight ~/ height).clamp(0, srcHeight - 1);
    for (var x = 0; x < width; x++) {
      final sx = width == 0 ? 0 : (x * srcWidth ~/ width).clamp(0, srcWidth - 1);
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

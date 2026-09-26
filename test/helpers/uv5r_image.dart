// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:liberated_bread_mobile/src/rust/api/radio_api.dart';

/// A UV-5R-family image as a factory-fresh radio reads back: the ident,
/// every channel slot and name empty, and [firmware] where the radio keeps
/// its version string. Needs the host Rust library, for the image's length.
Future<Uint8List> blankUv5rImage({String firmware = 'BFB297'}) async {
  final image = Uint8List(await uv5RImageLen());
  image.setRange(0, 8, [0xAA, 0x30, 0x76, 0x04, 0x00, 0x05, 0x20, 0xDD]);
  // Behind the ident: slots at radio 0x0000..0x0800, names at 0x1000..0x1800.
  image.fillRange(8, 8 + 0x800, 0xFF);
  image.fillRange(8 + 0x1000, 8 + 0x1800, 0xFF);
  // Radio 0x1EF0 sits at 8 + 0x1800 + (0x1EF0 - 0x1EC0) in the image.
  const firmwareAt = 8 + 0x1800 + 0x30;
  image.fillRange(firmwareAt, firmwareAt + 14, 0xFF);
  image.setRange(firmwareAt, firmwareAt + firmware.length, firmware.codeUnits);
  return image;
}

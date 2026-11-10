// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

/// Where the editor's pictures go when the device is not on BLE: a Wi-Fi panel,
/// which takes the same picture through a transport of its own.
abstract class LedImageLink {
  /// Show [rgb] ([width] x [height], RGB888) on the device, returning once it
  /// has taken it.
  Future<void> sendImage(Uint8List rgb, int width, int height, String specYaml);

  /// The device's own size, when it states one; null when it does not.
  Future<({int width, int height})?> panelSize();
}

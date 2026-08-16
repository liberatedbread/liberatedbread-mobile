// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// Resolves a spec's `device.pictogram` token to a glyph — a finer-grained icon
/// than the broad `category`. A NAS, a power strip and a phone are all
/// "network" or "switch" or "other" by category, but each deserves its own
/// picture in the scan list.
///
/// This resolver owns the token table, deliberately: the vocabulary is
/// open-ended and grows in the specs first, so an unknown token is not an error
/// — it simply resolves to nothing and the caller falls back to the category
/// icon. Most tokens map to a Material glyph ([iconFor]); a few need a custom
/// painter the caller draws itself ([isCustom]).
class DevicePictogram {
  const DevicePictogram._();

  /// The Material glyph for a pictogram token, or null when the token is
  /// unknown OR is drawn by a custom widget (see [isCustom]) — in both cases
  /// the caller falls back (to a custom widget, then the category icon).
  static IconData? iconFor(String? token) => switch (token) {
        'light' => Icons.lightbulb_outline,
        'nas' => Icons.storage_outlined,
        'phone' => Icons.smartphone_outlined,
        'printer' => Icons.print_outlined,
        'router' => Icons.router_outlined,
        'wifi-ap' => Icons.wifi_tethering_outlined,
        'network-switch' => Icons.lan_outlined,
        'ip-camera' => Icons.videocam_outlined,
        'video-doorbell' => Icons.doorbell_outlined,
        'nvr' => Icons.dvr_outlined,
        'cloud-key' => Icons.vpn_key_outlined,
        'game-console' => Icons.sports_esports_outlined,
        'laptop' => Icons.laptop_outlined,
        'laptop-apple' => Icons.laptop_mac_outlined,
        'monitor' => Icons.desktop_windows_outlined,
        'drawable-display' => Icons.grid_on_outlined,
        // A device we can place on the network but not categorize further — a
        // Tuya beacon names no product type, only that it is one.
        'smart-device' => Icons.devices_other_outlined,
        _ => null,
      };

  /// Whether this token is drawn by a custom painter rather than a Material
  /// glyph — the caller builds the widget itself (the scan tile draws a
  /// [PowerStripIcon] for `power-strip`, a `ThreeDPrinterIcon` for
  /// `3d-printer`). Material has no glyph for either, so both are painted.
  static bool isCustom(String? token) =>
      token == 'power-strip' || token == '3d-printer';
}

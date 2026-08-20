// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A finer-grained device glyph than [DeviceCategory] gives — the "recognise it
// on sight" icon for devices worth drawing distinctly even when this app does
// not control them (a UniFi access point, a MikroTik router, a NAS, a
// Nintendo console, a 3D printer).

import 'package:flutter/material.dart';

import 'device_category.dart';

/// Resolves a spec's `device.pictogram` token to a glyph — a finer-grained
/// icon than the broad `category`. A NAS, a power strip and a phone are all
/// "network" or "switch" or "other" by category, but each deserves its own
/// picture in the scan list.
///
/// The vocabulary is owned upstream (the token strings live in
/// `device-specs/schema.json`'s `pictogram` description) and this table is a
/// *view* of it, exactly as [DeviceCategory] is a view of the category
/// vocabulary: an unknown token is not an error — it resolves to nothing and
/// the caller falls back to the category icon, then to its own generic glyph.
/// A pictogram added upstream after this build shipped costs only the specific
/// glyph, never the device. That is why the table is deliberately tolerant and
/// never throws.
///
/// Glyph choices are pinned to names verified present in Flutter's bundled
/// Material Icons font (not the newer Material Symbols set, which this app
/// does not ship), in the outlined style the category icons already use. Most
/// tokens map to a Material glyph ([iconFor]); a few need a custom painter the
/// caller draws itself ([isCustom]).
abstract final class DevicePictogram {
  /// token -> glyph. Kebab-case tokens, matching the spec vocabulary.
  static const Map<String, IconData> _glyphs = {
    // Network infrastructure
    'wifi-ap': Icons.wifi_tethering_outlined,
    'access-point': Icons.wifi_tethering_outlined,
    'network-switch': Icons.lan_outlined,
    'switch-network': Icons.lan_outlined,
    'router': Icons.router_outlined,
    'gateway': Icons.router_outlined,
    'firewall': Icons.security_outlined,
    'cloud-key': Icons.vpn_key_outlined, // a UniFi console/controller
    'nvr': Icons.dvr_outlined,
    'nas': Icons.storage_outlined,
    'file-server': Icons.storage_outlined,

    // Cameras
    'ip-camera': Icons.videocam_outlined,
    'cctv': Icons.videocam_outlined,
    'video-doorbell': Icons.doorbell_outlined,
    'doorbell': Icons.doorbell_outlined,

    // Computers / consoles / phones
    'laptop': Icons.laptop_outlined,
    'laptop-apple': Icons.laptop_mac_outlined,
    'macbook': Icons.laptop_mac_outlined,
    'laptop-windows': Icons.laptop_windows_outlined,
    'desktop': Icons.desktop_windows_outlined,
    'desktop-apple': Icons.desktop_mac_outlined,
    'mini-pc': Icons.desktop_mac_outlined,
    'monitor': Icons.desktop_windows_outlined,
    'drawable-display': Icons.grid_on_outlined,
    'game-console': Icons.sports_esports_outlined,
    'handheld-console': Icons.sports_esports_outlined,
    'phone': Icons.smartphone_outlined,

    // Media / voice
    'smart-speaker': Icons.speaker_outlined,
    'voice-assistant': Icons.assistant_outlined,
    'tv': Icons.tv_outlined,
    'streaming-stick': Icons.cast_outlined,

    // Appliances / sensors with a distinctive shape
    'light': Icons.lightbulb_outline,
    'printer': Icons.print_outlined,
    'label-printer': Icons.print_outlined,
    'thermostat': Icons.thermostat_outlined,
    'smoke-alarm': Icons.sensors_outlined, // no smoke-detector glyph
    'garage-door': Icons.garage_outlined,
    'power-station': Icons.battery_charging_full_outlined,
    'battery': Icons.battery_charging_full_outlined,
    'solar-gateway': Icons.solar_power_outlined,
    'air-quality': Icons.air_outlined,
    'co2-sensor': Icons.co2_outlined,
    'robot': Icons.smart_toy_outlined,

    // A device we can place on the network but not categorize further — a
    // Tuya beacon names no product type, only that it is one.
    'smart-device': Icons.devices_other_outlined,
  };

  /// The Material glyph for a pictogram token, or null when the token is
  /// absent, unknown, OR is drawn by a custom widget (see [isCustom]) — in
  /// each case the caller falls back (to a custom widget, then the category
  /// icon, then its own generic glyph).
  static IconData? iconFor(String? token) => _glyphs[_normalize(token)];

  /// Whether this token is drawn by a custom painter rather than a Material
  /// glyph — the caller builds the widget itself (the scan tile draws a
  /// [PowerStripIcon] for `power-strip`, a `ThreeDPrinterIcon` for
  /// `3d-printer`). Material has no faithful glyph for either, so both are
  /// painted.
  static bool isCustom(String? token) {
    final key = _normalize(token);
    return key == 'power-strip' || key == '3d-printer';
  }

  /// The glyph to draw for a device, most specific first: its `pictogram`
  /// token, then its [DeviceCategory] icon, then [fallback] (the caller's
  /// generic glyph, e.g. the scan tab's radio icon).
  ///
  /// [category] is the raw `device.category` string; it is parsed leniently so
  /// an unrecognised category degrades the same way an unrecognised pictogram
  /// does. A custom-painted pictogram falls through to the category here —
  /// this helper answers only in [IconData]; callers that can draw the painter
  /// check [isCustom] themselves.
  static IconData forDevice({
    String? pictogram,
    String? category,
    IconData fallback = unknownDeviceIcon,
  }) {
    return iconFor(pictogram) ??
        DeviceCategory.parse(category)?.icon ??
        fallback;
  }

  /// The spec vocabulary is kebab-case lowercase; tolerate stray case and
  /// whitespace in hand-written specs rather than losing the glyph over them.
  static String? _normalize(String? token) {
    if (token == null) return null;
    final key = token.trim().toLowerCase();
    return key.isEmpty ? null : key;
  }
}

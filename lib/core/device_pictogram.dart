// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A finer-grained device glyph than [DeviceCategory] gives — the "recognise it
// on sight" icon for devices worth drawing distinctly even when this app does
// not control them (a UniFi access point, a MikroTik router, a NAS, a
// Nintendo console, a 3D printer).

import 'package:flutter/material.dart';

import 'device_category.dart';

/// Resolves a spec's `device.pictogram` token to a concrete glyph.
///
/// The vocabulary is owned upstream (the token strings live in
/// `device-specs/schema.json`'s `pictogram` description) and this table is a
/// *view* of it, exactly as [DeviceCategory] is a view of the category
/// vocabulary: [resolve] answers `null` for a token it does not recognise so a
/// pictogram added upstream after this build shipped costs only the specific
/// glyph, never the device — the caller falls back to the category icon, and
/// then to the generic radio glyph. That is why the map is deliberately
/// tolerant and never throws.
///
/// Glyph choices are pinned to names verified present in Flutter's bundled
/// Material Icons font (not the newer Material Symbols set, which this app does
/// not ship). Where Material has no faithful glyph the nearest honest one is
/// used and noted — a 3D printer draws as a generic printer, a smoke alarm as a
/// sensor — rather than reaching for an off-brand shape.
abstract final class DevicePictogram {
  /// token -> glyph. Kebab-case tokens, matching the spec vocabulary.
  static const Map<String, IconData> _glyphs = {
    // Network infrastructure
    'wifi-ap': Icons.wifi,
    'access-point': Icons.wifi,
    'network-switch': Icons.lan,
    'switch-network': Icons.lan,
    'router': Icons.router,
    'gateway': Icons.router,
    'firewall': Icons.security,
    'cloud-key': Icons.dns, // a UniFi console/controller appliance
    'nvr': Icons.dvr,
    'nas': Icons.storage,
    'file-server': Icons.storage,

    // Cameras
    'ip-camera': Icons.videocam,
    'cctv': Icons.videocam,
    'video-doorbell': Icons.doorbell,
    'doorbell': Icons.doorbell,

    // Computers / consoles
    'laptop': Icons.laptop,
    'laptop-apple': Icons.laptop_mac,
    'macbook': Icons.laptop_mac,
    'laptop-windows': Icons.laptop_windows,
    'desktop': Icons.desktop_windows,
    'desktop-apple': Icons.desktop_mac,
    'mini-pc': Icons.desktop_mac,
    'game-console': Icons.sports_esports,
    'handheld-console': Icons.sports_esports,

    // Media / voice
    'smart-speaker': Icons.speaker,
    'voice-assistant': Icons.assistant,
    'tv': Icons.tv,
    'streaming-stick': Icons.cast,

    // Appliances / sensors with a distinctive shape
    '3d-printer': Icons.print, // Material has no 3D-printer glyph
    'label-printer': Icons.print,
    'thermostat': Icons.thermostat,
    'smoke-alarm': Icons.sensors, // no smoke-detector glyph in Material Icons
    'garage-door': Icons.garage,
    'power-station': Icons.battery_charging_full,
    'battery': Icons.battery_charging_full,
    'solar-gateway': Icons.solar_power,
    'air-quality': Icons.air,
    'co2-sensor': Icons.co2,
  };

  /// The glyph for [token], or `null` when the token is absent or unknown.
  static IconData? resolve(String? token) {
    if (token == null) return null;
    final key = token.trim().toLowerCase();
    if (key.isEmpty) return null;
    return _glyphs[key];
  }

  /// The glyph to draw for a device, most specific first: its `pictogram`
  /// token, then its [DeviceCategory] icon, then [fallback] (the caller's
  /// generic glyph, e.g. the scan tab's radio icon).
  ///
  /// [category] is the raw `device.category` string; it is parsed leniently so
  /// an unrecognised category degrades the same way an unrecognised pictogram
  /// does.
  static IconData forDevice({
    String? pictogram,
    String? category,
    IconData fallback = unknownDeviceIcon,
  }) {
    return resolve(pictogram) ??
        DeviceCategory.parse(category)?.icon ??
        fallback;
  }
}

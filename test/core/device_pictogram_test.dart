// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/device_category.dart';
import 'package:liberated_bread_mobile/core/device_pictogram.dart';

void main() {
  group('DevicePictogram.iconFor', () {
    test('resolves known tokens to Material glyphs', () {
      expect(DevicePictogram.iconFor('wifi-ap'), Icons.wifi_tethering_outlined);
      expect(DevicePictogram.iconFor('router'), Icons.router_outlined);
      expect(DevicePictogram.iconFor('ip-camera'), Icons.videocam_outlined);
      expect(DevicePictogram.iconFor('nas'), Icons.storage_outlined);
      expect(DevicePictogram.iconFor('game-console'),
          Icons.sports_esports_outlined);
      expect(DevicePictogram.iconFor('co2-sensor'), Icons.co2_outlined);
      expect(DevicePictogram.iconFor('garage-door'), Icons.garage_outlined);
    });

    test('is case- and whitespace-insensitive', () {
      expect(
          DevicePictogram.iconFor('  Wifi-AP '), Icons.wifi_tethering_outlined);
    });

    test('returns null for absent, empty, or unknown tokens', () {
      expect(DevicePictogram.iconFor(null), isNull);
      expect(DevicePictogram.iconFor(''), isNull);
      expect(DevicePictogram.iconFor('  '), isNull);
      expect(DevicePictogram.iconFor('flux-capacitor'), isNull);
    });
  });

  group('DevicePictogram.isCustom', () {
    test('custom-painted tokens have no Material glyph and say so', () {
      // Material has no faithful glyph for these; the scan tile draws a
      // custom painter instead, so iconFor must answer null to let it.
      for (final token in ['power-strip', '3d-printer']) {
        expect(DevicePictogram.isCustom(token), isTrue);
        expect(DevicePictogram.iconFor(token), isNull);
      }
    });

    test('is case- and whitespace-insensitive, and false elsewhere', () {
      expect(DevicePictogram.isCustom('  3D-Printer '), isTrue);
      expect(DevicePictogram.isCustom('router'), isFalse);
      expect(DevicePictogram.isCustom(null), isFalse);
    });
  });

  group('DevicePictogram.forDevice fallback chain', () {
    test('pictogram wins when present and known', () {
      final icon = DevicePictogram.forDevice(
        pictogram: 'router',
        category: 'sensor',
        fallback: Icons.bluetooth,
      );
      expect(icon, Icons.router_outlined);
    });

    test('falls back to the category icon when pictogram is unknown', () {
      final icon = DevicePictogram.forDevice(
        pictogram: 'unheard-of',
        category: 'light',
        fallback: Icons.bluetooth,
      );
      expect(icon, DeviceCategory.light.icon);
    });

    test('falls back to the category icon when pictogram is absent', () {
      final icon = DevicePictogram.forDevice(
        category: 'camera',
        fallback: Icons.bluetooth,
      );
      expect(icon, DeviceCategory.camera.icon);
    });

    test('falls back to the supplied fallback when both are unknown/absent',
        () {
      final icon = DevicePictogram.forDevice(
        pictogram: null,
        category: 'not-a-category',
        fallback: Icons.bluetooth,
      );
      expect(icon, Icons.bluetooth);
    });

    test('uses the generic device icon as the default fallback', () {
      expect(DevicePictogram.forDevice(), unknownDeviceIcon);
    });

    test('a network-category device with no pictogram still draws its category',
        () {
      // `network` is a real category; even without a pictogram it should not
      // collapse to the anonymous fallback.
      final icon = DevicePictogram.forDevice(
          category: 'network', fallback: Icons.bluetooth);
      expect(icon, isNot(Icons.bluetooth));
      expect(icon, DeviceCategory.parse('network')?.icon);
    });
  });
}

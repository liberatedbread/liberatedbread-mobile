// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/device_category.dart';
import 'package:liberated_bread_mobile/core/device_pictogram.dart';

void main() {
  group('DevicePictogram.resolve', () {
    test('resolves known tokens to Material glyphs', () {
      expect(DevicePictogram.resolve('wifi-ap'), Icons.wifi);
      expect(DevicePictogram.resolve('router'), Icons.router);
      expect(DevicePictogram.resolve('ip-camera'), Icons.videocam);
      expect(DevicePictogram.resolve('nas'), Icons.storage);
      expect(DevicePictogram.resolve('game-console'), Icons.sports_esports);
      expect(DevicePictogram.resolve('3d-printer'), Icons.print);
      expect(DevicePictogram.resolve('co2-sensor'), Icons.co2);
      expect(DevicePictogram.resolve('garage-door'), Icons.garage);
    });

    test('is case- and whitespace-insensitive', () {
      expect(DevicePictogram.resolve('  Wifi-AP '), Icons.wifi);
    });

    test('returns null for absent, empty, or unknown tokens', () {
      expect(DevicePictogram.resolve(null), isNull);
      expect(DevicePictogram.resolve(''), isNull);
      expect(DevicePictogram.resolve('  '), isNull);
      expect(DevicePictogram.resolve('flux-capacitor'), isNull);
    });
  });

  group('DevicePictogram.forDevice fallback chain', () {
    test('pictogram wins when present and known', () {
      final icon = DevicePictogram.forDevice(
        pictogram: 'router',
        category: 'sensor',
        fallback: Icons.bluetooth,
      );
      expect(icon, Icons.router);
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

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

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
      expect(
        DevicePictogram.iconFor('game-console'),
        Icons.sports_esports_outlined,
      );
      expect(DevicePictogram.iconFor('co2-sensor'), Icons.co2_outlined);
      expect(DevicePictogram.iconFor('garage-door'), Icons.garage_outlined);
    });

    test('is case- and whitespace-insensitive', () {
      expect(
        DevicePictogram.iconFor('  Wifi-AP '),
        Icons.wifi_tethering_outlined,
      );
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

    test(
      'falls back to the supplied fallback when both are unknown/absent',
      () {
        final icon = DevicePictogram.forDevice(
          pictogram: null,
          category: 'not-a-category',
          fallback: Icons.bluetooth,
        );
        expect(icon, Icons.bluetooth);
      },
    );

    test('uses the generic device icon as the default fallback', () {
      expect(DevicePictogram.forDevice(), unknownDeviceIcon);
    });

    test(
      'a network-category device with no pictogram still draws its category',
      () {
        // `network` is a real category; even without a pictogram it should not
        // collapse to the anonymous fallback.
        final icon = DevicePictogram.forDevice(
          category: 'network',
          fallback: Icons.bluetooth,
        );
        expect(icon, isNot(Icons.bluetooth));
        expect(icon, DeviceCategory.parse('network')?.icon);
      },
    );
  });

  group('DevicePictogram.infer', () {
    String? infer(String name, String category) =>
        DevicePictogram.infer(deviceName: name, category: category);

    test('tells sub-kinds of one category apart by name', () {
      // A laser distance meter is not a thermometer, though both are sensors.
      expect(
        infer('Johnson JLX LDM330 Laser Distance Meter', 'sensor'),
        'distance-meter',
      );
      expect(
        infer('Govee H5075 Thermometer/Hygrometer', 'sensor'),
        'thermometer',
      );
      // An LED strip controller is not a bulb, and an LED sign is not either.
      expect(
        infer('ELK-BLEDOM BLE LED Strip Controller', 'light'),
        'led-strip',
      );
      expect(infer('Govee H6001 Smart Bulb', 'light'), 'light');
      expect(infer('CoolLEDX LED Sign', 'display'), 'led-sign');
      // Names that do not say what the device measures or is.
      expect(infer('Airthings Wave Family', 'sensor'), 'radon-sensor');
      expect(
        infer('Govee RGBIC / DreamColor Lights (segmented)', 'light'),
        'led-strip',
      );
      expect(infer('Hörmann BiSecur Gateway', 'hub'), 'garage-door');
      expect(infer('Hyperice Hypervolt Plus', 'fitness'), 'massage-gun');
      expect(infer('TiVo DVRs and Minis (Series 3 and later)', 'tv'), 'dvr');
      expect(infer('Rachio Controller', 'irrigation'), 'sprinkler-controller');
      // A grow light's controller is not a strip's.
      expect(
        infer('Spider Farmer GGS Grow Light Controller', 'light'),
        'grow-light',
      );
      expect(infer('Bluetooth LED Name Badge', 'display'), 'name-badge');
    });

    test('a sub-kind never draws the same glyph as its own category', () {
      // A token whose glyph is its category's icon gains the device nothing,
      // which is how the air purifier first shipped.
      final cases = {
        'air-purifier': 'climate',
        'led-strip': 'light',
        'thermometer': 'sensor',
        'radon-sensor': 'sensor',
        'dvr': 'tv',
        'garage-door': 'hub',
        'fingerprint-lock': 'lock',
        'sprinkler-controller': 'irrigation',
        'thermal-camera': 'camera',
      };
      cases.forEach((token, category) {
        expect(
          DevicePictogram.iconFor(token),
          isNot(DeviceCategory.parse(category)!.icon),
          reason: token,
        );
      });
    });

    test('keeps a word inside its category', () {
      // "band" is a fitness band under fitness, and nothing under light.
      expect(infer('M6 Smart Fitness Band', 'fitness'), 'fitness-band');
      expect(infer('Band Light', 'light'), isNull);
    });

    test('a spec\'s own pictogram outranks the inference', () {
      expect(
        DevicePictogram.forSpec(
          deviceName: 'Some LED Strip',
          category: 'light',
          pictogram: 'smart-device',
        ),
        'smart-device',
      );
    });

    test('every token inferred for the vendored catalogue has a glyph', () {
      final name = RegExp(r'^  name:\s*"?([^"\n]+)"?', multiLine: true);
      final category = RegExp(r'^  category:\s*"?(\w+)', multiLine: true);
      final pictogram = RegExp(r'^  pictogram:', multiLine: true);
      var inferred = 0;
      for (final file in Directory(
        'vendor/protocol-specs/device-specs/devices',
      ).listSync().whereType<File>().where((f) => f.path.endsWith('.yaml'))) {
        final text = file.readAsStringSync();
        final n = name.firstMatch(text)?[1];
        final c = category.firstMatch(text)?[1];
        if (n == null || pictogram.hasMatch(text)) continue;
        final token = DevicePictogram.infer(deviceName: n, category: c);
        if (token == null) continue;
        inferred++;
        expect(
          DevicePictogram.iconFor(token) != null ||
              DevicePictogram.isCustom(token),
          isTrue,
          reason: '${file.path} infers "$token", which draws nothing',
        );
      }
      // The point of the table: most of the catalogue sets no pictogram, and
      // a good share of it should now get something finer than its category.
      expect(inferred, greaterThan(60));
    });
  });
}

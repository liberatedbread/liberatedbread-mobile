// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/health_reference.dart';

void main() {
  group('NIH oxygen guidance', () {
    test('uses the published 95/90 boundaries', () {
      expect(oxygenNihReference(100).label, 'Common adult range');
      expect(oxygenNihReference(95).label, 'Common adult range');
      expect(oxygenNihReference(94.9).label, 'Below common range');
      expect(oxygenNihReference(90).label, 'Below common range');
      expect(oxygenNihReference(89.9).label, 'Hypoxemia range');
      expect(oxygenNihReference(101).label, 'Outside cited range');
      expect(oxygenNihReference(double.nan).label, 'Outside cited range');
    });
  });

  group('Beurer oxygen guidance', () {
    test('keeps the distinct 94/90 and 99 boundaries', () {
      expect(oxygenBeurerReference(99).label, 'Normal range');
      expect(oxygenBeurerReference(100).label, 'Outside cited range');
      expect(oxygenBeurerReference(94).label, 'Normal range');
      expect(oxygenBeurerReference(93).label, 'Decreased range');
      expect(oxygenBeurerReference(90).label, 'Decreased range');
      expect(oxygenBeurerReference(89).label, 'Critical range');
    });
  });

  group('NIH blood-pressure guidance', () {
    test('uses both numbers and the higher category', () {
      expect(bloodPressureNihReference(119, 79).label, 'Normal');
      expect(bloodPressureNihReference(120, 79).label, 'Elevated');
      expect(bloodPressureNihReference(129, 79).label, 'Elevated');
      expect(bloodPressureNihReference(130, 79).label, contains('stage 1'));
      expect(bloodPressureNihReference(120, 80).label, contains('stage 1'));
      expect(bloodPressureNihReference(110, 85).label, contains('stage 1'));
      expect(bloodPressureNihReference(139, 89).label, contains('stage 1'));
      expect(bloodPressureNihReference(140, 70).label, contains('stage 2'));
      expect(bloodPressureNihReference(120, 90).label, contains('stage 2'));
      expect(bloodPressureNihReference(180, 120).label, contains('stage 2'));
      expect(bloodPressureNihReference(181, 120).label, 'Hypertensive crisis');
      expect(bloodPressureNihReference(180, 121).label, 'Hypertensive crisis');
    });
  });

  group('Beurer blood-pressure guidance', () {
    test('keeps its separate WHO-derived categories', () {
      expect(bloodPressureBeurerReference(119, 79).label, 'Optimal');
      expect(bloodPressureBeurerReference(120, 70).label, 'Normal');
      expect(bloodPressureBeurerReference(110, 84).label, 'Normal');
      expect(bloodPressureBeurerReference(130, 70).label, 'High normal');
      expect(bloodPressureBeurerReference(120, 85).label, 'High normal');
      expect(bloodPressureBeurerReference(140, 70).label, contains('Grade 1'));
      expect(bloodPressureBeurerReference(120, 90).label, contains('Grade 1'));
      expect(bloodPressureBeurerReference(160, 70).label, contains('Grade 2'));
      expect(bloodPressureBeurerReference(120, 100).label, contains('Grade 2'));
      expect(bloodPressureBeurerReference(180, 70).label, contains('Grade 3'));
      expect(bloodPressureBeurerReference(120, 110).label, contains('Grade 3'));
    });
  });
}

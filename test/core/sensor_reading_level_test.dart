// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/sensor_reading_level.dart';

void main() {
  group('radon (matched by unit)', () {
    test('bands at the Airthings/WHO 100/150 thresholds', () {
      expect(sensorReadingLevel(unit: 'Bq/m³', value: 55),
          SensorReadingLevel.good);
      expect(sensorReadingLevel(unit: 'Bq/m³', value: 99.9),
          SensorReadingLevel.good);
      expect(sensorReadingLevel(unit: 'Bq/m³', value: 100),
          SensorReadingLevel.fair);
      expect(sensorReadingLevel(unit: 'Bq/m³', value: 149),
          SensorReadingLevel.fair);
      expect(sensorReadingLevel(unit: 'Bq/m³', value: 150),
          SensorReadingLevel.poor);
    });

    test('accepts the ASCII spelling of the unit', () {
      expect(sensorReadingLevel(unit: 'Bq/m3', value: 200),
          SensorReadingLevel.poor);
    });

    test('a radon reading mislabeled with a VOC class still gets radon bands',
        () {
      // An older catalogue copy claimed volatile_organic_compounds_parts on
      // its radon entities. 300 Bq/m³ is well past the radon red line but
      // comfortably inside the VOC ppb "fair" band — reading it against VOC
      // thresholds would print reassurance over a real hazard.
      expect(
        sensorReadingLevel(
          deviceClass: 'volatile_organic_compounds_parts',
          unit: 'Bq/m³',
          value: 300,
        ),
        SensorReadingLevel.poor,
      );
    });
  });

  group('CO₂', () {
    test('bands at the Airthings 800/1000 defaults', () {
      expect(
          sensorReadingLevel(
              deviceClass: 'carbon_dioxide', unit: 'ppm', value: 420),
          SensorReadingLevel.good);
      expect(
          sensorReadingLevel(
              deviceClass: 'carbon_dioxide', unit: 'ppm', value: 800),
          SensorReadingLevel.fair);
      expect(
          sensorReadingLevel(
              deviceClass: 'carbon_dioxide', unit: 'ppm', value: 1000),
          SensorReadingLevel.poor);
    });

    test('a CO₂ class in a unit the band does not hold in stays silent', () {
      expect(
          sensorReadingLevel(
              deviceClass: 'carbon_dioxide', unit: 'mg/m³', value: 900),
          isNull);
    });
  });

  group('VOC', () {
    test('bands ppb at the Airthings 250/2000 defaults', () {
      for (final klass in [
        'volatile_organic_compounds',
        'volatile_organic_compounds_parts',
      ]) {
        expect(sensorReadingLevel(deviceClass: klass, unit: 'ppb', value: 120),
            SensorReadingLevel.good);
        expect(sensorReadingLevel(deviceClass: klass, unit: 'ppb', value: 250),
            SensorReadingLevel.fair);
        expect(sensorReadingLevel(deviceClass: klass, unit: 'ppb', value: 2000),
            SensorReadingLevel.poor);
      }
    });
  });

  group('humidity', () {
    test('bands at the Airthings 25/30/60/70 defaults', () {
      expect(sensorReadingLevel(deviceClass: 'humidity', unit: '%', value: 20),
          SensorReadingLevel.poor);
      expect(sensorReadingLevel(deviceClass: 'humidity', unit: '%', value: 27),
          SensorReadingLevel.fair);
      expect(sensorReadingLevel(deviceClass: 'humidity', unit: '%', value: 45),
          SensorReadingLevel.good);
      expect(sensorReadingLevel(deviceClass: 'humidity', unit: '%', value: 65),
          SensorReadingLevel.fair);
      expect(sensorReadingLevel(deviceClass: 'humidity', unit: '%', value: 75),
          SensorReadingLevel.poor);
    });

    test('accepts the %RH spelling format fields use', () {
      expect(
          sensorReadingLevel(deviceClass: 'humidity', unit: '%RH', value: 45),
          SensorReadingLevel.good);
    });
  });

  group('particulates', () {
    test('PM2.5 bands at 10/25', () {
      expect(sensorReadingLevel(deviceClass: 'pm25', unit: 'µg/m³', value: 5),
          SensorReadingLevel.good);
      expect(sensorReadingLevel(deviceClass: 'pm25', unit: 'µg/m³', value: 12),
          SensorReadingLevel.fair);
      expect(sensorReadingLevel(deviceClass: 'pm25', unit: 'µg/m³', value: 30),
          SensorReadingLevel.poor);
    });

    test('PM10 bands at 20/50', () {
      expect(sensorReadingLevel(deviceClass: 'pm10', unit: 'ug/m3', value: 30),
          SensorReadingLevel.fair);
    });
  });

  group('battery', () {
    test('bands at the usual 20/10 warning rungs', () {
      expect(sensorReadingLevel(deviceClass: 'battery', unit: '%', value: 85),
          SensorReadingLevel.good);
      expect(sensorReadingLevel(deviceClass: 'battery', unit: '%', value: 20),
          SensorReadingLevel.fair);
      expect(sensorReadingLevel(deviceClass: 'battery', unit: '%', value: 10),
          SensorReadingLevel.poor);
    });

    test('a good battery hides its verdict; warnings surface', () {
      expect(
        sensorLevelVisible(
            deviceClass: 'battery', level: SensorReadingLevel.good),
        isFalse,
      );
      expect(
        sensorLevelVisible(
            deviceClass: 'battery', level: SensorReadingLevel.fair),
        isTrue,
      );
      expect(
        sensorLevelVisible(
            deviceClass: 'battery', level: SensorReadingLevel.poor),
        isTrue,
      );
    });

    test('air-quality verdicts are always visible, Good included', () {
      expect(
        sensorLevelVisible(
            deviceClass: 'carbon_dioxide', level: SensorReadingLevel.good),
        isTrue,
      );
      expect(
        sensorLevelVisible(deviceClass: null, level: SensorReadingLevel.good),
        isTrue,
      );
    });
  });

  group('honest silence', () {
    test('unbanded quantities get no verdict', () {
      // Temperature has no universal healthy range — comfort is preference —
      // and a made-up verdict there would cheapen the real ones.
      expect(
          sensorReadingLevel(deviceClass: 'temperature', unit: '°C', value: 22),
          isNull);
      expect(
          sensorReadingLevel(
              deviceClass: 'atmospheric_pressure', unit: 'hPa', value: 1013),
          isNull);
      expect(
          sensorReadingLevel(deviceClass: null, unit: null, value: 5), isNull);
    });

    test('a missing or non-finite value gets no verdict', () {
      expect(sensorReadingLevel(deviceClass: 'battery', unit: '%', value: null),
          isNull);
      expect(
          sensorReadingLevel(
              deviceClass: 'battery', unit: '%', value: double.nan),
          isNull);
    });
  });

  test('labels are the three one-word verdicts', () {
    expect(sensorReadingLevelLabel(SensorReadingLevel.good), 'Good');
    expect(sensorReadingLevelLabel(SensorReadingLevel.fair), 'Fair');
    expect(sensorReadingLevelLabel(SensorReadingLevel.poor), 'Poor');
  });

  test('chip colors keep readable contrast in both brightnesses', () {
    // Decoration must not cost legibility: every verdict chip has to clear
    // the WCAG 4.5:1 floor for small text, light theme and dark alike.
    for (final level in SensorReadingLevel.values) {
      for (final brightness in Brightness.values) {
        final colors = sensorReadingLevelColors(level, brightness);
        final l1 = colors.foreground.computeLuminance();
        final l2 = colors.background.computeLuminance();
        final ratio =
            l1 > l2 ? (l1 + 0.05) / (l2 + 0.05) : (l2 + 0.05) / (l1 + 0.05);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: '$level / $brightness chip contrast $ratio',
        );
      }
    }
  });
}

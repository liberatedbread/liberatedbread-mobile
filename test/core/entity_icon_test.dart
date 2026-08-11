// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/entity_icon.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

/// An entity carrying only what an icon choice looks at.
EntityDto _entity({String? icon, String? deviceClass}) => EntityDto(
      name: 'Reading',
      icon: icon,
      deviceClass: deviceClass,
      canNotify: false,
      hasFormat: true,
      onWhenNonzero: false,
      actions: const [],
    );

void main() {
  group('entityIcon', () {
    test('the spec\'s icon wins over the device class', () {
      // gerbing-thermogauge's heat levels are `number` entities with no
      // device_class that says "this warms you up", which is exactly why the
      // spec names one.
      expect(
        entityIcon(_entity(icon: 'mdi:heat-wave', deviceClass: 'temperature')),
        Icons.waves,
      );
    });

    test('an unmapped mdi name falls back rather than blanking', () {
      // MDI has thousands of names and this build ships a handful of
      // translations. A spec refreshed at runtime can ask for one added
      // upstream after this build shipped; the entity must still draw.
      expect(
        entityIcon(_entity(icon: 'mdi:some-glyph-from-2027')),
        Icons.sensors,
      );
      expect(
        entityIcon(
          _entity(icon: 'mdi:some-glyph-from-2027', deviceClass: 'battery'),
        ),
        Icons.battery_full,
      );
    });

    test('device_class still answers when no icon is declared', () {
      // The overwhelming majority of entities: stating an icon is only worth
      // it when the device class does not already say the right thing.
      expect(entityIcon(_entity(deviceClass: 'temperature')), Icons.thermostat);
      expect(entityIcon(_entity(deviceClass: 'humidity')),
          Icons.water_drop_outlined);
      expect(entityIcon(_entity()), Icons.sensors);
    });

    test('the caller chooses what "nothing to say" looks like', () {
      // A reading with nothing else to say for itself is a sensor; a control
      // with nothing else to say for itself is a knob. Only that last step
      // varies — a declared icon reaches every card.
      expect(entityIcon(_entity(), fallback: Icons.tune), Icons.tune);
      expect(
        entityIcon(_entity(icon: 'mdi:heat-wave'), fallback: Icons.tune),
        Icons.waves,
      );
      expect(
        entityIcon(_entity(deviceClass: 'battery'), fallback: Icons.tune),
        Icons.battery_full,
      );
    });

    test('an empty or oddly-cased icon is not a lookup failure', () {
      expect(entityIcon(_entity(icon: '')), Icons.sensors);
      expect(entityIcon(_entity(icon: '   ')), Icons.sensors);
      expect(entityIcon(_entity(icon: 'MDI:Heat-Wave')), Icons.waves);
    });

    test('air-quality classes and icons draw as themselves, not as "sensor"',
        () {
      // The Airthings family: radon asks for mdi:radioactive (there is no
      // radon device class to imply anything), CO₂/VOC/pressure lean on
      // their classes. All of these rendered as the generic sensors glyph
      // before, which made a six-tile air dashboard read as six copies of
      // the same reading.
      expect(entityIcon(_entity(icon: 'mdi:radioactive')), Icons.blur_on);
      expect(
          entityIcon(_entity(icon: 'mdi:water-thermometer')), Icons.dew_point);
      expect(entityIcon(_entity(icon: 'mdi:molecule-co2')), Icons.co2);
      expect(entityIcon(_entity(deviceClass: 'carbon_dioxide')), Icons.co2);
      expect(
        entityIcon(_entity(deviceClass: 'volatile_organic_compounds_parts')),
        Icons.science_outlined,
      );
      expect(
        entityIcon(_entity(deviceClass: 'volatile_organic_compounds')),
        Icons.science_outlined,
      );
      expect(entityIcon(_entity(deviceClass: 'atmospheric_pressure')),
          Icons.speed);
      expect(entityIcon(_entity(deviceClass: 'pm25')), Icons.grain);
      expect(entityIcon(_entity(deviceClass: 'illuminance')),
          Icons.light_mode_outlined);
    });
  });
}

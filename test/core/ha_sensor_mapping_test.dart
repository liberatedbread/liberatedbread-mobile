// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/ha_sensor_mapping.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

const _statusChar = CharacteristicDto(
  uuid: '0000fff2-0000-1000-8000-00805f9b34fb',
  name: 'Status',
  canRead: true,
  canWrite: false,
  canNotify: true,
  commands: [],
  formatFields: [],
);

const _customChar = CharacteristicDto(
  uuid: '12345678-9abc-def0-1234-56789abcdef0',
  name: 'Environment',
  canRead: true,
  canWrite: false,
  canNotify: false,
  commands: [],
  formatFields: [],
);

void main() {
  group('haUniqueId', () {
    test('uses the assigned number for Bluetooth-base UUIDs', () {
      expect(
        haUniqueId(
            'AA:BB:CC', '0000fff2-0000-1000-8000-00805f9b34fb', 'power_state'),
        'ogiot_aa_bb_cc_fff2_power_state',
      );
    });

    test('uses the first 8 hex chars for vendor UUIDs', () {
      expect(
        haUniqueId('d1', '12345678-9abc-def0-1234-56789abcdef0', 'temp'),
        'ogiot_d1_12345678_temp',
      );
    });

    test('same field name on two characteristics stays unique', () {
      final a = haUniqueId('d', _statusChar.uuid, 'level');
      final b = haUniqueId('d', _customChar.uuid, 'level');
      expect(a, isNot(b));
    });
  });

  group('mapDecodedValue', () {
    test('bool becomes a binary_sensor with bool state', () {
      final sensor = mapDecodedValue(
        deviceId: 'AA:BB',
        deviceName: 'Bulb',
        specChar: _statusChar,
        value: const DecodedValueDto(
          name: 'power_state',
          valueType: 'bool',
          display: 'on',
          boolValue: true,
        ),
      );
      expect(sensor.type, 'binary_sensor');
      expect(sensor.state, true);
      expect(sensor.deviceClass, isNull);
      expect(sensor.unitOfMeasurement, isNull);
      expect(sensor.name, 'Bulb Status Power state');
      expect(sensor.icon, 'mdi:lightbulb');
    });

    test('battery field maps to battery device class with %', () {
      final sensor = mapDecodedValue(
        deviceId: 'AA:BB',
        deviceName: 'Bulb',
        specChar: _statusChar,
        value: const DecodedValueDto(
          name: 'battery_percent',
          valueType: 'uint',
          display: '85',
          uintValue: 85,
        ),
      );
      expect(sensor.type, 'sensor');
      expect(sensor.state, 85);
      expect(sensor.deviceClass, 'battery');
      expect(sensor.unitOfMeasurement, '%');
      expect(sensor.icon, 'mdi:battery');
    });

    test('plain numeric field is a unitless sensor', () {
      final sensor = mapDecodedValue(
        deviceId: 'AA:BB',
        deviceName: 'Bulb',
        specChar: _statusChar,
        value: const DecodedValueDto(
          name: 'brightness',
          valueType: 'uint',
          display: '80',
          uintValue: 80,
        ),
      );
      expect(sensor.type, 'sensor');
      expect(sensor.state, 80);
      expect(sensor.deviceClass, isNull);
      expect(sensor.icon, 'mdi:lightbulb');
    });

    test('numeric temperature gets the icon but no device class', () {
      // Specs carry no unit info, so °C vs °F is unknowable and HA rejects a
      // unitless `temperature` device class for statistics.
      final temp = mapDecodedValue(
        deviceId: 'd',
        deviceName: 'Env',
        specChar: _customChar,
        value: const DecodedValueDto(
          name: 'temperature',
          valueType: 'int',
          display: '21',
          intValue: 21,
        ),
      );
      expect(temp.deviceClass, isNull);
      expect(temp.icon, 'mdi:thermometer');
      expect(temp.state, 21);
    });

    test('string-valued temperature field gets no device class', () {
      // A string state on a numeric device class is an invalid HA state.
      final temp = mapDecodedValue(
        deviceId: 'd',
        deviceName: 'Env',
        specChar: _customChar,
        value: const DecodedValueDto(
          name: 'temperature_label',
          valueType: 'string',
          display: 'warm',
          stringValue: 'warm',
        ),
      );
      expect(temp.deviceClass, isNull);
      expect(temp.state, 'warm');
    });

    test('numeric humidity gets the device class and % unit', () {
      final humidity = mapDecodedValue(
        deviceId: 'd',
        deviceName: 'Env',
        specChar: _customChar,
        value: const DecodedValueDto(
          name: 'humidity',
          valueType: 'uint',
          display: '40',
          uintValue: 40,
        ),
      );
      expect(humidity.deviceClass, 'humidity');
      // HA numeric device classes need a unit.
      expect(humidity.unitOfMeasurement, '%');
    });

    test('string-valued humidity field gets no device class or unit', () {
      final humidity = mapDecodedValue(
        deviceId: 'd',
        deviceName: 'Env',
        specChar: _customChar,
        value: const DecodedValueDto(
          name: 'humidity_status',
          valueType: 'string',
          display: 'dry',
          stringValue: 'dry',
        ),
      );
      expect(humidity.deviceClass, isNull);
      expect(humidity.unitOfMeasurement, isNull);
      expect(humidity.state, 'dry');
    });

    test('non-numeric value falls back to display text', () {
      final sensor = mapDecodedValue(
        deviceId: 'd',
        deviceName: 'Dev',
        specChar: _customChar,
        value: const DecodedValueDto(
          name: 'mode',
          valueType: 'string',
          display: 'eco',
        ),
      );
      expect(sensor.type, 'sensor');
      expect(sensor.state, 'eco');
    });

    test('webhook payloads have the expected shape', () {
      final sensor = mapDecodedValue(
        deviceId: 'AA:BB',
        deviceName: 'Bulb',
        specChar: _statusChar,
        value: const DecodedValueDto(
          name: 'battery_percent',
          valueType: 'uint',
          display: '85',
          uintValue: 85,
        ),
      );
      expect(sensor.toWebhookJson(), {
        'unique_id': 'ogiot_aa_bb_fff2_battery_percent',
        'name': 'Bulb Status Battery percent',
        'type': 'sensor',
        'state': 85,
        'device_class': 'battery',
        'unit_of_measurement': '%',
        'icon': 'mdi:battery',
      });
      expect(sensor.toState().toWebhookJson(), {
        'unique_id': 'ogiot_aa_bb_fff2_battery_percent',
        'type': 'sensor',
        'state': 85,
        'icon': 'mdi:battery',
      });
    });
  });
}

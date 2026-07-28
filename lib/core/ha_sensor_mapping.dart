// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

// Pure mapping from spec-decoded BLE values to Home Assistant sensor
// definitions. Kept free of I/O so it can be unit-tested exhaustively.

import '../models/ha_sensor.dart';
import '../services/spec_codec.dart';
import 'value_format.dart';

/// Stable Home Assistant `unique_id` for one decoded field of one
/// characteristic on one device. The characteristic UUID is included so the
/// same field name on two characteristics never collides.
///
/// The `ogiot_` prefix is the stable key for already-registered HA entities:
/// renaming it would orphan every existing sensor, so it is deliberately kept
/// through the rebrand.
String haUniqueId(String deviceId, String charUuid, String fieldName) {
  return 'ogiot_${_sanitize(deviceId)}_${_shortUuid(charUuid)}'
      '_${_sanitize(fieldName)}';
}

/// Map one decoded value to the sensor definition to register/update in HA.
HaSensorRegistration mapDecodedValue({
  required String deviceId,
  required String deviceName,
  required CharacteristicDto specChar,
  required DecodedValueDto value,
}) {
  final fieldName = value.name.toLowerCase();
  final isBinary = value.boolValue != null || value.valueType == 'bool';
  final numeric = value.uintValue?.toInt() ?? value.intValue?.toInt();

  // Every device-class branch requires a numeric value: HA rejects a string
  // state on a numeric device class, so a string-valued "temperature" field
  // must register as a plain sensor.
  String? deviceClass;
  String? unit;
  var icon = 'mdi:bluetooth';
  if (fieldName.contains('battery') && numeric != null) {
    deviceClass = 'battery';
    unit = '%';
    icon = 'mdi:battery';
  } else if (fieldName.contains('humidity') && numeric != null) {
    deviceClass = 'humidity';
    // HA numeric device classes need a unit.
    unit = '%';
    icon = 'mdi:water-percent';
  } else if (fieldName.contains('temp') && numeric != null) {
    // No device_class: specs carry no unit info, so °C vs °F is unknowable,
    // and HA rejects unitless temperature sensors for statistics. Icon only.
    icon = 'mdi:thermometer';
  } else if (fieldName.contains('power') || fieldName.contains('brightness')) {
    icon = 'mdi:lightbulb';
  }

  final Object? state;
  if (isBinary) {
    state = value.boolValue ?? false;
  } else if (numeric != null) {
    state = numeric;
  } else {
    state = value.stringValue ?? value.display;
  }

  return HaSensorRegistration(
    uniqueId: haUniqueId(deviceId, specChar.uuid, value.name),
    name: '$deviceName ${humanizeName(specChar.name)} '
        '${humanizeName(value.name)}',
    type: isBinary ? 'binary_sensor' : 'sensor',
    state: state,
    deviceClass: isBinary ? null : deviceClass,
    unitOfMeasurement: isBinary ? null : unit,
    icon: icon,
  );
}

String _sanitize(String raw) =>
    raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');

/// The 4-hex assigned number for Bluetooth-base UUIDs
/// (`0000xxxx-0000-1000-8000-00805f9b34fb`), else the first 8 hex chars.
String _shortUuid(String uuid) {
  final hex = uuid.toLowerCase().replaceAll('-', '');
  if (hex.length == 32 &&
      hex.startsWith('0000') &&
      hex.endsWith('00001000800000805f9b34fb')) {
    return hex.substring(4, 8);
  }
  return hex.length >= 8 ? hex.substring(0, 8) : hex;
}

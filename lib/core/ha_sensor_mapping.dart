// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

// Pure mapping from spec-decoded BLE values to Home Assistant sensor
// definitions. Kept free of I/O so it can be unit-tested exhaustively.

import '../models/ha_sensor.dart';
import '../services/spec_codec.dart';
import 'decoded_number.dart';
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

/// Units Home Assistant accepts for each numeric device class it is worth
/// claiming, keyed by the class.
///
/// HA validates this pairing and rejects the registration outright when it
/// does not hold, so a class is only ever claimed once the spec has supplied a
/// unit from the matching set. That is the whole reason this table exists
/// rather than a hardcoded unit per class: the unit is the spec's to state.
const Map<String, Set<String>> _deviceClassUnits = {
  'battery': {'%'},
  'humidity': {'%'},
  'temperature': {'°C', '°F', 'K'},
  'illuminance': {'lx'},
  'pressure': {'hPa', 'Pa', 'kPa', 'bar', 'mbar', 'psi'},
  'atmospheric_pressure': {'hPa', 'Pa', 'kPa', 'mbar'},
  'power': {'W', 'kW'},
  'energy': {'Wh', 'kWh'},
  'voltage': {'V', 'mV'},
  'current': {'A', 'mA'},
  'signal_strength': {'dB', 'dBm'},
};

/// Spellings of a unit that mean the same thing to Home Assistant.
///
/// Specs write temperature units as `C`, `°C` and `degC` across the
/// catalogue; HA only knows the middle one. Normalising here rather than
/// asking every spec author to agree keeps the catalogue tolerant and the
/// registration valid.
const Map<String, String> _unitAliases = {
  'c': '°C',
  'degc': '°C',
  '°c': '°C',
  'f': '°F',
  'degf': '°F',
  '°f': '°F',
  'k': 'K',
  'lux': 'lx',
  'percent': '%',
  'pct': '%',
};

/// [unit] in the spelling Home Assistant expects, or null when the spec gave
/// none.
String? normalizeHaUnit(String? unit) {
  if (unit == null) return null;
  final trimmed = unit.trim();
  if (trimmed.isEmpty) return null;
  return _unitAliases[trimmed.toLowerCase()] ?? trimmed;
}

/// Units that are safe to assume when a spec names none.
///
/// Only where the quantity fixes the unit: a field called `battery_percent`
/// is a percentage whatever the spec forgot to say, and most of the catalogue
/// forgets — 69 of 92 bundled format fields carry no `unit` at all.
/// Temperature is deliberately absent: °C and °F are both ordinary answers,
/// so assuming either would be inventing the one number HA records forever.
const Map<String, String> _conventionalUnits = {
  'battery': '%',
  'humidity': '%',
};

/// The device class and unit to register a field under.
///
/// Two things resolved together because HA validates them as a pair and drops
/// the entity when they disagree. The class is inferred from the field name —
/// the spec's `format:` block has no device-class vocabulary of its own — but
/// the UNIT is the spec's to state: a declared `unit` always wins, and is
/// what decides whether the inferred class survives.
///
/// So a field named `battery_voltage` declaring `unit: "mV"` registers as a
/// plain sensor reading millivolts rather than as a battery percentage, and a
/// temperature field finally gets its `temperature` class now that specs
/// carry `unit: "°C"` — which the previous name-only mapping could not do,
/// because it had nothing but the name to go on.
({String? deviceClass, String? unit}) haClassAndUnit(
  String fieldName,
  String? specUnit,
) {
  final declared = normalizeHaUnit(specUnit);
  final lower = fieldName.toLowerCase();
  final guess = switch (lower) {
    _ when lower.contains('battery') => 'battery',
    _ when lower.contains('humid') => 'humidity',
    _ when lower.contains('temp') => 'temperature',
    _ when lower.contains('lux') || lower.contains('illumin') => 'illuminance',
    _ when lower.contains('pressure') => 'pressure',
    _ => null,
  };
  if (guess == null) return (deviceClass: null, unit: declared);
  final unit = declared ?? _conventionalUnits[guess];
  final accepted = _deviceClassUnits[guess]?.contains(unit) ?? false;
  // A unit the class does not accept keeps the unit and drops the class: the
  // spec knows what it measured, the name only guessed what it was.
  return (deviceClass: accepted ? guess : null, unit: unit);
}

/// Map one decoded value to the sensor definition to register/update in HA.
///
/// The state sent is the DECODED value — `raw * scale + value_offset`, or the
/// `values:` code-table name for an enumerated field — not the wire integer.
/// Forwarding the raw byte put centidegrees and half-degree-offset counts into
/// Home Assistant's long-term statistics, where they are permanent: a reading
/// this app renders as 23.5 °C was recorded as 2350.
HaSensorRegistration mapDecodedValue({
  required String deviceId,
  required String deviceName,
  required CharacteristicDto specChar,
  required DecodedValueDto value,
}) {
  final fieldName = value.name.toLowerCase();
  final isBinary = value.boolValue != null || value.valueType == 'bool';
  final decoded = decodedNumberOf(value);

  // An enumerated field's state is its name, not its code: HA charts and
  // automations key on the state string, and "5" means nothing there either.
  final label = value.valueLabel;

  // Three state shapes take neither a numeric device class nor a unit:
  //  - a bool and an enumerated name are not measurements, and HA rejects
  //    both on those state types;
  //  - a field whose `unit_source` is `device_setting` HAS a unit, but not
  //    one anybody here can name — the same raw number is °C or °F depending
  //    on how the device is configured. It is dropped outright rather than
  //    routed through the conventional-unit fallback, which would otherwise
  //    quietly re-invent the thing this case exists to refuse.
  final measured = !isBinary &&
      label == null &&
      decoded != null &&
      !unitFollowsDeviceSetting(value);
  final resolved = measured
      ? haClassAndUnit(fieldName, value.unit)
      : (deviceClass: null, unit: null);
  final unit = resolved.unit;
  final deviceClass = resolved.deviceClass;

  var icon = 'mdi:bluetooth';
  if (deviceClass == 'battery' || fieldName.contains('battery')) {
    icon = 'mdi:battery';
  } else if (deviceClass == 'humidity' || fieldName.contains('humid')) {
    icon = 'mdi:water-percent';
  } else if (deviceClass == 'temperature' || fieldName.contains('temp')) {
    icon = 'mdi:thermometer';
  } else if (fieldName.contains('power') || fieldName.contains('brightness')) {
    icon = 'mdi:lightbulb';
  }

  final Object? state;
  if (isBinary) {
    state = value.boolValue ?? false;
  } else if (label != null) {
    state = label;
  } else if (decoded != null) {
    state = _haNumber(decoded, value);
  } else {
    state = value.stringValue ?? value.display;
  }

  return HaSensorRegistration(
    uniqueId: haUniqueId(deviceId, specChar.uuid, value.name),
    name: '$deviceName ${humanizeName(specChar.name)} '
        '${humanizeName(value.name)}',
    type: isBinary ? 'binary_sensor' : 'sensor',
    state: state,
    deviceClass: deviceClass,
    unitOfMeasurement: unit,
    icon: icon,
  );
}

/// [decoded] as the narrowest JSON number that still says what the transform
/// produced.
///
/// An untransformed field stays an `int`, exactly as before — the common case,
/// and `85` reads better than `85.0` in HA. A transform with decimals sends a
/// double rounded to the places the transform actually carries, so float error
/// in `raw * 0.1` does not reach the server as 23.000000000000004.
num _haNumber(double decoded, DecodedValueDto value) {
  final decimals = decimalsForTransform(
    scale: value.scale,
    valueOffset: value.valueOffset,
  );
  if (decimals == 0) return decoded.round();
  return double.parse(decoded.toStringAsFixed(decimals));
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

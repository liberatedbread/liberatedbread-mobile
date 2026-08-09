// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/decoded_number.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

/// One decoded field, with only the number semantics a case cares about.
DecodedValueDto _field({
  String name = 'reading',
  String valueType = 'uint',
  String? display,
  int? uintValue,
  int? intValue,
  bool? boolValue,
  String? stringValue,
  double? scale,
  double? valueOffset,
  String? unit,
  String? valueLabel,
  String? unitSource,
}) =>
    DecodedValueDto(
      name: name,
      valueType: valueType,
      display: display ?? '${uintValue ?? intValue ?? stringValue ?? ''}',
      uintValue: uintValue,
      intValue: intValue,
      boolValue: boolValue,
      stringValue: stringValue,
      scale: scale,
      valueOffset: valueOffset,
      unit: unit,
      valueLabel: valueLabel,
      unitSource: unitSource,
    );

void main() {
  group('decodedNumberOf', () {
    test('applies scale AND value_offset, not just scale', () {
      // The regression this file exists for. gerbing-thermogauge declares
      // `scale: 0.5, value_offset: 85` on its temperature field; dropping the
      // offset reported a 135 F probe as 50 F — wrong by the whole offset,
      // and wrong in the direction that reads as a plausible temperature.
      expect(
        decodedNumberOf(_field(uintValue: 100, scale: 0.5, valueOffset: 85)),
        135.0,
      );
    });

    test('applies an offset with no scale', () {
      // The automotive `x - 40` idiom. Scale is absent (meaning 1), and the
      // early-out that used to key off a null scale skipped the offset
      // entirely and returned the raw byte.
      expect(decodedNumberOf(_field(uintValue: 60, valueOffset: -40)), 20.0);
    });

    test('applies scale alone', () {
      expect(decodedNumberOf(_field(intValue: 2350, scale: 0.01)), 23.5);
    });

    test('an untransformed field is its raw value', () {
      expect(decodedNumberOf(_field(uintValue: 85)), 85.0);
    });

    test('an entity scale REPLACES the field transform rather than compounding',
        () {
      // `state_mapping.scale` is the entity layer's complete statement about
      // its own value, which is how bindings::setpoint_transform resolves it
      // on the write path. Compounding would put decode and encode out of
      // step: the card would read back a different number than it just sent.
      expect(
        decodedNumberOf(
          _field(uintValue: 100, scale: 0.5, valueOffset: 85),
          scaleOverride: 0.01,
        ),
        1.0,
      );
    });

    test('a non-numeric field has no number', () {
      expect(decodedNumberOf(_field(valueType: 'string', stringValue: 'eco')),
          isNull);
      expect(
          decodedNumberOf(_field(valueType: 'bool', boolValue: true)), isNull);
    });
  });

  group('decimalsForTransform', () {
    test('shows as many places as the transform carries', () {
      expect(decimalsForTransform(scale: 0.01), 2);
      expect(decimalsForTransform(scale: 0.1), 1);
      expect(decimalsForTransform(scale: 0.5), 1);
      expect(decimalsForTransform(scale: 0.001), 3);
      expect(decimalsForTransform(scale: 2.5), 1);
    });

    test('an integral transform shows none', () {
      expect(decimalsForTransform(), 0);
      expect(decimalsForTransform(scale: 1), 0);
      expect(decimalsForTransform(scale: 2, valueOffset: -40), 0);
    });

    test('an offset can need more places than the scale', () {
      expect(decimalsForTransform(scale: 1, valueOffset: 0.25), 2);
    });

    test('a scale that renders in exponent form does not produce nonsense', () {
      // 1e-7.toString() is "1e-7", which has no '.' at all — splitting on one
      // and measuring the tail counted the exponent's digits as decimals.
      // Capped rather than honoured: past six places a reading is showing
      // float noise, not resolution.
      expect(decimalsForTransform(scale: 1e-7), lessThanOrEqualTo(6));
      expect(decimalsForTransform(scale: 1e-7), greaterThan(0));
    });

    test('a negative scale is measured by magnitude', () {
      expect(decimalsForTransform(scale: -0.5), 1);
    });
  });

  group('decodedTextOf', () {
    test('renders the transformed value at the transform precision', () {
      expect(decodedTextOf(_field(uintValue: 100, scale: 0.5, valueOffset: 85)),
          '135.0');
      expect(decodedTextOf(_field(intValue: 2350, scale: 0.01)), '23.50');
      expect(decodedTextOf(_field(uintValue: 85)), '85');
    });

    test('falls back to the codec rendering for a non-numeric field', () {
      expect(
        decodedTextOf(
            _field(valueType: 'bool', boolValue: true, display: 'on')),
        'on',
      );
      expect(
        decodedTextOf(
            _field(valueType: 'string', stringValue: 'eco', display: 'eco')),
        'eco',
      );
    });
  });

  group('labelledTextOf', () {
    test('a code-table name wins over the raw code', () {
      // Ember's liquid_state: 5 means "heating", and 5 on its own means
      // nothing without the spec open.
      expect(
        labelledTextOf(_field(uintValue: 5, valueLabel: 'heating')),
        'heating',
      );
    });

    test('without a label it is the transformed number', () {
      expect(labelledTextOf(_field(uintValue: 5)), '5');
    });
  });

  group('unitOf', () {
    test('the entity unit wins over the field unit', () {
      expect(unitOf(_field(unit: 'C'), entityUnit: '°F'), '°F');
    });

    test('falls back to the field unit', () {
      expect(unitOf(_field(unit: '%')), '%');
    });

    test('a device-setting unit is not stated as fact', () {
      // The Inkbird iBBQ sends whichever unit the device is set to, so the
      // same raw 165 is 165 C or 165 F.
      expect(
        unitOf(_field(unit: 'C', unitSource: 'device_setting')),
        isNull,
      );
    });

    test('an entity that names a unit overrides even a device-setting field',
        () {
      expect(
        unitOf(_field(unit: 'C', unitSource: 'device_setting'),
            entityUnit: '°C'),
        '°C',
      );
    });

    test('empty units read as absent', () {
      expect(unitOf(_field(unit: '')), isNull);
      expect(unitOf(_field(unit: '%'), entityUnit: ''), '%');
    });
  });
}

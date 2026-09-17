// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// decoded_number.dart is a READER now: the spec's number semantics are
// evaluated in `rust/src/codec/number.rs` and arrive on the DTO. So these
// cases hand it a DTO shaped the way Rust fills one in and assert which field
// each function chooses — the arithmetic itself is covered by the Rust unit
// tests (`codec::number::tests`), and `decoded_number_golden_test.dart` pins
// the two together by decoding real bytes through the real FFI.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/decoded_number.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

/// One decoded field, as the Rust decoder would hand it over.
///
/// [decodedNumber], [decodedText] and [decimals] are stated, never derived
/// from [scale]/[valueOffset] here: deriving them would make this file a
/// second implementation of the very contract it exists to stop duplicating.
DecodedValueDto _field({
  String name = 'reading',
  String valueType = 'uint',
  String? display,
  int? uintValue,
  int? intValue,
  bool? boolValue,
  String? stringValue,
  double? rawNumber,
  double? decodedNumber,
  String? decodedText,
  int? decimals,
  bool? isOn,
  double? scale,
  double? valueOffset,
  String? unit,
  String? valueLabel,
  String? unitSource,
}) {
  final raw = rawNumber ?? (uintValue ?? intValue)?.toDouble();
  return DecodedValueDto(
    name: name,
    valueType: valueType,
    display: display ?? '${uintValue ?? intValue ?? stringValue ?? ''}',
    uintValue: uintValue,
    intValue: intValue,
    boolValue: boolValue,
    stringValue: stringValue,
    rawNumber: raw,
    decodedNumber: decodedNumber ?? raw,
    decodedText: decodedText,
    decimals: decimals,
    isOn: isOn,
    scale: scale,
    valueOffset: valueOffset,
    unit: unit,
    valueLabel: valueLabel,
    unitSource: unitSource,
  );
}

void main() {
  group('rawNumberOf', () {
    test('is the value Rust decoded, not the one the FFI could carry', () {
      // A u64 above i64::MAX is clamped into `uintValue`; `rawNumber` is what
      // the device actually sent. Reading the clamp showed 9223372036854775807
      // for a counter that said something else entirely.
      const truthful = 18446744073709551615.0;
      final clamped = _field(
        uintValue: 9223372036854775807,
        rawNumber: truthful,
        decodedNumber: truthful,
      );
      expect(rawNumberOf(clamped), truthful);
    });

    test('a non-numeric field has no raw number', () {
      expect(
        rawNumberOf(_field(valueType: 'string', stringValue: 'eco')),
        isNull,
      );
      expect(rawNumberOf(_field(valueType: 'bool', boolValue: true)), isNull);
    });
  });

  group('decodedNumberOf', () {
    test('is the transformed number Rust computed', () {
      // gerbing-thermogauge declares `scale: 0.5, value_offset: 85`; the DTO
      // carries the answer so no consumer can drop half the transform, which
      // is what reported a 135 F probe as 50 F.
      expect(
        decodedNumberOf(
          _field(
            uintValue: 100,
            scale: 0.5,
            valueOffset: 85,
            decodedNumber: 135.0,
          ),
        ),
        135.0,
      );
    });

    test('an untransformed field is its raw value', () {
      expect(decodedNumberOf(_field(uintValue: 85)), 85.0);
    });

    test(
      'an entity scale REPLACES the field transform rather than compounding',
      () {
        // `state_mapping.scale` is the entity layer's complete statement about
        // its own value, which is how bindings::setpoint_transform resolves it
        // on the write path. Compounding would put decode and encode out of
        // step: the card would read back a different number than it just sent.
        expect(
          decodedNumberOf(
            _field(
              uintValue: 100,
              scale: 0.5,
              valueOffset: 85,
              decodedNumber: 135.0,
            ),
            scaleOverride: 0.01,
          ),
          1.0,
        );
      },
    );

    test('an entity scale applies to the truthful raw value', () {
      const truthful = 18446744073709551615.0;
      expect(
        decodedNumberOf(
          _field(uintValue: 9223372036854775807, rawNumber: truthful),
          scaleOverride: 2,
        ),
        truthful * 2,
      );
    });

    test('a non-numeric field has no number', () {
      expect(
        decodedNumberOf(_field(valueType: 'string', stringValue: 'eco')),
        isNull,
      );
      expect(
        decodedNumberOf(_field(valueType: 'bool', boolValue: true)),
        isNull,
      );
      expect(
        decodedNumberOf(
          _field(valueType: 'bool', boolValue: true),
          scaleOverride: 0.5,
        ),
        isNull,
      );
    });
  });

  group('decodedTextOf', () {
    test('is the text Rust rendered', () {
      expect(
        decodedTextOf(
          _field(
            uintValue: 100,
            scale: 0.5,
            valueOffset: 85,
            decodedNumber: 135.0,
            decodedText: '135.0',
            decimals: 1,
          ),
        ),
        '135.0',
      );
      expect(
        decodedTextOf(_field(uintValue: 85, decodedText: '85', decimals: 0)),
        '85',
      );
    });

    test('is the truthful number for a uint the FFI had to clamp', () {
      // The clamped `uintValue` reads as i64::MAX; the rendering Rust did
      // reads as the counter the device sent.
      const truthful = '18446744073709551615';
      expect(
        decodedTextOf(
          _field(
            uintValue: 9223372036854775807,
            display: truthful,
            decodedText: truthful,
          ),
        ),
        truthful,
      );
    });

    test('falls back to the codec rendering for a non-numeric field', () {
      expect(
        decodedTextOf(
          _field(valueType: 'bool', boolValue: true, display: 'on'),
        ),
        'on',
      );
      expect(
        decodedTextOf(
          _field(valueType: 'string', stringValue: 'eco', display: 'eco'),
        ),
        'eco',
      );
    });
  });

  group('the entity overlay', () {
    // `state_mapping.scale` and `precision` belong to an entity, not to the
    // format field, so they are not known when the characteristic is decoded.
    // These are the only cases decoded_number.dart still computes; their Rust
    // twin is NumberSemantics.
    DecodedValueDto centidegrees() => _field(
      intValue: 2347,
      scale: 0.01,
      decodedNumber: 23.47,
      decodedText: '23.47',
      decimals: 2,
    );

    test('precision rounds and prints to the declared increment', () {
      // ember's centi-degree encoding is finer than a mug's thermometer
      // actually is; hotwired-heated-gear declares `precision: 1.0` on a
      // control whose level is a whole number.
      expect(decodedTextOf(centidegrees()), '23.47');
      expect(decodedTextOf(centidegrees(), precision: 0.1), '23.5');
      expect(decodedTextOf(centidegrees(), precision: 1), '23');
      expect(decodedTextOf(centidegrees(), precision: 0.5), '23.5');
    });

    test('absent or nonsensical precision leaves Rust rendering in charge', () {
      expect(decodedTextOf(centidegrees(), precision: null), '23.47');
      // Zero would divide; a negative increment means nothing. Neither is a
      // reason to stop rendering the reading.
      expect(decodedTextOf(centidegrees(), precision: 0), '23.47');
      expect(decodedTextOf(centidegrees(), precision: -1), '23.47');
    });

    test('a non-finite reading renders instead of throwing', () {
      // A malformed spec can produce one — an entity scale of infinity, an
      // overflowing offset. Rounding to the increment threw UnsupportedError
      // on the way, taking the card down over a number it could have shown.
      final infinite = _field(
        intValue: 1,
        decodedNumber: double.infinity,
        decodedText: 'Infinity',
      );
      expect(decodedTextOf(infinite, precision: 0.1), 'Infinity');
      expect(
        decodedTextOf(
          _field(
            intValue: 1,
            decodedNumber: double.negativeInfinity,
            decodedText: '-Infinity',
          ),
          precision: 0.1,
        ),
        '-Infinity',
      );
      expect(
        decodedTextOf(
          _field(intValue: 1, decodedNumber: double.nan, decodedText: 'NaN'),
          precision: 0.5,
        ),
        'NaN',
      );
      // And with an entity scale that produces the non-finite value itself.
      expect(
        decodedTextOf(_field(intValue: 1), scaleOverride: double.infinity),
        'Infinity',
      );
    });

    test('an entity scale renders at the places that scale carries', () {
      expect(
        decodedTextOf(_field(uintValue: 100), scaleOverride: 0.01),
        '1.00',
      );
      expect(decodedTextOf(_field(uintValue: 100), scaleOverride: 2), '200');
    });

    test('a code-table label still wins over any rounding', () {
      // For an enumerated field the number IS the code, so there is nothing
      // to round — ember's `liquid_state: 5` means "heating".
      final enumerated = _field(uintValue: 5, valueLabel: 'heating');
      expect(labelledTextOf(enumerated, precision: 1), 'heating');
    });

    test('is presentation only — the number itself is untouched', () {
      // Controls seed from decodedNumberOf, which must keep the real value:
      // rounding a slider's starting point would write back the rounding.
      expect(decodedNumberOf(centidegrees()), closeTo(23.47, 1e-9));
    });
  });

  group('decimalsForTransform', () {
    // The mirror of `decimals_for_transform` in rust/src/codec/number.rs,
    // kept for the Home Assistant forwarder, which re-renders the number as
    // JSON rather than showing the text. Same cases as the Rust side.
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

    test('precision decimals read the increment', () {
      expect(decimalsForPrecision(0.1), 1);
      expect(decimalsForPrecision(0.5), 1);
      expect(decimalsForPrecision(1), 0);
      expect(decimalsForPrecision(0.05), 2);
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

    test('without a label it is the text Rust rendered', () {
      expect(labelledTextOf(_field(uintValue: 5, decodedText: '5')), '5');
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
      expect(unitOf(_field(unit: 'C', unitSource: 'device_setting')), isNull);
    });

    test(
      'an entity that names a unit overrides even a device-setting field',
      () {
        expect(
          unitOf(
            _field(unit: 'C', unitSource: 'device_setting'),
            entityUnit: '°C',
          ),
          '°C',
        );
      },
    );

    test('empty units read as absent', () {
      expect(unitOf(_field(unit: '')), isNull);
      expect(unitOf(_field(unit: '%'), entityUnit: ''), '%');
    });
  });
}

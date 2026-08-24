// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The catalogue spells units for comparison and this spells them for people.
// The claims are that the translation happens, that it is only a spelling
// change, and that an unknown unit still reaches the screen.

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/unit_display.dart';

void main() {
  test('the catalogue\'s bare temperature symbols gain their degree sign', () {
    // Specs say `C` so the string compares equal to a device's own unit_values
    // table; a thermometer reading "21.4 C" would look broken.
    expect(displayUnit('C'), '°C');
    expect(displayUnit('F'), '°F');
    expect(displayUnit('degC'), '°C');
    // Case and stray whitespace are the spec author's, not the reader's.
    expect(displayUnit(' f '), '°F');
  });

  test('a unit already written for a reader is left alone', () {
    expect(displayUnit('°C'), '°C');
    expect(displayUnit('%'), '%');
    expect(displayUnit('Bq/m³'), 'Bq/m³');
    expect(displayUnit('km/h'), 'km/h');
  });

  test('an unknown unit reaches the screen verbatim', () {
    // Passing it through is the honest failure: it is still the spec's answer.
    expect(displayUnit('furlongs/fortnight'), 'furlongs/fortnight');
  });

  test('no unit and an empty unit both read as none', () {
    expect(displayUnit(null), isNull);
    expect(displayUnit(''), isNull);
    expect(displayUnit('   '), isNull);
  });

  test('K stays K — it has no degree sign', () {
    // Kelvin is written without one by convention, so the table must not
    // "helpfully" add it the way it does for C and F.
    expect(displayUnit('K'), 'K');
  });
}

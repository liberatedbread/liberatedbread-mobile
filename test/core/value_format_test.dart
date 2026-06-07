// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/core/value_format.dart';

void main() {
  test('humanizeName turns identifiers into labels', () {
    expect(humanizeName('set_brightness'), 'Set brightness');
    expect(humanizeName('power-on'), 'Power on');
    expect(humanizeName('battery_percent'), 'Battery percent');
    expect(humanizeName('already nice'), 'Already nice');
    expect(humanizeName(''), '');
  });

  test('rangeFor falls back to the natural range of the type', () {
    expect(rangeFor('bool', null, null), (min: 0.0, max: 1.0));
    expect(rangeFor('uint8', null, null), (min: 0.0, max: 255.0));
    expect(rangeFor('uint16', null, null), (min: 0.0, max: 65535.0));
    expect(rangeFor('int8', null, null), (min: -128.0, max: 127.0));
    expect(rangeFor('int16', null, null), (min: -32768.0, max: 32767.0));
    expect(rangeFor('mystery', null, null), (min: 0.0, max: 255.0));
  });

  test('rangeFor honors explicit spec bounds', () {
    expect(rangeFor('uint8', 0, 100), (min: 0.0, max: 100.0));
    expect(rangeFor('uint8', 10, null), (min: 10.0, max: 255.0));
  });

  test('divisionsFor returns step count or null for wide/degenerate ranges',
      () {
    expect(divisionsFor(0, 100), 100);
    expect(divisionsFor(0, 0), isNull);
    expect(divisionsFor(0, 65535), isNull);
  });
}

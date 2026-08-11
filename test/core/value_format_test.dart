// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/value_format.dart';

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
    expect(rangeFor('uint32', null, null), (min: 0.0, max: 4294967295.0));
    expect(rangeFor('int8', null, null), (min: -128.0, max: 127.0));
    expect(rangeFor('int16', null, null), (min: -32768.0, max: 32767.0));
    expect(
        rangeFor('int32', null, null), (min: -2147483648.0, max: 2147483647.0));
    expect(rangeFor('mystery', null, null), (min: 0.0, max: 255.0));
  });

  test('rangeFor honors explicit spec bounds', () {
    expect(rangeFor('uint8', 0, 100), (min: 0.0, max: 100.0));
    expect(rangeFor('uint8', 10, null), (min: 10.0, max: 255.0));
  });

  test('rangeFor falls back to a safe range for degenerate/inverted bounds',
      () {
    // min > max (malformed spec) -> type's natural range, never inverted.
    expect(rangeFor('uint8', 200, 50), (min: 0.0, max: 255.0));
    // min == max (zero-width) -> type's natural range.
    expect(rangeFor('uint8', 40, 40), (min: 0.0, max: 255.0));
    // Inverted with only-implicit other bound still normalizes.
    expect(rangeFor('int8', 100, -100), (min: -128.0, max: 127.0));
    // The safe range is always well-ordered.
    final r = rangeFor('mystery', 9, 9);
    expect(r.min < r.max, isTrue);
  });

  test('divisionsFor returns step count or null for wide/degenerate ranges',
      () {
    expect(divisionsFor(0, 100), 100);
    expect(divisionsFor(0, 0), isNull);
    expect(divisionsFor(0, 65535), isNull);
  });

  test('snapToStep lands on device-representable values and clamps', () {
    // The continuous-slider case divisionsForStep gives up on: a 0..1000
    // range stepped by 1 must still only ever produce whole numbers, or the
    // label shows a value the write path rounds away.
    expect(snapToStep(523.4, 0, 1000, 1), 523);
    expect(snapToStep(523.5, 0, 1000, 1), 524);
    // Steps coarser than 1 snap to the grid anchored at min.
    expect(snapToStep(37, 10, 110, 25), 35);
    // Ends clamp rather than overshooting the range.
    expect(snapToStep(1000.4, 0, 1000, 1), 1000);
    expect(snapToStep(-3, 0, 1000, 1), 0);
    // Unsnappable inputs pass through rather than corrupting the drag.
    expect(snapToStep(42.5, 0, 100, 0), 42.5);
    expect(snapToStep(42.5, 0, 100, double.nan), 42.5);
  });

  test('allowedEntryLabel pairs label with wire value, or shows value alone',
      () {
    expect(allowedEntryLabel('OFF', 0), 'OFF (0)');
    expect(allowedEntryLabel('Low', 200), 'Low (200)');
    // Allowed values cross the FFI as BigInt; they must render identically.
    expect(allowedEntryLabel('High', BigInt.from(1000)), 'High (1000)');
    expect(allowedEntryLabel(null, BigInt.from(400)), '400');
    // A degenerate empty label falls back to the raw value too.
    expect(allowedEntryLabel('', 7), '7');
  });

  test('isNumericValueType accepts integer types only', () {
    for (final t in ['uint8', 'uint16', 'uint32', 'int8', 'int16', 'int32']) {
      expect(isNumericValueType(t), isTrue, reason: t);
    }
    // bool has its own switch control; string/bytes/unknown get no slider.
    for (final t in ['bool', 'string', 'bytes', 'mystery']) {
      expect(isNumericValueType(t), isFalse, reason: t);
    }
  });

  test('shortAge writes a span at the coarsest useful unit', () {
    // Seconds matter here: the difference between a device that went quiet
    // twenty seconds ago and one that went quiet twenty minutes ago is the
    // difference between a dropped packet and an unplugged device.
    expect(shortAge(Duration.zero), '0s');
    expect(shortAge(const Duration(milliseconds: 900)), '0s');
    expect(shortAge(const Duration(seconds: 45)), '45s');
    expect(shortAge(const Duration(seconds: 59)), '59s');
    expect(shortAge(const Duration(minutes: 1)), '1m');
    expect(shortAge(const Duration(minutes: 59, seconds: 59)), '59m');
    expect(shortAge(const Duration(hours: 3, minutes: 30)), '3h');
    expect(shortAge(const Duration(days: 2)), '2d');
  });

  test(
      'displayValueFor/rawValueFor are inverse across the presentation '
      'transform', () {
    // A treadmill speed: raw 30 counts at scale 0.1 display as 3.0 km/h.
    expect(displayValueFor(30, 0.1, null), closeTo(3.0, 1e-9));
    expect(rawValueFor(3.0, 0.1, null), closeTo(30.0, 1e-9));
    // The additive term completes display = raw * scale + valueOffset.
    expect(displayValueFor(20, 0.5, 10), 20.0);
    expect(rawValueFor(20.0, 0.5, 10), 20.0);
    // Null scale/offset are the identity transform, so DTO fields pass
    // straight through for parameters declaring no presentation metadata.
    expect(displayValueFor(64, null, null), 64.0);
    expect(rawValueFor(64, null, null), 64.0);
  });

  test('decimalsForStep counts the digits a step needs', () {
    expect(decimalsForStep(1), 0);
    expect(decimalsForStep(25), 0);
    expect(decimalsForStep(0.5), 1);
    expect(decimalsForStep(0.1), 1);
    expect(decimalsForStep(0.01), 2);
    // A step that cannot be honoured formats as whole numbers rather than
    // looping forever.
    expect(decimalsForStep(0), 0);
    expect(decimalsForStep(double.nan), 0);
  });
}

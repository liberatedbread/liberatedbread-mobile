// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/core/maidenhead.dart';

void main() {
  group('maidenheadToPoint', () {
    test('FN31pr resolves to the ARRL neighbourhood', () {
      final point = maidenheadToPoint('FN31pr');
      expect(point, isNotNull);
      expect(point!.lat, closeTo(41.729, 0.001));
      expect(point.lon, closeTo(-72.708, 0.001));
    });

    test('CN87 resolves to the centre of the square, not a corner', () {
      // The square runs 47-48 N, 124-122 W. Its centre is the answer; its
      // south-west corner would be 55 km and 75 km out respectively.
      final point = maidenheadToPoint('CN87');
      expect(point!.lat, closeTo(47.5, 1e-9));
      expect(point.lon, closeTo(-123.0, 1e-9));
    });

    test('is case-insensitive and tolerates surrounding space', () {
      expect(maidenheadToPoint(' fn31PR '), maidenheadToPoint('FN31pr'));
    });

    test('accepts 2, 4, 6 and 8 characters', () {
      for (final grid in ['FN', 'FN31', 'FN31pr', 'FN31pr55']) {
        expect(maidenheadToPoint(grid), isNotNull, reason: grid);
      }
    });

    test('rejects malformed locators instead of guessing', () {
      for (final grid in [
        '',
        'F',
        'FN3',
        'FN31p',
        'FN31pr5',
        'FN31pr555',
        'ZZ99',
        'FNxx',
        'FN31zz',
        '1234',
      ]) {
        expect(maidenheadToPoint(grid), isNull, reason: grid);
      }
    });

    test('an 8-character locator is more precise than its 6-character prefix',
        () {
      final six = maidenheadToPoint('FN31pr')!;
      final eight = maidenheadToPoint('FN31pr99')!;
      expect(eight.lat, greaterThan(six.lat));
      expect(eight.lon, greaterThan(six.lon));
      // ...but still inside the same subsquare: under 5 km apart.
      expect(haversineKm(six, eight), lessThan(5));
    });
  });

  group('pointToMaidenhead', () {
    test('encodes a known point', () {
      expect(pointToMaidenhead(const GeoPoint(41.7291, -72.7083)), 'FN31pr');
    });

    test('honours the requested precision', () {
      const point = GeoPoint(41.7291, -72.7083);
      expect(pointToMaidenhead(point, precision: 2), 'FN');
      expect(pointToMaidenhead(point, precision: 4), 'FN31');
      expect(pointToMaidenhead(point, precision: 6), 'FN31pr');
      expect(pointToMaidenhead(point, precision: 8)!.length, 8);
    });

    test('refuses an odd precision rather than emitting a broken locator', () {
      const point = GeoPoint(41.7291, -72.7083);
      expect(pointToMaidenhead(point, precision: 3), isNull);
      expect(pointToMaidenhead(point, precision: 0), isNull);
      expect(pointToMaidenhead(point, precision: 10), isNull);
    });

    test('refuses a point that is not on the earth', () {
      expect(pointToMaidenhead(const GeoPoint(95, 0)), isNull);
      expect(pointToMaidenhead(const GeoPoint(double.nan, 0)), isNull);
    });

    test('handles the edges of the coordinate space', () {
      // Longitude exactly 180 is the one input that indexes past the last
      // field letter without a clamp.
      expect(pointToMaidenhead(const GeoPoint(0, 180)), isNotNull);
      expect(pointToMaidenhead(const GeoPoint(-90, -180)), 'AA00aa');
      expect(pointToMaidenhead(const GeoPoint(90, 180)), isNotNull);
    });
  });

  test('round trip lands inside the square it names', () {
    const points = [
      GeoPoint(47.6062, -122.3321),
      GeoPoint(-33.8688, 151.2093),
      GeoPoint(51.5074, -0.1278),
      GeoPoint(0.0, 0.0),
      GeoPoint(-15.7939, -47.8828),
      GeoPoint(64.1466, -21.9426),
    ];
    for (final point in points) {
      final grid = pointToMaidenhead(point);
      expect(grid, isNotNull, reason: '$point');
      final back = maidenheadToPoint(grid!);
      expect(back, isNotNull, reason: grid);
      // A 6-character subsquare is 5' x 2.5'. At the equator that is 9.3 km
      // by 4.6 km, so the furthest a point can sit from its own square's
      // centre is the half-diagonal, ~5.2 km. Anything beyond 6 km is a bug,
      // not geometry.
      expect(haversineKm(point, back!), lessThan(6), reason: '$point -> $grid');
    }
  });

  test('encoding is stable across the round trip', () {
    for (final grid in ['FN31pr', 'CN87ux', 'JJ00aa', 'RR99xx', 'AA00aa']) {
      final point = maidenheadToPoint(grid);
      expect(pointToMaidenhead(point!), grid, reason: grid);
    }
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/geo.dart';

void main() {
  group('GeoPoint', () {
    test('accepts coordinates on the earth', () {
      expect(const GeoPoint(41.7, -72.7).isValid, isTrue);
      expect(const GeoPoint(90, 180).isValid, isTrue);
      expect(const GeoPoint(-90, -180).isValid, isTrue);
    });

    test('rejects coordinates that are not', () {
      expect(const GeoPoint(91, 0).isValid, isFalse);
      expect(const GeoPoint(0, 181).isValid, isFalse);
      expect(const GeoPoint(double.nan, 0).isValid, isFalse);
      expect(const GeoPoint(0, double.infinity).isValid, isFalse);
    });

    test('round-trips through JSON', () {
      const point = GeoPoint(47.6062, -122.3321);
      expect(GeoPoint.fromJson(point.toJson()), point);
    });

    test('decodes defensively', () {
      expect(GeoPoint.fromJson({'lat': 'north', 'lon': 0}), isNull);
      expect(GeoPoint.fromJson({'lat': 1.0}), isNull);
      expect(GeoPoint.fromJson(const {}), isNull);
      // A coordinate pair that decodes but is not on the earth is rejected
      // here rather than being left to fail a radius filter 6000 km away.
      expect(GeoPoint.fromJson({'lat': 200.0, 'lon': 0.0}), isNull);
    });

    test('accepts ints, which is what a hand-written JSON fixture has', () {
      expect(
        GeoPoint.fromJson({'lat': 47, 'lon': -122}),
        const GeoPoint(47.0, -122.0),
      );
    });

    test('has value equality', () {
      expect(const GeoPoint(1, 2), const GeoPoint(1, 2));
      expect(const GeoPoint(1, 2).hashCode, const GeoPoint(1, 2).hashCode);
      expect(const GeoPoint(1, 2), isNot(const GeoPoint(2, 1)));
    });
  });

  group('haversineKm', () {
    test('is zero for a point against itself', () {
      expect(
        haversineKm(const GeoPoint(41.7, -72.7), const GeoPoint(41.7, -72.7)),
        0.0,
      );
    });

    test('matches a published distance: Seattle to Portland', () {
      // ~233 km great-circle. Tolerance is 2 km, well inside haversine's
      // disagreement with the ellipsoid and well outside a coding error.
      final km = haversineKm(
        const GeoPoint(47.6062, -122.3321),
        const GeoPoint(45.5152, -122.6784),
      );
      expect(km, closeTo(233, 2));
    });

    test('matches a published distance: London to Paris', () {
      final km = haversineKm(
        const GeoPoint(51.5074, -0.1278),
        const GeoPoint(48.8566, 2.3522),
      );
      expect(km, closeTo(343, 3));
    });

    test('one degree of latitude is about 111 km anywhere', () {
      for (final lat in [0.0, 45.0, 70.0]) {
        expect(
          haversineKm(GeoPoint(lat, 0), GeoPoint(lat + 1, 0)),
          closeTo(111.2, 0.5),
        );
      }
    });

    test('is symmetric', () {
      const a = GeoPoint(35.6762, 139.6503);
      const b = GeoPoint(-33.8688, 151.2093);
      expect(haversineKm(a, b), closeTo(haversineKm(b, a), 1e-9));
    });

    test('crosses the antimeridian without going the long way', () {
      // 1 degree apart, either side of 180. A naive linear difference would
      // call this 359 degrees.
      final km = haversineKm(
        const GeoPoint(0, 179.5),
        const GeoPoint(0, -179.5),
      );
      expect(km, closeTo(111.2, 0.5));
    });

    test('survives antipodal points without NaN', () {
      final km = haversineKm(const GeoPoint(0, 0), const GeoPoint(0, 180));
      expect(km.isNaN, isFalse);
      expect(km, closeTo(earthRadiusKm * 3.14159265, 1));
    });
  });
}

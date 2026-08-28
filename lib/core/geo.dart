// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Geographic primitives for the radio suggestion engine.

import 'dart:math' as math;

/// A point on the earth, in signed decimal degrees.
///
/// Latitude is positive north, longitude positive east — the convention every
/// source this app reads (GPS, RepeaterBook, myGMRS, NOAA) already uses, so
/// nothing has to remember to flip a sign.
class GeoPoint {
  final double lat;
  final double lon;

  const GeoPoint(this.lat, this.lon);

  /// Whether this is a point on the earth at all.
  ///
  /// Worth having as a predicate rather than an assertion because most of the
  /// coordinates this app sees arrive from someone else's JSON: a repeater
  /// listing with a blank longitude decodes to 0.0 and would otherwise sit
  /// silently in the Gulf of Guinea, 6000 km from everything, looking like a
  /// real result that simply failed the radius filter.
  bool get isValid =>
      lat.isFinite &&
      lon.isFinite &&
      lat >= -90 &&
      lat <= 90 &&
      lon >= -180 &&
      lon <= 180;

  Map<String, dynamic> toJson() => {'lat': lat, 'lon': lon};

  /// Returns null for anything that is not a usable coordinate pair, so a
  /// corrupt stored location degrades to "ask again" rather than throwing.
  static GeoPoint? fromJson(Map<String, dynamic> json) {
    final lat = json['lat'];
    final lon = json['lon'];
    if (lat is! num || lon is! num) return null;
    final point = GeoPoint(lat.toDouble(), lon.toDouble());
    return point.isValid ? point : null;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GeoPoint && lat == other.lat && lon == other.lon;

  @override
  int get hashCode => Object.hash(lat, lon);

  @override
  String toString() =>
      'GeoPoint(${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)})';
}

/// Mean earth radius in km (IUGG), the value the haversine formula is
/// conventionally quoted with.
const double earthRadiusKm = 6371.0088;

double _radians(double degrees) => degrees * math.pi / 180.0;

/// Great-circle distance between [a] and [b] in kilometres.
///
/// Haversine rather than Vincenty: the error against the ellipsoid is a few
/// tenths of a percent, and every consumer of this number is either sorting by
/// it or comparing it to a radius the user picked from a menu of round numbers.
/// Nobody's 40 km filter cares about 80 m.
double haversineKm(GeoPoint a, GeoPoint b) {
  final dLat = _radians(b.lat - a.lat);
  final dLon = _radians(b.lon - a.lon);
  final lat1 = _radians(a.lat);
  final lat2 = _radians(b.lat);

  final sinLat = math.sin(dLat / 2);
  final sinLon = math.sin(dLon / 2);
  final h = sinLat * sinLat + math.cos(lat1) * math.cos(lat2) * sinLon * sinLon;
  // clamp: floating point can push h a hair above 1 for antipodal points,
  // and asin(1.0000000000000002) is NaN.
  return 2 * earthRadiusKm * math.asin(math.sqrt(h).clamp(0.0, 1.0));
}

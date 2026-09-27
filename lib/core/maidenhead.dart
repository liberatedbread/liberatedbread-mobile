// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Maidenhead grid locators, both directions, offline.
//
// Amateur operators say where they are in grid squares far more readily than
// in decimal degrees — "FN31pr" is on QSL cards, in club rosters and on every
// repeater directory listing. Supporting it in the manual-location dialog
// means someone with no GPS fix can still type the thing they already know.

import 'geo.dart';

const _upper = 'ABCDEFGHIJKLMNOPQR';
const _lower = 'abcdefghijklmnopqrstuvwx';

/// Convert [locator] to the point at the CENTRE of the square it names.
///
/// The centre, not the south-west corner, because the caller is asking "where
/// am I" and a corner is systematically wrong by half a square — up to 55 km
/// of latitude for a 4-character locator, which is the whole radius someone
/// might have been searching within.
///
/// Accepts 2, 4, 6 or 8 characters, case-insensitively. Returns null for
/// anything else, including an odd length or an out-of-alphabet character.
GeoPoint? maidenheadToPoint(String locator) {
  final grid = locator.trim();
  if (grid.length < 2 || grid.length > 8 || grid.length.isOdd) return null;

  final field = grid.substring(0, 2).toUpperCase();
  final lonField = _upper.indexOf(field[0]);
  final latField = _upper.indexOf(field[1]);
  if (lonField < 0 || latField < 0) return null;

  // Width of the square accumulated so far, in degrees. Longitude squares are
  // twice as wide as latitude squares are tall at every level, which is what
  // keeps them roughly square on the ground at mid latitudes.
  var lonSize = 20.0;
  var latSize = 10.0;
  var lon = lonField * lonSize - 180.0;
  var lat = latField * latSize - 90.0;

  if (grid.length >= 4) {
    final lonSquare = int.tryParse(grid[2]);
    final latSquare = int.tryParse(grid[3]);
    if (lonSquare == null || latSquare == null) return null;
    lonSize /= 10;
    latSize /= 10;
    lon += lonSquare * lonSize;
    lat += latSquare * latSize;
  }

  if (grid.length >= 6) {
    final sub = grid.substring(4, 6).toLowerCase();
    final lonSub = _lower.indexOf(sub[0]);
    final latSub = _lower.indexOf(sub[1]);
    if (lonSub < 0 || latSub < 0) return null;
    lonSize /= 24;
    latSize /= 24;
    lon += lonSub * lonSize;
    lat += latSub * latSize;
  }

  if (grid.length == 8) {
    final lonExt = int.tryParse(grid[6]);
    final latExt = int.tryParse(grid[7]);
    if (lonExt == null || latExt == null) return null;
    lonSize /= 10;
    latSize /= 10;
    lon += lonExt * lonSize;
    lat += latExt * latSize;
  }

  final point = GeoPoint(lat + latSize / 2, lon + lonSize / 2);
  return point.isValid ? point : null;
}

/// The [precision]-character locator containing [point].
///
/// [precision] must be 2, 4, 6 or 8; 6 is what people quote. Returns null for
/// an invalid point or precision rather than emitting a locator that decodes
/// to somewhere else.
String? pointToMaidenhead(GeoPoint point, {int precision = 6}) {
  if (!point.isValid) return null;
  if (precision != 2 && precision != 4 && precision != 6 && precision != 8) {
    return null;
  }

  // Shift into the all-positive space the encoding is defined over. The clamp
  // catches exactly one input: longitude 180.0, which lands on field index 18
  // and would index past 'R'.
  var lon = (point.lon + 180.0).clamp(0.0, 359.999999);
  var lat = (point.lat + 90.0).clamp(0.0, 179.999999);

  final out = StringBuffer();
  final lonField = lon ~/ 20;
  final latField = lat ~/ 10;
  out.write(_upper[lonField]);
  out.write(_upper[latField]);
  if (precision == 2) return out.toString();

  lon -= lonField * 20;
  lat -= latField * 10;
  final lonSquare = lon ~/ 2;
  final latSquare = lat ~/ 1;
  out.write(lonSquare);
  out.write(latSquare);
  if (precision == 4) return out.toString();

  lon -= lonSquare * 2;
  lat -= latSquare * 1;
  final lonSub = (lon / (2 / 24)).floor().clamp(0, 23);
  final latSub = (lat / (1 / 24)).floor().clamp(0, 23);
  out.write(_lower[lonSub]);
  out.write(_lower[latSub]);
  if (precision == 6) return out.toString();

  lon -= lonSub * (2 / 24);
  lat -= latSub * (1 / 24);
  out.write((lon / (2 / 240)).floor().clamp(0, 9));
  out.write((lat / (1 / 240)).floor().clamp(0, 9));
  return out.toString();
}

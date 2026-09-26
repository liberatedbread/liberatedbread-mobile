// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Turning "here, plus a radius" into the states worth asking about.

import 'dart:math' as math;

import '../core/geo.dart';
import 'radio_bundled_data.dart';

/// Kilometres per degree of latitude. Constant everywhere, unlike longitude.
const double _kmPerDegreeLat = 111.2;

/// Which states could hold something within [radiusKm] of [point].
///
/// Both online repeater sources are state-scoped — neither offers a proximity
/// query — so a search near a state line has to ask more than one. The answer
/// is deliberately generous: an extra state costs one HTTP request whose
/// listings the distance filter then drops, while a missing one loses exactly
/// the repeaters a border-dweller is closest to.
///
/// Returns codes in a stable order (the bundled data's, which is alphabetical)
/// so a request key built from them is comparable.
Future<List<String>> statesNear(
  RadioBundledData data,
  GeoPoint point, {
  required double radiusKm,
}) async {
  final bounds = await data.stateBounds();
  if (bounds.isEmpty || !point.isValid) return const [];

  final latPad = radiusKm / _kmPerDegreeLat;
  // A degree of longitude shrinks with the cosine of latitude, so the same
  // radius spans more longitude the further north you are. The floor stops a
  // division by ~zero at the poles turning the pad into infinity — at 89.5
  // degrees the whole hemisphere is within a few hundred km anyway.
  final cosLat = math.cos(point.lat * math.pi / 180.0).abs();
  final lonPad = radiusKm / (_kmPerDegreeLat * math.max(cosLat, 0.01));

  final minLat = point.lat - latPad;
  final maxLat = point.lat + latPad;
  final minLon = point.lon - lonPad;
  final maxLon = point.lon + lonPad;

  final codes = <String>[];
  for (final state in bounds) {
    if (state.overlaps(
      minLat: minLat,
      maxLat: maxLat,
      minLon: minLon,
      maxLon: maxLon,
    )) {
      codes.add(state.code);
    }
    // A search box that runs past +/-180 is not wrapped here: the only US
    // state it could reach across the line is Alaska, whose western boxes are
    // already listed separately, so the wrap would add nothing but a way to
    // get the arithmetic wrong.
  }
  return codes;
}

/// The state [point] is most likely in, or null if it is outside the bundled
/// extents entirely (which is most of the world).
///
/// Coarse: a bounding box is not a border, and near a corner two states'
/// boxes overlap. Used only to label a location for the user, never to decide
/// what to fetch.
Future<StateBounds?> stateContaining(
  RadioBundledData data,
  GeoPoint point,
) async {
  final bounds = await data.stateBounds();
  for (final state in bounds) {
    if (state.contains(point)) return state;
  }
  return null;
}

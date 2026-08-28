// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Reading the data that ships inside the app.

import 'dart:convert';

import 'package:flutter/services.dart';

import '../core/geo.dart';
import '../core/log.dart';

/// One state's coarse extent, as one or more boxes.
///
/// More than one box only for states that cross the antimeridian — Alaska. A
/// single box for Alaska spans nearly every longitude, which would make it a
/// candidate from anywhere on earth.
class StateBounds {
  /// Postal abbreviation — what myGMRS's `state` parameter takes.
  final String code;

  /// FIPS numeric code — what RepeaterBook's `state_id` parameter takes.
  ///
  /// Both are carried so neither client needs a lookup table of its own that
  /// could drift from the other's.
  final String fips;

  final String name;
  final List<({double minLat, double minLon, double maxLat, double maxLon})>
      boxes;

  const StateBounds({
    required this.code,
    required this.name,
    required this.boxes,
    this.fips = '',
  });

  /// Whether any part of this state falls inside the given latitude/longitude
  /// window. The window is the caller's search box, already padded for the
  /// radius, so this is a cheap rectangle overlap and not a distance test.
  bool overlaps({
    required double minLat,
    required double maxLat,
    required double minLon,
    required double maxLon,
  }) {
    for (final box in boxes) {
      final latOverlap = box.minLat <= maxLat && box.maxLat >= minLat;
      final lonOverlap = box.minLon <= maxLon && box.maxLon >= minLon;
      if (latOverlap && lonOverlap) return true;
    }
    return false;
  }

  /// Whether [point] is inside this state's box. Coarse by construction — a
  /// box is not a border — and used only to name the state a user is probably
  /// standing in.
  bool contains(GeoPoint point) => overlaps(
        minLat: point.lat,
        maxLat: point.lat,
        minLon: point.lon,
        maxLon: point.lon,
      );

  static StateBounds? fromJson(Map<String, dynamic> json) {
    final code = json['code'];
    final name = json['name'];
    final raw = json['boxes'];
    if (code is! String || code.isEmpty || raw is! List) return null;

    final boxes =
        <({double minLat, double minLon, double maxLat, double maxLon})>[];
    for (final entry in raw) {
      if (entry is! Map<String, dynamic>) continue;
      final minLat = entry['minLat'];
      final maxLat = entry['maxLat'];
      final minLon = entry['minLon'];
      final maxLon = entry['maxLon'];
      if (minLat is! num || maxLat is! num) continue;
      if (minLon is! num || maxLon is! num) continue;
      boxes.add((
        minLat: minLat.toDouble(),
        minLon: minLon.toDouble(),
        maxLat: maxLat.toDouble(),
        maxLon: maxLon.toDouble(),
      ));
    }
    if (boxes.isEmpty) return null;
    final fips = json['fips'];
    return StateBounds(
      code: code,
      fips: fips is String ? fips : '',
      name: name is String && name.isNotEmpty ? name : code,
      boxes: boxes,
    );
  }
}

/// Loads the app's bundled radio data.
///
/// Every load is defensive and every failure is empty-plus-a-log rather than
/// a throw: a corrupt or missing asset must cost the state-scoped online
/// sources, not the whole Radio tab. The presets and the plan editor do not
/// depend on any of this.
class RadioBundledData {
  static const stateBoundsAsset = 'assets/radio/us_state_bounds.json';

  final AssetBundle _bundle;

  RadioBundledData({AssetBundle? bundle}) : _bundle = bundle ?? rootBundle;

  List<StateBounds>? _cachedStates;

  /// The state extents, parsed once per app run.
  Future<List<StateBounds>> stateBounds() async {
    final cached = _cachedStates;
    if (cached != null) return cached;

    List<StateBounds> parsed;
    try {
      final raw = await _bundle.loadString(stateBoundsAsset);
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('state bounds is not a JSON object');
      }
      final states = decoded['states'];
      if (states is! List) {
        throw const FormatException('state bounds has no states list');
      }
      parsed = [
        for (final entry in states)
          if (entry is Map<String, dynamic>)
            if (StateBounds.fromJson(entry) case final StateBounds bounds)
              bounds,
      ];
    } catch (error) {
      Log.radio.warning('bundled state bounds unreadable', error: error);
      parsed = const [];
    }
    _cachedStates = parsed;
    return parsed;
  }
}

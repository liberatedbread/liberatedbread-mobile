// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/geo.dart';
import '../services/geolocator_location_service.dart';
import '../services/location_service.dart';
import 'json_setting.dart';
import 'spec_pack_provider.dart';

/// Provides the location backend. Tests override this with a fake; the Linux
/// desktop gets the real one and it reports itself unavailable.
final locationServiceProvider = Provider<LocationService>(
  (ref) => const GeolocatorLocationService(),
);

/// A position the user has searched from, with a label worth showing again.
///
/// Remembered so that the second search does not start from nothing. This is
/// the difference between "tap GPS, wait for a fix" every time and "you last
/// searched near Seattle — again?", which matters most in the case the GPS
/// cannot help with anyway: someone planning a trip from their desk.
class SavedLocation {
  final GeoPoint point;

  /// How to name it: a state from the bundled extents, a grid square, or the
  /// coordinates themselves. Never empty.
  final String label;

  const SavedLocation({required this.point, required this.label});

  Map<String, dynamic> toJson() => {
    'lat': point.lat,
    'lon': point.lon,
    'label': label,
  };

  static SavedLocation? fromJson(Map<String, dynamic> json) {
    final point = GeoPoint.fromJson(json);
    if (point == null) return null;
    final label = json['label'];
    // The invented label is at the kept precision: build() rounds only the
    // point and writes this label back, so the old 4-decimal (~11 m) label
    // kept on disk the position the rounding exists to drop.
    const places = LastLocationNotifier.coarseDecimals;
    return SavedLocation(
      point: point,
      label: label is String && label.trim().isNotEmpty
          ? label.trim()
          : '${point.lat.toStringAsFixed(places)}, '
                '${point.lon.toStringAsFixed(places)}',
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SavedLocation && point == other.point && label == other.label;

  @override
  int get hashCode => Object.hash(point, label);
}

/// The last place the user searched from, or null if they never have.
final lastLocationProvider =
    AsyncNotifierProvider<LastLocationNotifier, SavedLocation?>(
      LastLocationNotifier.new,
    );

class LastLocationNotifier extends AsyncNotifier<SavedLocation?> {
  static const key = 'radio_last_location_v1';

  /// Decimal places a remembered position keeps: about 1 km of latitude.
  ///
  /// This record outlives the search it came from, sits in plain
  /// preferences and rides device backups. It used to hold the fix to full
  /// double precision, so every "Use my location" left the user's exact
  /// whereabouts (their home, usually) on disk indefinitely, although the
  /// fix is only asked for at ~100 m accuracy and the only reader is a
  /// repeater search whose radius is tens of kilometres. A kilometre is
  /// still "near here" for that search and is no longer an address.
  static const coarseDecimals = 2;

  /// [location] with its point rounded to [coarseDecimals].
  static SavedLocation coarsen(SavedLocation location) {
    final scale = math.pow(10, coarseDecimals).toDouble();
    double round(double v) => (v * scale).roundToDouble() / scale;

    final point = location.point;
    final coarse = GeoPoint(round(point.lat), round(point.lon));
    return coarse == point
        ? location
        : SavedLocation(point: coarse, label: location.label);
  }

  @override
  Future<SavedLocation?> build() async {
    final stored = await readJsonSetting(ref, key);
    final location = stored == null ? null : SavedLocation.fromJson(stored);
    if (location == null) return null;
    final coarse = coarsen(location);
    if (coarse != location) {
      // Written by a build that stored the exact fix: rewrite it rounded
      // rather than keep the precise copy on disk until the next search.
      await writeJsonSetting(ref, key, coarse.toJson());
    }
    return coarse;
  }

  /// Record where a search ran from, rounded to [coarseDecimals].
  ///
  /// The label is kept as given: the caller names the place from the exact
  /// point (a state, or a six-character grid square, both coarser than the
  /// rounding), so it reads the same either way.
  Future<void> remember(SavedLocation location) async {
    final coarse = coarsen(location);
    await writeJsonSetting(ref, key, coarse.toJson());
    state = AsyncData(coarse);
  }

  /// Drop the remembered position, from disk and from memory.
  ///
  /// Without this, nothing ever removed it: "Clear cached listings" clears
  /// the directory listings and left the position in place.
  Future<void> forget() async {
    final store = await ref.read(prefsSettingsStoreProvider.future);
    await store.delete(key);
    state = const AsyncData(null);
  }
}

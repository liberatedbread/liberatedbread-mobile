// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/geo.dart';
import '../services/geolocator_location_service.dart';
import '../services/location_service.dart';
import 'json_setting.dart';

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
    return SavedLocation(
      point: point,
      label: label is String && label.trim().isNotEmpty
          ? label.trim()
          : '${point.lat.toStringAsFixed(4)}, '
                '${point.lon.toStringAsFixed(4)}',
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

  @override
  Future<SavedLocation?> build() async {
    final stored = await readJsonSetting(ref, key);
    return stored == null ? null : SavedLocation.fromJson(stored);
  }

  /// Record where a search ran from.
  Future<void> remember(SavedLocation location) async {
    await writeJsonSetting(ref, key, location.toJson());
    state = AsyncData(location);
  }
}

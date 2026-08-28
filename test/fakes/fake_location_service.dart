// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/services/location_service.dart';

/// A [LocationService] that answers whatever a test told it to.
///
/// Covers the three shapes the UI has to handle: a fix, a refusal, and a
/// platform with no backend — which is not a hypothetical, it is every Linux
/// desktop run.
class FakeLocationService implements LocationService {
  /// Answered by [currentPosition] when no error is set.
  GeoPoint position;

  /// Thrown by [currentPosition] instead of answering.
  Object? error;

  /// Answered by [gpsAvailable].
  bool available;

  /// How many times [currentPosition] has been asked, so a test can prove the
  /// screen does not poll.
  int positionCalls = 0;

  int availabilityCalls = 0;

  FakeLocationService({
    this.position = const GeoPoint(47.6062, -122.3321),
    this.error,
    this.available = true,
  });

  /// A service on a platform with no location backend, which is what the
  /// Linux desktop build gets.
  factory FakeLocationService.unavailable() => FakeLocationService(
        available: false,
        error: const LocationUnavailableException(),
      );

  factory FakeLocationService.denied() => FakeLocationService(
        error: const LocationPermissionDeniedException(),
      );

  @override
  Future<bool> gpsAvailable() async {
    availabilityCalls++;
    return available;
  }

  @override
  Future<GeoPoint> currentPosition() async {
    positionCalls++;
    final failure = error;
    if (failure != null) throw failure;
    return position;
  }
}

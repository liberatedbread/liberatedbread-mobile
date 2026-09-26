// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The real location backend, and the places it has none.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';

import '../core/geo.dart';
import '../core/log.dart';
import 'location_service.dart';

/// [LocationService] over the geolocator plugin.
///
/// Every platform call is wrapped, because the interesting failures here are
/// not exceptional: permission refused is a normal answer, and on the Linux
/// desktop there is no plugin implementation at all, so the very first call
/// throws [MissingPluginException]. Both become typed results the UI can
/// route to a recovery, rather than a red screen.
class GeolocatorLocationService implements LocationService {
  /// How long to wait for a fix before giving up and offering manual entry.
  ///
  /// A cold GPS start outdoors is 30-60 seconds, but this app does not need a
  /// GPS-grade fix: it is picking repeaters within tens of kilometres, and a
  /// network-derived position is more than good enough. So the accuracy asked
  /// for is medium and the wait is short — a fast approximate answer beats an
  /// exact one nobody stayed on the screen for.
  static const Duration fixTimeout = Duration(seconds: 20);

  static const LocationSettings _settings = LocationSettings(
    accuracy: LocationAccuracy.medium,
    timeLimit: fixTimeout,
  );

  const GeolocatorLocationService();

  @override
  Future<bool> gpsAvailable() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return false;
      final permission = await Geolocator.checkPermission();
      // deniedForever is the only permission state that cannot become a fix:
      // plain `denied` still gets a prompt when we ask.
      return permission != LocationPermission.deniedForever;
    } on MissingPluginException {
      // No backend on this platform. Not an error — the Linux desktop build
      // is expected to land here every time.
      return false;
    } catch (error) {
      Log.radio.debug('location availability check failed', error: error);
      return false;
    }
  }

  @override
  Future<GeoPoint> currentPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw const LocationServicesDisabledException();
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      switch (permission) {
        case LocationPermission.denied:
        case LocationPermission.unableToDetermine:
          throw const LocationPermissionDeniedException();
        case LocationPermission.deniedForever:
          throw const LocationPermissionPermanentlyDeniedException();
        case LocationPermission.whileInUse:
        case LocationPermission.always:
          break;
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: _settings,
      );
      final point = GeoPoint(position.latitude, position.longitude);
      if (!point.isValid) {
        // A backend that answers with a non-position is broken in a way the
        // user can still route around, so it reads as "no fix" rather than
        // propagating a coordinate the distance filter would quietly misuse.
        throw const LocationTimeoutException();
      }
      return point;
    } on MissingPluginException {
      throw const LocationUnavailableException();
    } on TimeoutException {
      throw const LocationTimeoutException();
    } on LocationServiceDisabledException {
      // geolocator's own exception type, whose name differs from this app's
      // by one letter. Mapped rather than propagated: the plugin's message is
      // written for a developer.
      throw const LocationServicesDisabledException();
    } on PermissionDefinitionsNotFoundException {
      // The platform manifest is missing the usage description. That is a
      // build defect, not something the user did, but the recovery offered is
      // the same one that works regardless.
      Log.radio.warning(
        'location usage description missing from the '
        'platform manifest',
      );
      throw const LocationUnavailableException();
    }
  }
}

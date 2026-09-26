// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Where the user is, or an explanation of why the app cannot say.

import '../core/error_text.dart';
import '../core/geo.dart';

/// Raised when location permission was refused.
///
/// A distinct type, not a bare failure, for the same reason
/// [BlePermissionDeniedException] is one: the recovery is specific (grant the
/// permission, or type coordinates instead) and a generic "could not get your
/// location" sends the user looking for a GPS problem they do not have.
class LocationPermissionDeniedException implements UserFacingException {
  @override
  final String message;
  const LocationPermissionDeniedException([
    this.message =
        'Location permission denied. Grant location access to '
        'find repeaters near you — or enter your position by hand instead.',
  ]);

  @override
  String toString() => message;
}

/// Raised when the permission was refused permanently, so asking again does
/// nothing and only the system settings can change it.
class LocationPermissionPermanentlyDeniedException
    implements UserFacingException {
  @override
  final String message;
  const LocationPermissionPermanentlyDeniedException([
    this.message =
        'Location access is turned off for this app. Turn it on '
        'in system settings, or enter your position by hand instead.',
  ]);

  @override
  String toString() => message;
}

/// Raised when location services are switched off device-wide, as opposed to
/// this app being refused.
class LocationServicesDisabledException implements UserFacingException {
  @override
  final String message;
  const LocationServicesDisabledException([
    this.message =
        'Location services are turned off. Turn them on, or '
        'enter your position by hand instead.',
  ]);

  @override
  String toString() => message;
}

/// Raised where the platform has no location backend at all.
///
/// The Linux desktop build is the case that matters: geolocator ships no
/// Linux implementation, so every call throws `MissingPluginException`. That
/// is not an error the user caused and not one they can fix, so it gets a
/// message that says what to do rather than what broke.
class LocationUnavailableException implements UserFacingException {
  @override
  final String message;
  const LocationUnavailableException([
    this.message =
        'This device cannot report its position. Enter your '
        'location by hand — coordinates or a grid square both work.',
  ]);

  @override
  String toString() => message;
}

/// Raised when a fix did not arrive in time.
class LocationTimeoutException implements UserFacingException {
  @override
  final String message;
  const LocationTimeoutException([
    this.message =
        'Could not get a position fix. Move somewhere with a '
        'clearer view of the sky, or enter your location by hand.',
  ]);

  @override
  String toString() => message;
}

/// The app's view of the device's position.
///
/// An interface rather than a direct geolocator call so that widget tests,
/// which have no platform channels, inject an answer — and so the Linux
/// desktop's "there is no backend" case is a value this returns rather than a
/// plugin exception leaking into a screen.
abstract class LocationService {
  /// The device's current position, or one of this file's exceptions.
  Future<GeoPoint> currentPosition();
}

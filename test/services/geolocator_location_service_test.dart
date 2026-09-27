// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The no-backend path, which a unit test gets for free.
//
// There is no geolocator platform implementation under `flutter test` -- the
// method channel has no handler -- which is exactly the situation the Linux
// desktop build is in permanently. So this suite runs the real service and
// asserts it degrades the way the Linux build must: it turns the platform's
// exception into an app one that tells the user to type coordinates
// instead.
//
// The branches a phone reaches -- services off, a refusal, a refusal for
// good, a slow fix -- run against a scripted GeolocatorPlatform instead. They
// decide which recovery the user is offered (open Settings, or type
// coordinates), and nothing else checked the real service picks the right
// one: the screen tests drive a fake LocationService.
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:liberated_bread_mobile/core/geo.dart';
import 'package:liberated_bread_mobile/services/geolocator_location_service.dart';
import 'package:liberated_bread_mobile/services/location_service.dart';

/// A geolocator backend that answers from a script and counts the calls.
///
/// Extends [GeolocatorPlatform] directly (as the real Apple and Android
/// implementations do), so the platform-interface token check passes.
class _FakeGeolocator extends GeolocatorPlatform {
  _FakeGeolocator({
    this.serviceEnabled = true,
    this.checkResult = LocationPermission.whileInUse,
    this.requestResult = LocationPermission.denied,
    this.requestError,
    this.position,
    this.positionError,
  });

  final bool serviceEnabled;
  final LocationPermission checkResult;
  final LocationPermission requestResult;
  final Object? requestError;
  final Position? position;
  final Object? positionError;

  int checkCalls = 0;
  int requestCalls = 0;

  @override
  Future<bool> isLocationServiceEnabled() async => serviceEnabled;

  @override
  Future<LocationPermission> checkPermission() async {
    checkCalls++;
    return checkResult;
  }

  @override
  Future<LocationPermission> requestPermission() async {
    requestCalls++;
    if (requestError != null) throw requestError!;
    return requestResult;
  }

  @override
  Future<Position> getCurrentPosition({
    LocationSettings? locationSettings,
  }) async {
    if (positionError != null) throw positionError!;
    return position ?? _at(41.7658, -72.6734);
  }
}

Position _at(double latitude, double longitude) => Position(
  latitude: latitude,
  longitude: longitude,
  timestamp: DateTime.utc(2026, 9, 27),
  accuracy: 50,
  altitude: 0,
  altitudeAccuracy: 0,
  heading: 0,
  headingAccuracy: 0,
  speed: 0,
  speedAccuracy: 0,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const service = GeolocatorLocationService();

  test(
    'asking for a position raises an app exception, not a plugin one',
    () async {
      await expectLater(
        service.currentPosition(),
        throwsA(isA<LocationUnavailableException>()),
      );
    },
  );

  test('the timeout is short enough that a person waits for it', () {
    // A cold GPS fix can take a minute; this app is choosing repeaters within
    // tens of kilometres and does not need one. The point of the constant is
    // that manual entry is offered quickly.
    expect(
      GeolocatorLocationService.fixTimeout.inSeconds,
      lessThanOrEqualTo(30),
    );
  });

  group('on a phone', () {
    late GeolocatorPlatform original;

    setUp(() => original = GeolocatorPlatform.instance);
    tearDown(() => GeolocatorPlatform.instance = original);

    _FakeGeolocator install(_FakeGeolocator fake) =>
        GeolocatorPlatform.instance = fake;

    test('services off says so, before asking for permission', () async {
      final fake = install(_FakeGeolocator(serviceEnabled: false));
      await expectLater(
        service.currentPosition(),
        throwsA(isA<LocationServicesDisabledException>()),
      );
      expect(fake.checkCalls, 0);
      expect(fake.requestCalls, 0);
    });

    test(
      'a first-run "denied" asks once, and a refusal is a refusal',
      () async {
        // iOS reports "not determined" as denied, so the request is what raises
        // the system prompt on a fresh install. Drop it and every new user is
        // told they refused without ever being asked.
        final fake = install(
          _FakeGeolocator(
            checkResult: LocationPermission.denied,
            requestResult: LocationPermission.denied,
          ),
        );
        await expectLater(
          service.currentPosition(),
          throwsA(isA<LocationPermissionDeniedException>()),
        );
        expect(fake.requestCalls, 1);
      },
    );

    test('a prompt accepted goes on to the fix', () async {
      final fake = install(
        _FakeGeolocator(
          checkResult: LocationPermission.denied,
          requestResult: LocationPermission.whileInUse,
        ),
      );
      expect(
        await service.currentPosition(),
        const GeoPoint(41.7658, -72.6734),
      );
      expect(fake.requestCalls, 1);
    });

    test('denied for good points at Settings, without re-asking', () async {
      // The OS will not show the prompt again; asking would be a no-op and
      // the only recovery is the Settings app.
      final fake = install(
        _FakeGeolocator(checkResult: LocationPermission.deniedForever),
      );
      await expectLater(
        service.currentPosition(),
        throwsA(isA<LocationPermissionPermanentlyDeniedException>()),
      );
      expect(fake.requestCalls, 0);
    });

    test('a prompt answered "never" is denied for good', () async {
      install(
        _FakeGeolocator(
          checkResult: LocationPermission.denied,
          requestResult: LocationPermission.deniedForever,
        ),
      );
      await expectLater(
        service.currentPosition(),
        throwsA(isA<LocationPermissionPermanentlyDeniedException>()),
      );
    });

    test('an undeterminable permission reads as a refusal', () async {
      install(
        _FakeGeolocator(checkResult: LocationPermission.unableToDetermine),
      );
      await expectLater(
        service.currentPosition(),
        throwsA(isA<LocationPermissionDeniedException>()),
      );
    });

    test('a slow fix is a timeout', () async {
      install(_FakeGeolocator(positionError: TimeoutException('no fix')));
      await expectLater(
        service.currentPosition(),
        throwsA(isA<LocationTimeoutException>()),
      );
    });

    test('a non-position is a timeout, not a coordinate', () async {
      install(_FakeGeolocator(position: _at(double.nan, -72.6734)));
      await expectLater(
        service.currentPosition(),
        throwsA(isA<LocationTimeoutException>()),
      );
    });

    test('services switched off mid-fix map to the app exception', () async {
      install(
        _FakeGeolocator(
          positionError: const LocationServiceDisabledException(),
        ),
      );
      await expectLater(
        service.currentPosition(),
        throwsA(isA<LocationServicesDisabledException>()),
      );
    });

    test('a missing usage description is unavailable', () async {
      install(
        _FakeGeolocator(
          checkResult: LocationPermission.denied,
          requestError: const PermissionDefinitionsNotFoundException('none'),
        ),
      );
      await expectLater(
        service.currentPosition(),
        throwsA(isA<LocationUnavailableException>()),
      );
    });
  });
}

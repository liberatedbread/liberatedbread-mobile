// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The no-backend path, which a unit test gets for free.
//
// There is no geolocator platform implementation under `flutter test` -- the
// method channel has no handler -- which is exactly the situation the Linux
// desktop build is in permanently. So this suite runs the real service and
// asserts it degrades the way the Linux build must: reports itself
// unavailable rather than throwing, and turns the platform's exception into
// an app one that tells the user to type coordinates instead.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';
import 'package:liberated_bread_mobile/services/geolocator_location_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const service = GeolocatorLocationService();

  test('reports itself unavailable where there is no backend', () async {
    expect(await service.gpsAvailable(), isFalse);
  });

  test('gpsAvailable never throws, whatever the platform does', () async {
    // The UI calls this to decide whether to offer the GPS button at all, so
    // it has to be a question with an answer rather than one that can fail.
    for (var i = 0; i < 3; i++) {
      expect(await service.gpsAvailable(), isA<bool>());
    }
  });

  test('asking for a position raises an app exception, not a plugin one',
      () async {
    await expectLater(
      service.currentPosition(),
      throwsA(isA<UserFacingException>()),
    );
  });

  test('the timeout is short enough that a person waits for it', () {
    // A cold GPS fix can take a minute; this app is choosing repeaters within
    // tens of kilometres and does not need one. The point of the constant is
    // that manual entry is offered quickly.
    expect(
        GeolocatorLocationService.fixTimeout.inSeconds, lessThanOrEqualTo(30));
  });
}

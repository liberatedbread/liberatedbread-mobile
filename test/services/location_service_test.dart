// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';
import 'package:liberated_bread_mobile/services/location_service.dart';

void main() {
  // Each of these is text a user reads on a screen when the GPS button did
  // not work, so each is checked for saying what to do next rather than what
  // broke. The manual-entry escape hatch is the one every message must name:
  // it is the recovery that works no matter which of them fired.
  const failures = <UserFacingException>[
    LocationPermissionDeniedException(),
    LocationPermissionPermanentlyDeniedException(),
    LocationServicesDisabledException(),
    LocationUnavailableException(),
    LocationTimeoutException(),
  ];

  test('every location failure is user-facing', () {
    for (final failure in failures) {
      expect(failure, isA<UserFacingException>());
      expect(failure.message, isNotEmpty);
      expect(failure.toString(), failure.message);
      // friendlyErrorText passes UserFacingException messages through
      // untouched; anything else would reach the user as fallback text.
      expect(friendlyErrorText(failure, fallback: 'fallback'), failure.message);
    }
  });

  test('every location failure offers the manual way round', () {
    for (final failure in failures) {
      expect(
        failure.message.toLowerCase(),
        contains('by hand'),
        reason: '${failure.runtimeType} leaves the user with no next step',
      );
    }
  });

  test('a permanent refusal points at settings, not at another prompt', () {
    // Asking again does nothing once the answer is deniedForever, so the
    // message must not imply that it would.
    expect(
      const LocationPermissionPermanentlyDeniedException().message
          .toLowerCase(),
      contains('settings'),
    );
  });

  test('messages can be overridden for a caller with more context', () {
    expect(const LocationPermissionDeniedException('custom').message, 'custom');
  });
}

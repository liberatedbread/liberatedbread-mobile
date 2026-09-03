// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The BLE failures whose user-facing text differs by platform.
//
// Both messages here were written for Android and are actively misleading on
// iOS: they tell the user to do something that cannot work there. Neither is
// caught by a type check or an analyzer rule, because the code is correct and
// only the words are wrong — so they get pinned.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/error_text.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';

void main() {
  group('BlePairingRequiredException wording follows the platform', () {
    test('Apple platforms are pointed at the system alert, not at Settings',
        () {
      final message =
          BlePairingRequiredException.forPlatform(isApple: true).message;
      expect(
        message,
        contains('Bluetooth Pairing Request'),
        reason: 'On iOS and macOS the prompt is an alert CoreBluetooth puts '
            'over the app. Naming it is what lets the user recognise what '
            'they just dismissed.',
      );
      expect(
        message,
        isNot(contains('settings')),
        reason: 'An unbonded BLE peripheral does not appear under Settings > '
            'Bluetooth on iOS, so sending the user there shows them nothing.',
      );
    });

    test('Android and BlueZ keep the settings wording', () {
      final message =
          BlePairingRequiredException.forPlatform(isApple: false).message;
      expect(message, contains('system Bluetooth'));
      expect(message, equals(const BlePairingRequiredException().message),
          reason: 'The non-Apple form must stay the default, so nothing that '
              'constructs the exception without a platform changes meaning.');
    });

    test('both forms still say what the user has to do', () {
      for (final isApple in [true, false]) {
        expect(
          BlePairingRequiredException.forPlatform(isApple: isApple).message,
          contains('try again'),
          reason: 'The retry is the actionable half; a refusal that only '
              'explains itself leaves the user stuck.',
        );
      }
    });
  });

  group('a forgotten Apple identifier is not a proximity problem', () {
    test('the message says to scan, not to move closer', () {
      final message = const BleDeviceUnheardException().message;
      expect(
        message,
        contains('scan'),
        reason: 'On Apple platforms a device id is a system-minted UUID, not '
            'a MAC. Once CoreBluetooth has dropped it, no amount of proximity '
            'reopens the link — only a fresh advertisement sighting does. '
            '"Move closer and retry" is advice that cannot succeed.',
      );
      expect(
        message,
        isNot(contains('closer')),
        reason: 'The generic connect-failure wording is what this type exists '
            'to replace.',
      );
    });

    test('it says what state the device has to be in', () {
      final message = const BleDeviceUnheardException().message;
      expect(message, contains('powered on'));
      expect(
        message,
        contains('range'),
        reason: 'A sighting needs the device advertising and within radio '
            'range; naming both is what makes the instruction actionable.',
      );
    });

    test('it is a UserFacingException, so the UI renders it verbatim', () {
      expect(const BleDeviceUnheardException(), isA<UserFacingException>(),
          reason: 'Otherwise friendlyErrorText falls back to a generic string '
              'and the specific guidance is lost on its way to the screen.');
    });
  });
}

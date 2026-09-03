// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The pairing refusal has to name the place the prompt actually appears.
//
// CoreBluetooth raises its own "Bluetooth Pairing Request" alert over the app,
// and an unbonded BLE peripheral never shows up under Settings > Bluetooth —
// so the Android/BlueZ wording ("accept it from your system Bluetooth
// settings") sends an iOS user to a screen that shows nothing, right after
// dismissing the alert that would have worked.
import 'package:flutter_test/flutter_test.dart';
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
}

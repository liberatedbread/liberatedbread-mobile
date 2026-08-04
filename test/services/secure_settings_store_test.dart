// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/secure_settings_store.dart';

void main() {
  // These options are load-bearing (see the comments on the constants):
  // changing the Android backend strands stored tokens, dropping resetOnError
  // re-introduces read crashes after key invalidation, and a stricter iOS
  // accessibility breaks background forwarding. Asserted via `params` because
  // flutter_secure_storage keeps the option fields private.
  test('Android keeps the EncryptedSharedPreferences backend + resetOnError',
      () {
    final params = SecureSettingsStore.androidOptions.params;
    expect(params['encryptedSharedPreferences'], 'true');
    expect(params['resetOnError'], 'true');
  });

  test('iOS keychain items are readable after the first post-boot unlock', () {
    final params = SecureSettingsStore.iosOptions.params;
    expect(
      params['accessibility'],
      KeychainAccessibility.first_unlock.name,
    );
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/log.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_key_store.dart';

import '../fakes/in_memory_settings_store.dart';

void main() {
  tearDown(() {
    Log.clearSecrets();
    Log.reset();
  });

  test('candidateKeys registers every key it hands out, cold start', () async {
    const key = '0123456789abcdef0123456789abcdef';
    final settings = InMemorySettingsStore();
    await RabbitAirKeyStore(settings).saveUserKey('ble-AA:BB', key);
    // A fresh process: nothing registered, a new store over the same
    // keychain. The BLE path reaches the key through candidateKeys alone,
    // which returned it unregistered — so a failed handshake that logged it
    // put the AES key in the buffer verbatim (fails on the old code).
    Log.clearSecrets();
    final keys = await RabbitAirKeyStore(
      settings,
    ).candidateKeys(preferredScope: 'ble-CC:DD');
    expect(keys, [key]);

    final records = Log.captureRecords();
    Log.ble.warning('handshake failed with key $key');
    expect(records.single.message, isNot(contains(key)));
  });
}

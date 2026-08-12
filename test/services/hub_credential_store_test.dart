// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The pairing store's contract: keyed by bridgeid (never IP), spelled
// case-insensitively because mDNS TXT says 001788FFFE61FCB0 and the TLS
// certificate CN says 001788fffe61fcb0 — a store that treated those as two
// bridges would strand the credential the moment the second spelling arrived.

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/hub_credential_store.dart';

import '../fakes/in_memory_settings_store.dart';

void main() {
  const bridgeId = '001788FFFE61FCB0';

  late InMemorySettingsStore settings;
  late HubCredentialStore store;

  setUp(() {
    settings = InMemorySettingsStore();
    store = HubCredentialStore(settings);
  });

  test('credentials round-trip, clientkey included', () async {
    expect(await store.credentials(bridgeId), isNull);

    await store.saveCredentials(
      bridgeId,
      const HubCredentials(username: 'nUP9k2sQ', clientKey: 'E39B1C9F'),
    );
    final loaded = await store.credentials(bridgeId);
    expect(loaded?.username, 'nUP9k2sQ');
    expect(loaded?.clientKey, 'E39B1C9F');
  });

  test('a credential saved under one case is found under the other', () async {
    await store.saveCredentials(
      bridgeId.toLowerCase(),
      const HubCredentials(username: 'user'),
    );
    expect((await store.credentials(bridgeId.toUpperCase()))?.username, 'user');
  });

  test('pin and scheme round-trip, pin normalized lowercase', () async {
    await store.saveCertPin(bridgeId, 'ABCDEF0123');
    expect(await store.certPin(bridgeId), 'abcdef0123');

    expect(await store.scheme(bridgeId), isNull);
    await store.saveScheme(bridgeId, 'https');
    expect(await store.scheme(bridgeId), 'https');
  });

  test('forget clears credential, clientkey, pin and scheme together',
      () async {
    await store.saveCredentials(
      bridgeId,
      const HubCredentials(username: 'user', clientKey: 'key'),
    );
    await store.saveCertPin(bridgeId, 'aa');
    await store.saveScheme(bridgeId, 'https');

    await store.forget(bridgeId);

    expect(await store.credentials(bridgeId), isNull);
    expect(await store.certPin(bridgeId), isNull);
    expect(await store.scheme(bridgeId), isNull);
  });

  test('two bridges do not share anything', () async {
    await store.saveCredentials(
      bridgeId,
      const HubCredentials(username: 'kitchen'),
    );
    await store.saveCredentials(
      'AABBCCFFFE112233',
      const HubCredentials(username: 'office'),
    );
    await store.forget(bridgeId);
    expect((await store.credentials('AABBCCFFFE112233'))?.username, 'office');
  });
}

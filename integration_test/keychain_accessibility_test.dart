// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The one test that talks to a REAL keychain.
//
// Everything else about SecureSettingsStore is covered with a fake, and a fake
// can never see a `kSecAttrAccessible` predicate — which is exactly where the
// bug was. flutter_secure_storage puts the accessibility class into the
// keychain QUERY, so a store configured with one class silently matches
// nothing written under another: SecItemCopyMatching returns nothing and
// SecItemDelete deletes nothing, and both look like success.
//
// That is what made changing the write class destructive. On any device that
// had run an earlier build, readAll() went blind (so per-device credentials
// and TLS pins enumerated empty, and "forget" left items behind) while
// single-key read() kept working, and the fresh-install wipe could not delete
// the very items it exists to delete.
//
// So this writes under the OLD class and asserts the shipping store can still
// see and clear it. Runs on the simulator; needs no hardware, no network and
// no real device, which is why it is part of the CI aggregate rather than the
// e2e walkthrough.
//
// NOTE it clears this app's keychain items on whatever simulator it runs
// against — that is the behaviour under test. Simulator state is disposable;
// do not point it at a device you care about.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/services/secure_settings_store.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const legacyKey = 'legacy_accessibility_probe';
  const legacyValue = 'written-by-an-older-build';

  /// A store configured the way builds before the accessibility change were.
  const legacy = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
    mOptions: MacOsOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  setUp(() async {
    await legacy.delete(key: legacyKey);
    await legacy.write(key: legacyKey, value: legacyValue);
  });

  tearDown(() async => legacy.delete(key: legacyKey));

  testWidgets('readAll sees an item written under the previous class', (
    tester,
  ) async {
    final all = await SecureSettingsStore().readAll();
    expect(
      all[legacyKey],
      legacyValue,
      reason:
          'readAll() must not be scoped to the current write class. '
          'DeviceCredentialStore.credentials(), the Rabbit Air candidate keys '
          'and "forget this device" all enumerate it, so a scoped readAll '
          'makes every credential stored by an earlier build vanish while '
          'single-key reads still work.',
    );
  });

  testWidgets('read sees it too', (tester) async {
    expect(await SecureSettingsStore().read(legacyKey), legacyValue);
  });

  testWidgets('the fresh-install wipe actually clears it', (tester) async {
    // Reaches the wipe through the same call main() makes, so the wiring is
    // under test as well as the query.
    final store = SecureSettingsStore();
    expect(await store.readAll(), contains(legacyKey));

    await store.wipeForTest();

    expect(
      await store.readAll(),
      isNot(contains(legacyKey)),
      reason:
          'A class-scoped deleteAll matches nothing written under the '
          'previous class, returns errSecItemNotFound, and the plugin maps '
          'that to success — so the wipe reported that it had cleared '
          'credentials that were all still there.',
    );
    expect(await store.read(legacyKey), isNull);
  });
}

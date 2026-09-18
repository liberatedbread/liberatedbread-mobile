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

import 'dart:io' show Platform;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/services/secure_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const legacyKey = 'legacy_accessibility_probe';
  const legacyValue = 'written-by-an-older-build';

  /// A store configured the way builds before the accessibility change were.
  ///
  /// iOS ONLY, and the suite is skipped elsewhere — see [notOnMacOs]. Writing
  /// the probe under `first_unlock` on macOS would invent a state macOS has
  /// never been in.
  const legacy = FlutterSecureStorage(
    iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock),
  );

  /// Why every test here is iOS-only.
  ///
  /// The whole suite rests on one premise: that the shipping store's queries
  /// are not scoped to an accessibility class, so an item written under the
  /// previous class is still visible and still deletable. On iOS that holds —
  /// baseQuery is `if (accessibility != nil) { … }`, and
  /// [SecureSettingsStore.iosOptionsAnyAccessibility] passes nil.
  ///
  /// On macOS it does not. flutter_secure_storage_macos builds its query with
  /// `kSecAttrAccessible: parseAccessibleAttr(accessibility:)`
  /// unconditionally, and nil maps to `whenUnlocked` — so there is no
  /// unconstrained query to test for, and a probe written under any other
  /// class is invisible to the store BY DESIGN rather than by the bug this
  /// suite guards. macOS gets the coherence property instead (writes and
  /// sweeps carry one pinned class, [SecureSettingsStore.macOsOptions]),
  /// which `test/services/secure_settings_store_test.dart` asserts on the
  /// host with no keychain at all.
  ///
  /// Nothing has ever written macOS items under another class either: this
  /// file set no `mOptions` until that constant existed, so every macOS build
  /// has used the plugin default. There is no legacy state here to migrate.
  final notOnMacOs = Platform.isMacOS
      ? 'iOS-only: macOS keychain queries always carry an accessibility '
            'class, so the unscoped-query premise this suite tests does not '
            'exist there.'
      : null;

  setUp(() async {
    if (notOnMacOs != null) return;
    await legacy.delete(key: legacyKey);
    await legacy.write(key: legacyKey, value: legacyValue);
  });

  tearDown(() async {
    if (notOnMacOs != null) return;
    await legacy.delete(key: legacyKey);
  });

  testWidgets(
    'readAll sees an item written under the previous class',
    (tester) async {
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
    },
    skip: notOnMacOs != null,
  );

  testWidgets('read sees it too', (tester) async {
    expect(await SecureSettingsStore().read(legacyKey), legacyValue);
  }, skip: notOnMacOs != null);

  testWidgets('the fresh-install wipe actually clears it', (tester) async {
    // Reaches the wipe through reconcileInstall — the same call main() makes
    // — so the wiring is under test as well as the query. There used to be a
    // `wipeForTest()` hook here instead; a method whose entire job is
    // "delete every secret this app holds, no questions asked" had no
    // business shipping in the release binary just so one test could take a
    // shortcut, and @visibleForTesting is an analyzer note, not a lock.
    //
    // Driving the real entry point needs the two preferences it reads to look
    // like a fresh install: no marker, and no accepted-terms witness.
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(SecureSettingsStore.freshInstallMarkerKey);
    await prefs.remove(AppConstants.termsAcceptedKey);

    final store = SecureSettingsStore();
    expect(await store.readAll(), contains(legacyKey));

    expect(
      await store.reconcileInstall(prefs),
      isTrue,
      reason: 'the wipe must report that it ran, not just that it decided',
    );

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
    // And the decision is recorded, so the next launch does not re-examine —
    // and re-wipe — a store the user has since filled again.
    expect(
      prefs.containsKey(SecureSettingsStore.freshInstallMarkerKey),
      isTrue,
    );
  }, skip: notOnMacOs != null);
}

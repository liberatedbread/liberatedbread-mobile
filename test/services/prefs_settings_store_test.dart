// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// PrefsSettingsStore had no test at all — 0 of 7 lines in coverage/lcov.info,
// one of only three files in the project at zero.
//
// It is a thin wrapper, which is exactly why the gap survived: there is
// visibly nothing to go wrong in it. What it is NOT, though, is
// interchangeable with the other SettingsStore implementation. It writes to
// plain platform preferences, while SecureSettingsStore writes to the
// keychain/keystore, and spec_pack_provider.dart picks this one for the
// spec-pack source URL specifically because that is not a secret. A future
// edit that swapped the delegate, or made write() a no-op on the empty string,
// or had delete() write "" instead of removing the key, would be caught by
// nothing.
//
// So: assert the contract the interface promises, plus the two behaviours a
// caller actually depends on — a missing key reads as null rather than
// throwing or returning "", and delete() genuinely removes.
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/prefs_settings_store.dart';
import 'package:liberated_bread_mobile/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  late SharedPreferences prefs;
  late PrefsSettingsStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    store = PrefsSettingsStore(prefs);
  });

  test('is a SettingsStore', () {
    // spec_pack_provider.dart returns it as the interface type; if it stopped
    // implementing it the failure would land there, not here.
    expect(store, isA<SettingsStore>());
  });

  test('a key that was never written reads as null', () async {
    // Not '' — callers branch on null to mean "unset" and would treat an empty
    // string as a configured-but-blank URL.
    expect(await store.read('spec_pack_source'), isNull);
  });

  test('write then read round-trips the value', () async {
    await store.write('spec_pack_source', 'https://example.com/packs.json');
    expect(
        await store.read('spec_pack_source'), 'https://example.com/packs.json');
  });

  test('write overwrites rather than appending', () async {
    await store.write('k', 'first');
    await store.write('k', 'second');
    expect(await store.read('k'), 'second');
  });

  test('delete removes the key, so it reads as null again', () async {
    await store.write('k', 'v');
    await store.delete('k');
    expect(await store.read('k'), isNull);
    // The distinction that matters: gone, not blanked. A store that wrote ''
    // would still satisfy a null-vs-empty-insensitive caller and quietly leave
    // the key behind in the platform preferences.
    expect(prefs.containsKey('k'), isFalse);
  });

  test('deleting a key that was never there is not an error', () async {
    await expectLater(store.delete('never-written'), completes);
  });

  test('writes land in the underlying SharedPreferences, not a private map',
      () async {
    // The point of this implementation over an in-memory one: another reader
    // of the same SharedPreferences instance must see the value.
    await store.write('spec_pack_source', 'https://example.com/p.json');
    expect(prefs.getString('spec_pack_source'), 'https://example.com/p.json');
  });
}

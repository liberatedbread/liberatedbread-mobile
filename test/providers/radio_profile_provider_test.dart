// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/providers/radio_profile_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';

import '../fakes/in_memory_settings_store.dart';

ProviderContainer _container(InMemorySettingsStore store) {
  final container = ProviderContainer(overrides: [
    prefsSettingsStoreProvider.overrideWith((ref) async => store),
  ]);
  addTearDown(container.dispose);
  return container;
}

void main() {
  group('the selected radio', () {
    test('defaults to one this build can program', () async {
      final profile = await _container(InMemorySettingsStore())
          .read(selectedRadioProfileProvider.future);
      expect(profile, defaultRadioProfile);
      expect(profile.isProgrammable, isTrue);
    });

    test('reads back what was stored', () async {
      final store = InMemorySettingsStore(
          {SelectedRadioProfileNotifier.key: uv17rPlusProfile.id});
      expect(await _container(store).read(selectedRadioProfileProvider.future),
          uv17rPlusProfile);
    });

    test('a profile this build no longer knows falls back', () async {
      // A stored id can outlive the build that wrote it. Leaving the Radio
      // tab with no radio selected would be worse than picking the default.
      final store = InMemorySettingsStore(
          {SelectedRadioProfileNotifier.key: 'discontinued-radio'});
      expect(await _container(store).read(selectedRadioProfileProvider.future),
          defaultRadioProfile);
    });

    test('selecting persists', () async {
      final store = InMemorySettingsStore();
      final container = _container(store);
      await container.read(selectedRadioProfileProvider.future);

      await container
          .read(selectedRadioProfileProvider.notifier)
          .select(uv5gProfile);

      expect(container.read(selectedRadioProfileProvider).value, uv5gProfile);
      expect(store.values[SelectedRadioProfileNotifier.key], uv5gProfile.id);
      expect(await _container(store).read(selectedRadioProfileProvider.future),
          uv5gProfile);
    });
  });

  group('the transmit-range unlock', () {
    test('is off for every radio until turned on', () async {
      final container = _container(InMemorySettingsStore());
      await container.read(txUnlockProvider.future);
      final notifier = container.read(txUnlockProvider.notifier);
      for (final profile in radioProfiles) {
        expect(notifier.isEnabledFor(profile), isFalse, reason: profile.id);
      }
    });

    test('is per radio, because the acknowledgement is', () async {
      // Agreeing to widen a Mini says nothing about a UV-17R Plus: different
      // radio, different ranges, different acknowledgement.
      final container = _container(InMemorySettingsStore());
      await container.read(txUnlockProvider.future);
      final notifier = container.read(txUnlockProvider.notifier);

      await notifier.setEnabled(uv5rProfile, true);

      expect(notifier.isEnabledFor(uv5rProfile), isTrue);
      expect(notifier.isEnabledFor(bfF8hpProfile), isFalse);
    });

    test('persists across containers', () async {
      final store = InMemorySettingsStore();
      final first = _container(store);
      await first.read(txUnlockProvider.future);
      await first.read(txUnlockProvider.notifier).setEnabled(uv5rProfile, true);

      final second = _container(store);
      await second.read(txUnlockProvider.future);
      expect(second.read(txUnlockProvider.notifier).isEnabledFor(uv5rProfile),
          isTrue);
    });

    test('cannot be turned on for a radio with no software path', () async {
      const locked = RadioProfile(
        id: 'test-locked',
        displayName: 'Test',
        rxRanges: [FreqRange(136000000, 174000000)],
        factoryTxRanges: [FreqRange(144000000, 148000000)],
        channelCapacity: 16,
        nameLength: 6,
        programmingFamily: ProgrammingFamily.serialUv5r,
      );
      final store = InMemorySettingsStore();
      final container = _container(store);
      await container.read(txUnlockProvider.future);
      final notifier = container.read(txUnlockProvider.notifier);

      await notifier.setEnabled(locked, true);

      expect(notifier.isEnabledFor(locked), isFalse);
      expect(store.values, isEmpty, reason: 'nothing should have been stored');
    });

    test('a stale stored true for an unlockable-no-more radio reads false',
        () async {
      // A setting cannot grant a capability the radio does not have, whatever
      // an older build wrote.
      const locked = RadioProfile(
        id: 'test-locked',
        displayName: 'Test',
        rxRanges: [FreqRange(136000000, 174000000)],
        factoryTxRanges: [FreqRange(144000000, 148000000)],
        channelCapacity: 16,
        nameLength: 6,
        programmingFamily: ProgrammingFamily.serialUv5r,
      );
      final store = InMemorySettingsStore({
        TxUnlockNotifier.key: jsonEncode({'test-locked': true})
      });
      final container = _container(store);
      await container.read(txUnlockProvider.future);
      expect(container.read(txUnlockProvider.notifier).isEnabledFor(locked),
          isFalse);
    });

    test('an unreadable setting reads as off', () async {
      for (final corrupt in ['not json', '[]', '{"a": "yes"}']) {
        final store = InMemorySettingsStore({TxUnlockNotifier.key: corrupt});
        final container = _container(store);
        await container.read(txUnlockProvider.future);
        expect(
            container.read(txUnlockProvider.notifier).isEnabledFor(uv5rProfile),
            isFalse,
            reason: corrupt);
      }
    });

    test('turning it off again persists', () async {
      final store = InMemorySettingsStore();
      final container = _container(store);
      await container.read(txUnlockProvider.future);
      final notifier = container.read(txUnlockProvider.notifier);

      await notifier.setEnabled(uv5rProfile, true);
      await notifier.setEnabled(uv5rProfile, false);

      expect(notifier.isEnabledFor(uv5rProfile), isFalse);
      final reread = _container(store);
      await reread.read(txUnlockProvider.future);
      expect(reread.read(txUnlockProvider.notifier).isEnabledFor(uv5rProfile),
          isFalse);
    });
  });

  group('txUnlockEnabledProvider', () {
    test('follows the selected radio', () async {
      final store = InMemorySettingsStore({
        SelectedRadioProfileNotifier.key: uv5rProfile.id,
        TxUnlockNotifier.key: jsonEncode({uv5rProfile.id: true}),
      });
      final container = _container(store);
      await container.read(selectedRadioProfileProvider.future);
      await container.read(txUnlockProvider.future);

      expect(container.read(txUnlockEnabledProvider), isTrue);

      // Switching to a radio whose family has no band limits turns it off,
      // whatever is stored for the previous one.
      await container
          .read(selectedRadioProfileProvider.notifier)
          .select(uv5rMiniProfile);
      expect(container.read(txUnlockEnabledProvider), isFalse);
    });

    test('is false while anything is still loading', () {
      final container = _container(InMemorySettingsStore());
      expect(container.read(txUnlockEnabledProvider), isFalse);
    });
  });
}

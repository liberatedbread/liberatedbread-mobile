// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/services/saved_device_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final seen = DateTime(2026, 8, 11, 10);

  Future<ProviderContainer> makeContainer() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(container.dispose);
    return container;
  }

  test('touch merges into an existing record instead of replacing it',
      () async {
    final container = await makeContainer();
    final notifier = container.read(savedDevicesProvider.notifier);

    await notifier.save(SavedDevice(
      id: 'AA:BB',
      name: 'Bulb',
      lastSeen: seen,
      category: 'light',
      specKey: 'Example Smart Bulb|Acme Corp',
    ));
    await notifier.touch(
        id: 'AA:BB',
        name: 'Bulb renamed',
        seenAt: seen.add(const Duration(hours: 1)));

    final device = container.read(savedDevicesProvider).single;
    expect(device.name, 'Bulb renamed');
    expect(device.lastSeen, seen.add(const Duration(hours: 1)));
    // The merge is the point: a plain replace would drop these.
    expect(device.category, 'light');
    expect(device.specKey, 'Example Smart Bulb|Acme Corp');
  });

  test('touch creates a record for a device never saved before', () async {
    final container = await makeContainer();
    final notifier = container.read(savedDevicesProvider.notifier);

    await notifier.touch(id: 'CC:DD', name: 'Fresh', seenAt: seen);

    final device = container.read(savedDevicesProvider).single;
    expect(device.id, 'CC:DD');
    expect(device.category, isNull);
    expect(device.specKey, isNull);
  });

  test('recordMatch stores category and specKey on an existing record',
      () async {
    final container = await makeContainer();
    final notifier = container.read(savedDevicesProvider.notifier);

    await notifier.touch(id: 'AA:BB', name: 'Bulb', seenAt: seen);
    await notifier.recordMatch(
      id: 'AA:BB',
      category: 'light',
      specKey: 'Example Smart Bulb|Acme Corp',
    );

    final device = container.read(savedDevicesProvider).single;
    expect(device.category, 'light');
    expect(device.specKey, 'Example Smart Bulb|Acme Corp');
    expect(device.name, 'Bulb');
    expect(device.lastSeen, seen);
  });

  test('recordMatch replaces both fields together', () async {
    final container = await makeContainer();
    final notifier = container.read(savedDevicesProvider.notifier);

    await notifier.save(SavedDevice(
      id: 'AA:BB',
      name: 'Bulb',
      lastSeen: seen,
      category: 'light',
      specKey: 'Example Smart Bulb|Acme Corp',
    ));
    // The user re-picked a spec with no category: the stale 'light' must not
    // survive next to the new key.
    await notifier.recordMatch(
        id: 'AA:BB', category: null, specKey: 'Mystery|Unknown');

    final device = container.read(savedDevicesProvider).single;
    expect(device.category, isNull);
    expect(device.specKey, 'Mystery|Unknown');
  });

  test('recordMatch is a no-op for unknown devices', () async {
    final container = await makeContainer();
    final notifier = container.read(savedDevicesProvider.notifier);

    await notifier.recordMatch(id: 'ZZ:ZZ', category: 'light', specKey: 'A|B');

    expect(container.read(savedDevicesProvider), isEmpty);
  });

  test('recordMatch with unchanged values does not rewrite the list', () async {
    final container = await makeContainer();
    final notifier = container.read(savedDevicesProvider.notifier);

    await notifier.save(SavedDevice(
        id: 'AA:BB',
        name: 'Bulb',
        lastSeen: seen,
        category: 'light',
        specKey: 'A|B'));
    final before = container.read(savedDevicesProvider);
    await notifier.recordMatch(id: 'AA:BB', category: 'light', specKey: 'A|B');

    expect(identical(before, container.read(savedDevicesProvider)), isTrue);
  });
}

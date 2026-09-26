// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_target.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_radio_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _radio = RadioTarget(
  transport: RadioTransport.ble,
  id: 'AA:BB',
  name: 'UV-5R Mini',
);

Future<ProviderContainer> _container() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final container = ProviderContainer(
    overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('starts empty, and a touch saves the radio', () async {
    final container = await _container();
    final notifier = container.read(savedRadiosProvider.notifier);
    expect(container.read(savedRadiosProvider), isEmpty);

    await notifier.touch(
      target: _radio,
      seenAt: DateTime(2026, 9, 1),
      radioProfileId: 'uv-5r-mini',
    );

    final saved = container.read(savedRadiosProvider).single;
    expect(saved.target, _radio);
    expect(saved.radioProfileId, 'uv-5r-mini');
    expect(notifier.contains(_radio), isTrue);
  });

  test('a touch without a model keeps the one chosen before', () async {
    final container = await _container();
    final notifier = container.read(savedRadiosProvider.notifier);
    await notifier.touch(
      target: _radio,
      seenAt: DateTime(2026, 9, 1),
      radioProfileId: 'uv-32',
    );
    await notifier.touch(target: _radio, seenAt: DateTime(2026, 9, 2));

    final saved = container.read(savedRadiosProvider).single;
    expect(saved.radioProfileId, 'uv-32');
    expect(saved.lastSeen, DateTime(2026, 9, 2));
  });

  test('a touch without a name keeps the name it had', () async {
    final container = await _container();
    final notifier = container.read(savedRadiosProvider.notifier);
    await notifier.touch(target: _radio, seenAt: DateTime(2026, 9, 1));
    await notifier.touch(
      target: const RadioTarget(
        transport: RadioTransport.ble,
        id: 'AA:BB',
        name: '',
      ),
      seenAt: DateTime(2026, 9, 2),
    );
    expect(container.read(savedRadiosProvider).single.name, 'UV-5R Mini');
  });

  test('remove forgets it', () async {
    final container = await _container();
    final notifier = container.read(savedRadiosProvider.notifier);
    await notifier.touch(target: _radio, seenAt: DateTime(2026, 9, 1));
    await notifier.remove(_radio);
    expect(container.read(savedRadiosProvider), isEmpty);
    expect(notifier.contains(_radio), isFalse);
    expect(notifier.savedRadioFor(_radio), isNull);
  });

  test('persists across a fresh container', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final first = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    await first
        .read(savedRadiosProvider.notifier)
        .touch(target: _radio, seenAt: DateTime(2026, 9, 1));
    first.dispose();

    final second = ProviderContainer(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
    );
    addTearDown(second.dispose);
    expect(second.read(savedRadiosProvider).single.target, _radio);
  });
}

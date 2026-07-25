// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/providers/device_spec_provider.dart';
import 'package:opengreeniot_mobile/providers/spec_pack_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads bundled example-bulb.yaml', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final specs = await container.read(deviceSpecsProvider.future);
    expect(specs, contains('assets/device_specs/example-bulb.yaml'));
    expect(specs['assets/device_specs/example-bulb.yaml'], isNotEmpty);
  });

  test('specs map is defensively typed', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final specs = await container.read(deviceSpecsProvider.future);
    expect(specs, isA<Map<String, String>>());
  });

  test('merges bundled specs with cached remote packs', () async {
    final container = ProviderContainer(overrides: [
      cachedSpecPacksProvider.overrideWith((ref) async => {
            'pack:Acme/bulb.yaml': 'device_name: Remote Bulb',
          }),
    ]);
    addTearDown(container.dispose);

    final specs = await container.read(deviceSpecsProvider.future);
    // Bundled asset is still present as a fallback...
    expect(specs, contains('assets/device_specs/example-bulb.yaml'));
    // ...alongside the namespaced remote spec.
    expect(specs['pack:Acme/bulb.yaml'], 'device_name: Remote Bulb');
  });

  test('bundled specs survive when remote packs fail to load', () async {
    final container = ProviderContainer(overrides: [
      // Simulate the cached-pack provider itself yielding nothing (its own
      // errors are swallowed to {} in production).
      cachedSpecPacksProvider.overrideWith((ref) async => const {}),
    ]);
    addTearDown(container.dispose);

    final specs = await container.read(deviceSpecsProvider.future);
    expect(specs, contains('assets/device_specs/example-bulb.yaml'));
  });
}

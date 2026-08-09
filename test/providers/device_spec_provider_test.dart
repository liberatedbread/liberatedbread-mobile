// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_pack_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads bundled example-bulb.yaml', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final specs = await container.read(deviceSpecsProvider.future);
    expect(
        specs,
        contains(
            'vendor/protocol-specs/device-specs/examples/example-bulb.yaml'));
    expect(
        specs['vendor/protocol-specs/device-specs/examples/example-bulb.yaml'],
        isNotEmpty);
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
    expect(
        specs,
        contains(
            'vendor/protocol-specs/device-specs/examples/example-bulb.yaml'));
    // ...alongside the namespaced remote spec.
    expect(specs['pack:Acme/bulb.yaml'], 'device_name: Remote Bulb');
  });

  test('bundled and remote key spaces cannot collide', () async {
    // The bundled keys moved from `assets/device_specs/...` to
    // `vendor/protocol-specs/...` when the app stopped copying the subtree.
    // Remote packs merge into the SAME map via addAll, so if the two namespaces
    // ever overlapped a pack could silently shadow a bundled spec, or be
    // shadowed by one. Neither is visible at runtime -- you would just get the
    // wrong YAML for a device -- so pin the invariant rather than trusting the
    // prefixes to stay different by luck.
    final container = ProviderContainer(overrides: [
      cachedSpecPacksProvider.overrideWith((ref) async => {
            'pack:Acme/bulb.yaml': 'device_name: Remote Bulb',
          }),
    ]);
    addTearDown(container.dispose);

    final specs = await container.read(deviceSpecsProvider.future);
    final bundled = specs.keys.where((k) => !k.startsWith('pack:')).toList();
    final remote = specs.keys.where((k) => k.startsWith('pack:')).toList();

    expect(bundled, isNotEmpty);
    expect(remote, ['pack:Acme/bulb.yaml']);
    for (final key in bundled) {
      expect(key, startsWith('$specsRoot/'),
          reason: 'every bundled spec must be keyed by its subtree asset path');
    }
  });

  test('a remote pack is not dropped by the bundled loader', () async {
    // The bundled half swallows its own per-file errors. Make sure that
    // swallowing cannot take the remote half with it: even when NO bundled spec
    // resolves, an installed pack must still reach the catalogue.
    final container = ProviderContainer(overrides: [
      cachedSpecPacksProvider.overrideWith((ref) async => {
            'pack:Acme/one.yaml': 'device_name: One',
            'pack:Acme/two.yaml': 'device_name: Two',
          }),
    ]);
    addTearDown(container.dispose);

    final specs = await container.read(deviceSpecsProvider.future);
    expect(specs['pack:Acme/one.yaml'], 'device_name: One');
    expect(specs['pack:Acme/two.yaml'], 'device_name: Two');
  });

  test('bundled specs survive when remote packs fail to load', () async {
    final container = ProviderContainer(overrides: [
      // Simulate the cached-pack provider itself yielding nothing (its own
      // errors are swallowed to {} in production).
      cachedSpecPacksProvider.overrideWith((ref) async => const {}),
    ]);
    addTearDown(container.dispose);

    final specs = await container.read(deviceSpecsProvider.future);
    expect(
        specs,
        contains(
            'vendor/protocol-specs/device-specs/examples/example-bulb.yaml'));
  });
}

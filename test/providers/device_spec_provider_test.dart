// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/providers/device_spec_provider.dart';

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
}

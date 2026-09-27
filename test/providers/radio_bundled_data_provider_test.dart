// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/radio_bundled_data_provider.dart';
import 'package:liberated_bread_mobile/services/radio_bundled_data.dart';

void main() {
  setUpAll(TestWidgetsFlutterBinding.ensureInitialized);

  test('provides one loader, shared', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final data = container.read(radioBundledDataProvider);
    expect(data, isA<RadioBundledData>());
    // The loader caches its parse internally, so sharing the instance is what
    // stops every consumer re-parsing the asset.
    expect(container.read(radioBundledDataProvider), same(data));
  });

  test('reaches the real asset through the default bundle', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final states = await container.read(radioBundledDataProvider).stateBounds();
    expect(states, isNotEmpty);
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/radio_programmer_provider.dart';
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_radio_programmer.dart';

void main() {
  test('provides a real programmer over the app\'s BLE service', () {
    final container = ProviderContainer(overrides: [
      bleServiceProvider.overrideWithValue(FakeBleService()),
    ]);
    addTearDown(container.dispose);

    final programmer = container.read(radioProgrammerProvider);
    // Demo mode is a compile-time define, so under test this is the real
    // driver -- which is the arrangement worth pinning: the mock must not
    // reach a shipping build by accident.
    expect(isMockMode, isFalse);
    expect(programmer, isA<BaofengBleProgrammer>());
  });

  test('is overridable, which is how the screens are tested', () {
    final fake = FakeRadioProgrammer();
    final container = ProviderContainer(overrides: [
      radioProgrammerProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);
    expect(container.read(radioProgrammerProvider), same(fake));
    expect(fake, isA<RadioProgrammer>());
  });
}

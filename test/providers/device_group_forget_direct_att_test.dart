// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Its own file because the routed Linux stack (RoutedBle) is one per
// process: flutter_blue_plus binds to the platform it first meets.
import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/device_group_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/services/saved_device_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/routed_ble.dart';

void main() {
  late RoutedBle rig;

  setUpAll(() => rig = RoutedBle.install());
  setUp(() => rig.reset());

  test(
    'forgetting a device a hand-over remembered routes it to BlueZ',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final container = ProviderContainer(
        overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      );
      addTearDown(container.dispose);
      const id = 'AA:BB:CC:DD:EE:01';
      final saved = container.read(savedDevicesProvider.notifier);
      await saved.save(
        SavedDevice(id: id, name: 'Strip', lastSeen: DateTime(2026, 9, 27)),
      );
      // What a hand-over after the silent-probe stall leaves behind.
      await rig.registry.add(id);
      expect(rig.router.routesDirect(const DeviceIdentifier(id)), isTrue);

      await forgetDevice(
        savedDevices: saved,
        groups: container.read(deviceGroupsProvider.notifier),
        deviceId: id,
        directAtt: rig.router,
      );

      // Before the cascade called DirectAttRouter.forget nothing did: the
      // device stayed direct (no RSSI, no BlueZ) across Remove and re-save.
      expect(rig.router.routesDirect(const DeviceIdentifier(id)), isFalse);
      expect(rig.registry.devices, isEmpty);
    },
  );
}

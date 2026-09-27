// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// BluezView, and the scan it repairs, against a virtual BlueZ: the REAL
// package:bluez and flutter_blue_plus_linux talking D-Bus to
// scripts/ble_virtual_peripheral.py, with the Linux router and the shipping
// RealBleService on top. No radio, no root.
//
// The scenario keeps two devices bluetoothd already knows (persisted: in its
// object tree from the start, announced by a scan only as property changes,
// exactly as bluetoothd does for a device that was once connected) beside one
// it has never seen. flutter_blue_plus_linux alone reports only the last.
//
// Run it through the harness, with the scenario:
//
//   LB_VIRTUAL_BLE_SCENARIO=test/fixtures/virtual_ble/known_devices.json \
//     ./scripts/linux-virtual-ble.sh \
//     flutter test test/services/direct_att/bluez_view_virtual_test.dart
//
// A plain `flutter test` has no virtual stack (LB_VIRTUAL_BLE unset) and
// skips it, rather than talking to the machine's real bluetoothd.
@Tags(['bluez'])
library;

import 'dart:io' show Platform;

import 'package:bluez/bluez.dart';
import 'package:flutter_blue_plus_linux/flutter_blue_plus_linux.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/direct_att/bluez_view.dart';
import 'package:liberated_bread_mobile/services/direct_att/direct_att_router.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/services/settings_store.dart';

import '../../fakes/in_memory_settings_store.dart';

const _meter = '18:7A:93:12:DE:94';
const _tag = 'D4:CA:6E:00:00:01';
const _fresh = 'AA:BB:CC:DD:EE:01';

void main() {
  final underHarness = Platform.environment['LB_VIRTUAL_BLE'] == '1';
  final skip = underHarness
      ? null
      : 'needs the virtual BlueZ stack: run through scripts/linux-virtual-ble.sh '
            'with LB_VIRTUAL_BLE_SCENARIO=test/fixtures/virtual_ble/'
            'known_devices.json';

  late BlueZClient client;
  late bool scenarioLoaded;

  setUpAll(() async {
    if (!underHarness) return;
    client = BlueZClient();
    await client.connect();
    scenarioLoaded = client.devices.any((d) => d.address == _meter);
  });

  tearDownAll(() async {
    if (underHarness) await client.close();
  });

  bool needScenario() {
    if (scenarioLoaded) return true;
    markTestSkipped(
      'the virtual stack is serving another scenario; set '
      'LB_VIRTUAL_BLE_SCENARIO=test/fixtures/virtual_ble/known_devices.json',
    );
    return false;
  }

  test('reads the LE address type bluetoothd recorded', skip: skip, () async {
    if (!needScenario()) return;
    final view = BluezView();
    addTearDown(view.close);
    expect(await view.isRandom(_meter), isFalse);
    expect(await view.isRandom(_tag), isTrue);
    expect(await view.isRandom('00:00:00:00:00:99'), isFalse);
  });

  test(
    'sights the devices bluetoothd already keeps — and not the new one, '
    "which is the backend's to report",
    skip: skip,
    () async {
      if (!needScenario()) return;
      final view = BluezView();
      addTearDown(view.close);
      await view.warmUp();
      final seen = <String, int>{};
      final sub = view.sightings().listen(
        (ad) => seen[ad.remoteId.str] = ad.rssi,
      );
      addTearDown(sub.cancel);
      await Future<void>.delayed(const Duration(milliseconds: 100));

      await client.adapters.first.startDiscovery();
      addTearDown(() => client.adapters.first.stopDiscovery());
      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(seen, {_meter: -58, _tag: -71});
    },
  );

  test(
    'a scan through the app\'s Linux stack finds devices BlueZ already knew',
    skip: skip,
    () async {
      if (!needScenario()) return;
      FlutterBluePlusLinux.registerWith();
      expect(
        installDirectAttRouter(
          Future<SettingsStore>.value(InMemorySettingsStore()),
        ),
        isNotNull,
      );
      final ble = RealBleService();

      final found = await ble
          .scan(timeout: const Duration(milliseconds: 1500))
          .map((d) => d.id.toUpperCase())
          .toSet();

      // The fresh device is flutter_blue_plus_linux's own report; the kept
      // two exist in the results only because the router sighted them.
      expect(found, containsAll([_fresh, _meter, _tag]));
    },
    timeout: const Timeout(Duration(minutes: 1)),
  );
}

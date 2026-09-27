// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Every test in real_ble_service_emulated_test.dart, run again — unmodified —
// with the Linux direct-ATT router between flutter_blue_plus and the emulated
// BlueZ, exactly where it sits in the shipping Linux app.
//
// That suite is the specification of how RealBleService behaves over a
// Bluetooth stack. Passing it through the router is the claim this whole
// design rests on, checked: putting the router in costs a device that BlueZ
// CAN serve nothing — same scans, same connects and claims, same discovery
// retries, same notify sharing, same pairing and error handling — so the
// code above flutter_blue_plus really is the one the phones run, and the
// Linux-only part really is only the transport.
//
// Mechanics: the router is installed first (the root setUpAll runs before
// the imported suite's), so flutter_blue_plus binds to it; the suite's own
// EmulatedBleAdapter.install() then returns the same adapter without
// touching the installed platform, and its setUp resets it as usual.

import 'package:flutter_test/flutter_test.dart';

import '../fakes/routed_ble.dart';
import 'real_ble_service_emulated_test.dart' as bare;

void main() {
  late RoutedBle rig;

  setUpAll(() {
    rig = RoutedBle.install();
  });

  setUp(() async {
    await rig.reset();
  });

  group('through the Linux direct-ATT router', bare.main);
}

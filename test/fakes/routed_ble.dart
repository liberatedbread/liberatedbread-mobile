// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Linux Bluetooth stack as the app ships it, with no radio: the REAL
// flutter_blue_plus, bound to the REAL DirectAttRouter, which fronts an
// emulated BlueZ (emulated_ble.dart) and a DirectAttPlatform whose ATT
// bearers go to scripted peripherals (fake_att_channel.dart).
//
// One device can be given both views — an EmulatedPeripheral for what
// bluetoothd reports about it and a FakeAttPeripheral for what its ATT server
// answers — which is how the silent-probe stall and the hand-over that
// follows are reproduced: BlueZ's discovery blocks, resolves empty and drops
// the link, while the same address answers a direct walk.
//
// ONE PER PROCESS, like the adapter it wraps: flutter_blue_plus binds to the
// installed platform's streams on its first call and never again, so the
// router must be the instance from the first test in a file to the last.
// reset() returns everything to a clean state between tests.

import 'dart:async';

import 'package:flutter_blue_plus_platform_interface/flutter_blue_plus_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/direct_att/direct_att_platform.dart';
import 'package:liberated_bread_mobile/services/direct_att/direct_att_registry.dart';
import 'package:liberated_bread_mobile/services/direct_att/direct_att_router.dart';
import 'package:liberated_bread_mobile/services/settings_store.dart';

import 'emulated_ble.dart';
import 'fake_att_channel.dart';
import 'in_memory_settings_store.dart';

/// The routed Linux stack. See the file comment.
class RoutedBle {
  static RoutedBle? _installed;

  /// BlueZ's view of the world.
  final EmulatedBleAdapter ble;

  /// Where direct ATT bearers go: add a FakeAttPeripheral per address.
  final FakeAttChannelFactory channels;

  final DirectAttPlatform direct;
  final DirectAttRouter router;

  /// The router's registry is fixed for the process (it is load-once); its
  /// backing store is what reset() swaps out.
  final _SwappableStore _store;

  /// Every address the direct path looked up the type of.
  final List<String> addressLookups = [];

  /// Addresses whose LE address type is random.
  final Set<String> randomAddresses = {};

  /// What bluetoothd reports hearing from devices it already knows (the
  /// production source is BluezView.sightings): add to it to script one.
  /// Lives as long as the process-wide rig, like the router it feeds.
  // ignore: close_sinks
  final StreamController<BmScanAdvertisement> sightings =
      StreamController<BmScanAdvertisement>.broadcast();

  RoutedBle._(this.ble, this.channels, this.direct, this.router, this._store);

  /// The router's registry.
  DirectAttRegistry get registry => router.registry;

  /// The store the registry persists to, fresh each test.
  InMemorySettingsStore get store => _store.current;

  /// Install (first call) or return the process's routed stack. Thresholds
  /// are scaled down so a "30 s" stall is a few hundred milliseconds of
  /// real time; the ratios between them are the production ones.
  static RoutedBle install({
    Duration stallThreshold = const Duration(milliseconds: 200),
    Duration bluezDiscoveryLimit = const Duration(milliseconds: 1500),
    Duration requestTimeout = const Duration(milliseconds: 400),
  }) {
    final existing = _installed;
    if (existing != null) return existing;
    TestWidgetsFlutterBinding.ensureInitialized();
    final ble = EmulatedBleAdapter.install();
    if (FlutterBluePlusPlatform.instance is DirectAttRouter) {
      throw StateError('a router is already installed in this process');
    }
    if (ble.debugHasListeners) {
      throw StateError(
        'flutter_blue_plus already bound to the bare emulated adapter in '
        'this process; install the router before the first Bluetooth call',
      );
    }
    final channels = FakeAttChannelFactory();
    final store = _SwappableStore();
    late final RoutedBle rig;
    late final DirectAttRouter router;
    final direct = DirectAttPlatform(
      channels,
      isRandomAddress: (address) async {
        rig.addressLookups.add(address);
        return rig.randomAddresses.contains(address.toUpperCase());
      },
      onBusy: (id) => router.evictFromBluez(id),
      connectTimeout: const Duration(seconds: 2),
      requestTimeout: requestTimeout,
      securityTimeout: const Duration(seconds: 1),
      busyRetryDelay: const Duration(milliseconds: 30),
    );
    router = DirectAttRouter(
      inner: ble,
      direct: direct,
      registry: DirectAttRegistry(Future.value(store)),
      stallThreshold: stallThreshold,
      bluezDiscoveryLimit: bluezDiscoveryLimit,
      evictionWait: const Duration(milliseconds: 300),
      linkReleaseWait: const Duration(milliseconds: 300),
      handOverRetryDelay: const Duration(milliseconds: 50),
      knownDeviceSightings: () => rig.sightings.stream,
      routeHintTimeout: const Duration(milliseconds: 200),
    );
    FlutterBluePlusPlatform.instance = router;
    rig = RoutedBle._(ble, channels, direct, router, store);
    return _installed = rig;
  }

  /// Between tests: close every direct link (reported as disconnected),
  /// reset the emulated adapter, forget scripted peripherals. The registry
  /// cannot be reloaded, so remembered devices are removed one by one.
  Future<void> reset() async {
    await router.debugReset();
    await ble.reset();
    for (final id in registry.devices.toList()) {
      await registry.remove(id);
    }
    _store.current = InMemorySettingsStore();
    channels.peripherals.clear();
    channels.attempts.clear();
    channels.channels.clear();
    channels.connectError = null;
    channels.onChannelOpened = null;
    router.routeHint = null;
    addressLookups.clear();
    randomAddresses.clear();
  }
}

/// A SettingsStore whose backing map can be replaced between tests.
class _SwappableStore implements SettingsStore {
  InMemorySettingsStore current = InMemorySettingsStore();

  @override
  Future<String?> read(String key) => current.read(key);
  @override
  Future<void> write(String key, String value) => current.write(key, value);
  @override
  Future<void> delete(String key) => current.delete(key);
  @override
  Future<Map<String, String>> readAll() => current.readAll();
}

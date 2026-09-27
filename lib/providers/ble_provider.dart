// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/ble_service.dart';
import '../services/direct_att/direct_att_router.dart';
import '../services/mock_ble_service.dart';
import '../services/prefs_settings_store.dart';
import '../services/real_ble_service.dart';
import 'direct_att_hint_provider.dart';

/// Whether the app is running in mock mode (no real BLE hardware).
const isMockMode = bool.fromEnvironment('LIBERATED_BREAD_MOCK');

/// The Linux direct-ATT router under flutter_blue_plus
/// (lib/services/direct_att/), or null: anywhere but Linux, in mock mode, and
/// with `LB_DIRECT_ATT=off`.
///
/// Installing it is what lets peripherals BlueZ cannot enumerate work at all,
/// while every line above the platform layer stays the code iOS and Android
/// run. Its remembered-device list lives in plain preferences: it is a
/// routing hint, not a secret, and the secure store's keychain round trip
/// would be paid for nothing. It is also handed the spec catalogue's say
/// (specDeclaresDirectAttProvider), so a device a spec marks as BlueZ-
/// incompatible goes direct from its first connection.
final directAttRouterProvider = Provider<DirectAttRouter?>((ref) {
  if (isMockMode) return null;
  final router = installDirectAttRouter(
    SharedPreferences.getInstance().then(PrefsSettingsStore.new),
  );
  if (router == null) return null;
  // Read, not watched, and only when the router asks: see the provider.
  late final DirectAttRouteHint hint;
  hint = (deviceId, seen) =>
      ref.read(specDeclaresDirectAttProvider)(deviceId, seen);
  router.routeHint = hint;
  ref.onDispose(() {
    // The router outlives any one container (it is process-wide); leave a
    // hint a newer container installed.
    if (identical(router.routeHint, hint)) router.routeHint = null;
  });
  return router;
});

/// Provides the BLE service implementation (real or mock).
final bleServiceProvider = Provider<BleService>((ref) {
  if (!isMockMode) {
    // Before RealBleService exists — flutter_blue_plus binds to whatever
    // platform it first meets, and RealBleService is the only code that
    // talks to it. A no-op off Linux.
    ref.watch(directAttRouterProvider);
    return RealBleService();
  }
  final mock = MockBleService();
  // The mock keeps a broadcast StreamController per device for its
  // connection-state stream. Close them when the provider is torn down so they
  // don't outlive the container, mirroring how haApiClientProvider disposes its
  // http.Client. Without this, MockBleService.dispose() is never called outside
  // tests.
  ref.onDispose(mock.dispose);
  return mock;
});

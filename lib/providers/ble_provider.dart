// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ble_service.dart';
import '../services/mock_ble_service.dart';
import '../services/real_ble_service.dart';

/// Whether the app is running in mock mode (no real BLE hardware).
const isMockMode = bool.fromEnvironment('OPENGREENIOT_MOCK');

/// Provides the BLE service implementation (real or mock).
final bleServiceProvider = Provider<BleService>((ref) {
  if (!isMockMode) return RealBleService();
  final mock = MockBleService();
  // The mock keeps a broadcast StreamController per device for its
  // connection-state stream. Close them when the provider is torn down so they
  // don't outlive the container, mirroring how haApiClientProvider disposes its
  // http.Client. Without this, MockBleService.dispose() is never called outside
  // tests.
  ref.onDispose(mock.dispose);
  return mock;
});

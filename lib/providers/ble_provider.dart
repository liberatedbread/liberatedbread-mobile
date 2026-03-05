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
  return isMockMode ? MockBleService() : RealBleService();
});

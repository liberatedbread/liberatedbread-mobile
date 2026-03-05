// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../services/ble_service.dart';
import 'ble_provider.dart';

/// Connection state for a specific device, keyed by device ID.
final deviceConnectionProvider =
    StreamProvider.family<BleConnectionState, String>((ref, deviceId) {
  final bleService = ref.read(bleServiceProvider);
  return bleService.connectionState(deviceId);
});

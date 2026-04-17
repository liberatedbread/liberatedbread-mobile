// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/services/ble_service.dart';
import 'package:opengreeniot_mobile/services/real_ble_service.dart';

void main() {
  group('mapConnectionState', () {
    test('connected maps through', () {
      expect(
        mapConnectionState(BluetoothConnectionState.connected),
        BleConnectionState.connected,
      );
    });

    test('disconnected maps through', () {
      expect(
        mapConnectionState(BluetoothConnectionState.disconnected),
        BleConnectionState.disconnected,
      );
    });
  });
}

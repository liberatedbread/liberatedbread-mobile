// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Abstract BLE service interface. Implementations:
//   - RealBleService (flutter_blue_plus)
//   - MockBleService (simulated devices for demo mode)

import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';

/// Connection state for a BLE device.
enum BleConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

/// Abstract interface for BLE operations.
abstract class BleService {
  /// Request runtime permissions for BLE scanning.
  Future<bool> requestPermissions();

  /// Scan for nearby BLE devices.
  Stream<IoTDevice> scan({Duration timeout = const Duration(seconds: 10)});

  /// Stop an in-progress scan.
  Future<void> stopScan();

  /// Connect to a device by its ID.
  Future<void> connect(String deviceId);

  /// Disconnect from a device.
  Future<void> disconnect(String deviceId);

  /// Stream the connection state of a device.
  Stream<BleConnectionState> connectionState(String deviceId);

  /// Discover GATT services on a connected device.
  Future<List<BleDiscoveredService>> discoverServices(String deviceId);

  /// Read a characteristic value.
  Future<List<int>> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  );

  /// Write a value to a characteristic.
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  );

  /// Subscribe to characteristic notifications. Returns a stream of byte values.
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  );
}

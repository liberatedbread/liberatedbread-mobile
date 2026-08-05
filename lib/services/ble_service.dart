// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Abstract BLE service interface. Implementations:
//   - RealBleService (flutter_blue_plus)
//   - MockBleService (simulated devices for demo mode)

import '../core/constants.dart';
import '../core/error_text.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';

/// Connection state for a BLE device.
enum BleConnectionState {
  disconnected,
  connecting,
  connected,
  disconnecting,
}

/// Raised on the [BleService.scan] stream when BLE permissions were denied.
///
/// Surfaced as a distinct error (rather than silently closing the scan) so the
/// UI can show permission-specific guidance and an open-settings recovery path
/// instead of a generic "no devices found" empty state.
class BlePermissionDeniedException implements UserFacingException {
  @override
  final String message;
  const BlePermissionDeniedException(
      [this.message =
          'Bluetooth permission denied. Grant Bluetooth (and, on Android, '
              'nearby-devices/location) access to scan for devices.']);

  @override
  String toString() => message;
}

/// Raised on the [BleService.scan] stream when the Bluetooth radio is off (or
/// otherwise unavailable), as opposed to permission being withheld.
///
/// A distinct type, not a bare `StateError`, so the recovery the UI offers can
/// be specific — and so the message reaching the user is one written for them
/// rather than Dart's "Bad state: ..." rendering of an internal error.
class BleUnavailableException implements UserFacingException {
  @override
  final String message;
  const BleUnavailableException(
      [this.message = 'Bluetooth is turned off. Turn it on to scan for '
          'devices.']);

  @override
  String toString() => message;
}

/// Abstract interface for BLE operations.
abstract class BleService {
  /// Request runtime permissions for BLE scanning.
  Future<bool> requestPermissions();

  /// Scan for nearby BLE devices.
  Stream<IoTDevice> scan({
    Duration timeout =
        const Duration(seconds: AppConstants.defaultScanDuration),
  });

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

  /// The current ATT MTU for a connected device, in bytes.
  ///
  /// Callers that chunk bulk transfers (image frames) size their writes from
  /// this: usable payload per write is `mtu - 3`. Returns the BLE minimum of
  /// 23 when the platform has not reported a negotiated value — sizing for 23
  /// is always safe, just slower.
  Future<int> mtu(String deviceId);
}

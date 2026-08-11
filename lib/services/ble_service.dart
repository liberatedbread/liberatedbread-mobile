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

/// Raised when a peripheral refuses a GATT operation because the link has not
/// been paired (bonded) yet.
///
/// Some BLE devices mark their characteristics as requiring an authenticated
/// link — locks, anything handling payment, and any vendor that followed the
/// security guidance. Such a device advertises, connects and answers service
/// discovery exactly like an open one; the refusal only arrives on the first
/// read or write, as ATT error 0x05. Without a distinct type for it the user
/// got the generic "the device did not accept that command", which points them
/// at the command rather than at the pairing prompt that is the actual next
/// step — so this exists to say the one useful thing instead.
class BlePairingRequiredException implements UserFacingException {
  @override
  final String message;
  const BlePairingRequiredException(
      [this.message = 'This device needs to be paired before it will share '
          'data. Accept the pairing request from your system Bluetooth '
          'settings, then try again.']);

  @override
  String toString() => message;
}

/// How hard [BleService.scan] should drive the radio.
///
/// The dial is real only on Android, where scan mode sets the radio's duty
/// cycle — balanced listens roughly a quarter of the time, low latency all of
/// it. Apple platforms expose no equivalent, so there the two are the same
/// scan; the enum still names the caller's intent, which is what the screen's
/// burst-then-downshift logic runs on.
enum ScanIntensity {
  /// The user just pressed Scan and is watching the list: discovery latency
  /// is the product, so the radio listens continuously.
  active,

  /// The app is keeping watch on its own — nobody asked for this particular
  /// moment of scanning, so it duty-cycles the radio and takes the slightly
  /// later discoveries.
  ambient,
}

/// Abstract interface for BLE operations.
abstract class BleService {
  /// Request runtime permissions for BLE scanning.
  Future<bool> requestPermissions();

  /// Scan for nearby BLE devices.
  ///
  /// A null [timeout] scans continuously: the stream stays open, and keeps
  /// reporting, until the consumer cancels it or [stopScan] is called. That is
  /// what the scan screen uses — discovery is not an event with an end, it is a
  /// picture of what is on air, and a device that only powers on a minute after
  /// the user opened the app should still appear. A non-null timeout keeps the
  /// old one-shot behaviour, where the stream closes when the window ends.
  ///
  /// Devices are re-reported as they keep advertising, so a consumer can tell a
  /// device still on air from one that has gone quiet — see [IoTDevice.lastSeen].
  ///
  /// [intensity] says whose idea this scan was — see [ScanIntensity]. Defaults
  /// to [ScanIntensity.active], which is the pre-dial behaviour, so a caller
  /// that has not opted into duty-cycling never gets it by surprise.
  Stream<IoTDevice> scan({
    Duration? timeout =
        const Duration(seconds: AppConstants.defaultScanDuration),
    ScanIntensity intensity = ScanIntensity.active,
  });

  /// Stop an in-progress scan.
  Future<void> stopScan();

  /// Whether the radio is in a state [scan] could succeed in — the current
  /// answer on listen, then every change.
  ///
  /// Exists for one recovery the lifecycle observer cannot make: on Android,
  /// Bluetooth is toggled from quick settings without the app ever losing
  /// focus, so no lifecycle event announces the radio coming back. Without
  /// this, a scan screen showing "Bluetooth is turned off" keeps showing it
  /// after the user has done exactly what it asked, until they find the Retry
  /// button for a problem they already fixed.
  ///
  /// False covers unauthorized as well as off — a permission granted in
  /// system settings requires leaving the app, so the resumed-lifecycle path
  /// already handles that recovery.
  Stream<bool> adapterReady();

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

  /// Read the current signal strength (RSSI, dBm) of a *connected* device.
  ///
  /// Drives the Find Device view's live proximity readout. Only valid while
  /// connected — a connected peripheral stops advertising, so the connection
  /// is the one place its RSSI can still be measured. Throws when the device
  /// is not connected.
  Future<int> readRssi(String deviceId);
}

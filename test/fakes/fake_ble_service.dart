// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';

/// Configurable fake [BleService] for widget/screen tests.
///
/// Each stage of the flow can be independently controlled: the devices
/// emitted by [scan], whether connect/discover/read succeed, and what
/// values reads return.
class FakeBleService implements BleService {
  final List<IoTDevice> devicesToEmit;
  final List<BleDiscoveredService> servicesToReturn;
  final Map<String, List<int>> readValues;
  final Duration scanStepDelay;
  final Object? scanError;
  final Object? connectError;
  final Object? discoverError;
  final Object? readError;

  /// Stream returned by [subscribeCharacteristic]; defaults to an empty stream.
  final Stream<List<int>>? notifyStream;

  /// Stream returned by [connectionState]; defaults to an empty stream. Tests
  /// can supply a controller-backed stream to simulate a mid-session
  /// disconnect.
  final Stream<BleConnectionState>? connectionStateStream;

  /// When set, [connect] awaits this before resolving — lets a test hold a
  /// connect in flight (e.g. to unmount the screen mid-connect).
  final Completer<void>? connectGate;

  /// When set, [discoverServices] awaits this before resolving.
  final Completer<void>? discoverGate;

  /// Returned by [mtu]; the BLE minimum unless a test raises it.
  final int mtuToReturn;

  /// When set, every [writeCharacteristic] call awaits this before recording,
  /// letting a test hold writes in flight to exercise send serialization.
  final Future<void>? writeGate;

  final List<String> connectedIds = [];
  final List<String> disconnectedIds = [];
  final List<({String deviceId, String charUuid, List<int> value})> writes = [];
  int stopScanCount = 0;

  /// Ordered log of connect/disconnect calls (e.g. 'connect:01',
  /// 'disconnect:01'). Lets tests assert the *order* of lifecycle calls, which
  /// call-count lists alone can't capture.
  final List<String> events = [];

  FakeBleService({
    this.devicesToEmit = const [],
    this.servicesToReturn = const [],
    this.readValues = const {},
    this.scanStepDelay = Duration.zero,
    this.scanError,
    this.connectError,
    this.discoverError,
    this.readError,
    this.notifyStream,
    this.connectionStateStream,
    this.connectGate,
    this.discoverGate,
    this.mtuToReturn = 23,
    this.writeGate,
  });

  @override
  Future<bool> requestPermissions() async => true;

  // Matches the fixed RealBleService contract: devices stream in during the
  // scan window and the stream closes only when the window ends (here: when
  // there is nothing left to emit) — never early with results still pending.
  @override
  Stream<IoTDevice> scan({
    Duration timeout =
        const Duration(seconds: AppConstants.defaultScanDuration),
  }) async* {
    if (scanError != null) throw scanError!;
    for (final d in devicesToEmit) {
      if (scanStepDelay > Duration.zero) {
        await Future<void>.delayed(scanStepDelay);
      }
      yield d;
    }
  }

  @override
  Future<void> stopScan() async {
    stopScanCount++;
  }

  @override
  Future<void> connect(String deviceId) async {
    if (connectGate != null) await connectGate!.future;
    if (connectError != null) throw connectError!;
    connectedIds.add(deviceId);
    events.add('connect:$deviceId');
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectedIds.add(deviceId);
    events.add('disconnect:$deviceId');
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) =>
      connectionStateStream ?? const Stream.empty();

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
    if (discoverGate != null) await discoverGate!.future;
    if (discoverError != null) throw discoverError!;
    return servicesToReturn;
  }

  @override
  Future<List<int>> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) async {
    if (readError != null) throw readError!;
    return readValues[charUuid.toLowerCase()] ?? const [0];
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    if (writeGate != null) await writeGate;
    writes.add((deviceId: deviceId, charUuid: charUuid, value: value));
  }

  /// Every characteristic [subscribeCharacteristic] was called for, in order.
  ///
  /// A widget that remounts re-subscribes, and the real service has no
  /// reference counting behind `setNotifyValue`, so a duplicate here is a
  /// characteristic that can end up silently disabled. Counting them is the
  /// only way a widget test can see that from outside.
  final List<String> subscriptions = [];

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    subscriptions.add(charUuid);
    return notifyStream ?? const Stream<List<int>>.empty();
  }

  @override
  Future<int> mtu(String deviceId) async => mtuToReturn;
}

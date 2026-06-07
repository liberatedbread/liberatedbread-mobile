// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:opengreeniot_mobile/models/ble_discovered_service.dart';
import 'package:opengreeniot_mobile/models/iot_device.dart';
import 'package:opengreeniot_mobile/services/ble_service.dart';

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

  final List<String> connectedIds = [];
  final List<String> disconnectedIds = [];
  final List<({String deviceId, String charUuid, List<int> value})> writes = [];

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
  });

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Stream<IoTDevice> scan(
      {Duration timeout = const Duration(seconds: 10)}) async* {
    if (scanError != null) throw scanError!;
    for (final d in devicesToEmit) {
      if (scanStepDelay > Duration.zero) {
        await Future<void>.delayed(scanStepDelay);
      }
      yield d;
    }
  }

  @override
  Future<void> stopScan() async {}

  @override
  Future<void> connect(String deviceId) async {
    if (connectError != null) throw connectError!;
    connectedIds.add(deviceId);
  }

  @override
  Future<void> disconnect(String deviceId) async {
    disconnectedIds.add(deviceId);
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) =>
      const Stream.empty();

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
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
    writes.add((deviceId: deviceId, charUuid: charUuid, value: value));
  }

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) =>
      notifyStream ?? const Stream<List<int>>.empty();
}

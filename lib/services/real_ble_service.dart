// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import 'ble_service.dart';

/// Map a flutter_blue_plus connection state to our internal enum.
/// Extracted as a top-level function so it can be unit-tested without
/// a real Bluetooth adapter.
BleConnectionState mapConnectionState(BluetoothConnectionState state) {
  switch (state) {
    case BluetoothConnectionState.connected:
      return BleConnectionState.connected;
    case BluetoothConnectionState.disconnected:
      return BleConnectionState.disconnected;
    default:
      return BleConnectionState.disconnected;
  }
}

/// Real BLE implementation using flutter_blue_plus.
class RealBleService implements BleService {
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  final Map<String, List<BluetoothService>> _servicesCache = {};

  @override
  Future<bool> requestPermissions() async {
    if (Platform.isAndroid) {
      final statuses = await [
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
        Permission.locationWhenInUse,
      ].request();
      return statuses.values.every((s) => s.isGranted);
    }
    if (Platform.isIOS) {
      final status = await Permission.bluetooth.request();
      return status.isGranted;
    }
    return true;
  }

  @override
  Stream<IoTDevice> scan({Duration timeout = const Duration(seconds: 10)}) {
    final controller = StreamController<IoTDevice>();

    Future<void> closeIfOpen() async {
      if (!controller.isClosed) await controller.close();
    }

    () async {
      try {
        final granted = await requestPermissions();
        if (!granted) {
          await closeIfOpen();
          return;
        }

        final adapterState = await FlutterBluePlus.adapterState.first;
        if (adapterState != BluetoothAdapterState.on) {
          controller.addError(
            StateError('Bluetooth is not enabled. Please turn on Bluetooth.'),
          );
          await closeIfOpen();
          return;
        }

        _scanSubscription = FlutterBluePlus.scanResults.listen(
          (results) {
            for (final result in results) {
              controller.add(IoTDevice(
                id: result.device.remoteId.str,
                name: result.device.platformName,
                rssi: result.rssi,
                isConnectable: result.advertisementData.connectable,
                discoveredAt: DateTime.now(),
              ));
            }
          },
          onError: (Object error) {
            controller.addError(error);
          },
        );

        await FlutterBluePlus.startScan(timeout: timeout);

        await _scanSubscription?.cancel();
        _scanSubscription = null;
        await closeIfOpen();
      } catch (e) {
        controller.addError(e);
        await _scanSubscription?.cancel();
        _scanSubscription = null;
        await closeIfOpen();
      }
    }();

    return controller.stream;
  }

  @override
  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }

  @override
  Future<void> connect(String deviceId) async {
    final device = BluetoothDevice.fromId(deviceId);
    await device.connect(timeout: const Duration(seconds: 15));
  }

  @override
  Future<void> disconnect(String deviceId) async {
    _servicesCache.remove(deviceId);
    final device = BluetoothDevice.fromId(deviceId);
    await device.disconnect();
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) {
    final device = BluetoothDevice.fromId(deviceId);
    return device.connectionState.map(mapConnectionState);
  }

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
    final services = await _loadServices(deviceId);
    return services
        .map((s) => BleDiscoveredService(
              uuid: s.uuid.toString(),
              characteristics: s.characteristics
                  .map((c) => BleDiscoveredCharacteristic(
                        uuid: c.uuid.toString(),
                        canRead: c.properties.read,
                        canWrite: c.properties.write ||
                            c.properties.writeWithoutResponse,
                        canNotify: c.properties.notify || c.properties.indicate,
                      ))
                  .toList(),
            ))
        .toList();
  }

  /// Load GATT services for a device, caching the result so follow-up
  /// read/write/subscribe calls don't trigger a fresh discovery round-trip.
  /// The cache is invalidated in [disconnect].
  Future<List<BluetoothService>> _loadServices(String deviceId) async {
    final cached = _servicesCache[deviceId];
    if (cached != null) return cached;
    final device = BluetoothDevice.fromId(deviceId);
    final services = await device.discoverServices();
    _servicesCache[deviceId] = services;
    return services;
  }

  /// Find a specific BLE characteristic by service and characteristic UUID.
  Future<BluetoothCharacteristic> _findCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) async {
    final services = await _loadServices(deviceId);
    final s = normalizeUuid(serviceUuid);
    final c = normalizeUuid(charUuid);
    for (final service in services) {
      if (normalizeUuid(service.uuid.toString()) == s) {
        for (final char in service.characteristics) {
          if (normalizeUuid(char.uuid.toString()) == c) {
            return char;
          }
        }
      }
    }
    throw StateError('Characteristic $charUuid not found');
  }

  @override
  Future<List<int>> readCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) async {
    final char = await _findCharacteristic(deviceId, serviceUuid, charUuid);
    return char.read();
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    final char = await _findCharacteristic(deviceId, serviceUuid, charUuid);
    await char.write(value);
  }

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    final controller = StreamController<List<int>>();
    StreamSubscription<List<int>>? sub;

    () async {
      try {
        final char = await _findCharacteristic(deviceId, serviceUuid, charUuid);
        await char.setNotifyValue(true);
        sub = char.lastValueStream.listen(
          (value) => controller.add(value),
          onError: (Object error) => controller.addError(error),
          onDone: () async {
            if (!controller.isClosed) await controller.close();
          },
        );
      } catch (e) {
        controller.addError(e);
        if (!controller.isClosed) await controller.close();
      }
    }();

    controller.onCancel = () async {
      await sub?.cancel();
    };

    return controller.stream;
  }
}

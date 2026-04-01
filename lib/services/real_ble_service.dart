// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import 'ble_service.dart';

/// Real BLE implementation using flutter_blue_plus.
class RealBleService implements BleService {
  StreamSubscription<List<ScanResult>>? _scanSubscription;

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

    () async {
      try {
        final granted = await requestPermissions();
        if (!granted) {
          controller.close();
          return;
        }

        final adapterState = await FlutterBluePlus.adapterState.first;
        if (adapterState != BluetoothAdapterState.on) {
          controller.addError(
            StateError('Bluetooth is not enabled. Please turn on Bluetooth.'),
          );
          controller.close();
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
        await controller.close();
      } catch (e) {
        controller.addError(e);
        await _scanSubscription?.cancel();
        _scanSubscription = null;
        await controller.close();
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
    final device = BluetoothDevice.fromId(deviceId);
    await device.disconnect();
  }

  @override
  Stream<BleConnectionState> connectionState(String deviceId) {
    final device = BluetoothDevice.fromId(deviceId);
    return device.connectionState.map((state) {
      switch (state) {
        case BluetoothConnectionState.connected:
          return BleConnectionState.connected;
        case BluetoothConnectionState.disconnected:
          return BleConnectionState.disconnected;
        default:
          return BleConnectionState.disconnected;
      }
    });
  }

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
    final device = BluetoothDevice.fromId(deviceId);
    final services = await device.discoverServices();
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

  /// Find a specific BLE characteristic by service and characteristic UUID.
  Future<BluetoothCharacteristic> _findCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) async {
    final device = BluetoothDevice.fromId(deviceId);
    final services = await device.discoverServices();
    for (final service in services) {
      if (service.uuid.toString().toLowerCase() == serviceUuid.toLowerCase()) {
        for (final char in service.characteristics) {
          if (char.uuid.toString().toLowerCase() == charUuid.toLowerCase()) {
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
    return await char.read();
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

    () async {
      try {
        final char = await _findCharacteristic(deviceId, serviceUuid, charUuid);
        await char.setNotifyValue(true);
        char.lastValueStream.listen(
          (value) => controller.add(value),
          onError: (Object error) => controller.addError(error),
          onDone: () => controller.close(),
        );
      } catch (e) {
        controller.addError(e);
        controller.close();
      }
    }();

    return controller.stream;
  }
}

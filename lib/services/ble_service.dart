// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:io';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/iot_device.dart';

class BleService {
  StreamSubscription<List<ScanResult>>? _scanSubscription;

  /// Request the runtime permissions needed for BLE scanning.
  ///
  /// Returns true if all required permissions were granted.
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

  /// Scan for BLE devices, yielding each discovery as an [IoTDevice].
  ///
  /// Automatically requests permissions before scanning. If permissions are
  /// denied, the returned stream closes immediately with no results.
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

        // Scan finished — clean up.
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

  Future<void> stopScan() async {
    await FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
  }
}

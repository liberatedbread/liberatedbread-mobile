// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import '../models/iot_device.dart';

class BleService {
  Stream<IoTDevice> scan({Duration timeout = const Duration(seconds: 10)}) {
    final controller = StreamController<IoTDevice>();
    FlutterBluePlus.startScan(timeout: timeout);
    final subscription = FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        controller.add(IoTDevice(
          id: result.device.remoteId.str,
          name: result.device.platformName,
          rssi: result.rssi,
          isConnectable: result.advertisementData.connectable,
          discoveredAt: DateTime.now(),
        ));
      }
    });
    FlutterBluePlus.isScanning.where((s) => !s).first.then((_) {
      subscription.cancel();
      controller.close();
    });
    return controller.stream;
  }

  Future<void> stopScan() async => await FlutterBluePlus.stopScan();
}

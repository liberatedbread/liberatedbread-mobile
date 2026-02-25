// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import '../models/iot_device.dart';

class DeviceScreen extends StatelessWidget {
  final IoTDevice device;

  const DeviceScreen({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(device.displayName)),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.bluetooth_connected, size: 64),
            const SizedBox(height: 16),
            Text(device.displayName, style: const TextStyle(fontSize: 20)),
            const SizedBox(height: 8),
            Text('RSSI: ${device.rssi} dBm', style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
            const Text('Services and characteristics will appear here.'),
          ],
        ),
      ),
    );
  }
}

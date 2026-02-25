// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import '../models/device_characteristic.dart';

class CharacteristicScreen extends StatelessWidget {
  final DeviceCharacteristic characteristic;

  const CharacteristicScreen({super.key, required this.characteristic});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(characteristic.name ?? characteristic.uuid)),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('UUID: ${characteristic.uuid}', style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 16),
            Text('Hex: ${characteristic.hexValue}'),
            if (characteristic.stringValue != null) ...[
              const SizedBox(height: 8),
              Text('String: ${characteristic.stringValue}'),
            ],
            const SizedBox(height: 16),
            Wrap(
              spacing: 8,
              children: [
                if (characteristic.canRead) const Chip(label: Text('Read')),
                if (characteristic.canWrite) const Chip(label: Text('Write')),
                if (characteristic.canNotify) const Chip(label: Text('Notify')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

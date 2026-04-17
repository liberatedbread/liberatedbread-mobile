// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import '../models/device_characteristic.dart';

/// Detail view for a single BLE characteristic.
/// Shows the characteristic value prominently with metadata below.
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
            // UUID
            Text('UUID: ${characteristic.uuid}',
                style: const TextStyle(fontFamily: 'monospace')),
            const SizedBox(height: 16),

            // Value display
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Value',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 16)),
                    const SizedBox(height: 8),
                    Text('Hex: ${characteristic.hexValue}',
                        style: const TextStyle(fontFamily: 'monospace')),
                    if (characteristic.stringValue != null) ...[
                      const SizedBox(height: 4),
                      Text('String: ${characteristic.stringValue}'),
                    ],
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Properties
            const Text('Properties',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 8),
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

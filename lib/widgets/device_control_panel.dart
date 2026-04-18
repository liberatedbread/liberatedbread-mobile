// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import '../models/ble_discovered_service.dart';
import 'raw_characteristic_widget.dart';

/// Displays all services and characteristics for a connected device as a
/// raw GATT browser.
// TODO: match services against loaded device specs and render typed
// controls (toggles, sliders, gauges) instead of raw hex.
class DeviceControlPanel extends StatelessWidget {
  final String deviceId;
  final List<BleDiscoveredService> services;

  const DeviceControlPanel({
    super.key,
    required this.deviceId,
    required this.services,
  });

  @override
  Widget build(BuildContext context) {
    if (services.isEmpty) {
      return const Center(
        child: Text('No services found on this device.'),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: services.length,
      itemBuilder: (context, serviceIndex) {
        final service = services[serviceIndex];
        return _ServiceCard(
          deviceId: deviceId,
          service: service,
        );
      },
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final String deviceId;
  final BleDiscoveredService service;

  const _ServiceCard({
    required this.deviceId,
    required this.service,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: const Icon(Icons.account_tree),
        title: Text(
          _serviceDisplayName(service.uuid),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          service.uuid,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
        initiallyExpanded: true,
        children: service.characteristics.map((char) {
          return RawCharacteristicWidget(
            deviceId: deviceId,
            serviceUuid: service.uuid,
            characteristic: char,
          );
        }).toList(),
      ),
    );
  }

  String _serviceDisplayName(String uuid) {
    // Well-known BLE service names
    final lower = uuid.toLowerCase();
    if (lower.startsWith('0000180f')) return 'Battery Service';
    if (lower.startsWith('00001800')) return 'Generic Access';
    if (lower.startsWith('00001801')) return 'Generic Attribute';
    if (lower.startsWith('0000181a')) return 'Environmental Sensing';
    return 'Service';
  }
}

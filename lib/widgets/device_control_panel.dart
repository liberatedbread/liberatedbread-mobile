// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import '../providers/device_spec_match_provider.dart';
import 'raw_characteristic_widget.dart';
import 'typed_characteristic_widget.dart';

/// Displays the services/characteristics of a connected device. When the device
/// matches a bundled device spec, characteristics are rendered as typed
/// controls (command buttons, sliders, decoded values); anything unmatched
/// falls back to the raw GATT/hex browser.
class DeviceControlPanel extends ConsumerWidget {
  final String deviceId;
  final String deviceName;
  final List<BleDiscoveredService> services;

  const DeviceControlPanel({
    super.key,
    required this.deviceId,
    required this.deviceName,
    required this.services,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (services.isEmpty) {
      return const Center(
        child: Text('No services found on this device.'),
      );
    }

    // Normalize (lowercase) + sort the UUIDs so the family cache key is stable
    // regardless of discovery order/casing; the Rust matcher is already
    // case-insensitive, so this only affects the key's stability.
    final serviceUuids = [for (final s in services) normalizeUuid(s.uuid)]
      ..sort();

    // Collapse loading / error / no-match to null so the raw browser shows
    // immediately and is replaced in place once a spec match resolves.
    final match = ref
        .watch(matchedDeviceSpecProvider(
          SpecMatchRequest(deviceName: deviceName, serviceUuids: serviceUuids),
        ))
        .asData
        ?.value;

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: services.length,
      itemBuilder: (context, serviceIndex) {
        return _ServiceCard(
          deviceId: deviceId,
          service: services[serviceIndex],
          matched: match,
        );
      },
    );
  }
}

class _ServiceCard extends StatelessWidget {
  final String deviceId;
  final BleDiscoveredService service;
  final MatchedSpec? matched;

  const _ServiceCard({
    required this.deviceId,
    required this.service,
    required this.matched,
  });

  @override
  Widget build(BuildContext context) {
    final specService = matched == null
        ? null
        : findServiceForUuid(matched!.spec, service.uuid);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: ExpansionTile(
        leading: const Icon(Icons.account_tree),
        title: Text(
          specService?.name ?? _serviceDisplayName(service.uuid),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text(
          service.uuid,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
        ),
        initiallyExpanded: true,
        children: service.characteristics.map((char) {
          final specChar = specService == null
              ? null
              : findCharForUuid(specService, char.uuid);
          if (matched != null && specChar != null) {
            return TypedCharacteristicWidget(
              deviceId: deviceId,
              serviceUuid: service.uuid,
              specYaml: matched!.yaml,
              specChar: specChar,
              discovered: char,
            );
          }
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
    // Well-known BLE service names.
    final lower = normalizeUuid(uuid);
    if (lower.startsWith('0000180f')) return 'Battery Service';
    if (lower.startsWith('00001800')) return 'Generic Access';
    if (lower.startsWith('00001801')) return 'Generic Attribute';
    if (lower.startsWith('0000181a')) return 'Environmental Sensing';
    return 'Service';
  }
}

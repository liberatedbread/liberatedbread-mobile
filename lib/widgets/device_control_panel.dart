// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import '../providers/device_spec_match_provider.dart';
import '../providers/spec_choice_provider.dart';
import '../services/spec_codec.dart';
import 'entity_sensor_card.dart';
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

    // Collapse loading / error to null so the raw browser shows immediately
    // and is replaced in place once a spec match resolves.
    final outcome = ref
        .watch(matchedDeviceSpecProvider(
          SpecMatchRequest(
            deviceId: deviceId,
            deviceName: deviceName,
            serviceUuids: serviceUuids,
          ),
        ))
        .asData
        ?.value;
    final match = outcome?.chosen;

    // Entities the spec declares, paired with the discovered service that
    // actually carries them. An entity whose characteristic was not discovered
    // on this device is dropped: the spec may describe a variant with more
    // hardware than the unit in front of us.
    final readings = <({EntityDto entity, String serviceUuid})>[];
    for (final entity in match?.spec.entities ?? const <EntityDto>[]) {
      // Only sensors render as readings; `light`/`switch` entities are control
      // surfaces and still come through the typed command widgets below.
      if (entity.platform != null && entity.platform != 'sensor') continue;
      final owning = services.where(
        (s) => s.characteristics.any(
          (c) =>
              normalizeUuid(c.uuid) ==
              normalizeUuid(entity.stateCharacteristic),
        ),
      );
      if (owning.isEmpty) continue;
      readings.add((entity: entity, serviceUuid: owning.first.uuid));
    }

    // Leading slots above the raw service list: the spec chooser when several
    // specs tie (raw controls stay usable below it), then any spec-declared
    // readings once a spec is chosen. Mutually exclusive today — no spec is
    // chosen while a choice is pending — but built as a list so that isn't
    // load-bearing.
    final leading = <Widget>[
      if (outcome != null && outcome.needsChoice)
        _SpecChoicePrompt(deviceId: deviceId, candidates: outcome.candidates),
      if (readings.isNotEmpty)
        _ReadingsSection(
          deviceId: deviceId,
          readings: readings,
          specYaml: match!.yaml,
        ),
    ];

    return ListView.builder(
      padding: const EdgeInsets.all(8),
      itemCount: services.length + leading.length,
      itemBuilder: (context, index) {
        if (index < leading.length) return leading[index];
        return _ServiceCard(
          deviceId: deviceId,
          service: services[index - leading.length],
          matched: match,
        );
      },
    );
  }
}

/// Asks the user which spec a device is when ranking cannot decide.
///
/// White-label hardware is why this state exists at all: several brands ship
/// the same GATT platform (identical service UUIDs), each with its own spec.
/// Guessing silently would pin another brand's name — and possibly command
/// set — to the device with nothing telling the user. The choice is stored
/// per device id ([specChoicesProvider]) and honored on future connections;
/// the raw GATT browser stays available below while the question is open.
class _SpecChoicePrompt extends ConsumerWidget {
  final String deviceId;
  final List<MatchedSpec> candidates;

  const _SpecChoicePrompt({required this.deviceId, required this.candidates});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.help_outline, color: scheme.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Which device is this?',
                    style:
                        text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '${candidates.length} device types match equally well — they '
              'share the same Bluetooth services. Pick one to get named '
              'controls; your choice is remembered for this device.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            for (final candidate in candidates)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 44),
                      alignment: Alignment.centerLeft,
                    ),
                    onPressed: () => ref
                        .read(specChoicesProvider.notifier)
                        .choose(deviceId, specKeyFor(candidate.spec)),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(candidate.spec.deviceName),
                        Text(
                          candidate.spec.manufacturer,
                          style: text.bodySmall
                              ?.copyWith(color: scheme.onSurfaceVariant),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Spec-declared readings, shown above the raw GATT services.
///
/// These come straight from the spec's `entities:` block, so a device gains a
/// named, unit-labelled reading purely by its spec being vendored — no
/// per-device code.
class _ReadingsSection extends StatelessWidget {
  final String deviceId;
  final List<({EntityDto entity, String serviceUuid})> readings;
  final String specYaml;

  const _ReadingsSection({
    required this.deviceId,
    required this.readings,
    required this.specYaml,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Readings',
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 10),
          for (final reading in readings) ...[
            EntitySensorCard(
              deviceId: deviceId,
              serviceUuid: reading.serviceUuid,
              entity: reading.entity,
              specYaml: specYaml,
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
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

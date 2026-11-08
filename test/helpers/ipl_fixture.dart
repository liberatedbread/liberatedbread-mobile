// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

DeviceSpecDto iplSpec(String handler) => DeviceSpecDto(
  deviceName: 'Test IPL',
  manufacturer: 'Test manufacturer',
  manufacturerStatus: 'active',
  protocol: 'ble',
  category: 'personal_care',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  nameMatchers: const [],
  txtMatchGroups: const [],
  platformFallbackTypes: const [],
  services: const [],
  protocolHandler: handler,
  entities: const [],
  hiddenEntityNames: const [],
);

List<BleDiscoveredService> iplDiscovered(Iterable<String> charUuids) => [
  BleDiscoveredService(
    uuid: 'actual-service',
    characteristics: [
      for (final uuid in charUuids)
        BleDiscoveredCharacteristic(
          uuid: uuid,
          canRead: true,
          canWrite: true,
          canNotify: true,
        ),
    ],
  ),
];

DecodedValueDto decodedInt(String name, int value) => DecodedValueDto(
  name: name,
  valueType: 'uint',
  display: '$value',
  uintValue: value,
  rawNumber: value.toDouble(),
  decodedNumber: value.toDouble(),
  decodedText: '$value',
  decimals: 0,
);

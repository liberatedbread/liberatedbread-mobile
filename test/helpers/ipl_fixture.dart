// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';
import 'dart:typed_data';

import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

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

const foreoCommandChar = '0000fff1-0000-1000-8000-00805f9b34fb';
const foreoSwRevisionChar = '00002a28-0000-1000-8000-00805f9b34fb';

/// A FOREO answering FFF1 the way the replayed F.REV.K unit did: each write
/// is read back as an 18-byte reply, 01-led for an accepted setting, the mode
/// byte for a 0BD0 query. Which command was written is taken from the spec
/// codec's encode log, since the fake codec's bytes are canned.
class FakeForeoBle extends FakeBleService {
  final FakeSpecCodec specCodec;

  /// Removal mode as the unit holds it: 01 Basic, 06 Pro.
  int mode;

  /// Busy (all-FF) replies to hand out before answering normally.
  int busyReplies;

  /// When false, settings writes are acknowledged but not applied.
  bool applies;

  FakeForeoBle({
    required this.specCodec,
    String swRevision = 'PEACH2 F.REV.K',
    this.mode = 0x01,
    this.busyReplies = 0,
    this.applies = true,
    Map<String, List<int>> extraReads = const {},
  }) : super(
         readValues: {
           foreoSwRevisionChar: utf8.encode(swRevision),
           '00000a20-0000-1000-8000-00805f9b34fb': const [0x01, 0x12, 0x34],
           ...extraReads,
         },
       );

  List<int> _reply(int first) => [first, ...List.filled(17, 0)];

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    await super.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
    if (charUuid.toLowerCase() != foreoCommandChar) return;
    if (busyReplies > 0) {
      busyReplies--;
      readValues[foreoCommandChar] = List.filled(18, 0xFF);
      return;
    }
    switch (specCodec.encodeCalls.last.commandName) {
      case 'get_removal_mode':
        readValues[foreoCommandChar] = _reply(mode);
      case 'set_removal_mode_pro':
        if (applies) mode = 0x06;
        readValues[foreoCommandChar] = _reply(0x01);
      case 'set_removal_mode_basic':
        if (applies) mode = 0x01;
        readValues[foreoCommandChar] = _reply(0x01);
    }
  }
}

/// [iplSpec] carrying the spec's FFF1 Pro command and its warning.
DeviceSpecDto foreoSpec({String? proWarning}) {
  final base = iplSpec('ipl_foreo');
  return DeviceSpecDto(
    deviceName: base.deviceName,
    manufacturer: base.manufacturer,
    manufacturerStatus: base.manufacturerStatus,
    protocol: base.protocol,
    category: base.category,
    localNamePrefixes: base.localNamePrefixes,
    localNames: base.localNames,
    serviceUuids: base.serviceUuids,
    companyIds: base.companyIds,
    macPrefixes: base.macPrefixes,
    mdnsServiceTypes: base.mdnsServiceTypes,
    ssdpSearchTargets: base.ssdpSearchTargets,
    lanProtocols: base.lanProtocols,
    nameMatchers: base.nameMatchers,
    txtMatchGroups: base.txtMatchGroups,
    platformFallbackTypes: base.platformFallbackTypes,
    services: [
      ServiceDto(
        uuid: '0000fff0-0000-1000-8000-00805f9b34fb',
        name: 'Command',
        characteristics: [
          CharacteristicDto(
            uuid: foreoCommandChar,
            name: 'Command channel',
            canRead: true,
            canWrite: true,
            canNotify: false,
            commands: [
              CommandDto(
                name: 'set_removal_mode_pro',
                description: 'Pro',
                parameters: const [],
                isFixed: true,
                isEncodable: true,
                advanced: true,
                advancedReason: proWarning,
              ),
            ],
            formatFields: const [],
          ),
        ],
      ),
    ],
    protocolHandler: 'ipl_foreo',
    entities: base.entities,
    hiddenEntityNames: base.hiddenEntityNames,
  );
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
import 'package:liberated_bread_mobile/core/stop_signal.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/group_runner.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

// A group read narrows a family spec to the variant the member matched, as
// the write path and the device screen do. Without it the first-declared
// variant's binding won, so a member of the second variant was read (and
// decoded) on the other model's characteristic.

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _charA = '0000fff1-0000-1000-8000-00805f9b34fb';
const _charB = '0000fff2-0000-1000-8000-00805f9b34fb';

EntityDto _entity(String variant, String char, {String? deviceClass}) =>
    EntityDto(
      options: const [],
      name: deviceClass == 'battery' ? 'Battery' : 'Temperature',
      platform: 'sensor',
      deviceClass: deviceClass,
      stateCharacteristic: char,
      canNotify: false,
      hasFormat: true,
      onWhenNonzero: false,
      actions: const [],
      variants: [variant],
    );

/// Two variants binding the same-named reading to different characteristics,
/// variant `a` declared first.
DeviceSpecDto _familySpec({String? deviceClass}) => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Family',
  manufacturer: 'Acme',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [_svc],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  services: const [],
  entities: [
    _entity('a', _charA, deviceClass: deviceClass),
    _entity('b', _charB, deviceClass: deviceClass),
  ],
);

const _service = BleDiscoveredService(
  uuid: _svc,
  characteristics: [
    BleDiscoveredCharacteristic(
      uuid: _charA,
      canRead: true,
      canWrite: false,
      canNotify: false,
    ),
    BleDiscoveredCharacteristic(
      uuid: _charB,
      canRead: true,
      canWrite: false,
      canNotify: false,
    ),
  ],
);

Future<FakeBleService> _run(GroupOp op, {String? deviceClass}) async {
  final ble = FakeBleService(servicesToReturn: const [_service]);
  final codec = FakeSpecCodec()..bleVariantNames = (_, _) => const ['b'];
  final runner = GroupRunner(ble: ble, codec: codec);
  final events = await runner.run(op, [
    GroupMember(
      id: 'M',
      name: 'M',
      spec: _familySpec(deviceClass: deviceClass),
      specYaml: 'y',
    ),
  ], stop: StopSignal()).toList();
  expect(events.last.status, GroupDeviceStatus.ok);
  return ble;
}

void main() {
  test('a sensor snapshot reads the matched variant binding', () async {
    final ble = await _run(GroupOp.readSensors);
    expect([for (final r in ble.reads) r.charUuid], [_charB]);
  });

  test('a battery read reads the matched variant binding', () async {
    final ble = await _run(GroupOp.readBattery, deviceClass: 'battery');
    expect([for (final r in ble.reads) r.charUuid], [_charB]);
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/device_setup_help_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

final _spec = DeviceSpecDto(
  deviceName: 'Ember Mug',
  manufacturer: 'Ember',
  manufacturerStatus: 'active',
  protocol: 'ble',
  category: 'appliance',
  localNamePrefixes: const ['Ember'],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List.fromList(const [961]),
  macPrefixes: const [],
  mdnsServiceType: null,
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: const [],
);

const _instructions = SetupInstructionsDto(
  notes: 'Turn it on.',
  methods: [
    SetupMethodDto(
      methodType: 'ble_direct',
      description: 'Pair over BLE.',
      steps: [
        SetupStepDto(action: 'Hold the button.', actor: 'user', expect: null),
      ],
      troubleshooting: [
        TroubleshootingDto(
          symptom: "Won't connect.",
          causes: ['Another phone holds the link.'],
        ),
      ],
    ),
  ],
  factoryReset: null,
  rejoin: RejoinDto(
    inPlaceSupported: true,
    requiresFactoryReset: false,
    notes: 'Close the other app.',
  ),
);

ScanMatch _match(
  MatchConfidence confidence, {
  int specIndex = 0,
  String deviceName = 'Ember Mug',
}) =>
    ScanMatch(
      specIndex: specIndex,
      deviceName: deviceName,
      manufacturer: 'Ember',
      category: 'appliance',
      pictogram: null,
      integration: null,
      securityAdvisory: null,
      confidence: confidence,
      matchedByNamePrefix: true,
      matchedServiceUuids: const [],
      matchedCompanyIds: Uint16List(0),
      matchedMacPrefix: null,
      matchedServiceTypes: const [],
    );

// IoTDevice.discoveredAt is required and non-null, so build it in a helper.
IoTDevice _dev() => IoTDevice(
      id: 'FF:34:1C:4D:71:62',
      name: 'Ember Ceramic Mug',
      rssi: -50,
      isConnectable: true,
      discoveredAt: DateTime(2026, 8, 19),
    );

ProviderContainer _container(FakeSpecCodec codec) {
  final c = ProviderContainer(overrides: [
    specCodecProvider.overrideWithValue(codec),
    deviceSpecsProvider.overrideWith((ref) => {'ember-mug.yaml': 'ember-yaml'}),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('a confident match with instructions yields the help', () async {
    final codec = FakeSpecCodec(
      spec: _spec,
      scanMatches: (_) => [_match(MatchConfidence.strong)],
    )..setupInstructionsFor = (_) => _instructions;
    final c = _container(codec);

    final help =
        await c.read(deviceSetupHelpProvider(ScanIdentity.of(_dev())).future);

    expect(help, isNotNull);
    expect(help!.deviceName, 'Ember Mug');
    expect(help.instructions.rejoin?.notes, 'Close the other app.');
    // Resolved the YAML the matcher's specIndex pointed at.
    expect(codec.setupInstructionsCalls, ['ember-yaml']);
  });

  test('a possible (OUI-only) match names no product, so no help is offered',
      () async {
    final codec = FakeSpecCodec(
      spec: _spec,
      scanMatches: (_) => [_match(MatchConfidence.possible)],
    )..setupInstructionsFor = (_) => _instructions;
    final c = _container(codec);

    final help =
        await c.read(deviceSetupHelpProvider(ScanIdentity.of(_dev())).future);

    expect(help, isNull);
    // Never even asked for the instructions: the guess did not name a product.
    expect(codec.setupInstructionsCalls, isEmpty);
  });

  test('a matched spec with no setup prose yields no help', () async {
    final codec = FakeSpecCodec(
      spec: _spec,
      scanMatches: (_) => [_match(MatchConfidence.strong)],
    )..setupInstructionsFor = (_) => null;
    final c = _container(codec);

    final help =
        await c.read(deviceSetupHelpProvider(ScanIdentity.of(_dev())).future);

    expect(help, isNull);
    expect(codec.setupInstructionsCalls, ['ember-yaml']);
  });

  test('no match at all yields no help', () async {
    final codec = FakeSpecCodec(
      spec: _spec,
      scanMatches: (_) => const [],
    )..setupInstructionsFor = (_) => _instructions;
    final c = _container(codec);

    final help =
        await c.read(deviceSetupHelpProvider(ScanIdentity.of(_dev())).future);

    expect(help, isNull);
  });

  test('an out-of-range specIndex is refused rather than throwing', () async {
    final codec = FakeSpecCodec(
      spec: _spec,
      scanMatches: (_) => [_match(MatchConfidence.strong, specIndex: 7)],
    )..setupInstructionsFor = (_) => _instructions;
    final c = _container(codec);

    final help =
        await c.read(deviceSetupHelpProvider(ScanIdentity.of(_dev())).future);

    expect(help, isNull);
  });
}

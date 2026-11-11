// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The list behind the Nearby tab's "Pairing a new device": every Bluetooth
// spec with pairing steps, and nothing a person could not usefully pair.
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_pairing_guide_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';
import '../helpers/host_rust_lib.dart';
import '../services/spec_catalogue_golden_test.dart' show bundledSpecs;

DeviceSpecDto _spec(
  String name, {
  String protocol = 'ble',
  List<String> namePrefixes = const [],
  List<String> serviceUuids = const [],
  List<int> companyIds = const [],
  List<String> mdnsTypes = const [],
  String? integration,
  SecurityAdvisoryDto? advisory,
  String manufacturer = 'Acme',
}) => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: name,
  manufacturer: manufacturer,
  manufacturerStatus: 'active',
  protocol: protocol,
  category: 'light',
  integration: integration,
  securityAdvisory: advisory,
  localNamePrefixes: namePrefixes,
  localNames: const [],
  serviceUuids: serviceUuids,
  companyIds: Uint16List.fromList(companyIds),
  macPrefixes: const [],
  mdnsServiceTypes: mdnsTypes,
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: const [],
);

SetupInstructionsDto _steps(String action) => SetupInstructionsDto(
  methods: [
    SetupMethodDto(
      methodType: 'ble_direct',
      stages: const [],
      steps: [SetupStepDto(action: action, actor: 'user')],
      troubleshooting: const [],
    ),
  ],
);

/// A setup block with a factory reset and nothing about pairing.
const _resetOnly = SetupInstructionsDto(
  methods: [],
  factoryReset: FactoryResetDto(
    effect: 'Wipes it.',
    procedures: [
      FactoryResetProcedureDto(
        name: 'Reset',
        steps: [SetupStepDto(action: 'Hold the button.', actor: 'user')],
      ),
    ],
  ),
);

ProviderContainer _container({
  required Map<String, DeviceSpecDto> specs,
  required SetupInstructionsDto? Function(String yaml) setup,
}) {
  final codec = FakeSpecCodec(specByYaml: specs)..setupInstructionsFor = setup;
  final c = ProviderContainer(
    overrides: [
      specCodecProvider.overrideWithValue(codec),
      // Keyed by the YAML itself so the fake's specByYaml can answer it.
      deviceSpecsProvider.overrideWith(
        (ref) => {for (final yaml in specs.keys) '$yaml.yaml': yaml},
      ),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  test('lists Bluetooth specs with pairing steps, sorted by name', () async {
    final c = _container(
      specs: {
        'zeta': _spec('Zeta Lamp', namePrefixes: const ['ZL']),
        'alpha': _spec('alpha mug', companyIds: const [961]),
        'mid': _spec('Mid Sensor', serviceUuids: const ['fce0']),
      },
      setup: (yaml) => _steps('Hold $yaml'),
    );

    final entries = await c.read(blePairingGuideProvider.future);

    // Case-insensitive: "alpha mug" sorts before "Mid Sensor".
    expect(entries.map((e) => e.deviceName), [
      'alpha mug',
      'Mid Sensor',
      'Zeta Lamp',
    ]);
    expect(
      entries.first.instructions.methods.single.steps.single.action,
      'Hold alpha',
    );
    expect(entries.first.manufacturer, 'Acme');
    expect(entries.first.category, 'light');
  });

  test('leaves out what a person could not usefully pair', () async {
    final c = _container(
      specs: {
        'ok': _spec('Real Bulb', namePrefixes: const ['RB']),
        // Found on Wi-Fi only: a Bluetooth scan can never see it.
        'wifi': _spec(
          'Wi-Fi Plug',
          protocol: 'wifi',
          mdnsTypes: const ['_plug._tcp'],
        ),
        'identify': _spec(
          'Named Only',
          namePrefixes: const ['NO'],
          integration: 'identify_only',
        ),
        'skimmer': _spec(
          'HC-05 Skimmer',
          namePrefixes: const ['HC-05'],
          advisory: const SecurityAdvisoryDto(
            severity: 'malicious',
            summary: 'Card skimmer',
          ),
        ),
        // A known but not-malicious issue is still a real product.
        'vulnerable': _spec(
          'Leaky Lock',
          namePrefixes: const ['LL'],
          advisory: const SecurityAdvisoryDto(
            severity: 'vulnerable',
            summary: 'Weak pairing',
          ),
        ),
        'reset': _spec('Reset Only', namePrefixes: const ['RO']),
        'none': _spec('No Setup', namePrefixes: const ['NS']),
      },
      setup: (yaml) => switch (yaml) {
        'reset' => _resetOnly,
        'none' => null,
        _ => _steps('Go'),
      },
    );

    final entries = await c.read(blePairingGuideProvider.future);

    expect(entries.map((e) => e.deviceName), ['Leaky Lock', 'Real Bulb']);
  });

  test('a pack copy that is now flagged hides the bundled copy too', () async {
    // Shadowing before filtering: a pack that corrects a spec to malicious
    // or identify_only must take the device out of the guide, not be
    // skipped so the stale bundled copy shows through.
    final c = _container(
      specs: {
        'bundled-skimmer': _spec('Sketchy Lock', namePrefixes: const ['SL']),
        'pack-skimmer': _spec(
          'Sketchy Lock',
          namePrefixes: const ['SL'],
          advisory: const SecurityAdvisoryDto(
            severity: 'malicious',
            summary: 'Card skimmer',
          ),
        ),
        'bundled-tag': _spec('Old Tag', namePrefixes: const ['OT']),
        'pack-tag': _spec(
          'Old Tag',
          namePrefixes: const ['OT'],
          integration: 'identify_only',
        ),
      },
      setup: (_) => _steps('Go'),
    );

    expect(await c.read(blePairingGuideProvider.future), isEmpty);
  });

  test('two makers with the same product name are both listed', () async {
    final c = _container(
      specs: {
        'a': _spec('LED Strip', namePrefixes: const ['A'], manufacturer: 'Zed'),
        'b': _spec(
          'LED Strip',
          namePrefixes: const ['B'],
          manufacturer: 'Acme',
        ),
      },
      setup: (yaml) => _steps('from $yaml'),
    );

    final entries = await c.read(blePairingGuideProvider.future);

    // Same name, ordered by maker.
    expect(entries.map((e) => e.manufacturer), ['Acme', 'Zed']);
  });

  test('a route that sends Wi-Fi details over Bluetooth is flagged', () async {
    final c = _container(
      specs: {
        'purifier': _spec('Purifier', namePrefixes: const ['P']),
        'bulb': _spec('Bulb', namePrefixes: const ['B']),
      },
      setup: (yaml) => SetupInstructionsDto(
        methods: [
          SetupMethodDto(
            methodType: yaml == 'purifier' ? 'ble_provisioning' : 'ble_direct',
            stages: const [],
            steps: const [SetupStepDto(action: 'Go', actor: 'user')],
            troubleshooting: const [],
          ),
        ],
      ),
    );

    final entries = await c.read(blePairingGuideProvider.future);

    expect(
      {for (final e in entries) e.deviceName: e.provisionsWifiOverBle},
      {'Bulb': false, 'Purifier': true},
    );
  });

  test('a later copy of a same-named spec shadows the earlier one', () async {
    // Catalogue order is the deviceSpecsProvider map's order: bundled first,
    // then an installed pack's correction.
    final c = _container(
      specs: {
        'bundled': _spec('Ember Mug', namePrefixes: const ['Ember']),
        'pack': _spec('Ember Mug', namePrefixes: const ['Ember']),
      },
      setup: (yaml) => _steps('from $yaml'),
    );

    final entries = await c.read(blePairingGuideProvider.future);

    expect(entries, hasLength(1));
    expect(
      entries.single.instructions.methods.single.steps.single.action,
      'from pack',
    );
  });

  test('hasPairingSteps wants a route, not just prose about resetting', () {
    expect(hasPairingSteps(_steps('Go')), isTrue);
    expect(hasPairingSteps(_resetOnly), isFalse);
    expect(
      hasPairingSteps(
        const SetupInstructionsDto(
          methods: [
            SetupMethodDto(
              description: '   ',
              stages: [],
              steps: [],
              troubleshooting: [],
            ),
          ],
        ),
      ),
      isFalse,
      reason: 'a blank description is no route',
    );
    expect(
      hasPairingSteps(
        const SetupInstructionsDto(
          methods: [
            SetupMethodDto(
              description: 'Pair it in the maker’s app first.',
              stages: [],
              steps: [],
              troubleshooting: [],
            ),
          ],
        ),
      ),
      isTrue,
    );
  });

  group('over the vendored catalogue', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test(
      'every protocol: ble spec with pairing steps is in the guide',
      () async {
        if (!await initHostRustLib()) {
          markTestSkipped('Rust lib not loaded');
          return;
        }
        final specs = await bundledSpecs();
        final codec = RealSpecCodec();
        final c = ProviderContainer(
          overrides: [
            specCodecProvider.overrideWithValue(codec),
            deviceSpecsProvider.overrideWith((ref) => specs),
          ],
        );
        addTearDown(c.dispose);

        final listed = {
          for (final e in await c.read(blePairingGuideProvider.future))
            e.deviceName,
        };
        expect(listed.length, greaterThan(50), reason: 'a vacuous guide');

        // The truth isBluetoothSpec stands in for: `device.protocol`, which
        // only the full DTO carries. A spec the guide should list and does
        // not means the identity projection has stopped carrying a BLE axis.
        final catalogue = await c.read(specCatalogueProvider.future);
        final missing = <String>[];
        for (final entry in catalogue.specs) {
          final dto = await catalogue.specAt(entry.index);
          if (dto.protocol != 'ble') continue;
          if (dto.integration == 'identify_only') continue;
          if (dto.securityAdvisory?.severity == 'malicious') continue;
          final setup = await codec.setupInstructions(entry.yaml);
          if (setup == null || !hasPairingSteps(setup)) continue;
          if (!listed.contains(dto.deviceName)) missing.add(entry.key);
        }
        expect(missing, isEmpty);
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}

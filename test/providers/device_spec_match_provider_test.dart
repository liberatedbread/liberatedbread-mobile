// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_spec_codec.dart';

const _svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
const _charUuid = '0000fff1-0000-1000-8000-00805f9b34fb';

const _spec = DeviceSpecDto(
  deviceName: 'Bulb',
  manufacturer: 'Acme',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  localNamePrefix: 'ACME_',
  serviceUuids: [_svcUuid],
  entities: <EntityDto>[],
  services: [
    ServiceDto(uuid: _svcUuid, name: 'Control Service', characteristics: [
      CharacteristicDto(
        uuid: _charUuid,
        name: 'Command',
        canRead: false,
        canWrite: true,
        canNotify: false,
        commands: [],
        formatFields: [],
      ),
    ]),
  ],
);

Future<ProviderContainer> _container(
  FakeSpecCodec codec,
  Map<String, String> specs, {
  Map<String, String> initialPrefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final prefs = await SharedPreferences.getInstance();
  final c = ProviderContainer(overrides: [
    sharedPreferencesProvider.overrideWithValue(prefs),
    specCodecProvider.overrideWithValue(codec),
    deviceSpecsProvider.overrideWith((ref) => specs),
  ]);
  addTearDown(c.dispose);
  return c;
}

SpecMatchRequest _req({
  String deviceId = 'AA:BB',
  String deviceName = 'ACME_X',
  List<String> serviceUuids = const [_svcUuid],
}) =>
    SpecMatchRequest(
      deviceId: deviceId,
      deviceName: deviceName,
      serviceUuids: serviceUuids,
    );

void main() {
  group('rank + evidence policy (pure)', () {
    const nameOnly = MatchResult(
      spec: _spec,
      matchedByNamePrefix: true,
      matchedServiceUuids: [],
    );
    const uuidOnly = MatchResult(
      spec: _spec,
      matchedByNamePrefix: false,
      matchedServiceUuids: [_svcUuid],
    );
    const corroborated = MatchResult(
      spec: _spec,
      matchedByNamePrefix: true,
      matchedServiceUuids: [_svcUuid],
    );

    test('evidence tiers order corroborated > uuidOnly > nameOnly', () {
      expect(matchEvidenceOf(corroborated), MatchEvidence.corroborated);
      expect(matchEvidenceOf(uuidOnly), MatchEvidence.uuidOnly);
      expect(matchEvidenceOf(nameOnly), MatchEvidence.nameOnly);

      final ranked = rankSpecMatches(
        [nameOnly, uuidOnly, corroborated],
        discoveredUuids: const [],
      );
      expect(ranked, [corroborated, uuidOnly, nameOnly]);
    });

    test(
        'a name-only match is dropped when the device carries none of the '
        'spec\'s GATT services (the short-prefix collision case)', () {
      // A device named e.g. "DNS-Widget" trips a two-letter prefix like "DN"
      // but demonstrably lacks the spec's GATT service: not a match. _spec's
      // services block declares _svcUuid, absent from what was discovered.
      const discovered = ['0000aaaa-0000-1000-8000-00805f9b34fb'];
      expect(
        isContradictedNameOnlyMatch(nameOnly, discoveredUuids: discovered),
        isTrue,
      );
      expect(
        rankSpecMatches([nameOnly], discoveredUuids: discovered),
        isEmpty,
      );
    });

    test(
        'a name-only match survives when the spec\'s GATT services ARE on '
        'the device (advertisement-only identification UUIDs)', () {
      // The Govee/Mi-Flora shape: identification.service_uuids carries an
      // advertisement service-data UUID that never appears in a GATT table,
      // so the UUID axis can't corroborate — but the spec's real GATT
      // services are present on the device. That is support, not
      // contradiction; the regression this pins is those devices silently
      // degrading to the raw browser.
      const advOnly = DeviceSpecDto(
        deviceName: 'Thermo',
        manufacturer: 'Govee-ish',
        manufacturerStatus: 'active',
        protocol: 'ble',
        localNamePrefix: 'GVH',
        // Advertisement service-data UUID, never a GATT service.
        serviceUuids: ['00008888-0000-1000-8000-00805f9b34fb'],
        entities: <EntityDto>[],
        services: [
          ServiceDto(uuid: _svcUuid, name: 'Real GATT', characteristics: []),
        ],
      );
      const match = MatchResult(
        spec: advOnly,
        matchedByNamePrefix: true,
        matchedServiceUuids: [], // the adv UUID matched nothing discovered
      );
      expect(
        isContradictedNameOnlyMatch(match, discoveredUuids: const [_svcUuid]),
        isFalse,
      );
      expect(
        rankSpecMatches([match], discoveredUuids: const [_svcUuid]),
        [match],
      );
    });

    test('a name-only match survives when the spec declares no services', () {
      const nameIsOnlyAxis = DeviceSpecDto(
        deviceName: 'NameOnly',
        manufacturer: 'X',
        manufacturerStatus: 'abandoned',
        protocol: 'ble',
        localNamePrefix: 'NAMEONLY_',
        serviceUuids: [],
        entities: <EntityDto>[],
        services: [],
      );
      const match = MatchResult(
        spec: nameIsOnlyAxis,
        matchedByNamePrefix: true,
        matchedServiceUuids: [],
      );
      expect(
        isContradictedNameOnlyMatch(match, discoveredUuids: const ['1234']),
        isFalse,
      );
      expect(
        rankSpecMatches([match], discoveredUuids: const ['1234']),
        [match],
      );
    });

    test('a name-only match survives when nothing was discovered', () {
      // No discovered services = no evidence against the name.
      expect(
        isContradictedNameOnlyMatch(nameOnly, discoveredUuids: const []),
        isFalse,
      );
    });

    test('topTiedSpecMatches returns the leading equal-rank run', () {
      final ranked = rankSpecMatches(
        [corroborated, uuidOnly, corroborated],
        discoveredUuids: const [_svcUuid],
      );
      expect(topTiedSpecMatches(ranked), hasLength(2));
      expect(topTiedSpecMatches(const []), isEmpty);
    });
  });

  test('returns the best match with its source yaml', () async {
    final codec = FakeSpecCodec(
      spec: _spec,
      matches: const [
        MatchResult(
          spec: _spec,
          matchedByNamePrefix: true,
          matchedServiceUuids: [_svcUuid],
        ),
      ],
    );
    final c = await _container(codec, const {'bulb.yaml': 'dummy-yaml'});

    final r = await c.read(matchedDeviceSpecProvider(_req()).future);

    expect(r.source, SpecChoiceSource.auto);
    expect(r.chosen, isNotNull);
    expect(r.chosen!.spec.deviceName, 'Bulb');
    expect(r.chosen!.yaml, 'dummy-yaml');
  });

  test('corroborated (name + uuid) beats uuid-only with more matched uuids',
      () async {
    const other = DeviceSpecDto(
      deviceName: 'Other',
      manufacturer: 'X',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      serviceUuids: [_svcUuid],
      entities: <EntityDto>[],
      services: [],
    );
    final codec = FakeSpecCodec(
      spec: _spec,
      matches: const [
        MatchResult(
          spec: other,
          matchedByNamePrefix: false,
          matchedServiceUuids: [_svcUuid, _charUuid],
        ),
        MatchResult(
          spec: _spec,
          matchedByNamePrefix: true,
          matchedServiceUuids: [_svcUuid],
        ),
      ],
    );
    final c = await _container(codec, const {'bulb.yaml': 'dummy-yaml'});

    final r = await c.read(matchedDeviceSpecProvider(_req()).future);

    expect(r.chosen!.spec.deviceName, 'Bulb');
  });

  test('uuid evidence beats a bare name-prefix match', () async {
    // The regression this pins: a device whose GATT matched spec A must not
    // be claimed by spec B on the strength of a short name prefix alone.
    const byUuid = DeviceSpecDto(
      deviceName: 'RightOne',
      manufacturer: 'X',
      manufacturerStatus: 'active',
      protocol: 'ble',
      serviceUuids: [_svcUuid],
      entities: <EntityDto>[],
      services: [],
    );
    // Declares no UUIDs, so its name match is not contradicted — it still
    // must rank below hard GATT evidence.
    const byName = DeviceSpecDto(
      deviceName: 'NameGrabber',
      manufacturer: 'Y',
      manufacturerStatus: 'active',
      protocol: 'ble',
      localNamePrefix: 'AC',
      serviceUuids: [],
      entities: <EntityDto>[],
      services: [],
    );
    final codec = FakeSpecCodec(
      specByYaml: const {'yaml-right': byUuid, 'yaml-name': byName},
      matches: const [
        MatchResult(
          spec: byName,
          matchedByNamePrefix: true,
          matchedServiceUuids: [],
        ),
        MatchResult(
          spec: byUuid,
          matchedByNamePrefix: false,
          matchedServiceUuids: [_svcUuid],
        ),
      ],
    );
    final c = await _container(
        codec, const {'right': 'yaml-right', 'name': 'yaml-name'});

    final r = await c.read(matchedDeviceSpecProvider(_req()).future);

    expect(r.chosen!.spec.deviceName, 'RightOne');
    expect(r.chosen!.yaml, 'yaml-right');
  });

  test(
      'a name-prefix collision alone yields no match when the device lacks '
      'the spec\'s services', () async {
    final codec = FakeSpecCodec(
      spec: _spec,
      matches: const [
        MatchResult(
          spec: _spec, // declares _svcUuid
          matchedByNamePrefix: true,
          matchedServiceUuids: [], // ...but the device doesn't carry it
        ),
      ],
    );
    final c = await _container(codec, const {'bulb.yaml': 'dummy-yaml'});

    final r = await c.read(matchedDeviceSpecProvider(
      _req(deviceName: 'ACME_lookalike', serviceUuids: const ['1234']),
    ).future);

    expect(r.source, SpecChoiceSource.none);
    expect(r.chosen, isNull);
  });

  test('two specs tying on evidence ask the user instead of guessing',
      () async {
    const brandA = DeviceSpecDto(
      deviceName: 'Brand A Lights',
      manufacturer: 'A',
      manufacturerStatus: 'active',
      protocol: 'ble',
      serviceUuids: [_svcUuid],
      entities: <EntityDto>[],
      services: [],
    );
    const brandB = DeviceSpecDto(
      deviceName: 'Brand B Lights',
      manufacturer: 'B',
      manufacturerStatus: 'active',
      protocol: 'ble',
      serviceUuids: [_svcUuid],
      entities: <EntityDto>[],
      services: [],
    );
    final codec = FakeSpecCodec(
      specByYaml: const {'yaml-a': brandA, 'yaml-b': brandB},
      matches: const [
        MatchResult(
          spec: brandA,
          matchedByNamePrefix: false,
          matchedServiceUuids: [_svcUuid],
        ),
        MatchResult(
          spec: brandB,
          matchedByNamePrefix: false,
          matchedServiceUuids: [_svcUuid],
        ),
      ],
    );
    final c = await _container(codec, const {'a': 'yaml-a', 'b': 'yaml-b'});

    final r = await c.read(matchedDeviceSpecProvider(
      _req(deviceName: 'Mystery'),
    ).future);

    expect(r.source, SpecChoiceSource.prompt);
    expect(r.needsChoice, isTrue);
    expect(r.chosen, isNull);
    expect(
      r.candidates.map((m) => m.spec.deviceName),
      ['Brand A Lights', 'Brand B Lights'],
    );
    // Each candidate carries its own yaml so choosing one can encode commands.
    expect(r.candidates.map((m) => m.yaml), ['yaml-a', 'yaml-b']);
  });

  test('a saved user choice resolves a tie and is marked as such', () async {
    const brandA = DeviceSpecDto(
      deviceName: 'Brand A Lights',
      manufacturer: 'A',
      manufacturerStatus: 'active',
      protocol: 'ble',
      serviceUuids: [_svcUuid],
      entities: <EntityDto>[],
      services: [],
    );
    const brandB = DeviceSpecDto(
      deviceName: 'Brand B Lights',
      manufacturer: 'B',
      manufacturerStatus: 'active',
      protocol: 'ble',
      serviceUuids: [_svcUuid],
      entities: <EntityDto>[],
      services: [],
    );
    final codec = FakeSpecCodec(
      specByYaml: const {'yaml-a': brandA, 'yaml-b': brandB},
      matches: const [
        MatchResult(
          spec: brandA,
          matchedByNamePrefix: false,
          matchedServiceUuids: [_svcUuid],
        ),
        MatchResult(
          spec: brandB,
          matchedByNamePrefix: false,
          matchedServiceUuids: [_svcUuid],
        ),
      ],
    );
    final c = await _container(
      codec,
      const {'a': 'yaml-a', 'b': 'yaml-b'},
      initialPrefs: {
        'spec_choices_v1': jsonEncode({'AA:BB': specKeyFor(brandB)}),
      },
    );

    final r = await c.read(matchedDeviceSpecProvider(
      _req(deviceName: 'Mystery'),
    ).future);

    expect(r.source, SpecChoiceSource.saved);
    expect(r.chosen!.spec.deviceName, 'Brand B Lights');
    expect(r.chosen!.yaml, 'yaml-b');
  });

  test('a stale saved choice is ignored and ranking proceeds', () async {
    final codec = FakeSpecCodec(
      spec: _spec,
      matches: const [
        MatchResult(
          spec: _spec,
          matchedByNamePrefix: true,
          matchedServiceUuids: [_svcUuid],
        ),
      ],
    );
    final c = await _container(
      codec,
      const {'bulb.yaml': 'dummy-yaml'},
      initialPrefs: {
        'spec_choices_v1': jsonEncode({'AA:BB': 'Gone Spec|Nobody'}),
      },
    );

    final r = await c.read(matchedDeviceSpecProvider(_req()).future);

    expect(r.source, SpecChoiceSource.auto);
    expect(r.chosen!.spec.deviceName, 'Bulb');
  });

  test('none when nothing matches', () async {
    final codec = FakeSpecCodec(spec: _spec, matches: const []);
    final c = await _container(codec, const {'bulb.yaml': 'dummy'});

    final r = await c.read(matchedDeviceSpecProvider(
      _req(deviceName: 'Nope', serviceUuids: const ['1234']),
    ).future);

    expect(r.source, SpecChoiceSource.none);
    expect(r.chosen, isNull);
  });

  test('none when the codec is unavailable (native absent)', () async {
    final codec = FakeSpecCodec(loadError: StateError('no native lib'));
    final c = await _container(codec, const {'bulb.yaml': 'dummy'});

    final r = await c.read(matchedDeviceSpecProvider(_req()).future);

    expect(r.source, SpecChoiceSource.none);
    expect(r.chosen, isNull);
  });

  test('associates the winning spec with its own yaml, not parsed.first',
      () async {
    const svcA = '0000aaa0-0000-1000-8000-00805f9b34fb';
    const svcB = '0000bbb0-0000-1000-8000-00805f9b34fb';
    const specA = DeviceSpecDto(
      deviceName: 'Alpha',
      manufacturer: 'A',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      localNamePrefix: 'ALPHA_',
      serviceUuids: [svcA],
      entities: <EntityDto>[],
      services: [],
    );
    const specB = DeviceSpecDto(
      deviceName: 'Beta',
      manufacturer: 'B',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      localNamePrefix: 'BETA_',
      serviceUuids: [svcB],
      entities: <EntityDto>[],
      services: [],
    );
    // A separate, non-const instance with the same content as specB, simulating
    // the FFI round-trip. The generated `DeviceSpecDto ==` compares lists by
    // reference, so this does NOT `==` specB (what the old lookup relied on);
    // the runtime List.of keeps it a distinct instance.
    final specBRoundTrip = DeviceSpecDto(
      deviceName: 'Beta',
      manufacturer: 'B',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      localNamePrefix: 'BETA_',
      serviceUuids: List<String>.of(const [svcB]),
      entities: <EntityDto>[],
      services: const [],
    );

    final codec = FakeSpecCodec(
      specByYaml: const {'yaml-a': specA, 'yaml-b': specB},
      matches: [
        MatchResult(
          spec: specBRoundTrip,
          matchedByNamePrefix: true,
          matchedServiceUuids: const [svcB],
        ),
      ],
    );
    final c = await _container(codec, const {'a': 'yaml-a', 'b': 'yaml-b'});

    final r = await c.read(matchedDeviceSpecProvider(
      _req(deviceName: 'BETA_1', serviceUuids: const [svcB]),
    ).future);

    expect(r.chosen!.spec.deviceName, 'Beta');
    expect(r.chosen!.yaml, 'yaml-b');
  });
}

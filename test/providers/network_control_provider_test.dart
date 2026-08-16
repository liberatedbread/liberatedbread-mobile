// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// networkControlsProvider: matched spec → declared controls, or null. Null is
// the load-bearing answer — it is what keeps a hub or a printer on the plain
// details sheet instead of a control screen with nothing on it.

import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

DeviceSpecDto _spec(String name, String manufacturer) => DeviceSpecDto(
      deviceName: name,
      manufacturer: manufacturer,
      manufacturerStatus: 'shutdown',
      protocol: 'wifi',
      localNamePrefixes: const [],
      localNames: const [],
      serviceUuids: const [],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceType: null,
      ssdpSearchTargets: const ['urn:Belkin:service:basicevent:1'],
      lanProtocols: const [],
      defaultPort: null,
      entities: const [],
      services: const [],
    );

const _plugEntity = NetworkEntityDto(
  isInstanced: false,
  name: 'Plug',
  platform: 'switch',
  stateCommand: 'GetBinaryState',
  options: [],
  actions: [],
);

ProviderContainer _container(
  FakeSpecCodec codec, {
  required List<({DeviceSpecDto spec, String yaml})> parsed,
}) {
  final container = ProviderContainer(overrides: [
    specCodecProvider.overrideWithValue(codec),
    parsedDeviceSpecsProvider.overrideWith((ref) async => parsed),
  ]);
  addTearDown(container.dispose);
  return container;
}

const _request = NetworkControlRequest(
  deviceName: 'Belkin Wemo Smart Devices',
  manufacturer: 'Belkin',
  ssdpTargets: ['urn:Belkin:device:crockpot:1'],
);

void main() {
  test('resolves the matched spec and its declared controls', () async {
    late List<String> asked;
    final codec = FakeSpecCodec(networkEntities: (targets) {
      asked = targets;
      return const [_plugEntity];
    });
    final container = _container(codec, parsed: [
      (spec: _spec('Belkin Wemo Smart Devices', 'Belkin'), yaml: 'wemo-yaml'),
      (spec: _spec('Hue Bridge', 'Signify'), yaml: 'hue-yaml'),
    ]);

    final controls =
        await container.read(networkControlsProvider(_request).future);

    expect(controls, isNotNull);
    expect(controls!.specYaml, 'wemo-yaml');
    expect(controls.entities.single.name, 'Plug');
    // The device's own SSDP answers reach the codec — they are what narrow a
    // family spec to the model actually found.
    expect(asked, ['urn:Belkin:device:crockpot:1']);
  });

  test('a spec declaring no network entities resolves to null', () async {
    final codec = FakeSpecCodec(networkEntities: (_) => const []);
    final container = _container(codec, parsed: [
      (spec: _spec('Hue Bridge', 'Signify'), yaml: 'hue-yaml'),
    ]);

    final controls = await container.read(networkControlsProvider(
      const NetworkControlRequest(
        deviceName: 'Hue Bridge',
        manufacturer: 'Signify',
        ssdpTargets: [],
      ),
    ).future);

    expect(controls, isNull);
  });

  test('an unmatched device resolves to null without asking the codec',
      () async {
    var askedCodec = false;
    final codec = FakeSpecCodec(networkEntities: (_) {
      askedCodec = true;
      return const [_plugEntity];
    });
    final container = _container(codec, parsed: [
      (spec: _spec('Hue Bridge', 'Signify'), yaml: 'hue-yaml'),
    ]);

    final controls =
        await container.read(networkControlsProvider(_request).future);

    expect(controls, isNull);
    expect(askedCodec, isFalse);
  });

  test('a codec failure degrades to null, never an error', () async {
    // The provider is watched from inside the scan list; a throw here would
    // break the tile that asked, for a device that only needed the sheet.
    final codec = FakeSpecCodec(
        networkEntities: (_) => throw StateError('native codec unavailable'));
    final container = _container(codec, parsed: [
      (spec: _spec('Belkin Wemo Smart Devices', 'Belkin'), yaml: 'wemo-yaml'),
    ]);

    final controls =
        await container.read(networkControlsProvider(_request).future);
    expect(controls, isNull);
  });

  test('requests are value-equal so the family caches per device', () {
    const a = NetworkControlRequest(
        deviceName: 'X', manufacturer: 'Y', ssdpTargets: ['t']);
    const b = NetworkControlRequest(
        deviceName: 'X', manufacturer: 'Y', ssdpTargets: ['t']);
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(
      a,
      isNot(const NetworkControlRequest(
          deviceName: 'X', manufacturer: 'Y', ssdpTargets: ['other'])),
    );
  });
}

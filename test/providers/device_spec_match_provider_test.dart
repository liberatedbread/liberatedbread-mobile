// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/providers/device_spec_match_provider.dart';
import 'package:opengreeniot_mobile/providers/device_spec_provider.dart';
import 'package:opengreeniot_mobile/providers/spec_codec_provider.dart';
import 'package:opengreeniot_mobile/services/spec_codec.dart';

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

ProviderContainer _container(FakeSpecCodec codec, Map<String, String> specs) {
  final c = ProviderContainer(overrides: [
    specCodecProvider.overrideWithValue(codec),
    deviceSpecsProvider.overrideWith((ref) => specs),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
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
    final c = _container(codec, const {'bulb.yaml': 'dummy-yaml'});

    final r = await c.read(matchedDeviceSpecProvider(
      const SpecMatchRequest(deviceName: 'ACME_X', serviceUuids: [_svcUuid]),
    ).future);

    expect(r, isNotNull);
    expect(r!.spec.deviceName, 'Bulb');
    expect(r.yaml, 'dummy-yaml');
  });

  test('prefers name-prefix match over more service-uuid matches', () async {
    const other = DeviceSpecDto(
      deviceName: 'Other',
      manufacturer: 'X',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      serviceUuids: [_svcUuid],
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
    final c = _container(codec, const {'bulb.yaml': 'dummy-yaml'});

    final r = await c.read(matchedDeviceSpecProvider(
      const SpecMatchRequest(deviceName: 'ACME_X', serviceUuids: [_svcUuid]),
    ).future);

    expect(r!.spec.deviceName, 'Bulb');
  });

  test('null when nothing matches', () async {
    final codec = FakeSpecCodec(spec: _spec, matches: const []);
    final c = _container(codec, const {'bulb.yaml': 'dummy'});

    final r = await c.read(matchedDeviceSpecProvider(
      const SpecMatchRequest(deviceName: 'Nope', serviceUuids: ['1234']),
    ).future);

    expect(r, isNull);
  });

  test('null when the codec is unavailable (native absent)', () async {
    final codec = FakeSpecCodec(loadError: StateError('no native lib'));
    final c = _container(codec, const {'bulb.yaml': 'dummy'});

    final r = await c.read(matchedDeviceSpecProvider(
      const SpecMatchRequest(deviceName: 'ACME_X', serviceUuids: [_svcUuid]),
    ).future);

    expect(r, isNull);
  });
}

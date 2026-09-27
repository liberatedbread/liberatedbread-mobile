// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The providers that put the Linux direct-ATT router under flutter_blue_plus
// and hand it the spec catalogue's say — wired as the app wires them, over
// the routed stack (test/fakes/routed_ble.dart), so a saved laser meter whose
// spec marks it BlueZ-incompatible is connected direct the first time.

import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/emulated_ble.dart';
import '../fakes/fake_att_channel.dart';
import '../fakes/fake_spec_codec.dart';
import '../fakes/routed_ble.dart';

const _meterId = '18:7A:93:12:DE:94';

final _meterSpec = DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Laser Distance Meter',
  manufacturer: 'Johnson',
  manufacturerStatus: 'active',
  protocol: 'ble',
  localNamePrefixes: const ['Laser Distance Meter'],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: const [],
  bluezRawAtt: true,
);

void main() {
  late RoutedBle rig;

  setUpAll(() {
    rig = RoutedBle.install();
  });

  setUp(() async {
    await rig.reset();
  });

  Future<ProviderContainer> container({bool disposeAfter = true}) async {
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1': jsonEncode([
        {
          'id': _meterId,
          'name': 'Laser Distance Meter',
          'lastSeen': '2026-09-26T00:00:00.000',
          'specKey': 'Laser Distance Meter|Johnson',
        },
      ]),
    });
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        specCodecProvider.overrideWithValue(
          FakeSpecCodec(specByYaml: {'meter-yaml': _meterSpec}),
        ),
        deviceSpecsProvider.overrideWith((ref) => {'meter.yaml': 'meter-yaml'}),
      ],
    );
    if (disposeAfter) addTearDown(c.dispose);
    return c;
  }

  test(
    'the router is installed ahead of the service and asks the catalogue',
    skip: !Platform.isLinux,
    () async {
      final c = await container();

      final ble = c.read(bleServiceProvider);

      expect(ble, isA<RealBleService>());
      expect(c.read(directAttRouterProvider), same(rig.router));
      expect(rig.router.routeHint, isNotNull);
    },
  );

  test(
    'a saved device its spec marks BlueZ-incompatible goes direct at once',
    skip: !Platform.isLinux,
    () async {
      rig.ble.add(EmulatedPeripheral.bulb(id: _meterId));
      rig.channels.peripherals[_meterId] = FakeAttPeripheral.ldm330();
      final c = await container();
      final ble = c.read(bleServiceProvider);

      await ble.connect(_meterId);
      final services = await ble.discoverServices(_meterId);

      expect(rig.registry.isDeclared(_meterId), isTrue);
      expect(rig.ble.platformCalls, isNot(contains('connect:$_meterId')));
      expect(services, isNotEmpty);
      await ble.disconnect(_meterId);
    },
  );

  test(
    'disposing the container takes its hint back from the process-wide router',
    skip: !Platform.isLinux,
    () async {
      final c = await container(disposeAfter: false);
      c.read(bleServiceProvider);
      expect(rig.router.routeHint, isNotNull);

      c.dispose();

      expect(rig.router.routeHint, isNull);
    },
  );
}

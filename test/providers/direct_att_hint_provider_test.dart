// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// specDeclaresDirectAttProvider: when the spec catalogue says a device is one
// BlueZ's GATT client cannot drive (a spec's device.host_compatibility, as
// the identity's bluezRawAtt), so the Linux router takes it direct from its
// first connection. The policy only — the router side is in
// test/services/direct_att/direct_att_router_test.dart, the wiring in
// direct_att_router_provider_test.dart.

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/direct_att_hint_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_spec_codec.dart';

const _meterId = '18:7A:93:12:DE:94';
const _meterKey = 'Laser Distance Meter|Johnson';
const _bulbKey = 'Example Smart Bulb|Acme';

DeviceSpecDto _spec(String name, String manufacturer, {bool? bluezRawAtt}) =>
    DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
      deviceName: name,
      manufacturer: manufacturer,
      manufacturerStatus: 'active',
      protocol: 'ble',
      localNamePrefixes: [name],
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
      bluezRawAtt: bluezRawAtt,
    );

final _meter = _spec('Laser Distance Meter', 'Johnson', bluezRawAtt: true);
final _bulb = _spec('Example Smart Bulb', 'Acme');

ScanMatch _match(
  DeviceSpecDto spec, {
  MatchConfidence confidence = MatchConfidence.strong,
  int specIndex = 0,
}) => ScanMatch(
  specIndex: specIndex,
  deviceName: spec.deviceName,
  manufacturer: spec.manufacturer,
  confidence: confidence,
  matchedByNamePrefix: true,
  matchedServiceUuids: const [],
  matchedCompanyIds: Uint16List(0),
  matchedMacPrefix: null,
  matchedServiceTypes: const [],
  bluezRawAtt: spec.bluezRawAtt,
);

void main() {
  late FakeSpecCodec codec;

  Future<ProviderContainer> container({
    List<ScanMatch> Function(ScannedDeviceDto device)? scanMatches,
    List<Map<String, Object?>> saved = const [],
    Map<String, String> choices = const {},
  }) async {
    SharedPreferences.setMockInitialValues({
      if (saved.isNotEmpty) 'saved_devices_v1': jsonEncode(saved),
      if (choices.isNotEmpty) 'spec_choices_v1': jsonEncode(choices),
    });
    final prefs = await SharedPreferences.getInstance();
    codec = FakeSpecCodec(
      specByYaml: {'meter-yaml': _meter, 'bulb-yaml': _bulb},
      scanMatches: scanMatches,
    );
    final c = ProviderContainer(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        specCodecProvider.overrideWithValue(codec),
        deviceSpecsProvider.overrideWith(
          (ref) => {'meter.yaml': 'meter-yaml', 'bulb.yaml': 'bulb-yaml'},
        ),
      ],
    );
    addTearDown(c.dispose);
    return c;
  }

  Map<String, Object?> savedDevice({String name = 'Meter', String? specKey}) =>
      {
        'id': _meterId,
        'name': name,
        'lastSeen': '2026-09-26T00:00:00.000',
        'specKey': ?specKey,
      };

  Future<bool> ask(
    ProviderContainer c, {
    ({String name, List<String> serviceUuids, List<int> companyIds})? seen,
  }) => c.read(specDeclaresDirectAttProvider)(_meterId, seen);

  const sighting = (
    name: 'Laser Distance Meter',
    serviceUuids: <String>['0000f150-0000-1000-8000-00805f9b34fb'],
    companyIds: <int>[],
  );

  group('a spec the app already ties to the device decides', () {
    test('a saved device whose spec says so: yes, without matching', () async {
      final c = await container(saved: [savedDevice(specKey: _meterKey)]);

      expect(await ask(c), isTrue);
      expect(codec.scanMatchCalls, isEmpty);
    });

    test(
      'a saved device whose spec does not: no, whatever it advertises',
      () async {
        final c = await container(
          saved: [savedDevice(specKey: _bulbKey)],
          scanMatches: (_) => [_match(_meter)],
        );

        expect(await ask(c, seen: sighting), isFalse);
      },
    );

    test("the user's own spec choice wins over the saved one", () async {
      final c = await container(
        saved: [savedDevice(specKey: _bulbKey)],
        choices: {_meterId: _meterKey},
      );

      expect(await ask(c), isTrue);
    });

    test(
      'a saved key the catalogue no longer has falls through to matching',
      () async {
        final c = await container(
          saved: [savedDevice(specKey: 'Gone|Nobody')],
          scanMatches: (_) => [_match(_meter)],
        );

        expect(await ask(c, seen: sighting), isTrue);
      },
    );
  });

  group('otherwise, what it looks like', () {
    test(
      'an advertisement strongly matching a spec that says so: yes',
      () async {
        final c = await container(scanMatches: (_) => [_match(_meter)]);

        expect(await ask(c, seen: sighting), isTrue);
        expect(codec.scanMatchCalls.single.name, 'Laser Distance Meter');
        expect(codec.scanMatchCalls.single.serviceUuids, sighting.serviceUuids);
      },
    );

    test('a merely possible match (one shared OUI): no', () async {
      final c = await container(
        scanMatches: (_) => [
          _match(_meter, confidence: MatchConfidence.possible),
        ],
      );

      expect(await ask(c, seen: sighting), isFalse);
    });

    test('a tie with a spec that does not say so: no', () async {
      final c = await container(
        scanMatches: (_) => [_match(_meter), _match(_bulb, specIndex: 1)],
      );

      expect(await ask(c, seen: sighting), isFalse);
    });

    test(
      'a saved device opened without a scan is matched by its saved name',
      () async {
        // Saved while BlueZ stalled on it: a name, and no spec, because its
        // discovery found nothing to match.
        final c = await container(
          saved: [savedDevice(name: 'Laser Distance Meter')],
          scanMatches: (d) =>
              d.name == 'Laser Distance Meter' ? [_match(_meter)] : const [],
        );

        expect(await ask(c), isTrue);
      },
    );

    test('nothing known about it: no, and nothing is matched', () async {
      final c = await container(scanMatches: (_) => [_match(_meter)]);

      expect(await ask(c), isFalse);
      expect(codec.scanMatchCalls, isEmpty);
    });

    test('matching failing is a no, not an error', () async {
      final c = await container(
        scanMatches: (_) => throw StateError('codec down'),
      );

      expect(await ask(c, seen: sighting), isFalse);
    });
  });

  group('ScanGuess.bluezRawAtt', () {
    test('set when the best match and every tie agree', () {
      expect(ScanGuess.fromMatches([_match(_meter)])!.bluezRawAtt, isTrue);
      expect(
        ScanGuess.fromMatches([
          _match(_meter),
          _match(_meter, specIndex: 1),
        ])!.bluezRawAtt,
        isTrue,
      );
    });

    test('not set when a tie disagrees, or nothing says so', () {
      expect(
        ScanGuess.fromMatches([
          _match(_meter),
          _match(_bulb, specIndex: 1),
        ])!.bluezRawAtt,
        isFalse,
      );
      expect(ScanGuess.fromMatches([_match(_bulb)])!.bluezRawAtt, isFalse);
    });

    test('a trailing weaker match does not veto it', () {
      expect(
        ScanGuess.fromMatches([
          _match(_meter),
          _match(_bulb, confidence: MatchConfidence.possible, specIndex: 1),
        ])!.bluezRawAtt,
        isTrue,
      );
    });
  });
}

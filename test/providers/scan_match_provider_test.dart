// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

const _svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';

final _spec = DeviceSpecDto(
  deviceName: 'Example Smart Bulb',
  manufacturer: 'Acme',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  localNamePrefixes: const ['ACME_'],
  serviceUuids: const [_svcUuid],
  companyIds: Uint16List.fromList(const [961]),
  macPrefixes: const [
    MacPrefixDto(
      prefix: 'C4:7C:8D',
      confidence: MacPrefixConfidence.medium,
    ),
  ],
  mdnsServiceType: null,
  ssdpSearchTargets: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: const [],
);

ScanMatch _match(
  MatchConfidence confidence, {
  String deviceName = 'Example Smart Bulb',
  String manufacturer = 'Acme',
  int specIndex = 0,
}) =>
    ScanMatch(
      specIndex: specIndex,
      deviceName: deviceName,
      manufacturer: manufacturer,
      confidence: confidence,
      matchedByNamePrefix: false,
      matchedServiceUuids: const [],
      matchedCompanyIds: Uint16List(0),
      matchedMacPrefix: null,
      matchedServiceTypes: const [],
    );

IoTDevice _device({
  String id = 'AA:BB:CC:DD:EE:01',
  String name = 'ACME_Living_Room',
  int rssi = -50,
  List<String> serviceUuids = const [],
  List<int> companyIds = const [],
}) =>
    IoTDevice(
      id: id,
      name: name,
      rssi: rssi,
      isConnectable: true,
      discoveredAt: DateTime.now(),
      serviceUuids: serviceUuids,
      companyIds: companyIds,
    );

ProviderContainer _container(FakeSpecCodec codec) {
  final c = ProviderContainer(overrides: [
    specCodecProvider.overrideWithValue(codec),
    deviceSpecsProvider.overrideWith((ref) => {'bulb.yaml': 'dummy-yaml'}),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('specIdentitiesProvider', () {
    test('projects the identifying fields of every parsed spec', () async {
      final c = _container(FakeSpecCodec(spec: _spec));

      final identities = await c.read(specIdentitiesProvider.future);

      expect(identities, hasLength(1));
      expect(identities.single.deviceName, 'Example Smart Bulb');
      expect(identities.single.localNamePrefixes, const ['ACME_']);
      expect(identities.single.serviceUuids, const [_svcUuid]);
      expect(identities.single.companyIds, const [961]);
      expect(identities.single.macPrefixes, hasLength(1));
      expect(identities.single.macPrefixes.single.prefix, 'C4:7C:8D');
      expect(
        identities.single.macPrefixes.single.confidence,
        MacPrefixConfidence.medium,
        reason: 'the prefix must not lose its verdict on the way to matching',
      );
    });
  });

  group('scanGuessProvider', () {
    test('reports the best match', () async {
      final codec = FakeSpecCodec(
        spec: _spec,
        scanMatches: (_) => [_match(MatchConfidence.strong)],
      );
      final c = _container(codec);

      final guess =
          await c.read(scanGuessProvider(ScanIdentity.of(_device())).future);

      expect(guess, isNotNull);
      expect(guess!.confidence, MatchConfidence.strong);
      expect(guess.label, 'Example Smart Bulb');
    });

    test('passes the observed advertisement through to the matcher', () async {
      final codec = FakeSpecCodec(spec: _spec, scanMatches: (_) => []);
      final c = _container(codec);

      await c.read(scanGuessProvider(ScanIdentity.of(_device(
        serviceUuids: const [_svcUuid],
        companyIds: const [961],
      ))).future);

      final asked = codec.scanMatchCalls.single;
      expect(asked.name, 'ACME_Living_Room');
      expect(asked.serviceUuids, const [_svcUuid]);
      expect(asked.companyIds, const [961]);
      expect(asked.macAddress, 'AA:BB:CC:DD:EE:01');
    });

    test('an iOS device id is not offered to the matcher as an address',
        () async {
      final codec = FakeSpecCodec(spec: _spec, scanMatches: (_) => []);
      final c = _container(codec);

      await c.read(scanGuessProvider(ScanIdentity.of(
        _device(id: 'C47C8DAB-1234-5678-9ABC-DEF012345678'),
      )).future);

      expect(codec.scanMatchCalls.single.macAddress, isNull);
    });

    test('matching is cached across rssi changes', () async {
      final codec = FakeSpecCodec(
        spec: _spec,
        scanMatches: (_) => [_match(MatchConfidence.strong)],
      );
      final c = _container(codec);

      // Same device, two sightings, different signal strength. Identity is what
      // the family is keyed on, so the second must be a cache hit.
      await c
          .read(scanGuessProvider(ScanIdentity.of(_device(rssi: -50))).future);
      await c
          .read(scanGuessProvider(ScanIdentity.of(_device(rssi: -83))).future);

      expect(codec.scanMatchCalls, hasLength(1));
    });

    test('null when nothing matched', () async {
      final codec = FakeSpecCodec(spec: _spec, scanMatches: (_) => []);
      final c = _container(codec);

      final guess =
          await c.read(scanGuessProvider(ScanIdentity.of(_device())).future);

      expect(guess, isNull);
    });

    test('null, not a thrown scan, when the codec is unavailable', () async {
      final codec = FakeSpecCodec(loadError: StateError('no native lib'));
      final c = _container(codec);

      final guess =
          await c.read(scanGuessProvider(ScanIdentity.of(_device())).future);

      expect(guess, isNull);
    });
  });

  group('ScanGuess.fromMatches', () {
    test('sees one maker behind several tied specs', () {
      final g = ScanGuess.fromMatches([
        _match(MatchConfidence.possible, deviceName: 'Mi Flora'),
        _match(MatchConfidence.possible, deviceName: 'Mi Band', specIndex: 1),
      ]);
      expect(g!.otherMatches, 1);
      expect(g.manufacturerAgreed, isTrue);
    });

    test('sees several makers behind several tied specs', () {
      final g = ScanGuess.fromMatches([
        _match(MatchConfidence.possible, manufacturer: 'Enphase Energy'),
        _match(MatchConfidence.possible, manufacturer: 'Rachio', specIndex: 1),
      ]);
      expect(g!.manufacturerAgreed, isFalse);
      expect(g.label, 'Possibly supported');
    });

    test('ignores weaker matches when judging agreement', () {
      // A Strong match is not made ambiguous by a trailing Possible one, and
      // that other spec's maker has no bearing on the verdict either.
      final g = ScanGuess.fromMatches([
        _match(MatchConfidence.strong, manufacturer: 'Ember Technologies'),
        _match(MatchConfidence.possible, manufacturer: 'Rachio', specIndex: 1),
      ]);
      expect(g!.otherMatches, 0);
      expect(g.manufacturerAgreed, isTrue);
      expect(g.namesAProduct, isTrue);
    });
  });

  group('ScanGuess.label', () {
    ScanGuess guess(
      MatchConfidence confidence, {
      int otherMatches = 0,
      bool manufacturerAgreed = true,
    }) =>
        ScanGuess(
          deviceName: 'Ember Mug',
          manufacturer: 'Ember Technologies',
          confidence: confidence,
          otherMatches: otherMatches,
          manufacturerAgreed: manufacturerAgreed,
        );

    test('names the product on a strong match', () {
      expect(guess(MatchConfidence.strong).label, 'Ember Mug');
    });

    test('hedges on a likely match', () {
      expect(guess(MatchConfidence.likely).label, 'Likely Ember Mug');
    });

    test('never names a product on an OUI alone', () {
      // A Xiaomi OUI covers every Xiaomi radio ever built. Naming the plant
      // monitor on that basis would be a confident lie.
      final g = guess(MatchConfidence.possible);
      expect(g.label, 'Possibly Ember Technologies');
      expect(g.namesAProduct, isFalse);
    });

    test('drops the product name when several specs matched equally well', () {
      expect(guess(MatchConfidence.strong, otherMatches: 2).label,
          'Supported device');
      expect(guess(MatchConfidence.likely, otherMatches: 2).label,
          'Likely supported');
    });

    test('keeps the maker when the tied specs are all that maker', () {
      // Two Ember products matching one OUI still tells the user who made it.
      expect(guess(MatchConfidence.possible, otherMatches: 1).label,
          'Possibly Ember Technologies');
    });

    test('drops the maker when the tied specs disagree about it', () {
      // Four vendors' specs matching one shared OUI badged all of them with
      // whichever happened to sort first.
      final g = guess(MatchConfidence.possible,
          otherMatches: 3, manufacturerAgreed: false);
      expect(g.label, 'Possibly supported');
      expect(g.namesAProduct, isFalse);
    });
  });

  group('rankScannedDevices', () {
    ScanGuess g(MatchConfidence confidence) => ScanGuess(
          deviceName: 'X',
          manufacturer: 'Y',
          confidence: confidence,
          otherMatches: 0,
          manufacturerAgreed: true,
        );

    test('recognised devices come first, whatever the signal strength', () {
      final loudUnknown = _device(id: '1', rssi: -30);
      final faintMatch = _device(id: '2', rssi: -95);

      final ranked = rankScannedDevices(
        [loudUnknown, faintMatch],
        (d) => d.id == '2' ? g(MatchConfidence.strong) : null,
      );

      expect(ranked.likelySupported.map((r) => r.device.id), ['2']);
      expect(ranked.other.map((r) => r.device.id), ['1']);
    });

    test('an OUI-only match is a hint, not a claim of support', () {
      final ouiOnly = _device(id: '1', rssi: -90);
      final unknown = _device(id: '2', rssi: -40);

      final ranked = rankScannedDevices(
        [unknown, ouiOnly],
        (d) => d.id == '1' ? g(MatchConfidence.possible) : null,
      );

      expect(ranked.likelySupported, isEmpty,
          reason: 'a shared OUI must not promote a device above the fold');
      // It still outranks the anonymous device inside the lower group, which is
      // the entire value of the weakest tier.
      expect(ranked.other.map((r) => r.device.id), ['1', '2']);
    });

    test('stronger matches sort above weaker ones', () {
      final likely = _device(id: 'likely', rssi: -20);
      final strong = _device(id: 'strong', rssi: -85);

      final ranked = rankScannedDevices(
        [likely, strong],
        (d) => g(
            d.id == 'strong' ? MatchConfidence.strong : MatchConfidence.likely),
      );

      expect(
          ranked.likelySupported.map((r) => r.device.id), ['strong', 'likely']);
    });

    test('signal strength breaks ties within a confidence tier', () {
      final near = _device(id: 'near', rssi: -40);
      final far = _device(id: 'far', rssi: -88);

      final ranked =
          rankScannedDevices([far, near], (_) => g(MatchConfidence.strong));

      expect(ranked.likelySupported.map((r) => r.device.id), ['near', 'far']);
    });

    test('devices whose match has not resolved yet still list', () {
      // Matching is async; a row must appear immediately and gain its badge
      // later rather than the whole list waiting on the catalogue.
      final ranked = rankScannedDevices([_device()], (_) => null);

      expect(ranked.other, hasLength(1));
      expect(ranked.other.single.guess, isNull);
    });
  });
}

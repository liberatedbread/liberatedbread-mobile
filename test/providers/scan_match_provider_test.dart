// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/device_category.dart';
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
  category: 'light',
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
  String? category = 'light',
  int specIndex = 0,
}) =>
    ScanMatch(
      specIndex: specIndex,
      deviceName: deviceName,
      manufacturer: manufacturer,
      category: category,
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
  DateTime? discoveredAt,
}) =>
    IoTDevice(
      id: id,
      name: name,
      rssi: rssi,
      isConnectable: true,
      discoveredAt: discoveredAt ?? DateTime.now(),
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
      expect(identities.single.category, 'light',
          reason: 'the icon a row draws comes from here');
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

    test('rows do not trade places on rssi jitter inside a band', () {
      // The failure this prevents: a continuous scan reports each device
      // several times a second and its reading wanders a few dB while nothing
      // moves. Sorting on the exact number reshuffles neighbouring rows
      // continuously — so the row under a finger can change between deciding to
      // tap and tapping, and the tap opens a different device.
      // Named so the alphabetical id fallback would give the OPPOSITE order:
      // what holds these two in place has to be when each was found.
      final first = _device(
          id: 'zulu', rssi: -52, discoveredAt: DateTime(2026, 8, 10, 12));
      final second = _device(
          id: 'alpha', rssi: -50, discoveredAt: DateTime(2026, 8, 10, 12, 1));
      ({List<RankedDevice> likelySupported, List<RankedDevice> other}) rank(
        List<IoTDevice> devices,
      ) =>
          rankScannedDevices(devices, (_) => null);

      // 'first' was discovered first (see _device below), so it leads despite
      // the weaker reading — both are in the same band.
      expect(rank([first, second]).other.map((r) => r.device.id),
          ['zulu', 'alpha']);

      // Now 'second' jitters two dB the other way, still inside the band.
      final jittered = IoTDevice(
        id: second.id,
        name: second.name,
        rssi: -48,
        isConnectable: true,
        discoveredAt: second.discoveredAt,
        lastSeen: second.lastSeen,
      );
      expect(rank([first, jittered]).other.map((r) => r.device.id),
          ['zulu', 'alpha'],
          reason: 'nothing moved, so nothing may move');
    });

    test('a genuinely stronger device still sorts above a weaker one', () {
      // Banding must not flatten the list: a device a room away and one on the
      // desk belong in that order however long each has been listed.
      final onTheDesk = _device(id: 'desk', rssi: -35);
      final aRoomAway = _device(id: 'away', rssi: -85);

      final ranked = rankScannedDevices([aRoomAway, onTheDesk], (_) => null);

      expect(ranked.other.map((r) => r.device.id), ['desk', 'away']);
    });

    test('signal strength breaks ties within a confidence tier', () {
      final near = _device(id: 'near', rssi: -40);
      final far = _device(id: 'far', rssi: -88);

      final ranked =
          rankScannedDevices([far, near], (_) => g(MatchConfidence.strong));

      expect(ranked.likelySupported.map((r) => r.device.id), ['near', 'far']);
    });

    test('a device that has gone quiet sinks below the ones still heard', () {
      // Its signal reading is a memory: at -30 it would otherwise head the
      // list, above every device the scan can actually still hear.
      final quietButLoud = _device(id: 'quiet', rssi: -30);
      final liveButFaint = _device(id: 'live', rssi: -85);

      final ranked = rankScannedDevices(
        [quietButLoud, liveButFaint],
        (_) => null,
        isStale: (d) => d.id == 'quiet',
      );

      expect(ranked.other.map((r) => r.device.id), ['live', 'quiet']);
    });

    test('staleness only breaks ties inside a confidence tier', () {
      // A recognised device that went quiet is still the recognised one; it
      // does not fall out of the group it earned.
      final staleMatch = _device(id: 'match', rssi: -80);
      final liveUnknown = _device(id: 'unknown', rssi: -40);

      final ranked = rankScannedDevices(
        [liveUnknown, staleMatch],
        (d) => d.id == 'match' ? g(MatchConfidence.strong) : null,
        isStale: (d) => d.id == 'match',
      );

      expect(ranked.likelySupported.map((r) => r.device.id), ['match']);
      expect(ranked.other.map((r) => r.device.id), ['unknown']);
    });

    test('nothing is stale unless the caller says so', () {
      final a = _device(id: 'a', rssi: -30);
      final b = _device(id: 'b', rssi: -85);

      final ranked = rankScannedDevices([b, a], (_) => null);

      expect(ranked.other.map((r) => r.device.id), ['a', 'b']);
    });

    test('devices whose match has not resolved yet still list', () {
      // Matching is async; a row must appear immediately and gain its badge
      // later rather than the whole list waiting on the catalogue.
      final ranked = rankScannedDevices([_device()], (_) => null);

      expect(ranked.other, hasLength(1));
      expect(ranked.other.single.guess, isNull);
    });
  });

  group('ScanGuess.category', () {
    test('comes from the best match', () {
      final guess = ScanGuess.fromMatches([_match(MatchConfidence.strong)])!;
      expect(guess.category, DeviceCategory.light);
      expect(guess.iconOr(unknownDeviceIcon), DeviceCategory.light.icon);
    });

    test('survives a tie when every tied match agrees', () {
      // Which of a vendor's ten lights this is may be unknowable from an
      // advertisement; that it is a light is not.
      final guess = ScanGuess.fromMatches([
        _match(MatchConfidence.possible, deviceName: 'Bulb A'),
        _match(MatchConfidence.possible, deviceName: 'Bulb B'),
      ])!;
      expect(guess.namesAProduct, isFalse);
      expect(guess.category, DeviceCategory.light,
          reason: 'agreement is a lower bar than naming the product');
    });

    test('is dropped when the tied matches disagree', () {
      // A shared OUI can tie a plant sensor and a body scale. Drawing the
      // first one's icon would be the same confident guess as naming it.
      final guess = ScanGuess.fromMatches([
        _match(MatchConfidence.possible, category: 'sensor'),
        _match(MatchConfidence.possible, category: 'scale'),
      ])!;
      expect(guess.category, isNull);
      expect(guess.iconOr(unknownDeviceIcon), unknownDeviceIcon);
    });

    test('a trailing weaker match does not dilute a confident one', () {
      // Mirrors how `otherMatches` counts only ties at the best confidence: a
      // Strong match is not made ambiguous by a Possible one behind it.
      final guess = ScanGuess.fromMatches([
        _match(MatchConfidence.strong, category: 'light'),
        _match(MatchConfidence.possible, category: 'scale'),
      ])!;
      expect(guess.category, DeviceCategory.light);
    });

    test('a spec with no category falls back to the tab\'s own glyph', () {
      final guess = ScanGuess.fromMatches(
          [_match(MatchConfidence.strong, category: null)])!;
      expect(guess.category, isNull);
      expect(guess.iconOr(unknownDeviceIcon), unknownDeviceIcon);
      // Support is a fact about the catalogue; the icon is the bonus.
      expect(guess.namesAProduct, isTrue);
    });

    test('a category this build has not met is treated as absent', () {
      // The vocabulary grows upstream first and arrives here as vendored data.
      // An unknown value costs the icon, never the match.
      final guess = ScanGuess.fromMatches(
          [_match(MatchConfidence.strong, category: 'teleporter')])!;
      expect(guess.category, isNull);
      expect(guess.deviceName, 'Example Smart Bulb');
    });

    test('iconOr uses the caller\'s fallback, not a global one', () {
      // The Wi-Fi tab's anonymous device is a router glyph, not a Bluetooth
      // one — there is no radio to draw.
      final guess = ScanGuess.fromMatches(
          [_match(MatchConfidence.strong, category: null)])!;
      expect(guess.iconOr(Icons.router_outlined), Icons.router_outlined);
    });
  });
}

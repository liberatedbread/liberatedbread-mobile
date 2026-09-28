// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart' show Icons;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/device_category.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/real_spec_codec.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';
import '../helpers/host_rust_lib.dart';

const _svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';

/// Apple's company id, which every Apple device advertises under — and
/// which the vendored Nuki spec declares, because a paired lock is an iBeacon.
const _apple = 0x004C;

/// `02 15` + the Nuki Smart Lock command-service UUID: the payload prefix the
/// Nuki spec declares for a paired lock, as bytes after the company id.
const _nukiLockPrefix = [
  0x02, 0x15, 0xa9, 0x2e, 0xe2, 0x00, 0x55, 0x01, 0x11, 0xe4, //
  0x91, 0x6c, 0x08, 0x00, 0x20, 0x0c, 0x9a, 0x66,
];

/// A whole iBeacon payload: the prefix, then major, minor and TX power.
const _nukiLockBeacon = [..._nukiLockPrefix, 0x00, 0x01, 0x00, 0x02, 0xc5];

/// What an iPhone actually sends under 0x004C: a Continuity message, not an
/// iBeacon. Its bytes change by the second.
const _continuity = [0x10, 0x05, 0x01, 0x18, 0x6a, 0x3d, 0x8f];

final _spec = DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Example Smart Bulb',
  manufacturer: 'Acme',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  category: 'light',
  localNamePrefixes: const ['ACME_'],
  localNames: const [],
  serviceUuids: const [_svcUuid],
  companyIds: Uint16List.fromList(const [961]),
  macPrefixes: const [
    MacPrefixDto(prefix: 'C4:7C:8D', confidence: MacPrefixConfidence.medium),
  ],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: const [],
);

/// [_spec] as a beacon-shaped product: Apple's company id, narrowed by the
/// Nuki lock prefix.
final _beaconSpec = DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Example Beacon Lock',
  manufacturer: 'Acme',
  manufacturerStatus: 'active',
  protocol: 'ble',
  category: 'lock',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List.fromList(const [_apple]),
  manufacturerDataPrefixes: [
    ManufacturerPrefixDto(
      companyId: _apple,
      prefix: Uint8List.fromList(_nukiLockPrefix),
    ),
  ],
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
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
  SecurityAdvisoryDto? advisory,
  String? integration,
  String? pictogram,
}) => ScanMatch(
  specIndex: specIndex,
  deviceName: deviceName,
  manufacturer: manufacturer,
  category: category,
  pictogram: pictogram,
  integration: integration,
  securityAdvisory: advisory,
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
  Map<int, List<int>> manufacturerData = const {},
  DateTime? discoveredAt,
}) => IoTDevice(
  id: id,
  name: name,
  rssi: rssi,
  isConnectable: true,
  discoveredAt: discoveredAt ?? DateTime.now(),
  serviceUuids: serviceUuids,
  companyIds: companyIds,
  manufacturerData: manufacturerData,
);

/// The catalogue's declared prefixes as the scan screen hands them to
/// [ScanIdentity.of]: here, just the Nuki lock's under Apple's id.
final _nukiPrefixes = {
  _apple: [Uint8List.fromList(_nukiLockPrefix)],
};

ProviderContainer _container(FakeSpecCodec codec) {
  final c = ProviderContainer(
    overrides: [
      specCodecProvider.overrideWithValue(codec),
      deviceSpecsProvider.overrideWith((ref) => {'bulb.yaml': 'dummy-yaml'}),
    ],
  );
  addTearDown(c.dispose);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScanIdentity.of', () {
    test(
      'keeps a record only as far as the declared prefix it starts with',
      () {
        final identity = ScanIdentity.of(
          _device(
            companyIds: const [_apple],
            manufacturerData: const {_apple: _nukiLockBeacon},
          ),
          declaredPrefixes: _nukiPrefixes,
        );
        expect(identity.manufacturerData, {_apple: _nukiLockPrefix});
      },
    );

    test('a reading behind the prefix does not re-key the device', () {
      // A lock's major/minor are stable, but the point generalises: the
      // matcher reads whether the payload STARTS with the prefix, so bytes
      // after it are not identity, and keying on them would re-run matching
      // — and blank the badge while it ran — on every advertisement.
      final a = ScanIdentity.of(
        _device(
          companyIds: const [_apple],
          manufacturerData: const {
            _apple: [..._nukiLockPrefix, 0x00, 0x01, 0x00, 0x02, 0xc5],
          },
        ),
        declaredPrefixes: _nukiPrefixes,
      );
      final b = ScanIdentity.of(
        _device(
          companyIds: const [_apple],
          manufacturerData: const {
            _apple: [..._nukiLockPrefix, 0x00, 0x07, 0x00, 0x09, 0xb0],
          },
        ),
        declaredPrefixes: _nukiPrefixes,
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a record that matches no declared prefix is not identity', () {
      // An iPhone's Continuity bytes change by the second. Kept, they would
      // re-key the row on every packet; dropped, the device keys exactly as
      // it did when only its company id was read.
      final continuity = ScanIdentity.of(
        _device(
          companyIds: const [_apple],
          manufacturerData: const {_apple: _continuity},
        ),
        declaredPrefixes: _nukiPrefixes,
      );
      final bare = ScanIdentity.of(_device(companyIds: const [_apple]));
      expect(continuity.manufacturerData, isEmpty);
      expect(continuity, bare);
      expect(continuity.hashCode, bare.hashCode);
    });

    test('a beacon and a non-beacon under the same id are different', () {
      // The other half of the cache key: nameless iBeacon and nameless
      // AirPods, both 0x004C and (on iOS) no address, must not share a
      // cached guess.
      final lock = ScanIdentity.of(
        _device(
          name: '',
          companyIds: const [_apple],
          manufacturerData: const {_apple: _nukiLockBeacon},
        ),
        declaredPrefixes: _nukiPrefixes,
      );
      final airpods = ScanIdentity.of(
        _device(
          name: '',
          companyIds: const [_apple],
          manufacturerData: const {_apple: _continuity},
        ),
        declaredPrefixes: _nukiPrefixes,
      );
      expect(lock, isNot(airpods));
    });

    test('with no catalogue in hand, payloads are not read', () {
      final identity = ScanIdentity.of(
        _device(
          companyIds: const [_apple],
          manufacturerData: const {_apple: _nukiLockBeacon},
        ),
      );
      expect(identity.manufacturerData, isEmpty);
    });
  });

  group('declaredManufacturerPrefixesProvider', () {
    test('indexes every identity prefix by company id', () async {
      final c = _container(FakeSpecCodec(spec: _beaconSpec));

      // Empty until the identities have loaded; keyed once they have.
      expect(c.read(declaredManufacturerPrefixesProvider), isEmpty);
      await c.read(specIdentitiesProvider.future);

      final declared = c.read(declaredManufacturerPrefixesProvider);
      expect(declared.keys, [_apple]);
      expect(declared[_apple], [_nukiLockPrefix]);
    });
  });

  group('specIdentitiesProvider', () {
    test('projects the identifying fields of every parsed spec', () async {
      final c = _container(FakeSpecCodec(spec: _spec));

      final identities = await c.read(specIdentitiesProvider.future);

      expect(identities, hasLength(1));
      expect(identities.single.deviceName, 'Example Smart Bulb');
      expect(
        identities.single.category,
        'light',
        reason: 'the icon a row draws comes from here',
      );
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

    test('carries the security advisory the scan list badges from', () async {
      // The badge, the warning screen and the malicious-device alert all read
      // the advisory off the identity the matcher returns. It was left out of
      // this projection, which made the whole feature inert in production
      // while the widget tests, which build identities by hand, stayed green.
      const advisory = SecurityAdvisoryDto(
        severity: 'malicious',
        summary: 'Skimmer module signature.',
      );
      final flagged = DeviceSpecDto(
        nameMatchers: const [],
        platformFallbackTypes: const [],
        txtMatchGroups: const [],
        hiddenEntityNames: const [],
        deviceName: 'HC-05 skimmer',
        manufacturer: 'Unknown',
        manufacturerStatus: 'unsupported',
        protocol: 'ble',
        category: 'other',
        securityAdvisory: advisory,
        localNamePrefixes: const ['HC-05'],
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
      );
      final c = _container(FakeSpecCodec(spec: flagged));

      final identities = await c.read(specIdentitiesProvider.future);

      expect(identities.single.securityAdvisory?.severity, 'malicious');
    });
  });

  group('scanGuessProvider', () {
    test('reports the best match', () async {
      final codec = FakeSpecCodec(
        spec: _spec,
        scanMatches: (_) => [_match(MatchConfidence.strong)],
      );
      final c = _container(codec);

      final guess = await c.read(
        scanGuessProvider(ScanIdentity.of(_device())).future,
      );

      expect(guess, isNotNull);
      expect(guess!.confidence, MatchConfidence.strong);
      expect(guess.label, 'Example Smart Bulb');
    });

    test('passes the observed advertisement through to the matcher', () async {
      final codec = FakeSpecCodec(spec: _spec, scanMatches: (_) => []);
      final c = _container(codec);

      await c.read(
        scanGuessProvider(
          ScanIdentity.of(
            _device(serviceUuids: const [_svcUuid], companyIds: const [961]),
          ),
        ).future,
      );

      final asked = codec.scanMatchCalls.single;
      expect(asked.name, 'ACME_Living_Room');
      expect(asked.serviceUuids, const [_svcUuid]);
      expect(asked.companyIds, const [961]);
      expect(asked.manufacturerData, isEmpty);
      expect(asked.macAddress, 'AA:BB:CC:DD:EE:01');
    });

    test('passes the declared manufacturer data through as records', () async {
      // The Rust matcher reads the payload as (company id, bytes after it),
      // the same origin the catalogue's patterns are written against.
      final codec = FakeSpecCodec(spec: _spec, scanMatches: (_) => []);
      final c = _container(codec);

      await c.read(
        scanGuessProvider(
          ScanIdentity.of(
            _device(
              companyIds: const [_apple],
              manufacturerData: const {_apple: _nukiLockBeacon},
            ),
            declaredPrefixes: _nukiPrefixes,
          ),
        ).future,
      );

      final asked = codec.scanMatchCalls.single;
      expect(asked.companyIds, const [_apple]);
      expect(asked.manufacturerData, hasLength(1));
      expect(asked.manufacturerData.single.companyId, _apple);
      expect(asked.manufacturerData.single.data, _nukiLockPrefix);
    });

    test(
      'an iOS device id is not offered to the matcher as an address',
      () async {
        final codec = FakeSpecCodec(spec: _spec, scanMatches: (_) => []);
        final c = _container(codec);

        await c.read(
          scanGuessProvider(
            ScanIdentity.of(
              _device(id: 'C47C8DAB-1234-5678-9ABC-DEF012345678'),
            ),
          ).future,
        );

        expect(codec.scanMatchCalls.single.macAddress, isNull);
      },
    );

    test('matching is cached across rssi changes', () async {
      final codec = FakeSpecCodec(
        spec: _spec,
        scanMatches: (_) => [_match(MatchConfidence.strong)],
      );
      final c = _container(codec);

      // Same device, two sightings, different signal strength. Identity is what
      // the family is keyed on, so the second must be a cache hit.
      await c.read(
        scanGuessProvider(ScanIdentity.of(_device(rssi: -50))).future,
      );
      await c.read(
        scanGuessProvider(ScanIdentity.of(_device(rssi: -83))).future,
      );

      expect(codec.scanMatchCalls, hasLength(1));
    });

    test('null when nothing matched', () async {
      final codec = FakeSpecCodec(spec: _spec, scanMatches: (_) => []);
      final c = _container(codec);

      final guess = await c.read(
        scanGuessProvider(ScanIdentity.of(_device())).future,
      );

      expect(guess, isNull);
    });

    test('null, not a thrown scan, when the codec is unavailable', () async {
      final codec = FakeSpecCodec(loadError: StateError('no native lib'));
      final c = _container(codec);

      final guess = await c.read(
        scanGuessProvider(ScanIdentity.of(_device())).future,
      );

      expect(guess, isNull);
    });
  });

  group('scanGuessProvider against the vendored Nuki spec', () {
    // The bug as seen on an iPhone: every AirPods, iPad and Mac in the room
    // badged "Likely Nuki Smart Lock", because the spec declares Apple's
    // company id and every Apple advertisement carries it. Through the real
    // codec and the real spec, so the whole path — identity projection,
    // record marshalling, Rust matcher — is what is under test.
    late final bool rustReady;
    late final String nukiYaml;

    setUpAll(() async {
      rustReady = await initHostRustLib();
      nukiYaml = await rootBundle.loadString(
        'vendor/protocol-specs/device-specs/devices/nuki-smart-lock.yaml',
      );
    });

    Future<ScanGuess?> guessFor(IoTDevice device) async {
      final c = ProviderContainer(
        overrides: [
          specCodecProvider.overrideWithValue(RealSpecCodec()),
          deviceSpecsProvider.overrideWith(
            (ref) => {'nuki-smart-lock.yaml': nukiYaml},
          ),
        ],
      );
      addTearDown(c.dispose);
      // The scan screen keys a row with the catalogue's prefixes once the
      // identities have loaded; do the same.
      await c.read(specIdentitiesProvider.future);
      final declared = c.read(declaredManufacturerPrefixesProvider);
      return c.read(
        scanGuessProvider(
          ScanIdentity.of(device, declaredPrefixes: declared),
        ).future,
      );
    }

    test(
      'an Apple device carrying only the company id is not a Nuki',
      () async {
        if (!rustReady) {
          markTestSkipped('Rust lib not loaded');
          return;
        }
        final guess = await guessFor(
          _device(
            name: '',
            companyIds: const [_apple],
            manufacturerData: const {_apple: _continuity},
          ),
        );
        expect(guess, isNull);
      },
    );

    test('a paired lock\'s iBeacon is a Strong Nuki', () async {
      if (!rustReady) {
        markTestSkipped('Rust lib not loaded');
        return;
      }
      final guess = await guessFor(
        _device(
          name: '',
          companyIds: const [_apple],
          manufacturerData: const {_apple: _nukiLockBeacon},
        ),
      );
      expect(guess, isNotNull);
      expect(guess!.confidence, MatchConfidence.strong);
      expect(guess.label, 'Nuki Smart Lock');
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

    // Before the fix a pack's corrected copy of a bundled spec tied with
    // its own original: otherMatches 1, no product name, and the stale
    // bundled copy's pictogram/advisory on the row.
    test('a pack copy of a bundled spec is one candidate, and wins', () {
      final g = ScanGuess.fromMatches([
        _match(MatchConfidence.strong, deviceName: 'Ember Mug'),
        _match(
          MatchConfidence.strong,
          deviceName: 'Ember Mug',
          specIndex: 7,
          pictogram: 'mug',
        ),
      ]);
      expect(g!.otherMatches, 0);
      expect(g.namesAProduct, isTrue);
      expect(g.label, 'Ember Mug');
      expect(g.pictogram, 'mug');
      expect(g.specIndex, 7);
    });

    test('a bundled match speaks for the pack copy that did not match', () {
      // The pack tightened the matchers, so only the stale copy came back;
      // it still stands for the spec that shadows it.
      final bundled = specIdentityOf(_beaconSpec);
      final pack = SpecIdentityDto(
        deviceName: bundled.deviceName,
        manufacturer: bundled.manufacturer,
        category: bundled.category,
        pictogram: 'padlock',
        localNamePrefixes: const [],
        localNames: const [],
        serviceUuids: const [],
        companyIds: Uint16List(0),
        manufacturerDataPrefixes: const [],
        macPrefixes: const [],
        mdnsServiceTypes: const [],
        ssdpSearchTargets: const [],
        lanProtocols: const [],
        nameMatchers: const [],
        txtMatchGroups: const [],
        platformFallbackTypes: const [],
      );
      final g = ScanGuess.fromMatches(
        [
          _match(
            MatchConfidence.likely,
            deviceName: bundled.deviceName,
            category: 'lock',
          ),
        ],
        identities: [bundled, specIdentityOf(_spec), pack],
      );
      expect(g!.specIndex, 2);
      expect(g.pictogram, 'padlock');
      expect(g.confidence, MatchConfidence.likely);
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
    }) => ScanGuess(
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
      // Makers and kinds disagreeing too: nothing left to say but that it
      // matched.
      expect(
        guess(
          MatchConfidence.strong,
          otherMatches: 2,
          manufacturerAgreed: false,
        ).label,
        'Supported device',
      );
      expect(
        guess(
          MatchConfidence.likely,
          otherMatches: 2,
          manufacturerAgreed: false,
        ).label,
        'Likely supported',
      );
    });

    test('a tie keeps the maker the tied specs agree on', () {
      // Three of one vendor's specs sharing a service UUID cannot say which
      // product, but they can say whose — the old badge threw that away.
      expect(
        guess(MatchConfidence.strong, otherMatches: 2).label,
        'Ember Technologies device',
      );
      expect(
        guess(MatchConfidence.likely, otherMatches: 2).label,
        'Likely Ember Technologies',
      );
    });

    test('a tie keeps the kind the tied specs agree on', () {
      // The TCL Roku case: three TV makers' specs tied on a TV-only signal
      // badged the set "Supported device", when every one of them said TV.
      ScanGuess tv(MatchConfidence c, {bool sameMaker = false}) => ScanGuess(
        deviceName: 'Roku External Control Protocol',
        manufacturer: 'Roku / TCL',
        category: DeviceCategory.tv,
        confidence: c,
        otherMatches: 2,
        manufacturerAgreed: sameMaker,
      );
      expect(tv(MatchConfidence.strong).label, 'Supported TV');
      expect(tv(MatchConfidence.likely).label, 'Likely supported TV');
      expect(
        tv(MatchConfidence.strong, sameMaker: true).label,
        'Roku / TCL TV',
      );
      // A category label that is a word, not an initialism, reads lower-case
      // mid-sentence.
      const lights = ScanGuess(
        deviceName: 'Govee H6001',
        manufacturer: 'Govee',
        category: DeviceCategory.light,
        confidence: MatchConfidence.strong,
        otherMatches: 1,
        manufacturerAgreed: true,
      );
      expect(lights.label, 'Govee light');
    });

    test('a contested identify-only match falls back to its kind', () {
      const g = ScanGuess(
        deviceName: 'Network Printer (IPP / AirPrint / IPP Everywhere)',
        manufacturer: 'Various',
        category: DeviceCategory.printer,
        confidence: MatchConfidence.likely,
        otherMatches: 1,
        manufacturerAgreed: false,
        isIdentifyOnly: true,
      );
      expect(g.label, 'Recognized printer');
    });

    test('keeps the maker when the tied specs are all that maker', () {
      // Two Ember products matching one OUI still tells the user who made it.
      expect(
        guess(MatchConfidence.possible, otherMatches: 1).label,
        'Possibly Ember Technologies',
      );
    });

    test('drops the maker when the tied specs disagree about it', () {
      // Four vendors' specs matching one shared OUI badged all of them with
      // whichever happened to sort first.
      final g = guess(
        MatchConfidence.possible,
        otherMatches: 3,
        manufacturerAgreed: false,
      );
      expect(g.label, 'Possibly supported');
      expect(g.namesAProduct, isFalse);
    });

    test('an identify_only device is named, never claimed as supported', () {
      // A SmartThings hub matches Strong on its mDNS type but the app drives
      // nothing on it — recognise-only. So it is named, not badged "Supported
      // device", and it is not treated as a likely-supported row.
      final g = ScanGuess.fromMatches([
        _match(
          MatchConfidence.strong,
          deviceName: 'SmartThings Hub v2',
          integration: 'identify_only',
        ),
      ])!;
      expect(g.isIdentifyOnly, isTrue);
      expect(g.label, 'SmartThings Hub v2');
      expect(Ranked(device: _device(), guess: g).isLikelySupported, isFalse);
    });

    test(
      'a supported device still claims support and ranks above the fold',
      () {
        final g = ScanGuess.fromMatches([
          _match(MatchConfidence.strong, deviceName: 'Wemo Mini'),
        ])!;
        expect(g.isIdentifyOnly, isFalse);
        expect(g.label, 'Wemo Mini');
        expect(Ranked(device: _device(), guess: g).isLikelySupported, isTrue);
      },
    );
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

      final ranked = rankScannedDevices([
        loudUnknown,
        faintMatch,
      ], (d) => d.id == '2' ? g(MatchConfidence.strong) : null);

      expect(ranked.likelySupported.map((r) => r.device.id), ['2']);
      expect(ranked.other.map((r) => r.device.id), ['1']);
    });

    test('the group header hedges no more than its rows', () {
      Ranked<int> r(MatchConfidence c) => Ranked(device: 0, guess: g(c));
      expect(supportedGroupLabel([r(MatchConfidence.strong)]), 'Supported');
      expect(
        supportedGroupLabel([
          r(MatchConfidence.strong),
          r(MatchConfidence.likely),
        ]),
        'Likely supported',
      );
    });

    test('an OUI-only match is a hint, not a claim of support', () {
      final ouiOnly = _device(id: '1', rssi: -90);
      final unknown = _device(id: '2', rssi: -40);

      final ranked = rankScannedDevices([
        unknown,
        ouiOnly,
      ], (d) => d.id == '1' ? g(MatchConfidence.possible) : null);

      expect(
        ranked.likelySupported,
        isEmpty,
        reason: 'a shared OUI must not promote a device above the fold',
      );
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
          d.id == 'strong' ? MatchConfidence.strong : MatchConfidence.likely,
        ),
      );

      expect(ranked.likelySupported.map((r) => r.device.id), [
        'strong',
        'likely',
      ]);
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
        id: 'zulu',
        rssi: -52,
        discoveredAt: DateTime(2026, 8, 10, 12),
      );
      final second = _device(
        id: 'alpha',
        rssi: -50,
        discoveredAt: DateTime(2026, 8, 10, 12, 1),
      );
      ({List<RankedDevice> likelySupported, List<RankedDevice> other}) rank(
        List<IoTDevice> devices,
      ) => rankScannedDevices(devices, (_) => null);

      // 'first' was discovered first (see _device below), so it leads despite
      // the weaker reading — both are in the same band.
      expect(rank([first, second]).other.map((r) => r.device.id), [
        'zulu',
        'alpha',
      ]);

      // Now 'second' jitters two dB the other way, still inside the band.
      final jittered = IoTDevice(
        id: second.id,
        name: second.name,
        rssi: -48,
        isConnectable: true,
        discoveredAt: second.discoveredAt,
        lastSeen: second.lastSeen,
      );
      expect(
        rank([first, jittered]).other.map((r) => r.device.id),
        ['zulu', 'alpha'],
        reason: 'nothing moved, so nothing may move',
      );
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

      final ranked = rankScannedDevices([
        far,
        near,
      ], (_) => g(MatchConfidence.strong));

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

    test('the caller\'s band holds rows the readings alone would swap', () {
      // The failure this prevents, one boundary over from the jitter test
      // above: a device hovering around -70 reads -69 and -71 on alternate
      // advertisements, so banding the reading flips it between three bars
      // and two, and its row past every band-2 neighbour and back. The scan
      // screen's manager holds a smoothed, hysteretic band per device, and
      // the ranking has to sort by that — the bars a row draws and the band
      // it sorts into are one judgement.
      final hovering = _device(
        id: 'hover',
        rssi: -71,
        discoveredAt: DateTime(2026, 8, 10, 12),
      );
      final steady = _device(
        id: 'steady',
        rssi: -69,
        discoveredAt: DateTime(2026, 8, 10, 12, 1),
      );
      ({List<RankedDevice> likelySupported, List<RankedDevice> other}) rank({
        int Function(IoTDevice device)? bandFor,
      }) =>
          rankScannedDevices([hovering, steady], (_) => null, bandFor: bandFor);

      // The readings say two bars under three...
      expect(rank().other.map((r) => r.device.id), ['steady', 'hover']);
      // ...the held bands say the opposite, and they win.
      final held = {'hover': 3, 'steady': 2};
      expect(
        rank(bandFor: (d) => held[d.id]!).other.map((r) => r.device.id),
        ['hover', 'steady'],
        reason: 'the band the row sorts into is the one it draws',
      );
    });

    test('the caller\'s band still sits below staleness', () {
      // A stale row's band is a memory of a signal it no longer has; the
      // caller holding the band changes nothing about that.
      final quietButLoud = _device(id: 'quiet', rssi: -30);
      final liveButFaint = _device(id: 'live', rssi: -85);

      final ranked = rankScannedDevices(
        [quietButLoud, liveButFaint],
        (_) => null,
        isStale: (d) => d.id == 'quiet',
        bandFor: (d) => d.id == 'quiet' ? 4 : 1,
      );

      expect(ranked.other.map((r) => r.device.id), ['live', 'quiet']);
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
      expect(
        guess.category,
        DeviceCategory.light,
        reason: 'agreement is a lower bar than naming the product',
      );
    });

    test('is dropped when the tied matches disagree', () {
      // A shared OUI can tie a plant sensor and a body scale. Drawing the
      // first one's icon would be the same confident guess as naming it.
      final guess = ScanGuess.fromMatches([
        // Distinct specs, so distinct identities: two entries sharing a
        // name and maker are one spec shadowed by a pack, and collapse.
        _match(
          MatchConfidence.possible,
          deviceName: 'Plant sensor',
          category: 'sensor',
        ),
        _match(
          MatchConfidence.possible,
          deviceName: 'Body scale',
          category: 'scale',
          specIndex: 1,
        ),
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
      final guess = ScanGuess.fromMatches([
        _match(MatchConfidence.strong, category: null),
      ])!;
      expect(guess.category, isNull);
      expect(guess.iconOr(unknownDeviceIcon), unknownDeviceIcon);
      // Support is a fact about the catalogue; the icon is the bonus.
      expect(guess.namesAProduct, isTrue);
    });

    test('a category this build has not met is treated as absent', () {
      // The vocabulary grows upstream first and arrives here as vendored data.
      // An unknown value costs the icon, never the match.
      final guess = ScanGuess.fromMatches([
        _match(MatchConfidence.strong, category: 'teleporter'),
      ])!;
      expect(guess.category, isNull);
      expect(guess.deviceName, 'Example Smart Bulb');
    });

    test('iconOr uses the caller\'s fallback, not a global one', () {
      // The Wi-Fi tab's anonymous device is a router glyph, not a Bluetooth
      // one — there is no radio to draw.
      final guess = ScanGuess.fromMatches([
        _match(MatchConfidence.strong, category: null),
      ])!;
      expect(guess.iconOr(Icons.router_outlined), Icons.router_outlined);
    });
  });

  group('ScanGuess.advisory', () {
    const vuln = SecurityAdvisoryDto(
      severity: 'vulnerable',
      summary: 'Shared key unlocks the car.',
    );
    const skimmer = SecurityAdvisoryDto(
      severity: 'malicious',
      summary: 'Skimmer module signature.',
    );

    test('carries the best match advisory and flags the row as a warning', () {
      final guess = ScanGuess.fromMatches([
        _match(MatchConfidence.possible, advisory: vuln),
      ])!;
      expect(guess.advisory?.severity, 'vulnerable');
      expect(guess.isSecurityWarning, isTrue);
      expect(guess.isMalicious, isFalse);
    });

    test('isMalicious is true only for a malicious advisory', () {
      expect(
        ScanGuess.fromMatches([
          _match(MatchConfidence.possible, advisory: skimmer),
        ])!.isMalicious,
        isTrue,
      );
    });

    test('an ordinary device has no advisory and is not a warning', () {
      final guess = ScanGuess.fromMatches([_match(MatchConfidence.strong)])!;
      expect(guess.advisory, isNull);
      expect(guess.isSecurityWarning, isFalse);
    });

    test('is surfaced even at possible confidence — a maybe-skimmer still '
        'warns', () {
      // Warning specs match by an inferred name, so the match is usually
      // `possible`; dropping the advisory there would silence the warning.
      final guess = ScanGuess.fromMatches([
        _match(MatchConfidence.possible, advisory: skimmer),
      ])!;
      expect(guess.namesAProduct, isFalse, reason: 'possible + hedged');
      expect(guess.isSecurityWarning, isTrue);
    });
  });
}

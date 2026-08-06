// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/network_scan_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

final _spec = DeviceSpecDto(
  deviceName: 'Hue Bridge',
  manufacturer: 'Signify',
  manufacturerStatus: 'active',
  protocol: 'wifi',
  localNamePrefixes: const [],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceType: '_hue._tcp.local.',
  ssdpSearchTargets: const ['urn:schemas-upnp-org:device:Basic:1'],
  defaultPort: 80,
  entities: const <EntityDto>[],
  services: const [],
);

ScanMatch _match(MatchConfidence confidence) => ScanMatch(
      specIndex: 0,
      deviceName: 'Hue Bridge',
      manufacturer: 'Signify',
      confidence: confidence,
      matchedByNamePrefix: false,
      matchedServiceUuids: const [],
      matchedCompanyIds: Uint16List(0),
      matchedMacPrefix: null,
      matchedServiceTypes: const ['_hue._tcp.local.'],
    );

NetworkDevice _device({
  String host = '192.168.1.40',
  String name = '',
  String? hostname,
  int? port,
  List<String> serviceTypes = const [],
  List<String> ssdpTargets = const [],
}) =>
    NetworkDevice(
      host: host,
      name: name,
      hostname: hostname,
      port: port,
      serviceTypes: serviceTypes,
      ssdpTargets: ssdpTargets,
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime(2026),
    );

ProviderContainer _container(FakeSpecCodec codec) {
  final c = ProviderContainer(overrides: [
    specCodecProvider.overrideWithValue(codec),
    deviceSpecsProvider.overrideWith((ref) => {'hue.yaml': 'dummy-yaml'}),
  ]);
  addTearDown(c.dispose);
  return c;
}

void main() {
  group('specIdentitiesProvider carries the network fields', () {
    test('mdns, ssdp and port reach the matcher', () async {
      final c = _container(FakeSpecCodec(spec: _spec));
      final identities = await c.read(specIdentitiesProvider.future);
      expect(identities.single.mdnsServiceType, '_hue._tcp.local.');
      expect(identities.single.ssdpSearchTargets,
          const ['urn:schemas-upnp-org:device:Basic:1']);
      expect(identities.single.defaultPort, 80);
    });
  });

  group('networkGuessProvider', () {
    test('reports the best match', () async {
      final codec = FakeSpecCodec(
        spec: _spec,
        networkMatches: (_) => [_match(MatchConfidence.strong)],
      );
      final c = _container(codec);

      final guess = await c.read(networkGuessProvider(
        NetworkIdentity.of(_device(serviceTypes: const ['_hue._tcp.local'])),
      ).future);

      expect(guess!.label, 'Hue Bridge');
    });

    test('passes the observed advertisement through', () async {
      final codec = FakeSpecCodec(spec: _spec, networkMatches: (_) => []);
      final c = _container(codec);

      await c.read(networkGuessProvider(NetworkIdentity.of(_device(
        name: 'Philips Hue',
        hostname: 'Philips-hue.local',
        port: 443,
        serviceTypes: const ['_hue._tcp.local'],
        ssdpTargets: const ['urn:x:1'],
      ))).future);

      final asked = codec.networkMatchCalls.single;
      expect(asked.name, 'Philips Hue');
      expect(asked.hostname, 'Philips-hue.local');
      expect(asked.port, 443);
      expect(asked.serviceTypes, const ['_hue._tcp.local']);
      expect(asked.ssdpTargets, const ['urn:x:1']);
    });

    test('a re-announcement of the same records is a cache hit', () async {
      // mDNS devices re-announce constantly; matching each one would be waste.
      final codec = FakeSpecCodec(
        spec: _spec,
        networkMatches: (_) => [_match(MatchConfidence.strong)],
      );
      final c = _container(codec);

      final identity = NetworkIdentity.of(
          _device(serviceTypes: List.of(const ['_hue._tcp.local'])));
      final again = NetworkIdentity.of(
          _device(serviceTypes: List.of(const ['_hue._tcp.local'])));

      await c.read(networkGuessProvider(identity).future);
      await c.read(networkGuessProvider(again).future);

      expect(codec.networkMatchCalls, hasLength(1));
    });

    test('null when nothing matched or the codec is unavailable', () async {
      final none =
          _container(FakeSpecCodec(spec: _spec, networkMatches: (_) => []));
      expect(
        await none
            .read(networkGuessProvider(NetworkIdentity.of(_device())).future),
        isNull,
      );

      final broken = _container(FakeSpecCodec(loadError: StateError('no lib')));
      expect(
        await broken
            .read(networkGuessProvider(NetworkIdentity.of(_device())).future),
        isNull,
      );
    });
  });

  group('rankNetworkDevices', () {
    ScanGuess g(MatchConfidence confidence) => ScanGuess(
          deviceName: 'Hue Bridge',
          manufacturer: 'Signify',
          confidence: confidence,
          otherMatches: 0,
        );

    test('recognised devices come first', () {
      final unknown = _device(host: '192.168.1.99', name: 'aaa-printer');
      final known = _device(host: '192.168.1.40', name: 'zzz-hue');

      final ranked = rankNetworkDevices(
        [unknown, known],
        (d) => d.host == '192.168.1.40' ? g(MatchConfidence.strong) : null,
      );

      expect(
          ranked.likelySupported.map((r) => r.device.host), ['192.168.1.40']);
      expect(ranked.other.map((r) => r.device.host), ['192.168.1.99']);
    });

    test('a port-only match stays out of the promoted section', () {
      // Port 80 is evidence of nothing at all.
      final ranked = rankNetworkDevices(
        [_device()],
        (_) => g(MatchConfidence.possible),
      );
      expect(ranked.likelySupported, isEmpty);
      expect(ranked.other, hasLength(1));
    });

    test('ties break on name, not discovery order', () {
      // mDNS and SSDP answer at wildly different speeds; rows must not shuffle
      // under a finger as a scan progresses.
      final b = _device(host: '192.168.1.2', name: 'Bravo');
      final a = _device(host: '192.168.1.1', name: 'alpha');

      final ranked =
          rankNetworkDevices([b, a], (_) => g(MatchConfidence.strong));

      expect(
          ranked.likelySupported.map((r) => r.device.name), ['alpha', 'Bravo']);
    });

    test('devices whose match has not resolved yet still list', () {
      final ranked = rankNetworkDevices([_device()], (_) => null);
      expect(ranked.other, hasLength(1));
      expect(ranked.other.single.guess, isNull);
    });
  });
}

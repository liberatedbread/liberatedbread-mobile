// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/network_scan_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/wifi_scan_screen.dart';
import 'package:liberated_bread_mobile/services/network_scan_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

/// Emits a canned set of hosts, or an error.
class _FakeNetworkScanService implements NetworkScanService {
  final List<NetworkDevice> devices;
  final Object? error;
  bool stopped = false;

  _FakeNetworkScanService({this.devices = const [], this.error});

  @override
  Stream<NetworkDevice> scan({Duration timeout = const Duration(seconds: 8)}) {
    if (error != null) return Stream<NetworkDevice>.error(error!);
    return Stream.fromIterable(devices);
  }

  @override
  Future<void> stopScan() async => stopped = true;
}

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
  ssdpSearchTargets: const [],
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
      matchedServiceTypes: const [],
    );

NetworkDevice _device({
  String host = '192.168.1.40',
  String name = '',
  String? hostname,
  int? port,
  List<String> serviceTypes = const [],
  NetworkDiscoverySource source = NetworkDiscoverySource.mdns,
}) =>
    NetworkDevice(
      host: host,
      name: name,
      hostname: hostname,
      port: port,
      serviceTypes: serviceTypes,
      sources: {source},
      discoveredAt: DateTime(2026),
    );

Widget _wrap(
  _FakeNetworkScanService service, {
  List<ScanMatch> Function(NetworkDeviceDto)? matchFor,
}) =>
    ProviderScope(
      overrides: [
        networkScanServiceProvider.overrideWithValue(service),
        deviceSpecsProvider.overrideWith((ref) => {'hue.yaml': 'yaml'}),
        specCodecProvider.overrideWithValue(
          FakeSpecCodec(spec: _spec, networkMatches: matchFor),
        ),
      ],
      child: const MaterialApp(home: WifiScanScreen()),
    );

void main() {
  testWidgets('explains itself before the first scan', (tester) async {
    await tester.pumpWidget(_wrap(_FakeNetworkScanService()));

    expect(find.text('Scan your Wi-Fi network'), findsOneWidget);
    expect(find.textContaining('no Bluetooth'), findsOneWidget);
    expect(find.text('Found'), findsNothing);
  });

  testWidgets('lists hosts, with the transport that found them',
      (tester) async {
    final service = _FakeNetworkScanService(devices: [
      _device(host: '192.168.1.40', name: 'Philips Hue', port: 443),
      _device(
        host: '192.168.1.41',
        source: NetworkDiscoverySource.ssdp,
      ),
    ]);
    await tester.pumpWidget(_wrap(service, matchFor: (_) => const []));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Philips Hue'), findsOneWidget);
    expect(find.text('2 devices found'), findsOneWidget);
    expect(find.text('mDNS'), findsOneWidget);
    expect(find.text('SSDP'), findsOneWidget);
    // A device with no name at all is still addressable.
    expect(find.text('192.168.1.41'), findsWidgets);
  });

  testWidgets('a matched host is promoted and named', (tester) async {
    final service = _FakeNetworkScanService(devices: [
      _device(host: '192.168.1.99', name: 'office-printer'),
      _device(
        host: '192.168.1.40',
        name: 'Philips Hue',
        serviceTypes: const ['_hue._tcp.local'],
      ),
    ]);
    await tester.pumpWidget(_wrap(
      service,
      matchFor: (device) => device.serviceTypes.contains('_hue._tcp.local')
          ? [_match(MatchConfidence.strong)]
          : const [],
    ));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Likely supported'), findsOneWidget);
    expect(find.text('Other devices'), findsOneWidget);
    expect(find.text('Hue Bridge'), findsOneWidget);

    final promoted = tester.getTopLeft(find.text('Philips Hue')).dy;
    final otherHeader = tester.getTopLeft(find.text('Other devices')).dy;
    expect(promoted, lessThan(otherHeader));
  });

  testWidgets('a port-only match is a hint, not a claim', (tester) async {
    final service =
        _FakeNetworkScanService(devices: [_device(name: 'Mystery Box')]);
    await tester.pumpWidget(
        _wrap(service, matchFor: (_) => [_match(MatchConfidence.possible)]));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Likely supported'), findsNothing);
    expect(find.text('Possibly Signify'), findsOneWidget);
    expect(find.text('Hue Bridge'), findsNothing);
  });

  testWidgets('an unmatched host still says what it advertises',
      (tester) async {
    final service = _FakeNetworkScanService(devices: [
      _device(name: 'office-printer', serviceTypes: const ['_ipp._tcp.local']),
    ]);
    await tester.pumpWidget(_wrap(service, matchFor: (_) => const []));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // "_ipp._tcp" is a printer, and saying so beats saying nothing. The
    // .local suffix is on every service type and carries no information.
    expect(find.text('_ipp._tcp'), findsOneWidget);
  });

  testWidgets('a denied local network gets its own guidance', (tester) async {
    // The generic empty state would read as "you have no devices", which is
    // the wrong thing to tell someone whose permission was refused.
    final service =
        _FakeNetworkScanService(error: const LocalNetworkDeniedException());
    await tester.pumpWidget(_wrap(service));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Local network access needed'), findsOneWidget);
    expect(
        find.widgetWithText(ElevatedButton, 'Open settings'), findsOneWidget);
  });

  testWidgets('an empty scan offers a retry, not a dead end', (tester) async {
    await tester.pumpWidget(_wrap(_FakeNetworkScanService()));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('No devices found'), findsOneWidget);
    expect(find.textContaining('guest network'), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
  });

  testWidgets('a failed scan shows guidance, not the exception',
      (tester) async {
    final service = _FakeNetworkScanService(error: StateError('boom'));
    await tester.pumpWidget(_wrap(service));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.textContaining('Scanning failed'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('tapping a device shows what it advertised', (tester) async {
    final service = _FakeNetworkScanService(devices: [
      _device(
        name: 'Philips Hue',
        hostname: 'Philips-hue.local',
        port: 443,
        serviceTypes: const ['_hue._tcp.local'],
      ),
    ]);
    await tester.pumpWidget(_wrap(service, matchFor: (_) => const []));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Philips Hue'));
    await tester.pumpAndSettle();

    expect(find.text('Hostname'), findsOneWidget);
    expect(find.text('Philips-hue.local'), findsOneWidget);
    expect(find.text('mDNS'), findsWidgets);
  });
}

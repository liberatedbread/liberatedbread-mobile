// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/core/device_category.dart';
import 'package:liberated_bread_mobile/models/ad_banner.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/ad_banner_provider.dart';
import 'package:liberated_bread_mobile/models/ha_config.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart'
    show
        HaConfigNotifier,
        haApiClientProvider,
        settingsStoreProvider,
        urlOpenerProvider;
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/network_scan_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/providers/device_description_provider.dart';
import 'package:liberated_bread_mobile/screens/wifi_scan_screen.dart';
import 'package:liberated_bread_mobile/services/ad_banner_service.dart';
import 'package:liberated_bread_mobile/services/ha_api_client.dart';
import 'package:liberated_bread_mobile/services/number_registry.dart';
import 'package:liberated_bread_mobile/services/network_scan_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/ad_banner_bar.dart';

import '../fakes/fake_ha_api_client.dart';
import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

/// Emits a canned set of hosts, or an error.
class _FakeNetworkScanService implements NetworkScanService {
  final List<NetworkDevice> devices;
  final Object? error;
  bool stopped = false;

  /// The extra SSDP targets the screen asked for, per scan — how the tests
  /// see that the catalogue's targets reach the transport.
  final List<List<String>> extraTargetsPerScan = [];

  /// The extra mDNS service types the screen asked for, per scan — the same
  /// evidence for the direct-query transport a device deaf to the meta-query
  /// depends on.
  final List<List<String>> extraMdnsTypesPerScan = [];

  _FakeNetworkScanService({this.devices = const [], this.error});

  @override
  Stream<NetworkDevice> scan({
    Duration timeout = const Duration(seconds: 8),
    List<String> extraSearchTargets = const [],
    List<String> extraMdnsServiceTypes = const [],
  }) {
    extraTargetsPerScan.add(extraSearchTargets);
    extraMdnsTypesPerScan.add(extraMdnsServiceTypes);
    if (error != null) return Stream<NetworkDevice>.error(error!);
    return Stream.fromIterable(devices);
  }

  @override
  Future<void> stopScan() async => stopped = true;
}

final _spec = DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Hue Bridge',
  manufacturer: 'Signify',
  manufacturerStatus: 'active',
  protocol: 'wifi',
  category: 'hub',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const ['_hue._tcp.local.'],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: 80,
  entities: const <EntityDto>[],
  services: const [],
);

ScanMatch _match(
  MatchConfidence confidence, {
  String? category = 'hub',
  String? adminUrl,
  String? integration,
  String deviceName = 'Hue Bridge',
}) => ScanMatch(
  specIndex: 0,
  deviceName: deviceName,
  manufacturer: 'Signify',
  category: category,
  adminUrl: adminUrl,
  integration: integration,
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
  Map<String, String> txt = const {},
  NetworkDiscoverySource source = NetworkDiscoverySource.mdns,
}) => NetworkDevice(
  host: host,
  name: name,
  hostname: hostname,
  port: port,
  serviceTypes: serviceTypes,
  txt: txt,
  sources: {source},
  discoveredAt: DateTime(2026),
);

String _table(Map<String, String> rows) {
  final keys = rows.keys.toList()..sort();
  return keys.map((k) => '$k\t${rows[k]}\n').join();
}

/// Enough registry to name one block. Built here rather than read from the
/// vendored TSVs so the assertion does not move when IEEE reassigns anything.
final _registry = NumberRegistry(
  addressBlocks: [
    RegistryTable.parse(_table({'001788': 'Philips Lighting BV'}), keyWidth: 6),
  ],
  companyIds: RegistryTable.empty,
  serviceUuids: RegistryTable.empty,
);

Widget _wrap(
  _FakeNetworkScanService service, {
  List<ScanMatch> Function(NetworkDeviceDto)? matchFor,
  DeviceSpecDto? spec,
}) => ProviderScope(
  overrides: [
    networkScanServiceProvider.overrideWithValue(service),
    numberRegistryProvider.overrideWith((ref) async => _registry),
    deviceSpecsProvider.overrideWith((ref) => {'hue.yaml': 'yaml'}),
    specCodecProvider.overrideWithValue(
      FakeSpecCodec(spec: spec ?? _spec, networkMatches: matchFor),
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

  testWidgets('lists hosts, with the transport that found them', (
    tester,
  ) async {
    final service = _FakeNetworkScanService(
      devices: [
        _device(host: '192.168.1.40', name: 'Philips Hue', port: 443),
        _device(host: '192.168.1.41', source: NetworkDiscoverySource.ssdp),
      ],
    );
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
    final service = _FakeNetworkScanService(
      devices: [
        _device(host: '192.168.1.99', name: 'office-printer'),
        _device(
          host: '192.168.1.40',
          name: 'Philips Hue',
          serviceTypes: const ['_hue._tcp.local'],
        ),
      ],
    );
    await tester.pumpWidget(
      _wrap(
        service,
        matchFor: (device) => device.serviceTypes.contains('_hue._tcp.local')
            ? [_match(MatchConfidence.strong)]
            : const [],
      ),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Every row a strong match, so the header does not hedge.
    expect(find.text('Supported'), findsOneWidget);
    expect(find.text('Other devices'), findsOneWidget);
    expect(find.text('Hue Bridge'), findsOneWidget);

    final promoted = tester.getTopLeft(find.text('Philips Hue')).dy;
    final otherHeader = tester.getTopLeft(find.text('Other devices')).dy;
    expect(promoted, lessThan(otherHeader));
  });

  testWidgets('an admin page that will not open says so (R-088)', (
    tester,
  ) async {
    // Both external launches ignored the result and any exception, so a
    // phone with no browser for the scheme, a refusal, or a spec-supplied
    // address the allow-list rejects all looked identical to a dead button.
    final service = _FakeNetworkScanService(
      devices: [_device(name: 'Recognised NAS')],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          networkScanServiceProvider.overrideWithValue(service),
          numberRegistryProvider.overrideWith((ref) async => _registry),
          deviceSpecsProvider.overrideWith((ref) => {'hue.yaml': 'yaml'}),
          specCodecProvider.overrideWithValue(
            FakeSpecCodec(
              spec: _spec,
              networkMatches: (_) => [
                _match(
                  MatchConfidence.strong,
                  category: 'nas',
                  adminUrl: 'http://{address}:5000/',
                ),
              ],
            ),
          ),
          // The platform refuses to open it, which is what the screen has to
          // notice.
          urlOpenerProvider.overrideWithValue((uri) async => false),
        ],
        child: const MaterialApp(home: WifiScanScreen()),
      ),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recognised NAS'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not open'), findsOneWidget);
  });

  testWidgets('a printer it can only name is filed apart from the rest', (
    tester,
  ) async {
    // An office printer is recognised (identify_only) but not driven; a
    // Hue bridge is driven. They must not share a section, and the office
    // printer's row says what a tap does — open its own web page — since
    // printing to it is not on offer here.
    final service = _FakeNetworkScanService(
      devices: [
        _device(
          host: '192.168.1.50',
          name: 'Office LaserJet',
          serviceTypes: const ['_ipp._tcp.local'],
        ),
        _device(
          host: '192.168.1.40',
          name: 'Philips Hue',
          serviceTypes: const ['_hue._tcp.local'],
        ),
      ],
    );
    await tester.pumpWidget(
      _wrap(
        service,
        matchFor: (device) => device.serviceTypes.contains('_ipp._tcp.local')
            ? [
                _match(
                  MatchConfidence.likely,
                  category: 'printer',
                  adminUrl: 'http://{address}/',
                  integration: 'identify_only',
                  deviceName: 'Network Printer',
                ),
              ]
            : [_match(MatchConfidence.strong)],
      ),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // The list is lazy, and the recognised section is its last.
    await tester.scrollUntilVisible(find.text('Opens its own web page'), 100);
    expect(find.text('Recognized, not controlled here'), findsOneWidget);
    expect(find.text('Other devices'), findsNothing);
    expect(find.text('Opens its own web page'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('Supported'),
      -100,
      maxScrolls: 50,
    );
    expect(find.text('Supported'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Office LaserJet'), 100);

    final supported = tester.getTopLeft(find.text('Philips Hue')).dy;
    final recognizedHeader = tester
        .getTopLeft(find.text('Recognized, not controlled here'))
        .dy;
    final printer = tester.getTopLeft(find.text('Office LaserJet')).dy;
    expect(supported, lessThan(recognizedHeader));
    expect(recognizedHeader, lessThan(printer));
  });

  testWidgets('the house ad docks under the Wi-Fi tab too', (tester) async {
    // It was only ever mounted under the Nearby tab, so the Wi-Fi tab — the
    // one people land on to find printers and TVs — never showed it.
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          networkScanServiceProvider.overrideWithValue(
            _FakeNetworkScanService(),
          ),
          numberRegistryProvider.overrideWith((ref) async => _registry),
          deviceSpecsProvider.overrideWith((ref) => {'hue.yaml': 'yaml'}),
          specCodecProvider.overrideWithValue(FakeSpecCodec(spec: _spec)),
          // Fails fast, so the bundled banner is what shows.
          adBannerServiceProvider.overrideWithValue(
            AdBannerService(
              client: MockClient((_) async => http.Response('', 500)),
            ),
          ),
        ],
        child: const MaterialApp(home: WifiScanScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(AdBannerBar), findsOneWidget);
    expect(find.text('AD'), findsOneWidget);
    expect(find.text(AdBanner.fallback.message), findsOneWidget);
  });

  testWidgets('a port-only match is a hint, not a claim', (tester) async {
    final service = _FakeNetworkScanService(
      devices: [_device(name: 'Mystery Box')],
    );
    await tester.pumpWidget(
      _wrap(service, matchFor: (_) => [_match(MatchConfidence.possible)]),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Likely supported'), findsNothing);
    expect(find.text('Possibly Signify'), findsOneWidget);
    expect(find.text('Hue Bridge'), findsNothing);
  });

  testWidgets('an unmatched host still says what it advertises', (
    tester,
  ) async {
    final service = _FakeNetworkScanService(
      devices: [
        _device(
          name: 'office-printer',
          serviceTypes: const ['_ipp._tcp.local'],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(service, matchFor: (_) => const []));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // "_ipp._tcp" is a printer, and saying so beats saying nothing. The
    // .local suffix is on every service type and carries no information.
    expect(find.text('_ipp._tcp'), findsOneWidget);
  });

  testWidgets('an empty scan on Apple offers the hedged guidance', (
    tester,
  ) async {
    // The hedged message is rendered verbatim as guidance under a "Nothing
    // answered" headline — not flattened into a "Local network access needed"
    // assertion that points at a toggle that may already be on (F-015). The
    // Settings path is a secondary hint beside "Scan again", not a prominent
    // pill claiming the cause.
    final service = _FakeNetworkScanService(
      error: const LocalNetworkDeniedException(),
    );
    await tester.pumpWidget(_wrap(service));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Nothing answered'), findsOneWidget);
    expect(find.text('Local network access needed'), findsNothing);
    // The exception's own hedged wording is on screen as the subhead.
    expect(find.textContaining('If Local Network'), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
    // The list is lazy and the ad bar docks under it, so the hint below
    // 'Scan again' is built only once scrolled to.
    await tester.scrollUntilVisible(find.text('Open settings'), 100);
    // 'Open settings' is a secondary text button, no longer a headline pill.
    expect(find.widgetWithText(TextButton, 'Open settings'), findsOneWidget);
    expect(find.widgetWithText(ElevatedButton, 'Open settings'), findsNothing);
  });

  testWidgets('iOS silently re-runs one scan before showing the hint', (
    tester,
  ) async {
    // The first scan of a fresh iOS install can end empty because the system
    // Local Network prompt was up while the probes went out; nothing retries
    // after the user taps Allow. The screen re-runs one window, once, before
    // it reports anything (F-001).
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    try {
      final service = _FakeNetworkScanService(
        error: const LocalNetworkDeniedException(),
      );
      await tester.pumpWidget(_wrap(service));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      // Two scans ran: the first, and the one silent auto-retry.
      expect(service.extraTargetsPerScan.length, 2);
      // After the retry also came back denied, the hedged guidance is shown.
      expect(find.text('Nothing answered'), findsOneWidget);
    } finally {
      // Must be unset before the test body ends: the framework asserts no
      // foundation debug override leaks out of a test.
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('an empty scan offers a retry, not a dead end', (tester) async {
    await tester.pumpWidget(_wrap(_FakeNetworkScanService()));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('No devices found'), findsOneWidget);
    expect(find.textContaining('guest network'), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
  });

  testWidgets('a failed scan shows guidance, not the exception', (
    tester,
  ) async {
    final service = _FakeNetworkScanService(error: StateError('boom'));
    await tester.pumpWidget(_wrap(service));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.textContaining('Scanning failed'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('tapping a device shows what it advertised', (tester) async {
    final service = _FakeNetworkScanService(
      devices: [
        _device(
          name: 'Philips Hue',
          hostname: 'Philips-hue.local',
          port: 443,
          serviceTypes: const ['_hue._tcp.local'],
        ),
      ],
    );
    await tester.pumpWidget(_wrap(service, matchFor: (_) => const []));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Philips Hue'));
    await tester.pumpAndSettle();

    expect(find.text('Hostname'), findsOneWidget);
    expect(find.text('Philips-hue.local'), findsOneWidget);
    expect(find.text('mDNS'), findsWidgets);
  });

  testWidgets('copying the details closes the sheet and shows the toast', (
    tester,
  ) async {
    // A SnackBar raised from inside the modal sheet rendered in the Scaffold
    // under the barrier, docked exactly where the sheet was, and had expired
    // by the time the sheet was dismissed — so the confirmation was never
    // seen. Now the sheet is popped first and the screen shows it.
    //
    // Clipboard.setData never answers without a handler on the platform
    // channel, and the confirmation is only shown once the copy completes.
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final service = _FakeNetworkScanService(
      devices: [_device(host: '192.168.1.40', name: 'Mystery Box')],
    );
    await tester.pumpWidget(_wrap(service, matchFor: (_) => const []));
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Mystery Box'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Copy details'), findsOneWidget);

    await tester.tap(find.byTooltip('Copy details'));
    await tester.pumpAndSettle();

    expect(copied, contains('192.168.1.40'));
    expect(
      find.byType(BottomSheet),
      findsNothing,
      reason: 'the sheet is closed so the SnackBar is not behind it',
    );
    expect(find.text('Device details copied'), findsOneWidget);
  });

  testWidgets('the details sheet cites the MAC its vendor came from', (
    tester,
  ) async {
    // A Hue bridge publishes `bridgeid` as an EUI-64 — the 48-bit address with
    // FFFE spliced in — so this also proves the sheet shows the recovered
    // address rather than the raw TXT value.
    final service = _FakeNetworkScanService(
      devices: [
        _device(
          name: 'Philips Hue',
          txt: const {'bridgeid': '001788FFFE213C4D'},
        ),
      ],
    );
    await tester.pumpWidget(_wrap(service, matchFor: (_) => const []));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Philips Hue'));
    await tester.pumpAndSettle();

    expect(find.text('MAC'), findsOneWidget);
    expect(find.text('00:17:88:21:3C:4D'), findsOneWidget);
    // And the block it resolves to, so the sheet shows both the evidence and
    // the conclusion drawn from it. `findsWidgets` because the tile behind the
    // sheet already carries the vendor in its description; the label is what
    // is unique to the sheet.
    expect(find.text('Address block'), findsOneWidget);
    expect(find.text('Philips Lighting BV'), findsWidgets);
  });

  testWidgets("the catalogue's vendor SSDP targets ride along with the scan", (
    tester,
  ) async {
    // A Roku answers only its own search target, so the screen must hand the
    // catalogue's targets to the transport — a scan that only asks
    // `ssdp:all` never hears one. The fake records what it was asked.
    final service = _FakeNetworkScanService();
    await tester.pumpWidget(
      _wrap(
        service,
        spec: DeviceSpecDto(
          nameMatchers: const [],
          platformFallbackTypes: const [],
          txtMatchGroups: const [],
          hiddenEntityNames: const [],
          deviceName: 'Roku External Control Protocol',
          manufacturer: 'Roku / TCL',
          manufacturerStatus: 'active',
          protocol: 'wifi',
          category: 'tv',
          localNamePrefixes: const [],
          localNames: const [],
          serviceUuids: const [],
          companyIds: Uint16List(0),
          macPrefixes: const [],
          mdnsServiceTypes: const [],
          ssdpSearchTargets: const ['roku:ecp'],
          lanProtocols: const [],
          defaultPort: 8060,
          entities: const <EntityDto>[],
          services: const [],
        ),
      ),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(service.extraTargetsPerScan.single, contains('roku:ecp'));
  });

  testWidgets("the catalogue's mDNS service types ride along with the scan", (
    tester,
  ) async {
    // The mDNS twin of the SSDP case above: a Snapmaker U1's responder ignores
    // the `_services._dns-sd._udp.local` meta-query, so the screen must hand
    // the transport the exact `_vendor._tcp` type from the catalogue or the
    // device is never resolved. `_spec` declares `_hue._tcp.local.`.
    final service = _FakeNetworkScanService();
    await tester.pumpWidget(_wrap(service));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(service.extraMdnsTypesPerScan.single, contains('_hue._tcp.local.'));
    // Home Assistant's own type is asked for by name too: no spec names it,
    // and the LocalThings card depends on seeing it.
    expect(
      service.extraMdnsTypesPerScan.single,
      contains('_home-assistant._tcp.local.'),
    );
  });

  testWidgets('a chatty device cannot overflow the details sheet', (
    tester,
  ) async {
    // Regression: a printer's TXT records alone were 706px taller than the
    // sheet, and the Column overflowed instead of scrolling. The overflow
    // surfaces here as a test failure via FlutterError.onError.
    final service = _FakeNetworkScanService(
      devices: [
        _device(
          name: 'office-printer',
          hostname: 'printer.local',
          port: 631,
          serviceTypes: const ['_ipp._tcp.local', '_printer._tcp.local'],
          txt: {for (var i = 0; i < 40; i++) 'record-$i': 'value-$i'},
        ),
      ],
    );
    await tester.pumpWidget(_wrap(service, matchFor: (_) => const []));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.tap(find.text('office-printer'));
    await tester.pumpAndSettle();

    // The first rows are visible; the tail is reachable by scrolling rather
    // than clipped behind the sheet's bottom edge.
    expect(find.text('record-0'), findsOneWidget);
    await tester.drag(
      find.byType(SingleChildScrollView).last,
      const Offset(0, -2000),
    );
    await tester.pumpAndSettle();
    expect(find.text('record-39'), findsOneWidget);
  });

  testWidgets('a matched host is drawn with its device-type icon', (
    tester,
  ) async {
    final service = _FakeNetworkScanService(devices: [_device()]);
    await tester.pumpWidget(
      _wrap(service, matchFor: (_) => [_match(MatchConfidence.strong)]),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.byIcon(DeviceCategory.hub.icon), findsOneWidget);
    expect(find.byIcon(Icons.router_outlined), findsNothing);
  });

  testWidgets('an unmatched host keeps the router glyph, not the BLE one', (
    tester,
  ) async {
    // Each tab supplies its own fallback: there is no radio on this one, so
    // an anonymous host is a box on the network rather than a Bluetooth
    // device.
    final service = _FakeNetworkScanService(devices: [_device()]);
    await tester.pumpWidget(_wrap(service, matchFor: (_) => const []));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.router_outlined), findsOneWidget);
    expect(find.byIcon(unknownDeviceIcon), findsNothing);
  });

  group('LocalThings', () {
    final hub = _device(
      host: '192.168.1.70',
      name: 'SmartThings Hub',
      port: 8081,
      serviceTypes: const ['_smartthings._tcp.local'],
      txt: const {'id': '<hub-id>', 'type': 'hubv2'},
    );
    final ha = _device(
      host: '192.168.1.80',
      name: 'Home',
      port: 8123,
      serviceTypes: const ['_home-assistant._tcp.local'],
      txt: const {'internal_url': 'http://homeassistant.local:8123'},
    );

    Widget wrapWithHa(
      _FakeNetworkScanService service, {
      FakeHaApiClient? api,
      bool connected = false,
      List<Uri>? opened,
    }) => ProviderScope(
      overrides: [
        networkScanServiceProvider.overrideWithValue(service),
        numberRegistryProvider.overrideWith((ref) async => _registry),
        deviceSpecsProvider.overrideWith((ref) => {'hue.yaml': 'yaml'}),
        specCodecProvider.overrideWithValue(
          FakeSpecCodec(spec: _spec, networkMatches: (_) => const []),
        ),
        settingsStoreProvider.overrideWithValue(
          InMemorySettingsStore({
            if (connected)
              HaConfigNotifier.configKey: jsonEncode(
                const HaConfig(
                  baseUrl: 'http://ha.local:8123',
                  token: 'tok',
                  deviceId: 'dev',
                ).toJson(),
              ),
          }),
        ),
        haApiClientProvider.overrideWithValue(api ?? FakeHaApiClient()),
        urlOpenerProvider.overrideWithValue((uri) async {
          opened?.add(uri);
          return true;
        }),
      ],
      child: const MaterialApp(home: WifiScanScreen()),
    );

    Future<void> scan(WidgetTester tester) async {
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
    }

    testWidgets('a hub and a Home Assistant on the LAN bring up the card', (
      tester,
    ) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        wrapWithHa(_FakeNetworkScanService(devices: [hub, ha]), opened: opened),
      );
      await scan(tester);

      expect(find.byKey(const Key('localthings-suggestion')), findsOneWidget);
      expect(find.text('Take your Samsung appliances local'), findsOneWidget);

      await tester.tap(find.text('Get LocalThings'));
      await tester.pumpAndSettle();
      expect(opened.single.host, 'my.home-assistant.io');
      expect(opened.single.queryParameters['repository'], 'localthings');

      // Nobody could say whether it is installed, so the add flow is offered
      // too — at the instance the scan found, not via the hosted redirect.
      await tester.tap(find.text('Already installed? Add one'));
      await tester.pumpAndSettle();
      expect(
        opened.last.toString(),
        'http://homeassistant.local:8123/_my_redirect/config_flow_start'
        '?domain=localthings',
      );
    });

    testWidgets('a hub with no Home Assistant anywhere gets no card', (
      tester,
    ) async {
      await tester.pumpWidget(
        wrapWithHa(_FakeNetworkScanService(devices: [hub])),
      );
      await scan(tester);

      expect(find.byKey(const Key('localthings-suggestion')), findsNothing);
    });

    testWidgets('Home Assistant alone, with no SmartThings, asks nothing', (
      tester,
    ) async {
      final api = FakeHaApiClient()..components = {'localthings'};
      await tester.pumpWidget(
        wrapWithHa(
          _FakeNetworkScanService(devices: [ha]),
          api: api,
          connected: true,
        ),
      );
      await scan(tester);

      expect(find.byKey(const Key('localthings-suggestion')), findsNothing);
      expect(api.componentReads, 0);
    });

    testWidgets('a connected HA with LocalThings loaded offers the add flow', (
      tester,
    ) async {
      final opened = <Uri>[];
      final api = FakeHaApiClient()
        ..components = {'http', 'localthings', 'localthings.sensor'};
      await tester.pumpWidget(
        wrapWithHa(
          // No HA on the scan: the connected one is enough.
          _FakeNetworkScanService(devices: [hub]),
          api: api,
          connected: true,
          opened: opened,
        ),
      );
      await scan(tester);

      expect(api.componentReads, 1);
      expect(
        find.text('LocalThings is in your Home Assistant'),
        findsOneWidget,
      );
      expect(find.text('Get LocalThings'), findsNothing);

      await tester.tap(find.text('Add an appliance'));
      await tester.pumpAndSettle();
      // The connected address, which this phone has proven it can reach.
      expect(
        opened.single.toString(),
        'http://ha.local:8123/_my_redirect/config_flow_start'
        '?domain=localthings',
      );
    });

    testWidgets('a connected HA without LocalThings offers only the install', (
      tester,
    ) async {
      final api = FakeHaApiClient()..components = {'http', 'smartthings'};
      await tester.pumpWidget(
        wrapWithHa(
          _FakeNetworkScanService(devices: [hub]),
          api: api,
          connected: true,
        ),
      );
      await scan(tester);

      expect(find.text('Take your Samsung appliances local'), findsOneWidget);
      expect(find.text('Get LocalThings'), findsOneWidget);
      expect(find.text('Already installed? Add one'), findsNothing);
    });

    testWidgets('a Home Assistant that cannot answer still gets the advice', (
      tester,
    ) async {
      final api = FakeHaApiClient()
        ..componentsError = const HaNetworkException('no route');
      await tester.pumpWidget(
        wrapWithHa(
          _FakeNetworkScanService(devices: [hub]),
          api: api,
          connected: true,
        ),
      );
      await scan(tester);

      expect(find.text('Get LocalThings'), findsOneWidget);
      expect(find.text('Already installed? Add one'), findsOneWidget);
    });

    testWidgets("the hub's details point at LocalThings", (tester) async {
      final opened = <Uri>[];
      await tester.pumpWidget(
        wrapWithHa(_FakeNetworkScanService(devices: [hub]), opened: opened),
      );
      await scan(tester);

      await tester.tap(find.text('SmartThings Hub'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('About LocalThings'),
        100,
        scrollable: find.byType(Scrollable).last,
      );
      expect(find.text('Samsung appliances can go local'), findsOneWidget);

      await tester.tap(find.text('About LocalThings'));
      await tester.pumpAndSettle();
      expect(
        opened.single.toString(),
        'https://github.com/mbillow/localthings',
      );
    });
  });
}

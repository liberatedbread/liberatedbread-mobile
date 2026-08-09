// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/screens/ha_settings_screen.dart';
import 'package:liberated_bread_mobile/screens/scan_screen.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_ha_api_client.dart';
import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

/// Resolved in [setUp] so the scan screen can read saved devices synchronously
/// during build, the same way `main()` wires it in production.
late SharedPreferences _prefs;

Widget _wrap(FakeBleService fake) => ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(fake),
        sharedPreferencesProvider.overrideWithValue(_prefs),
      ],
      child: const MaterialApp(home: ScanScreen()),
    );

IoTDevice _device(String id,
    {String? name, int rssi = -40, bool connectable = true}) {
  return IoTDevice(
    id: id,
    name: name ?? 'dev-$id',
    rssi: rssi,
    isConnectable: connectable,
    discoveredAt: DateTime(2026),
  );
}

/// The one spec in the catalogue for the ranking tests below.
final _catalogueSpec = DeviceSpecDto(
  deviceName: 'Example Smart Bulb',
  manufacturer: 'Acme',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  localNamePrefixes: const ['ACME_'],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceType: null,
  ssdpSearchTargets: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: const [],
);

ScanMatch _scanMatch(MatchConfidence confidence) => ScanMatch(
      specIndex: 0,
      deviceName: 'Example Smart Bulb',
      manufacturer: 'Acme',
      confidence: confidence,
      matchedByNamePrefix: false,
      matchedServiceUuids: const [],
      matchedCompanyIds: Uint16List(0),
      matchedMacPrefix: null,
      matchedServiceTypes: const [],
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('shows empty-state prompt before scanning', (tester) async {
    await tester.pumpWidget(_wrap(FakeBleService()));
    expect(find.text('Scan for BLE Devices'), findsOneWidget);
    // No results section until a scan has actually produced something.
    expect(find.text('Found'), findsNothing);
  });

  testWidgets('populates the list after scan', (tester) async {
    final fake = FakeBleService(devicesToEmit: [
      _device('01', name: 'ACME_A', rssi: -40),
      _device('02', name: 'ACME_B', rssi: -60),
    ]);
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('ACME_A'), findsOneWidget);
    expect(find.text('Found'), findsOneWidget);
    expect(find.text('2 devices found'), findsOneWidget);
    // The docked ad bar costs the list a row of viewport; the second device
    // sits below the fold until scrolled to.
    await tester.scrollUntilVisible(find.text('ACME_B'), 80);
    expect(find.text('ACME_B'), findsOneWidget);
  });

  group('ranking recognised devices', () {
    /// Wires the scan screen with a spec catalogue, so the scan-time matcher
    /// actually runs. [matchFor] answers per device name.
    Widget wrapWithCatalogue(
      FakeBleService fake, {
      required List<ScanMatch> Function(String deviceName) matchFor,
    }) =>
        ProviderScope(
          overrides: [
            bleServiceProvider.overrideWithValue(fake),
            sharedPreferencesProvider.overrideWithValue(_prefs),
            deviceSpecsProvider.overrideWith((ref) => {'bulb.yaml': 'yaml'}),
            specCodecProvider.overrideWithValue(FakeSpecCodec(
              spec: _catalogueSpec,
              scanMatches: (device) => matchFor(device.name),
            )),
          ],
          child: const MaterialApp(home: ScanScreen()),
        );

    testWidgets('recognised devices get their own section, above the rest',
        (tester) async {
      // This asserts on the relative vertical positions of both section
      // headers, so both have to be laid out at once. The list is lazy and the
      // docked ad bar takes a slice of the viewport, which on the default test
      // surface leaves the second header unbuilt — and scrolling to it would
      // unbuild the first. A taller window is the honest fix: the ordering
      // rule under test has nothing to do with how much of it fits on screen.
      tester.view.physicalSize = const Size(1200, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final fake = FakeBleService(devicesToEmit: [
        // The unknown device has the far better signal, so ordering can only
        // come from what the catalogue knows.
        _device('01', name: 'Anonymous Thing', rssi: -30),
        _device('02', name: 'ACME_Bulb', rssi: -92),
      ]);
      await tester.pumpWidget(wrapWithCatalogue(fake, matchFor: (name) {
        return name == 'ACME_Bulb'
            ? [_scanMatch(MatchConfidence.strong)]
            : const [];
      }));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Likely supported'), findsOneWidget);
      expect(find.text('Other devices'), findsOneWidget);
      // The matched device carries the product name from the spec.
      expect(find.text('Example Smart Bulb'), findsOneWidget);

      final likelyHeader = tester.getTopLeft(find.text('Likely supported')).dy;
      final otherHeader = tester.getTopLeft(find.text('Other devices')).dy;
      final matched = tester.getTopLeft(find.text('ACME_Bulb')).dy;
      expect(likelyHeader, lessThan(matched));
      expect(matched, lessThan(otherHeader));

      // The louder unknown device is still listed, just below the fold.
      await tester.scrollUntilVisible(find.text('Anonymous Thing'), 200);
      expect(find.text('Anonymous Thing'), findsOneWidget);
    });

    testWidgets('an OUI-only match is a hint, not a supported-device claim',
        (tester) async {
      final fake =
          FakeBleService(devicesToEmit: [_device('01', name: 'Mystery')]);
      await tester.pumpWidget(wrapWithCatalogue(
        fake,
        matchFor: (_) => [_scanMatch(MatchConfidence.possible)],
      ));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Likely supported'), findsNothing);
      expect(find.text('Possibly Acme'), findsOneWidget);
      // Never the product name off a shared OUI.
      expect(find.text('Example Smart Bulb'), findsNothing);
    });

    testWidgets('an unrecognised list keeps the plain Found header',
        (tester) async {
      final fake = FakeBleService(devicesToEmit: [_device('01')]);
      await tester
          .pumpWidget(wrapWithCatalogue(fake, matchFor: (_) => const []));

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      expect(find.text('Found'), findsOneWidget);
      expect(find.text('Other devices'), findsNothing);
    });
  });

  testWidgets('FAB is disabled while scanning is in-flight', (tester) async {
    final fake = FakeBleService(
      devicesToEmit: [_device('01')],
      scanStepDelay: const Duration(milliseconds: 200),
    );
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump(const Duration(milliseconds: 50));

    final fab =
        tester.widget<FloatingActionButton>(find.byType(FloatingActionButton));
    expect(fab.onPressed, isNull);
    expect(find.text('Scanning...'), findsOneWidget);

    await tester.pumpAndSettle();
  });

  testWidgets('renders error state when scan throws', (tester) async {
    final fake = FakeBleService(scanError: StateError('boom'));
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // The user gets guidance, not the exception. 'Bad state:' is Dart's
    // rendering of a StateError and must never reach the screen.
    expect(find.textContaining('Scanning failed'), findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.textContaining('boom'), findsNothing);
  });

  testWidgets('settings gear opens the Home Assistant screen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        sharedPreferencesProvider.overrideWithValue(_prefs),
        settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
        haApiClientProvider.overrideWithValue(FakeHaApiClient()),
      ],
      child: const MaterialApp(home: ScanScreen()),
    ));

    await tester.tap(find.byIcon(Icons.settings));
    await tester.pumpAndSettle();

    expect(find.byType(HaSettingsScreen), findsOneWidget);
  });

  testWidgets('shows a distinct no-results state after an empty scan',
      (tester) async {
    // Never-scanned vs scanned-found-nothing must not be the same dead-end.
    final fake = FakeBleService();
    await tester.pumpWidget(_wrap(fake));

    // Before scanning: the generic prompt.
    expect(find.text('Scan for BLE Devices'), findsOneWidget);
    expect(find.text('No devices found'), findsNothing);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // After an empty scan: the distinct guidance + rescan action.
    expect(find.text('No devices found'), findsOneWidget);
    expect(find.textContaining('Move closer'), findsOneWidget);
    expect(find.text('Scan again'), findsOneWidget);
    expect(find.text('Scan for BLE Devices'), findsNothing);
  });

  testWidgets('permission denial shows specific guidance and open-settings',
      (tester) async {
    final fake =
        FakeBleService(scanError: const BlePermissionDeniedException());
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    expect(find.text('Bluetooth permission needed'), findsOneWidget);
    // The open-settings action uses a settings icon, not the refresh default.
    final openSettingsButton =
        find.widgetWithText(ElevatedButton, 'Open settings');
    expect(openSettingsButton, findsOneWidget);
    expect(
      find.descendant(
          of: openSettingsButton, matching: find.byIcon(Icons.settings)),
      findsOneWidget,
    );
    expect(
      find.descendant(
          of: openSettingsButton, matching: find.byIcon(Icons.refresh)),
      findsNothing,
    );
    await tester.scrollUntilVisible(find.text('Retry'), 80);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('tapping a device stops the scan before navigating',
      (tester) async {
    final fake = FakeBleService(devicesToEmit: [_device('01', name: 'ACME_A')]);
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(fake.stopScanCount, 0);

    await tester.tap(find.text('ACME_A'));
    await tester.pump();

    // Scan is stopped before the device screen is pushed / connect begins.
    expect(fake.stopScanCount, greaterThan(0));

    await tester.pumpAndSettle();
  });

  testWidgets('non-connectable device tile has no chevron', (tester) async {
    final fake = FakeBleService(devicesToEmit: [
      _device('01', name: 'nope', connectable: false),
    ]);
    await tester.pumpWidget(_wrap(fake));

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    // Scoped to the list: the docked ad bar legitimately carries a chevron of
    // its own.
    expect(
      find.descendant(
          of: find.byType(ListView),
          matching: find.byIcon(Icons.chevron_right)),
      findsNothing,
    );
  });
}

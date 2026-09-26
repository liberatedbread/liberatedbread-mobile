// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_group_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/settings_store_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/printer_provider.dart';
import 'package:liberated_bread_mobile/screens/print_label_screen.dart';
import 'package:liberated_bread_mobile/services/saved_device_store.dart';
import 'package:liberated_bread_mobile/screens/roomba_transport_screen.dart';
import 'package:liberated_bread_mobile/screens/saved_devices_screen.dart';
import 'package:liberated_bread_mobile/services/roomba_credential_store.dart';
import 'package:liberated_bread_mobile/services/panel_resolution_cache.dart';
import 'package:liberated_bread_mobile/services/settings_store.dart';
import 'package:liberated_bread_mobile/services/spec_choice_store.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

late SharedPreferences _prefs;

Widget _wrap({List<SavedPrinter>? printers}) => ProviderScope(
  overrides: [
    if (printers != null)
      savedPrintersProvider.overrideWith((ref) async => printers),
    bleServiceProvider.overrideWithValue(FakeBleService()),
    sharedPreferencesProvider.overrideWithValue(_prefs),
    // Forget now clears the Roomba and Rabbit Air secrets too, and the
    // real store behind them is the keychain plugin, whose platform
    // channel never answers in a widget test — the forget would hang.
    settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
  ],
  child: const MaterialApp(home: SavedDevicesScreen()),
);

Future<void> _seed(String json) async {
  SharedPreferences.setMockInitialValues({'saved_devices_v1': json});
  _prefs = await SharedPreferences.getInstance();
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('an empty pane explains how devices get here', (tester) async {
    // The pane is reachable from the bottom bar before anything is paired, so
    // it has to say something more useful than being blank.
    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('No saved devices yet'), findsOneWidget);
    expect(find.textContaining('Nearby tab'), findsOneWidget);
  });

  testWidgets('lists a previously paired device', (tester) async {
    await _seed(
      '[{"id":"aa","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]',
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Paired'), findsWidgets);
    expect(find.text('Probe One'), findsOneWidget);
  });

  testWidgets('forgetting a device removes it and says so', (tester) async {
    await _seed(
      '[{"id":"aa","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]',
    );

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Forget Probe One'));
    await tester.pumpAndSettle();
    // Nothing happens until the dialog is answered.
    expect(find.text('Forget Probe One?'), findsOneWidget);
    expect(find.text('Removed Probe One'), findsNothing);

    await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
    await tester.pumpAndSettle();

    expect(find.text('Probe One'), findsNothing);
    expect(find.text('Removed Probe One'), findsOneWidget);
    expect(find.text('No saved devices yet'), findsOneWidget);
  });

  testWidgets('a forget that is cancelled leaves the device and its groups', (
    tester,
  ) async {
    // Regression. The close icon used to act on the first tap: it sits on the
    // trailing edge of a row whose whole surface is the reconnect target, and
    // what it does (for a Wi-Fi device: the stored password, the certificate
    // pin, the group memberships) has no undo. Every other destructive flow
    // in the app confirms first; this one must too.
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1':
          '[{"id":"aa","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]',
      'device_groups_v1': '[{"id":"g1","name":"Room","deviceIds":["aa","bb"]}]',
    });
    _prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SavedDevicesScreen)),
      listen: false,
    );

    await tester.tap(find.byTooltip('Forget Probe One'));
    await tester.pumpAndSettle();
    expect(find.text('Forget Probe One?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(find.text('Probe One'), findsOneWidget);
    expect(find.text('Removed Probe One'), findsNothing);
    expect(container.read(deviceGroupsProvider).single.deviceIds, ['aa', 'bb']);
    expect(container.read(savedDevicesProvider).map((d) => d.id), ['aa']);
  });

  testWidgets('a device saved without a name still has a title', (
    tester,
  ) async {
    await _seed('[{"id":"aa","name":"","lastSeen":"2026-07-30T12:00:00.000"}]');

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    expect(find.text('Unknown device'), findsOneWidget);
  });

  testWidgets('forgetting a device prunes it from stored groups', (
    tester,
  ) async {
    // Without the prune, the membership lies dormant and silently restores
    // itself the moment the same device is saved again.
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1':
          '[{"id":"aa","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]',
      'device_groups_v1': '[{"id":"g1","name":"Room","deviceIds":["aa","bb"]}]',
    });
    _prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();
    final container = ProviderScope.containerOf(
      tester.element(find.byType(SavedDevicesScreen)),
      listen: false,
    );

    await tester.tap(find.byTooltip('Forget Probe One'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
    await tester.pumpAndSettle();

    expect(container.read(deviceGroupsProvider).single.deviceIds, ['bb']);
  });

  testWidgets('forgetting a device drops the preferences kept under its id', (
    tester,
  ) async {
    // R-063: these are keyed by the device id, and a re-saved device gets the
    // same id, so a spec choice the user removed the device BECAUSE of came
    // straight back — along with its LED designs and remembered panel size —
    // with nothing on screen to explain it.
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1':
          '[{"id":"aa","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]',
      'spec_choices_v1': '{"aa":"Wrong Bulb|Acme","bb":"Right Bulb|Acme"}',
      'saved_designs_v1:aa': '[{"cid":1,"name":"Heart"}]',
      'panel_res_aa': '16x16',
    });
    _prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(_wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byTooltip('Forget Probe One'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Forget'));
    await tester.pumpAndSettle();

    expect(SpecChoiceStore(_prefs).load(), {'bb': 'Right Bulb|Acme'});
    expect(_prefs.getString('saved_designs_v1:aa'), isNull);
    expect(PanelResolutionCache(_prefs).get('aa'), isNull);
  });

  group('relativeTime', () {
    test('reads as a relative time until that stops being useful', () {
      final now = DateTime.now();
      expect(relativeTime(now), 'Just now');
      expect(relativeTime(now.subtract(const Duration(minutes: 5))), '5m ago');
      expect(relativeTime(now.subtract(const Duration(hours: 3))), '3h ago');
      expect(relativeTime(now.subtract(const Duration(days: 2))), '2d ago');
      // Past a week "42d ago" tells you less than a date does.
      expect(relativeTime(DateTime(2026, 1, 2)), '2026-01-02');
    });
  });

  // R-093: the transport chooser was unreachable — its only caller passed no
  // credentials, so the direct and rest980 sections could never draw, and the
  // rest980 client's "clear the server address in this robot's settings"
  // pointed at a setting with no UI. A saved robot now carries the entry.
  group('a saved Roomba can be re-pointed', () {
    const blid = 'ABC123';
    const roombaSpec = 'Roomba|iRobot';

    Widget wrapRoomba({required SettingsStore store}) => ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        sharedPreferencesProvider.overrideWithValue(_prefs),
        settingsStoreProvider.overrideWithValue(store),
        specCodecProvider.overrideWithValue(
          FakeSpecCodec(
            networkEntities: (_) => const [
              NetworkEntityDto(
                isInstanced: false,
                name: 'Vacuum',
                platform: 'vacuum',
                stateCommand: 'state',
                options: [],
                actions: [],
              ),
            ],
            networkCapabilitiesResult: const NetworkCapabilitiesDto(
              protocolHandler: 'roomba_mqtt',
              tlsSelfSigned: true,
              advertisedPortUnreliable: false,
              mqttClientIdGenerated: true,
            ),
          ),
        ),
        specCatalogueProvider.overrideWith(
          (ref) async =>
              FallbackSpecCatalogue.fromParsed(ref.watch(specCodecProvider), [
                (
                  spec: DeviceSpecDto(
                    nameMatchers: const [],
                    platformFallbackTypes: const [],
                    txtMatchGroups: const [],
                    hiddenEntityNames: const [],
                    deviceName: 'Roomba',
                    manufacturer: 'iRobot',
                    manufacturerStatus: 'active',
                    protocol: 'wifi',
                    localNamePrefixes: const [],
                    localNames: const [],
                    serviceUuids: const [],
                    companyIds: Uint16List(0),
                    macPrefixes: const [],
                    mdnsServiceTypes: const [],
                    ssdpSearchTargets: const [],
                    lanProtocols: const [],
                    defaultPort: null,
                    entities: const [],
                    services: const [],
                  ),
                  yaml: 'roomba-yaml',
                ),
              ]),
        ),
      ],
      child: const MaterialApp(home: SavedDevicesScreen()),
    );

    Future<void> seedRobot() async {
      SharedPreferences.setMockInitialValues({
        'saved_network_devices_v1':
            '[{"id":"r1","name":"Dusty","lastSeen":"2026-07-30T12:00:00.000",'
            '"host":"192.168.1.40","txt":{"blid":"$blid"},'
            '"specKey":"$roombaSpec"}]',
      });
      _prefs = await SharedPreferences.getInstance();
    }

    testWidgets('opens the transport chooser with the stored password', (
      tester,
    ) async {
      await seedRobot();
      final store = InMemorySettingsStore();
      await RoombaCredentialStore(
        store,
      ).save(const RoombaCredentials(blid: blid, password: ':1:9:secret'));

      await tester.pumpWidget(wrapRoomba(store: store));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('How to reach this robot'));
      await tester.pumpAndSettle();

      expect(find.byType(RoombaTransportScreen), findsOneWidget);
      // With credentials in hand all three paths are offered — the two that
      // need the local password included.
      expect(find.text('Straight at the robot'), findsOneWidget);
    });

    testWidgets('says so when the robot has no password on this phone', (
      tester,
    ) async {
      // Adopted through Home Assistant: the robot is drivable, just not
      // directly, and a chooser with two dead sections would not say that.
      await seedRobot();

      await tester.pumpWidget(wrapRoomba(store: InMemorySettingsStore()));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('How to reach this robot'));
      await tester.pumpAndSettle();

      expect(find.byType(RoombaTransportScreen), findsNothing);
      expect(find.textContaining('only be reached through'), findsOneWidget);
    });

    testWidgets('a device that is not a robot has no such action', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'saved_network_devices_v1':
            '[{"id":"p1","name":"Desk Lamp","lastSeen":"2026-07-30T12:00:00.000",'
            '"host":"192.168.1.41"}]',
      });
      _prefs = await SharedPreferences.getInstance();

      await tester.pumpWidget(wrapRoomba(store: InMemorySettingsStore()));
      await tester.pumpAndSettle();

      expect(find.byTooltip('How to reach this robot'), findsNothing);
    });
  });

  group('asset labels', () {
    final printer = SavedPrinter(
      name: 'Label Cat',
      specYaml: 'cat-yaml',
      raster: const RasterPrintDto(
        handler: 'cat_printer',
        transport: 'ble_write_plan',
        encodable: true,
        dpi: 203,
        dpiAssumed: false,
        printableDots: 384,
        media: [],
      ),
      ble: SavedDevice(
        id: 'cc',
        name: 'Label Cat',
        lastSeen: DateTime(2026, 7, 30),
      ),
    );

    testWidgets('no label action until there is a printer to use', (
      tester,
    ) async {
      await _seed(
        '[{"id":"aa","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]',
      );
      await tester.pumpWidget(_wrap(printers: const []));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Print a label for Probe One'), findsNothing);
    });

    testWidgets('a saved printer puts the device on a label', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await _seed(
        '[{"id":"aa:bb","name":"Probe One","lastSeen":"2026-07-30T12:00:00.000"}]',
      );
      await tester.pumpWidget(_wrap(printers: [printer]));
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Print a label for Probe One'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      // One printer: no picker, straight to the composer, prefilled.
      expect(find.byType(PrintLabelScreen), findsOneWidget);
      expect(find.text('Label Cat'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Probe One'), findsOneWidget);
      expect(find.widgetWithText(TextField, 'aa:bb'), findsWidgets);
    });
  });
}

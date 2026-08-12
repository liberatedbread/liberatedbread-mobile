// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/screens/device_screen.dart';
import 'package:liberated_bread_mobile/screens/find_device_screen.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/ha_sensor_forwarder.dart';
import 'package:liberated_bread_mobile/providers/device_description_provider.dart';
import 'package:liberated_bread_mobile/services/number_registry.dart';

import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_ha_api_client.dart';

class _RecordingForwarder extends HaSensorForwarder {
  final Map<String, String> noted = {};

  _RecordingForwarder()
      : super(api: FakeHaApiClient(), readConfig: () async => null);

  @override
  void noteDeviceName(String deviceId, String name) {
    noted[deviceId] = name;
    super.noteDeviceName(deviceId, name);
  }
}

final _device = IoTDevice(
  id: '01',
  name: 'ACME_A',
  rssi: -40,
  isConnectable: true,
  discoveredAt: DateTime(2026),
);

/// Resolved in [setUp]; the device screen records a saved device on a
/// successful connect, so the store must be wired the same way `main()` does.
late SharedPreferences _prefs;

String _table(Map<String, String> rows) {
  final keys = rows.keys.toList()..sort();
  return keys.map((k) => '$k\t${rows[k]}\n').join();
}

/// Just enough registry to resolve the addresses these tests use. Built here
/// rather than read from the vendored TSVs so the assertions do not move when
/// IEEE reassigns something.
final _registry = NumberRegistry(
  addressBlocks: [
    RegistryTable.parse(_table({'B894D9': 'Texas Instruments'}), keyWidth: 6),
  ],
  companyIds:
      RegistryTable.parse(_table({'00961': 'Ember Technologies'}), keyWidth: 5),
  serviceUuids:
      RegistryTable.parse(_table({'180f': 'Battery Service'}), keyWidth: 4),
);

Widget _wrap(FakeBleService fake, {IoTDevice? device}) => ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(fake),
        sharedPreferencesProvider.overrideWithValue(_prefs),
        // Without this the provider indexes the real vendored registry off
        // rootBundle, so an assertion here would depend on IEEE's data.
        numberRegistryProvider.overrideWith((ref) async => _registry),
      ],
      child: MaterialApp(home: DeviceScreen(device: device ?? _device)),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('shows connecting state immediately', (tester) async {
    final fake = FakeBleService();
    await tester.pumpWidget(_wrap(fake));

    expect(find.text('Connecting...'), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('renders services after discovery succeeds', (tester) async {
    final fake = FakeBleService(servicesToReturn: const [
      BleDiscoveredService(
          uuid: '0000180f-0000-1000-8000-00805f9b34fb', characteristics: []),
    ]);
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    expect(find.text('Battery Service'), findsOneWidget);
  });

  testWidgets('reports the device name to the HA forwarder on connect',
      (tester) async {
    final forwarder = _RecordingForwarder();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(FakeBleService()),
        haForwarderProvider.overrideWithValue(forwarder),
      ],
      child: MaterialApp(home: DeviceScreen(device: _device)),
    ));
    await tester.pumpAndSettle();

    expect(forwarder.noted, {'01': 'ACME_A'});
  });

  testWidgets('shows error state and retry when connect fails', (tester) async {
    final fake = FakeBleService(connectError: StateError('no BLE'));
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not connect to this device'),
        findsOneWidget);
    expect(find.textContaining('no BLE'), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.byIcon(Icons.refresh), findsOneWidget);
  });

  testWidgets('retry re-attempts connection', (tester) async {
    final fake = FakeBleService(connectError: StateError('boom'));
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();
    expect(fake.connectedIds, isEmpty);

    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    // Still errors (connectError is sticky) but we've attempted again.
    expect(find.textContaining('Could not connect to this device'),
        findsOneWidget);
    expect(find.textContaining('Bad state'), findsNothing);
  });

  testWidgets('discovery failure disconnects the half-open peripheral',
      (tester) async {
    final fake = FakeBleService(discoverError: StateError('gatt fail'));
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    // Error surfaced — as guidance, not as the raw GATT exception...
    expect(find.textContaining('Could not connect to this device'),
        findsOneWidget);
    expect(find.textContaining('gatt fail'), findsNothing);
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    // ...and the half-open link we established was torn down exactly once, so
    // nothing is left connected behind the error state.
    expect(fake.connectedIds, ['01']);
    expect(fake.disconnectedIds, ['01']);
  });

  testWidgets('unmount during pending connect still disconnects (no leak)',
      (tester) async {
    // Hold connect() in flight so we can dispose the screen mid-connect.
    final connectGate = Completer<void>();
    final fake = FakeBleService(connectGate: connectGate);

    await tester.pumpWidget(_wrap(fake));
    await tester.pump(); // initState -> _connect() starts; connect() pending
    expect(find.text('Connecting...'), findsOneWidget);
    expect(fake.events, isEmpty);

    // Deterministically unmount the DeviceScreen (dispose() runs synchronously
    // during this pump) while connect() is still in flight. The peripheral
    // isn't connected yet, so nothing should be disconnected at this point.
    await tester
        .pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
    expect(fake.events, isEmpty);

    // Now let connect() resolve. The (unmounted) _connect() must tear down the
    // now-live connection instead of leaking it.
    connectGate.complete();
    await tester.pump();
    await tester.pump();

    // The disconnect must land AFTER the connect — the pre-fix code disconnected
    // BEFORE connect resolved (a no-op against a not-yet-connected peripheral)
    // and then returned without disconnecting the now-live link, leaking it.
    expect(fake.events, ['connect:01', 'disconnect:01']);
  });

  testWidgets('Find device opens the find screen for the connected device',
      (tester) async {
    final fake = FakeBleService(
      servicesToReturn: const [
        BleDiscoveredService(
            uuid: '0000180f-0000-1000-8000-00805f9b34fb', characteristics: []),
      ],
      rssiValues: const [-58],
    );
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    expect(find.text('Find device'), findsOneWidget);
    await tester.tap(find.text('Find device'));
    // Explicit pumps: once pushed, the find screen polls RSSI on a periodic
    // timer, so this stays on deterministic durations.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(FindDeviceScreen), findsOneWidget);
    // The find screen reads RSSI over the connection this screen owns.
    expect(fake.rssiReadCount, greaterThanOrEqualTo(1));

    // Unmount everything so the find screen's poll timer is cancelled
    // before the test ends.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
      'the failed state offers Try to find, and it lands in the find '
      'screen once the connect succeeds', (tester) async {
    // A failed connect usually MEANS out of range or powered off — "where is
    // it?" is the question that state poses, so the find affordance belongs
    // on it, not only on the connected header. Finding needs a live link for
    // its RSSI ping, so the button is connect-first: hence "Try".
    final fake = FakeBleService(connectError: StateError('out of range'));
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    // Twice: the app-bar status line and the state card both say it.
    expect(find.text('Connection failed'), findsNWidgets(2));
    expect(find.text('Try to find device'), findsOneWidget);

    // The user moved closer: the retry connect works now.
    fake.connectError = null;
    await tester.tap(find.text('Try to find device'));
    await tester.pumpAndSettle();

    expect(find.byType(FindDeviceScreen), findsOneWidget);
  });

  testWidgets(
      'a failed Try to find stays on the error state, and a later '
      'plain Retry does not surprise-open the find screen', (tester) async {
    final fake = FakeBleService(connectError: StateError('still out of range'));
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Try to find device'));
    await tester.pumpAndSettle();
    expect(find.byType(FindDeviceScreen), findsNothing);
    expect(find.text('Connection failed'), findsNWidgets(2));

    // The intent to find died with its attempt: a Retry pressed later is a
    // request for the controls screen, not the locator.
    fake.connectError = null;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();

    expect(find.byType(FindDeviceScreen), findsNothing);
    expect(find.text('Find device'), findsOneWidget,
        reason: 'the ready header, with its usual find button');
  });

  testWidgets('the disconnected state offers Try to find too', (tester) async {
    final conn = StreamController<BleConnectionState>.broadcast();
    addTearDown(conn.close);
    final fake = FakeBleService(connectionStateStream: conn.stream);
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    conn.add(BleConnectionState.disconnected);
    await tester.pumpAndSettle();

    expect(find.text('Device disconnected'), findsOneWidget);
    expect(find.text('Try to find device'), findsOneWidget);

    await tester.tap(find.text('Try to find device'));
    await tester.pumpAndSettle();
    expect(find.byType(FindDeviceScreen), findsOneWidget);
  });

  testWidgets('an unexpected disconnect flips to the reconnect state',
      (tester) async {
    final conn = StreamController<BleConnectionState>.broadcast();
    addTearDown(conn.close);
    final fake = FakeBleService(
      servicesToReturn: const [
        BleDiscoveredService(
            uuid: '0000180f-0000-1000-8000-00805f9b34fb', characteristics: []),
      ],
      connectionStateStream: conn.stream,
    );
    await tester.pumpWidget(_wrap(fake));
    await tester.pumpAndSettle();

    // Reached the ready state (controls visible).
    expect(find.text('Battery Service'), findsOneWidget);

    // Peripheral drops.
    conn.add(BleConnectionState.disconnected);
    await tester.pumpAndSettle();

    expect(find.text('Device disconnected'), findsOneWidget);
    expect(find.text('Reconnect'), findsOneWidget);
    expect(find.text('Battery Service'), findsNothing);
  });

  group('identity rows', () {
    IoTDevice deviceWith({
      String id = 'B8:94:D9:11:22:33',
      List<int> companyIds = const [],
    }) =>
        IoTDevice(
          id: id,
          name: 'ACME_A',
          rssi: -40,
          isConnectable: true,
          discoveredAt: DateTime(2026),
          companyIds: companyIds,
        );

    Future<void> pumpReady(WidgetTester tester, IoTDevice device) async {
      await tester.pumpWidget(_wrap(
        FakeBleService(servicesToReturn: const [
          BleDiscoveredService(
              uuid: '0000180f-0000-1000-8000-00805f9b34fb',
              characteristics: []),
        ]),
        device: device,
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the address and the block that owns it', (tester) async {
      await pumpReady(tester, deviceWith());

      expect(find.text('Address'), findsOneWidget);
      expect(find.text('B8:94:D9:11:22:33'), findsOneWidget);
      expect(find.text('Address block'), findsOneWidget);
      expect(find.text('Texas Instruments'), findsOneWidget);
    });

    testWidgets('keeps the advertised company distinct from the block',
        (tester) async {
      // The Caseta bridge in miniature: the address block is the radio
      // module's vendor and the company ID is the product's. Collapsing them
      // into one "manufacturer" line would report Texas Instruments as the
      // maker of an Ember device.
      await pumpReady(tester, deviceWith(companyIds: const [961]));

      expect(find.text('Advertises as'), findsOneWidget);
      expect(find.text('Ember Technologies'), findsOneWidget);
      expect(find.text('Address block'), findsOneWidget);
      expect(find.text('Texas Instruments'), findsOneWidget);
    });

    testWidgets('an unassigned block contributes no row', (tester) async {
      await pumpReady(tester, deviceWith(id: 'FF:FF:FF:11:22:33'));

      expect(find.text('Address'), findsOneWidget);
      expect(find.text('Address block'), findsNothing);
    });

    testWidgets('a CoreBluetooth UUID is not offered as an address',
        (tester) async {
      // Apple platforms substitute a per-host UUID for the hardware address.
      // It is not a MAC, so there is no block to look up and nothing to show —
      // printing the UUID under "Address" would invite a registry lookup that
      // can only ever be wrong.
      await pumpReady(
          tester, deviceWith(id: 'C47C8DAB-1234-5678-9ABC-DEF012345678'));

      expect(find.text('Address'), findsNothing);
      expect(find.text('Address block'), findsNothing);
    });
  });

  testWidgets('a resolved spec match lands on the saved-device record',
      (tester) async {
    final matched = DeviceSpecDto(
      deviceName: 'Example Smart Bulb',
      manufacturer: 'Acme Corp',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      category: 'light',
      localNamePrefixes: const [],
      serviceUuids: const [],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      services: const [],
      entities: const [],
    );
    final fake = FakeBleService(servicesToReturn: const [
      BleDiscoveredService(
          uuid: '0000180f-0000-1000-8000-00805f9b34fb', characteristics: []),
    ]);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(fake),
        sharedPreferencesProvider.overrideWithValue(_prefs),
        numberRegistryProvider.overrideWith((ref) async => _registry),
        matchedDeviceSpecProvider.overrideWith((ref, request) async =>
            SpecMatchOutcome.auto(MatchedSpec(spec: matched, yaml: 'yaml'))),
      ],
      child: MaterialApp(home: DeviceScreen(device: _device)),
    ));
    await tester.pumpAndSettle();

    final element = tester.element(find.byType(DeviceScreen));
    final container = ProviderScope.containerOf(element, listen: false);
    final saved = container
        .read(savedDevicesProvider)
        .firstWhere((d) => d.id == _device.id);
    expect(saved.category, 'light');
    expect(saved.specKey, 'Example Smart Bulb|Acme Corp');
  });
}

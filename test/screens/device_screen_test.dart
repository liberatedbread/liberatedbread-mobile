// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/ble_discovered_service.dart';
import 'package:opengreeniot_mobile/models/iot_device.dart';
import 'package:opengreeniot_mobile/providers/ble_provider.dart';
import 'package:opengreeniot_mobile/providers/ha_provider.dart';
import 'package:opengreeniot_mobile/screens/device_screen.dart';
import 'package:opengreeniot_mobile/services/ble_service.dart';
import 'package:opengreeniot_mobile/services/ha_sensor_forwarder.dart';

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

Widget _wrap(FakeBleService fake) => ProviderScope(
      overrides: [bleServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(home: DeviceScreen(device: _device)),
    );

void main() {
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
}

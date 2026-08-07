// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/find_device.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/find_device_screen.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _chr = '0000fff1-0000-1000-8000-00805f9b34fb';

const _immediateAlertService = BleDiscoveredService(
  uuid: immediateAlertServiceUuid,
  characteristics: [
    BleDiscoveredCharacteristic(
      uuid: alertLevelCharUuid,
      canRead: false,
      canWrite: true,
      canWriteWithoutResponse: true,
      canNotify: false,
    ),
  ],
);

const _batteryService = BleDiscoveredService(
  uuid: '0000180f-0000-1000-8000-00805f9b34fb',
  characteristics: [
    BleDiscoveredCharacteristic(
      uuid: '00002a19-0000-1000-8000-00805f9b34fb',
      canRead: true,
      canWrite: false,
      canNotify: true,
    ),
  ],
);

/// A spec whose control characteristic declares a fixed `find_me` command.
const _findMeSpec = DeviceSpecDto(
  deviceName: 'Fitness Band',
  manufacturer: 'Test Co',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  localNamePrefix: 'Band',
  serviceUuids: [_svc],
  entities: <EntityDto>[],
  services: [
    ServiceDto(uuid: _svc, name: 'Control', characteristics: [
      CharacteristicDto(
        uuid: _chr,
        name: 'Command',
        canRead: false,
        canWrite: true,
        canNotify: false,
        commands: [
          CommandDto(
            name: 'find_me',
            description: 'Make the band alert',
            parameters: [],
            isFixed: true,
            isEncodable: true,
          ),
        ],
        formatFields: [],
      ),
    ]),
  ],
);

const _controlService = BleDiscoveredService(
  uuid: _svc,
  characteristics: [
    BleDiscoveredCharacteristic(
      uuid: _chr,
      canRead: false,
      canWrite: true,
      canWriteWithoutResponse: true,
      canNotify: false,
    ),
  ],
);

Future<Widget> _wrap({
  required FakeBleService ble,
  required FakeSpecCodec codec,
  required List<BleDiscoveredService> services,
  String deviceName = 'Widget',
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      bleServiceProvider.overrideWithValue(ble),
      specCodecProvider.overrideWithValue(codec),
      deviceSpecsProvider.overrideWith((ref) => {'spec.yaml': 'yaml'}),
    ],
    child: MaterialApp(
      home: FindDeviceScreen(
        deviceId: '01',
        deviceName: deviceName,
        services: services,
      ),
    ),
  );
}

/// Unmount the screen so its poll timer is cancelled before the test ends.
Future<void> _teardown(WidgetTester tester) =>
    tester.pumpWidget(const SizedBox());

/// The alert section and footer sit below the gauge and the raw-values card,
/// past what the default 600-pixel test viewport's lazy ListView ever builds;
/// a taller surface keeps the whole screen built and tappable without scroll
/// choreography.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('shows the raw RSSI readings and a distance guess',
      (tester) async {
    // -59 dBm is exactly the assumed 1 m power, making the guess stable.
    final ble = FakeBleService(rssiValues: const [-59]);
    await tester.pumpWidget(await _wrap(
      ble: ble,
      codec: FakeSpecCodec(),
      services: const [_batteryService],
    ));
    await tester.pump(); // initial poll resolves

    // Raw values: live, smoothed, strongest and weakest all read -59 dBm.
    expect(find.text('Signal (raw values)'), findsOneWidget);
    expect(find.text('Live signal'), findsOneWidget);
    expect(find.text('-59 dBm'), findsNWidgets(4));

    // Distance guess appears in the gauge and in the raw-values card.
    expect(find.text('≈ 1.0 m'), findsNWidgets(2));
    expect(find.text('Very close'), findsOneWidget);

    // Device name is visible in the app bar.
    expect(find.text('Widget'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets('keeps polling on the timer and updates the readings',
      (tester) async {
    final ble = FakeBleService(rssiValues: const [-80, -60]);
    await tester.pumpWidget(await _wrap(
      ble: ble,
      codec: FakeSpecCodec(),
      services: const [_batteryService],
    ));
    await tester.pump();
    expect(find.text('-80 dBm'), findsWidgets);
    expect(ble.rssiReadCount, 1);

    await tester.pump(const Duration(seconds: 1));
    expect(ble.rssiReadCount, 2);
    // Live reading moved to the newest sample; the -80 survives as Weakest.
    expect(find.text('-60 dBm'), findsWidgets);
    expect(find.text('-80 dBm'), findsOneWidget);

    await _teardown(tester);
  });

  testWidgets(
      'offers Ring alert for the standard Immediate Alert service '
      'and writes the alert levels', (tester) async {
    _useTallSurface(tester);
    final ble = FakeBleService(rssiValues: const [-60]);
    await tester.pumpWidget(await _wrap(
      ble: ble,
      codec: FakeSpecCodec(),
      services: const [_immediateAlertService],
    ));
    await tester.pump();

    expect(find.text('Make it noticeable'), findsOneWidget);
    await tester.tap(find.text('Ring alert'));
    await tester.pump();
    await tester.pump();
    expect(ble.writes, hasLength(1));
    expect(ble.writes.single.charUuid, alertLevelCharUuid);
    expect(ble.writes.single.value, [0x02]);
    expect(find.text('Sent Ring alert'), findsOneWidget);

    await tester.tap(find.text('Stop ring alert'));
    await tester.pump();
    await tester.pump();
    expect(ble.writes, hasLength(2));
    expect(ble.writes.last.value, [0x00]);

    await _teardown(tester);
  });

  testWidgets('offers a spec-declared find_me command and encodes it',
      (tester) async {
    _useTallSurface(tester);
    final ble = FakeBleService(rssiValues: const [-60]);
    final codec = FakeSpecCodec(
      spec: _findMeSpec,
      matches: const [
        MatchResult(
          spec: _findMeSpec,
          matchedByNamePrefix: true,
          matchedServiceUuids: [_svc],
        ),
      ],
      encoded: Uint8List.fromList(const [0xCD, 0x01]),
    );
    await tester.pumpWidget(await _wrap(
      ble: ble,
      codec: codec,
      services: const [_controlService],
      deviceName: 'Band 7',
    ));
    // Let the spec match resolve (async provider chain).
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Find me'), findsOneWidget);
    // No Stop button for a plain command — nothing says it can be stopped.
    expect(find.textContaining('Stop'), findsNothing);

    await tester.tap(find.text('Find me'));
    await tester.pump();
    await tester.pump();

    expect(codec.encodeCalls, hasLength(1));
    expect(codec.encodeCalls.single.commandName, 'find_me');
    expect(codec.encodeCalls.single.charUuid, _chr);
    expect(ble.writes.single.value, [0xCD, 0x01]);
    expect(ble.writes.single.charUuid, _chr);

    await _teardown(tester);
  });

  testWidgets('says so when the device has no alert commands', (tester) async {
    _useTallSurface(tester);
    await tester.pumpWidget(await _wrap(
      ble: FakeBleService(rssiValues: const [-60]),
      codec: FakeSpecCodec(), // parse fails -> no spec matched
      services: const [_batteryService],
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      find.textContaining('doesn\'t declare a sound or flash command'),
      findsOneWidget,
    );

    await _teardown(tester);
  });

  testWidgets(
      'declares the signal lost after repeated read failures and '
      'recovers via Retry', (tester) async {
    final ble = FakeBleService(rssiError: StateError('gone'));
    await tester.pumpWidget(await _wrap(
      ble: ble,
      codec: FakeSpecCodec(),
      services: const [_batteryService],
    ));
    await tester.pump(); // failure 1
    expect(find.text('Signal lost'), findsNothing);

    await tester.pump(const Duration(seconds: 1)); // failure 2
    await tester.pump(const Duration(seconds: 1)); // failure 3 -> lost
    expect(find.text('Signal lost'), findsOneWidget);
    expect(
      find.textContaining('the connection may have dropped'),
      findsOneWidget,
    );
    final readsWhenLost = ble.rssiReadCount;
    expect(readsWhenLost, 3);

    // The poll timer stopped: no further reads while lost.
    await tester.pump(const Duration(seconds: 3));
    expect(ble.rssiReadCount, readsWhenLost);

    // Retry starts polling again (the fake still fails, but the attempt
    // proves the timer restarted).
    await tester.tap(find.text('Retry'));
    await tester.pump();
    expect(ble.rssiReadCount, greaterThan(readsWhenLost));

    await _teardown(tester);
  });
}

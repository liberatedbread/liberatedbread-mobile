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
final _findMeSpec = DeviceSpecDto(
  deviceName: 'Fitness Band',
  manufacturer: 'Test Co',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  localNamePrefixes: ['Band'],
  localNames: const [],
  serviceUuids: [_svc],
  companyIds: Uint16List(0),
  macPrefixes: [],
  mdnsServiceType: null,
  ssdpSearchTargets: [],
  lanProtocols: const [],
  defaultPort: null,
  entities: <EntityDto>[],
  services: [
    const ServiceDto(uuid: _svc, name: 'Control', characteristics: [
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
            advanced: false,
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
///
/// Registered with addTearDown rather than called at the end of a test body:
/// a failing expectation would otherwise skip the unmount, and the pending
/// 1 Hz timer's "A Timer is still pending" error would bury the real failure.
void _unmountOnTeardown(WidgetTester tester) {
  addTearDown(() => tester.pumpWidget(const SizedBox()));
}

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
    _unmountOnTeardown(tester);
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
  });

  testWidgets('keeps polling on the timer and updates the readings',
      (tester) async {
    _unmountOnTeardown(tester);
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
  });

  testWidgets(
      'offers Ring alert for the standard Immediate Alert service '
      'and writes the alert levels', (tester) async {
    _unmountOnTeardown(tester);
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
  });

  testWidgets('offers a spec-declared find_me command and encodes it',
      (tester) async {
    _unmountOnTeardown(tester);
    _useTallSurface(tester);
    final ble = FakeBleService(rssiValues: const [-60]);
    final codec = FakeSpecCodec(
      spec: _findMeSpec,
      matches: [
        MatchResult(
          spec: _findMeSpec,
          matchedByNamePrefix: true,
          matchedServiceUuids: [_svc],
          confidence: MatchConfidence.strong,
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
  });

  testWidgets('says so when the device has no alert commands', (tester) async {
    _unmountOnTeardown(tester);
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
  });

  testWidgets(
      'declares the signal lost after repeated read failures and '
      'recovers via Retry', (tester) async {
    _unmountOnTeardown(tester);
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

    // Retry starts polling again...
    await tester.tap(find.text('Retry'));
    await tester.pump();
    final readsAfterRetry = ble.rssiReadCount;
    expect(readsAfterRetry, greaterThan(readsWhenLost));
    // ...and the PERIODIC timer is re-armed, not just one read fired. Without
    // this second pump the assertion above passes even if Retry polls once
    // and never again, leaving a frozen readout that still looks live.
    await tester.pump(const Duration(seconds: 1));
    expect(ble.rssiReadCount, greaterThan(readsAfterRetry));
  });

  testWidgets('stops presenting readings as live once the signal is lost',
      (tester) async {
    _unmountOnTeardown(tester);
    _useTallSurface(tester);
    // Two good reads, THEN the link drops — the transition the signal-lost
    // state exists for, and the one where stale numbers can mislead.
    final ble = FakeBleService(
      rssiValues: const [-59, -59],
      rssiError: StateError('gone'),
      rssiErrorAfter: 2,
    );
    await tester.pumpWidget(await _wrap(
      ble: ble,
      codec: FakeSpecCodec(),
      services: const [_batteryService],
    ));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // Readings are live at this point.
    expect(find.text('≈ 1.0 m'), findsNWidgets(2));

    // Three failures.
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Signal lost'), findsOneWidget);

    // The frozen reading must NOT still be presented as current: the
    // distance guess is gone from both the gauge and the card, and the two
    // rows that claim to be live read blank.
    expect(find.text('≈ 1.0 m'), findsNothing);
    expect(find.text('Live signal'), findsOneWidget);
    expect(find.text('—'), findsWidgets);
    // Only Strongest/Weakest still show the value — they are history, not a
    // live claim, so they were 4 rows before the drop and are 2 now.
    expect(find.text('-59 dBm'), findsNWidgets(2));
    expect(find.text('Strongest'), findsOneWidget);
  });

  testWidgets('silences an alert it raised when the screen is left',
      (tester) async {
    _useTallSurface(tester);
    final ble = FakeBleService(rssiValues: const [-60]);
    await tester.pumpWidget(await _wrap(
      ble: ble,
      codec: FakeSpecCodec(),
      services: const [_immediateAlertService],
    ));
    await tester.pump();

    await tester.tap(find.text('Ring alert'));
    await tester.pump();
    await tester.pump();
    expect(ble.writes.single.value, [0x02]);

    // Navigating away must not leave a key finder buzzing with its only stop
    // control on the screen the user just left.
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(ble.writes, hasLength(2));
    expect(ble.writes.last.value, [0x00]);
    expect(ble.writes.last.charUuid, alertLevelCharUuid);
  });

  testWidgets('does not claim a steady signal before it has samples',
      (tester) async {
    _unmountOnTeardown(tester);
    await tester.pumpWidget(await _wrap(
      ble: FakeBleService(rssiValues: const [-60]),
      codec: FakeSpecCodec(),
      services: const [_batteryService],
    ));
    await tester.pump();

    // One sample is not a hot/cold verdict.
    expect(find.text('Signal steady'), findsNothing);
    expect(find.text('Reading signal...'), findsOneWidget);
  });

  testWidgets('renders without overflow at 2x text scale', (tester) async {
    _unmountOnTeardown(tester);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(ProviderScope(
      overrides: [
        bleServiceProvider
            .overrideWithValue(FakeBleService(rssiValues: const [-59])),
        specCodecProvider.overrideWithValue(FakeSpecCodec()),
        deviceSpecsProvider.overrideWith((ref) => {'spec.yaml': 'yaml'}),
      ],
      child: const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(2.0)),
          child: FindDeviceScreen(
            deviceId: '01',
            deviceName: 'Widget',
            services: [_batteryService],
          ),
        ),
      ),
    ));
    await tester.pump();

    // The distance headline and proximity bucket are the whole point of the
    // screen; at an ordinary accessibility font size they were rendering
    // behind overflow stripes with the caption clipped.
    expect(tester.takeException(), isNull);
    expect(find.text('≈ 1.0 m'), findsWidgets);
  });
}

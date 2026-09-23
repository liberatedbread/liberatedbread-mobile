// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The spec's connect-time handshake, executed.
//
// Six vendored specs declare an `initialization` block — "ordered handshake /
// setup steps executed after connecting and before normal commands", in the
// schema's words — and nothing ran them: a SpotLED panel's three writes to
// ff21 and a SmartDawn's two subscriptions were parsed to nowhere, so the
// first command a user sent went out to a device still waiting to be woken.
//
// What is under test here is the EXECUTOR, deliberately: every decision (which
// steps, what order, which service, which are executable at all) is made in
// Rust from the spec, and the Dart half is a loop that must do exactly what it
// is told, in order, and no more.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/device_screen.dart';
import 'package:liberated_bread_mobile/services/ble_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

BleHandshakeStepDto _step({
  String? service = '0000ff20-0000-1000-8000-00805f9b34fb',
  String characteristic = '0000ff21-0000-1000-8000-00805f9b34fb',
  List<int>? write,
  bool read = false,
  bool subscribe = false,
  int delayMs = 0,
}) => BleHandshakeStepDto(
  serviceUuid: service,
  characteristicUuid: characteristic,
  write: write == null ? null : Uint8List.fromList(write),
  read: read,
  subscribe: subscribe,
  delayMs: delayMs,
);

final _spec = DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'SpotLED Panel',
  manufacturer: 'SpotLED',
  manufacturerStatus: 'active',
  protocol: 'ble',
  category: 'light',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  services: const [],
  entities: const [],
);

late SharedPreferences _prefs;

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  test('every step runs in the order Rust put it in', () async {
    final ble = FakeBleService();
    final subs = await runBleHandshake(
      ble: ble,
      deviceId: '01',
      handshake: BleHandshakeDto(
        steps: [
          _step(write: const [0x00, 0x00, 0x00, 0x01]),
          _step(write: const [0x04, 0x14, 0x00, 0x00], read: true),
        ],
        described: const [],
      ),
    );

    expect(ble.writes.map((w) => w.value).toList(), [
      [0x00, 0x00, 0x00, 0x01],
      [0x04, 0x14, 0x00, 0x00],
    ]);
    expect(ble.reads.map((r) => r.charUuid).toList(), [
      '0000ff21-0000-1000-8000-00805f9b34fb',
    ]);
    expect(subs, isEmpty);
  });

  test(
    'a subscribe step opens notifications and hands back the handle',
    () async {
      // SmartDawn's shape: both notify channels open before anything is sent,
      // and they have to STAY open — the caller owns the cancel, because the
      // subscription's lifetime is the connection's, not the handshake's.
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final ble = FakeBleService(notifyStream: notify.stream);

      final subs = await runBleHandshake(
        ble: ble,
        deviceId: '01',
        handshake: BleHandshakeDto(
          steps: [
            _step(characteristic: '01010074-...', subscribe: true),
            _step(characteristic: '02010074-...', subscribe: true),
          ],
          described: const [],
        ),
      );

      expect(ble.subscriptions, ['01010074-...', '02010074-...']);
      expect(ble.writes, isEmpty);
      expect(subs, hasLength(2));
      for (final sub in subs) {
        await sub.cancel();
      }
    },
  );

  test('a step with no service to address is skipped, not guessed', () async {
    final ble = FakeBleService();
    await runBleHandshake(
      ble: ble,
      deviceId: '01',
      handshake: BleHandshakeDto(
        steps: [
          _step(service: null, write: const [1]),
          _step(write: const [2]),
        ],
        described: const [],
      ),
    );

    expect(ble.writes.map((w) => w.value).toList(), [
      [2],
    ]);
  });

  test('a failed step stops the handshake and frees what it opened', () async {
    // Ordered means dependent: running step three against a device that
    // refused step two is how a half-initialized device comes to look
    // initialized.
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final ble = FakeBleService(
      notifyStream: notify.stream,
      readError: StateError('gatt read failed'),
    );

    await expectLater(
      runBleHandshake(
        ble: ble,
        deviceId: '01',
        handshake: BleHandshakeDto(
          steps: [
            _step(subscribe: true),
            _step(write: const [1], read: true),
            _step(write: const [2]),
          ],
          described: const [],
        ),
      ),
      throwsA(isA<StateError>()),
    );

    expect(
      ble.writes.map((w) => w.value).toList(),
      [
        [1],
      ],
      reason: 'the step after the failure must not run',
    );
    expect(ble.cancelledSubscriptions, [
      '0000ff21-0000-1000-8000-00805f9b34fb',
    ]);
  });

  testWidgets("the connect path runs the matched spec's handshake", (
    tester,
  ) async {
    // End to end through the screen: connect, discover, and then — before the
    // screen reports itself Connected and the controls start reading — the
    // writes the catalogue says this device is waiting for.
    final ble = FakeBleService(
      servicesToReturn: const [
        BleDiscoveredService(
          uuid: '0000ff20-0000-1000-8000-00805f9b34fb',
          characteristics: [],
        ),
      ],
    );
    final codec = FakeSpecCodec(
      spec: _spec,
      handshake: BleHandshakeDto(
        steps: [
          _step(write: const [0x00, 0x00, 0x00, 0x01]),
        ],
        described: const ['a SPAKE2 exchange no spec can hold'],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(ble),
          specCodecProvider.overrideWithValue(codec),
          sharedPreferencesProvider.overrideWithValue(_prefs),
          matchedDeviceSpecProvider.overrideWith(
            (ref, request) async =>
                SpecMatchOutcome.auto(MatchedSpec(spec: _spec, yaml: 'yaml')),
          ),
        ],
        child: MaterialApp(
          home: DeviceScreen(
            device: IoTDevice(
              id: '01',
              name: 'SpotLED',
              rssi: -40,
              isConnectable: true,
              discoveredAt: DateTime(2026),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(ble.connectedIds, ['01']);
    expect(codec.handshakeCalls, ['yaml']);
    expect(ble.writes.map((w) => w.value).toList(), [
      [0x00, 0x00, 0x00, 0x01],
    ]);
    // And the prose step, which nothing can execute, did not stop the rest.
    expect(find.text('Connected'), findsOneWidget);
  });

  testWidgets('a drop during the handshake is not painted over as Connected', (
    tester,
  ) async {
    // The handshake awaits writes, reads and the spec's own delayMs sleeps —
    // seconds, for SmartDawn — and the connection watcher records a drop
    // that lands in that window as `disconnected`. The ready setState after
    // the handshake then overwrote it: "Connected · N services" and live
    // controls on a dead link, no reconnect affordance, every control
    // failing one by one.
    final connection = StreamController<BleConnectionState>();
    addTearDown(connection.close);
    final ble = FakeBleService(
      connectionStateStream: connection.stream,
      servicesToReturn: const [
        BleDiscoveredService(
          uuid: '0000ff20-0000-1000-8000-00805f9b34fb',
          characteristics: [],
        ),
      ],
    );
    final codec = FakeSpecCodec(
      spec: _spec,
      handshake: BleHandshakeDto(
        steps: [
          _step(write: const [0x00, 0x00, 0x00, 0x01], delayMs: 2000),
        ],
        described: const [],
      ),
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(ble),
          specCodecProvider.overrideWithValue(codec),
          sharedPreferencesProvider.overrideWithValue(_prefs),
          matchedDeviceSpecProvider.overrideWith(
            (ref, request) async =>
                SpecMatchOutcome.auto(MatchedSpec(spec: _spec, yaml: 'yaml')),
          ),
        ],
        child: MaterialApp(
          home: DeviceScreen(
            device: IoTDevice(
              id: '01',
              name: 'SpotLED',
              rssi: -40,
              isConnectable: true,
              discoveredAt: DateTime(2026),
            ),
          ),
        ),
      ),
    );
    // Into the handshake: the write is out, the 2 s delay is sleeping.
    await tester.pump(const Duration(milliseconds: 100));
    expect(ble.writes, hasLength(1), reason: 'the handshake is under way');
    expect(find.text('Connected'), findsNothing);

    // The peripheral drops mid-sleep.
    connection.add(BleConnectionState.disconnected);
    await tester.pump();
    expect(find.text('Disconnected'), findsOneWidget);

    // The handshake's sleep ends and the connect path resumes.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(
      find.text('Disconnected'),
      findsOneWidget,
      reason: 'the drop the watcher recorded must survive the handshake ending',
    );
    expect(find.text('Connected'), findsNothing);
  });

  testWidgets('a spec that declares no handshake still opens the screen', (
    tester,
  ) async {
    final ble = FakeBleService(
      servicesToReturn: const [
        BleDiscoveredService(
          uuid: '0000ff20-0000-1000-8000-00805f9b34fb',
          characteristics: [],
        ),
      ],
    );
    final codec = FakeSpecCodec(spec: _spec);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(ble),
          specCodecProvider.overrideWithValue(codec),
          sharedPreferencesProvider.overrideWithValue(_prefs),
          matchedDeviceSpecProvider.overrideWith(
            (ref, request) async =>
                SpecMatchOutcome.auto(MatchedSpec(spec: _spec, yaml: 'yaml')),
          ),
        ],
        child: MaterialApp(
          home: DeviceScreen(
            device: IoTDevice(
              id: '01',
              name: 'Bulb',
              rssi: -40,
              isConnectable: true,
              discoveredAt: DateTime(2026),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(ble.writes, isEmpty);
    expect(find.text('Connected'), findsOneWidget);
  });
}

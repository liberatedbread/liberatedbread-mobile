// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/device_category.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/scan_match_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/group_detail_screen.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _svc = '0000fff0-0000-1000-8000-00805f9b34fb';
const _chr = '0000fff1-0000-1000-8000-00805f9b34fb';

final _bulbSpec = DeviceSpecDto(
  deviceName: 'Example Smart Bulb',
  manufacturer: 'Acme Corp',
  manufacturerStatus: 'abandoned',
  protocol: 'ble',
  category: 'light',
  localNamePrefixes: const [],
  serviceUuids: const [_svc],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  services: const [],
  entities: const [
    EntityDto(
      name: 'Bulb',
      platform: 'light',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        EntityActionDto(
          role: 'turn_on',
          serviceUuid: _svc,
          characteristicUuid: _chr,
          commandName: 'power_on',
          userParams: [],
        ),
        EntityActionDto(
          role: 'turn_off',
          serviceUuid: _svc,
          characteristicUuid: _chr,
          commandName: 'power_off',
          userParams: [],
        ),
      ],
    ),
  ],
);

late SharedPreferences _prefs;

/// FilledButton.tonalIcon builds a private FilledButton subclass, so match
/// by predicate rather than exact runtimeType.
FilledButton _buttonWith(WidgetTester tester, String label) =>
    tester.widget<FilledButton>(find.ancestor(
      of: find.textContaining(label),
      matching: find.byWidgetPredicate((w) => w is FilledButton),
    ));

Map<String, Object> _twoBulbs() => {
      'saved_devices_v1': jsonEncode([
        for (final (id, name) in [
          ('AA:BB:CC:DD:EE:01', 'ACME_Living_Room'),
          ('AA:BB:CC:DD:EE:02', 'ACME_Bedroom'),
        ])
          {
            'id': id,
            'name': name,
            'lastSeen': '2026-08-11T10:00:00.000',
            'category': 'light',
            'specKey': 'Example Smart Bulb|Acme Corp',
          },
      ]),
    };

Widget _wrap(FakeBleService ble, FakeSpecCodec codec) => ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_prefs),
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
        scanGuessProvider.overrideWith((ref, identity) async => null),
        parsedDeviceSpecsProvider.overrideWith(
            (ref) async => [(spec: _bulbSpec, yaml: 'bulb-yaml')]),
      ],
      child: const MaterialApp(
        home: GroupDetailScreen(category: DeviceCategory.light),
      ),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(_twoBulbs());
    _prefs = await SharedPreferences.getInstance();
  });

  FakeBleService writableBle() => FakeBleService(servicesToReturn: const [
        BleDiscoveredService(uuid: _svc, characteristics: [
          BleDiscoveredCharacteristic(
            uuid: _chr,
            canRead: false,
            canWrite: true,
            canNotify: false,
          ),
        ]),
      ]);

  testWidgets('shows members with their supported operations', (tester) async {
    await tester.pumpWidget(_wrap(writableBle(), FakeSpecCodec()));
    await tester.pumpAndSettle();

    expect(find.text('Lights'), findsOneWidget);
    expect(find.text('ACME_Living_Room'), findsOneWidget);
    expect(find.text('ACME_Bedroom'), findsOneWidget);
    // Pre-run rows say what each member's spec resolves.
    expect(find.text('Turn all on · Turn all off'), findsNWidgets(2));
  });

  testWidgets(
      'brightness is disabled when no member resolves it, '
      'battery is always offered', (tester) async {
    await tester.pumpWidget(_wrap(writableBle(), FakeSpecCodec()));
    await tester.pumpAndSettle();

    expect(_buttonWith(tester, 'Set brightness').onPressed, isNull);
    expect(find.text('Set brightness · 0 of 2'), findsOneWidget);
    expect(_buttonWith(tester, 'Read batteries').onPressed, isNotNull);
  });

  testWidgets('commands stay enabled while a member may match on connect',
      (tester) async {
    // One member with no stored spec at all: its row promises a match on
    // connect, so the verbs must stay tappable — the runner reports the
    // honest per-device skip if the match never comes.
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1': jsonEncode([
        {
          'id': 'AA:BB:CC:DD:EE:03',
          'name': 'Unmatched',
          'lastSeen': '2026-08-11T10:00:00.000',
          'category': 'light',
        },
      ]),
    });
    _prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(_wrap(writableBle(), FakeSpecCodec()));
    await tester.pumpAndSettle();

    expect(find.text('Kind unknown — will match on connect'), findsOneWidget);
    expect(_buttonWith(tester, 'Turn all on').onPressed, isNotNull);
    expect(_buttonWith(tester, 'Set brightness').onPressed, isNotNull);
    expect(find.text('Set brightness · 0 of 1'), findsOneWidget);
  });

  testWidgets('resolving guesses read as waiting, not as forgotten members',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1': jsonEncode([
        {
          'id': 'AA:BB:CC:DD:EE:04',
          'name': 'Mystery',
          'lastSeen': '2026-08-11T10:00:00.000',
        },
      ]),
    });
    _prefs = await SharedPreferences.getInstance();
    final never = Completer<ScanGuess?>();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_prefs),
        bleServiceProvider.overrideWithValue(writableBle()),
        specCodecProvider.overrideWithValue(FakeSpecCodec()),
        scanGuessProvider.overrideWith((ref, identity) => never.future),
        parsedDeviceSpecsProvider.overrideWith((ref) async => []),
      ],
      child: const MaterialApp(
        home: GroupDetailScreen(category: DeviceCategory.light),
      ),
    ));
    // pump, not pumpAndSettle: the spinner animates for as long as the guess
    // pass is in flight, which here is forever.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.textContaining('may have been forgotten'), findsNothing);
  });

  testWidgets('a failed guess pass gets an error and a retry, not a spinner',
      (tester) async {
    // autoGroupsProvider is not autoDispose: once it settles in error,
    // nothing re-runs it short of an explicit refresh — so a settled error
    // must render as an error with a retry, never as an eternal spinner or
    // a false claim about forgotten members.
    SharedPreferences.setMockInitialValues({
      'saved_devices_v1': jsonEncode([
        {
          'id': 'AA:BB:CC:DD:EE:04',
          'name': 'Mystery',
          'lastSeen': '2026-08-11T10:00:00.000',
        },
      ]),
    });
    _prefs = await SharedPreferences.getInstance();
    var failGuesses = true;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_prefs),
        bleServiceProvider.overrideWithValue(writableBle()),
        specCodecProvider.overrideWithValue(FakeSpecCodec()),
        scanGuessProvider.overrideWith((ref, identity) async {
          if (failGuesses) throw Exception('catalogue unavailable');
          return null;
        }),
        parsedDeviceSpecsProvider.overrideWith((ref) async => []),
      ],
      child: const MaterialApp(
        home: GroupDetailScreen(category: DeviceCategory.light),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.textContaining('may have been forgotten'), findsNothing);
    expect(find.text('Try again'), findsOneWidget);

    failGuesses = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    // The retry re-ran the pass; with no guess, the bucket is just empty.
    expect(find.text('Try again'), findsNothing);
    expect(find.textContaining('may have been forgotten'), findsOneWidget);
  });

  testWidgets('turn all off runs the group and reports per-device outcomes',
      (tester) async {
    final ble = writableBle();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList(const [9, 9]));
    await tester.pumpWidget(_wrap(ble, codec));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Turn all off'));
    await tester.pumpAndSettle();

    // Both bulbs got the encoded command, one connection at a time.
    expect(ble.events, [
      'connect:AA:BB:CC:DD:EE:01',
      'disconnect:AA:BB:CC:DD:EE:01',
      'connect:AA:BB:CC:DD:EE:02',
      'disconnect:AA:BB:CC:DD:EE:02',
    ]);
    expect(ble.writes, hasLength(2));
    expect(ble.writes.first.value, const [9, 9]);
    expect(codec.encodeCalls.first.commandName, 'power_off');
    expect(find.text('1 command sent'), findsNWidgets(2));
  });

  testWidgets('a device the run cannot reach reads as failed, not silent',
      (tester) async {
    final ble = writableBle()..connectError = Exception('nope');
    await tester.pumpWidget(_wrap(ble, FakeSpecCodec()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Turn all off'));
    await tester.pumpAndSettle();

    expect(find.text('Could not reach this device.'), findsNWidgets(2));
    expect(find.byIcon(Icons.error_outline), findsNWidgets(2));
  });
}

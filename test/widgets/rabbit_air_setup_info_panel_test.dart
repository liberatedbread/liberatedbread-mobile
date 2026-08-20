// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Widget tests for the read-only setup-mode panel: a stand-in purifier
// answers the cleartext cmd 255 / cmd 4 envelopes over FakeBleService
// notifications, and the panel must render its identity, its live state
// through the shared reading cards, and the setup CTA — never a toggle or a
// key prompt.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/models/iot_device.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/rabbit_air_setup_info_panel.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _serviceUuid = '366048ae-9f36-43cf-8004-010c0c9fa52e';
const _charUuid = '53ef7d7d-c244-42bd-9064-a1569a521ca9';

const _rabbitService = BleDiscoveredService(
  uuid: _serviceUuid,
  characteristics: [
    BleDiscoveredCharacteristic(
      uuid: _charUuid,
      canRead: false,
      canWrite: true,
      canWriteWithResponse: true,
      canNotify: true,
    ),
  ],
);

void main() {
  final device = IoTDevice(
    id: '01',
    name: 'RabbitAirSetup-789A',
    rssi: -40,
    isConnectable: true,
    discoveredAt: DateTime(2026),
  );

  // The spec's control surface, trimmed: one switch, one select, two
  // sensors. State field names are the LAN get_state names — the setup-mode
  // cmd 4 answer carries the same ones.
  final entities = [
    const NetworkEntityDto(
      name: 'Power',
      platform: 'switch',
      stateCommand: 'get_state',
      valueField: 'power',
      options: [],
      isInstanced: false,
      actions: [],
    ),
    const NetworkEntityDto(
      name: 'Mode',
      platform: 'select',
      stateCommand: 'get_state',
      valueField: 'mode',
      options: [
        NetworkOptionDto(raw: '0', label: 'Auto'),
        NetworkOptionDto(raw: '1', label: 'Pollen'),
        NetworkOptionDto(raw: '2', label: 'Manual'),
      ],
      isInstanced: false,
      actions: [],
    ),
    const NetworkEntityDto(
      name: 'Air Quality',
      platform: 'sensor',
      stateCommand: 'get_state',
      valueField: 'quality',
      options: [
        NetworkOptionDto(raw: '0', label: 'Lowest'),
        NetworkOptionDto(raw: '2', label: 'Medium'),
      ],
      isInstanced: false,
      actions: [],
    ),
    const NetworkEntityDto(
      name: 'Filter Life',
      platform: 'sensor',
      unit: 'min',
      stateCommand: 'get_state',
      valueField: 'filter_life',
      options: [],
      isInstanced: false,
      actions: [],
    ),
  ];

  const infoData = {
    'name': 'abcdef1234_000000000000000000',
    'mac': 'AA:BB:CC:DD:EE:FF',
    'mcu': 27,
  };

  Map<String, Object?> stateData = {
    'power': true,
    'mode': 2,
    'quality': 2,
    'filter_life': 4320,
    'model': 1,
  };

  late StreamController<List<int>> notifications;
  late FakeBleService ble;
  late FakeSpecCodec codec;
  int answered = 0;

  /// Answer every envelope the panel has written since the last call with
  /// the canned cmd 255 / cmd 4 data, framed as one notification.
  Future<void> answerNewWrites(WidgetTester tester) async {
    await tester.pump();
    for (; answered < ble.writes.length; answered++) {
      // Writes are framed chunks: strip the 2-byte length prefix.
      final request =
          jsonDecode(utf8.decode(ble.writes[answered].value.sublist(2))) as Map;
      final body = utf8.encode(jsonEncode({
        'id': request['id'],
        'data': request['cmd'] == 255 ? infoData : stateData,
      }));
      notifications
          .add([body.length & 0xFF, (body.length >> 8) & 0xFF, ...body]);
    }
    await tester.pump();
  }

  Widget wrap({List<BleDiscoveredService> services = const [_rabbitService]}) =>
      ProviderScope(
        overrides: [
          bleServiceProvider.overrideWithValue(ble),
          specCodecProvider.overrideWithValue(codec),
          rabbitAirSpecSurfaceProvider.overrideWith(
              (ref) async => (specYaml: 'yaml', entities: entities)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: RabbitAirSetupInfoPanel(
              device: device,
              services: services,
              pollInterval: const Duration(seconds: 5),
              responseTimeout: const Duration(seconds: 1),
            ),
          ),
        ),
      );

  setUp(() {
    answered = 0;
    stateData = {
      'power': true,
      'mode': 2,
      'quality': 2,
      'filter_life': 4320,
      'model': 1,
    };
    notifications = StreamController<List<int>>.broadcast();
    ble = FakeBleService(
      servicesToReturn: const [_rabbitService],
      notifyStream: notifications.stream,
      mtuToReturn: 515,
    );
    codec = FakeSpecCodec(
      networkReading: (entity, returned) {
        final raw = switch (entity) {
          'Power' => returned['power'],
          'Mode' => returned['mode'],
          'Air Quality' => returned['quality'],
          'Filter Life' => returned['filter_life'],
          _ => null,
        };
        if (raw == null) return null;
        if (entity == 'Power') {
          final on = raw == 'true';
          return NetworkReadingDto(
              kind: NetworkReadingKind.onOff, isOn: on, raw: on ? '1' : '0');
        }
        if (entity == 'Mode' || entity == 'Air Quality') {
          final options = entities.firstWhere((e) => e.name == entity).options;
          final label = options
              .where((o) => o.raw == raw)
              .map((o) => o.label)
              .firstOrNull;
          return NetworkReadingDto(
              kind: NetworkReadingKind.option, label: label, raw: raw);
        }
        return NetworkReadingDto(
            kind: NetworkReadingKind.number,
            number: double.parse(raw),
            raw: raw);
      },
    );
  });

  tearDown(() async {
    await notifications.close();
  });

  /// Unmount the panel so its poll timer is cancelled before the test ends.
  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump();
  }

  testWidgets(
      'renders the info card and the live state, read-only, with '
      'the setup CTA', (tester) async {
    await tester.pumpWidget(wrap());
    await answerNewWrites(tester); // cmd 255
    await answerNewWrites(tester); // cmd 4
    await tester.pumpAndSettle();

    // The cmd 255 identity card.
    expect(find.text('Thing ID'), findsOneWidget);
    expect(find.text('abcdef1234_000000000000000000'), findsOneWidget);
    expect(find.text('AA:BB:CC:DD:EE:FF'), findsOneWidget);
    expect(find.text('v27'), findsOneWidget);
    expect(find.text('MinusA2'), findsOneWidget); // model 1, from cmd 4

    // The state, as readings: on/off, option label, value with unit.
    expect(find.text('On'), findsOneWidget); // Power
    expect(find.text('Manual'), findsOneWidget); // Mode 2
    expect(find.text('Medium'), findsOneWidget); // Air Quality 2
    expect(find.text('4320 min'), findsOneWidget);

    // Strictly read-only: no toggle, no key prompt.
    expect(find.byType(Switch), findsNothing);
    expect(find.text('Enter user key'), findsNothing);

    // The way into onboarding.
    expect(find.text('Finish setting up this purifier'), findsOneWidget);
    expect(find.text('Set up Wi-Fi'), findsOneWidget);

    // The cleartext envelope ids started at 0 — no key, no ts.
    final first =
        jsonDecode(utf8.decode(ble.writes.first.value.sublist(2))) as Map;
    expect(first, {'id': 0, 'cmd': 255});

    await unmount(tester);
  });

  testWidgets('polls the state on the interval while visible', (tester) async {
    await tester.pumpWidget(wrap());
    await answerNewWrites(tester);
    await answerNewWrites(tester);
    await tester.pumpAndSettle();
    expect(find.text('4320 min'), findsOneWidget);

    stateData = {...stateData, 'filter_life': 4300};
    await tester.pump(const Duration(seconds: 5)); // the poll timer fires
    await answerNewWrites(tester);
    await tester.pumpAndSettle();

    expect(find.text('4300 min'), findsOneWidget);
    expect(
      ble.writes
          .map((w) =>
              (jsonDecode(utf8.decode(w.value.sublist(2))) as Map)['cmd'])
          .toList(),
      [255, 4, 4],
    );

    await unmount(tester);
  });

  testWidgets(
      'a device without the command characteristic shows a '
      'non-fatal error with retry and the CTA', (tester) async {
    await tester.pumpWidget(wrap(services: const []));
    await tester.pumpAndSettle();

    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Finish setting up this purifier'), findsOneWidget);
    expect(find.byType(Switch), findsNothing);
    // No poll timer was ever started, so nothing more to clean up.
  });

  testWidgets(
      'a purifier that stops answering keeps the last readings and '
      'says so', (tester) async {
    await tester.pumpWidget(wrap());
    await answerNewWrites(tester);
    await answerNewWrites(tester);
    await tester.pumpAndSettle();
    expect(find.text('4320 min'), findsOneWidget);

    // The next poll gets no answer: the exchange times out, the error shows,
    // and the last good readings stay on screen.
    await tester.pump(const Duration(seconds: 5));
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('4320 min'), findsOneWidget);
    expect(find.text('abcdef1234_000000000000000000'), findsOneWidget);

    await unmount(tester);
  });
}

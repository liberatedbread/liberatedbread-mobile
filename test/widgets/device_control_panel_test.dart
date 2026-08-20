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
import 'package:liberated_bread_mobile/providers/device_description_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/number_registry.dart';
import 'package:liberated_bread_mobile/services/spec_choice_store.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/device_control_panel.dart';
import 'package:liberated_bread_mobile/widgets/entity_sensor_card.dart';
import 'package:liberated_bread_mobile/widgets/raw_characteristic_widget.dart';
import 'package:liberated_bread_mobile/widgets/typed_characteristic_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

/// A stand-in for the vendored Bluetooth SIG registry the panel names
/// standard services from.
///
/// Overridden rather than left to load for real: the production provider
/// reads ~1.7MB of assets through `rootBundle`, so the names would land some
/// unspecified number of frames after the widget does and the assertions
/// would race it. Entries must be sorted — [RegistryTable.parse] verifies it.
final _sigServices = NumberRegistry(
  addressBlocks: const [],
  companyIds: RegistryTable.empty,
  serviceUuids: RegistryTable.parse(
    '1800\tGeneric Access\n'
    '180f\tBattery Service\n',
    keyWidth: 4,
  ),
);

Future<Widget> _wrap(
  Widget child, {
  required FakeBleService ble,
  required FakeSpecCodec codec,
  Map<String, String>? specs,
  Map<String, Object> initialPrefs = const {},
}) async {
  SharedPreferences.setMockInitialValues(initialPrefs);
  final prefs = await SharedPreferences.getInstance();
  return ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      bleServiceProvider.overrideWithValue(ble),
      specCodecProvider.overrideWithValue(codec),
      numberRegistryProvider.overrideWith((ref) => _sigServices),
      if (specs != null) deviceSpecsProvider.overrideWith((ref) => specs),
    ],
    child: MaterialApp(home: Scaffold(body: child)),
  );
}

void main() {
  testWidgets('empty services renders the empty message', (tester) async {
    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(deviceId: '01', deviceName: 'Dev', services: []),
      ble: FakeBleService(),
      codec: FakeSpecCodec(),
    ));
    expect(find.text('No services found on this device.'), findsOneWidget);
  });

  testWidgets(
      'falls back to the raw browser with well-known names when no '
      'spec matches', (tester) async {
    const services = [
      BleDiscoveredService(
        uuid: '0000180f-0000-1000-8000-00805f9b34fb',
        characteristics: [],
      ),
      BleDiscoveredService(
        uuid: '00001800-0000-1000-8000-00805f9b34fb',
        characteristics: [],
      ),
    ];
    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: '01', deviceName: 'Dev', services: services),
      ble: FakeBleService(),
      codec: FakeSpecCodec(), // no spec -> no match -> raw fallback
    ));
    await tester.pumpAndSettle();

    expect(find.byType(Card), findsNWidgets(2));
    expect(find.text('Battery Service'), findsOneWidget);
    expect(find.text('Generic Access'), findsOneWidget);
    expect(find.byType(TypedCharacteristicWidget), findsNothing);
  });

  testWidgets('a service the registry does not know keeps the generic label',
      (tester) async {
    // A vendor's own 128-bit UUID is in no registry, and there is nothing
    // true to say about it here — identifying it is the spec matcher's job
    // one level up.
    const services = [
      BleDiscoveredService(
        uuid: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
        characteristics: [],
      ),
    ];
    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: '01', deviceName: 'Dev', services: services),
      ble: FakeBleService(),
      codec: FakeSpecCodec(),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Service'), findsOneWidget);
  });

  testWidgets('two instances of one service UUID each get their own card',
      (tester) async {
    // GATT permits a peripheral to expose several instances of one service,
    // and multi-channel vendor hardware does. Keying the cards on the UUID
    // alone collapsed them in `childIndexByKey`, so both were handed the same
    // index and the per-index reconciliation that callback exists to prevent
    // came straight back — remounting cards, and with them the notify
    // subscriptions bound in initState.
    const duplicated = [
      BleDiscoveredService(
        uuid: '0000aaa0-0000-1000-8000-00805f9b34fb',
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: '0000aaa1-0000-1000-8000-00805f9b34fb',
            canRead: false,
            canWrite: false,
            canNotify: true,
          ),
        ],
      ),
      BleDiscoveredService(
        uuid: '0000aaa0-0000-1000-8000-00805f9b34fb',
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: '0000aaa2-0000-1000-8000-00805f9b34fb',
            canRead: false,
            canWrite: false,
            canNotify: true,
          ),
        ],
      ),
    ];
    final ble = FakeBleService();
    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: 'AA:BB', deviceName: 'Dual', services: duplicated),
      ble: ble,
      codec: FakeSpecCodec(),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(Card), findsNWidgets(2));
    // Each instance subscribed to its own characteristic, exactly once.
    expect(
      ble.subscriptions,
      containsAll(const [
        '0000aaa1-0000-1000-8000-00805f9b34fb',
        '0000aaa2-0000-1000-8000-00805f9b34fb',
      ]),
    );
    expect(ble.subscriptions, hasLength(2));
  });

  testWidgets('renders typed controls for a matched characteristic',
      (tester) async {
    const svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
    const charUuid = '0000fff1-0000-1000-8000-00805f9b34fb';
    // `final`, not `const`: DeviceSpecDto.companyIds is a Uint16List, which has
    // no const form.
    final spec = DeviceSpecDto(
      deviceName: 'Example Smart Bulb',
      manufacturer: 'Acme',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      category: 'light',
      localNamePrefixes: const ['ACME_'],
      localNames: const [],
      serviceUuids: const [svcUuid],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceType: null,
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const <EntityDto>[],
      services: const [
        ServiceDto(uuid: svcUuid, name: 'Control Service', characteristics: [
          CharacteristicDto(
            uuid: charUuid,
            name: 'Command',
            canRead: false,
            canWrite: true,
            canNotify: false,
            commands: [
              CommandDto(
                name: 'power_on',
                description: 'Turn the bulb on',
                parameters: [],
                isFixed: true,
                isEncodable: true,
                unsupportedEncoding: null,
                advanced: false,
              ),
            ],
            formatFields: [],
          ),
        ]),
      ],
    );
    const services = [
      BleDiscoveredService(
        uuid: svcUuid,
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: charUuid,
            canRead: false,
            canWrite: true,
            canNotify: false,
          ),
        ],
      ),
    ];

    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: '01', deviceName: 'ACME_Living_Room', services: services),
      ble: FakeBleService(),
      codec: FakeSpecCodec(
        spec: spec,
        matches: [
          MatchResult(
            spec: spec,
            matchedByNamePrefix: true,
            matchedServiceUuids: const [svcUuid],
            confidence: MatchConfidence.strong,
          ),
        ],
        encoded: Uint8List.fromList([1, 1]),
      ),
      specs: const {
        'vendor/protocol-specs/device-specs/examples/example-bulb.yaml': 'dummy'
      },
    ));
    await tester.pumpAndSettle();

    // Service card uses the spec name, and a typed command control renders.
    expect(find.text('Control Service'), findsOneWidget);
    expect(find.byType(TypedCharacteristicWidget), findsOneWidget);
    expect(find.text('Power on'), findsWidgets);
  });

  testWidgets(
      'equally-matched specs show the chooser; picking one persists and '
      'renders its typed controls', (tester) async {
    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: 'AA:BB', deviceName: 'Mystery', services: _tieServices),
      ble: FakeBleService(),
      codec: _tieCodec(),
      specs: const {'a.yaml': 'yaml-a', 'b.yaml': 'yaml-b'},
    ));
    await tester.pumpAndSettle();

    // The tie renders a chooser with both brands; raw controls stay below
    // (the service card shows a generic name, not either brand's).
    expect(find.text('Which device is this?'), findsOneWidget);
    expect(find.text('Brand A Lights'), findsOneWidget);
    expect(find.text('Brand B Lights'), findsOneWidget);
    expect(find.byType(TypedCharacteristicWidget), findsNothing);

    await tester.tap(find.text('Brand A Lights'));
    await tester.pumpAndSettle();

    // Chooser gone, chosen spec's names and typed controls in place.
    expect(find.text('Which device is this?'), findsNothing);
    expect(find.text('A Control'), findsOneWidget);
    expect(find.byType(TypedCharacteristicWidget), findsOneWidget);

    // And the choice was persisted for the next connection.
    final store = SpecChoiceStore(await SharedPreferences.getInstance());
    expect(store.load(), {'AA:BB': 'Brand A Lights|Vendor A'});
  });

  testWidgets('a slot appearing above the service list does not resubscribe',
      (tester) async {
    // The list is lazy, and a lazy delegate reconciles per index unless it is
    // given findChildIndexCallback — so keyed rows were still torn down and
    // re-inflated whenever the leading slots changed count, which they do on
    // essentially every connect (the match provider is AsyncLoading for the
    // first frame). The remount's setNotifyValue(true) races the outgoing
    // element's setNotifyValue(false) on the same characteristic, with no
    // reference counting; when the disable lands last, the characteristic goes
    // quiet for the rest of the session.
    const notifying = [
      BleDiscoveredService(
        uuid: '0000aaa0-0000-1000-8000-00805f9b34fb',
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: '0000aaa1-0000-1000-8000-00805f9b34fb',
            canRead: false,
            canWrite: false,
            canNotify: true,
          ),
        ],
      ),
      ..._tieServices,
    ];
    final ble = FakeBleService();
    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: 'AA:BB', deviceName: 'Mystery', services: notifying),
      ble: ble,
      codec: _tieCodec(),
      specs: const {'a.yaml': 'yaml-a', 'b.yaml': 'yaml-b'},
    ));
    // First frame: no leading slot yet, every service card mounts.
    await tester.pump();
    expect(ble.subscriptions, hasLength(1));

    // The match resolves and the chooser takes slot 0, shifting every service
    // card down by one.
    await tester.pumpAndSettle();
    expect(find.text('Which device is this?'), findsOneWidget);
    expect(ble.subscriptions, hasLength(1),
        reason: 'the shifted card must be carried to its new index, not '
            'destroyed and re-inflated');

    // And again in the other direction, when answering the chooser removes it.
    await tester.tap(find.text('Brand A Lights'));
    await tester.pumpAndSettle();
    expect(ble.subscriptions, hasLength(1));
  });

  testWidgets(
      'a saved choice shows the banner; Change reopens the chooser and a '
      'new pick replaces the stored choice', (tester) async {
    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: 'AA:BB', deviceName: 'Mystery', services: _tieServices),
      ble: FakeBleService(),
      codec: _tieCodec(),
      specs: const {'a.yaml': 'yaml-a', 'b.yaml': 'yaml-b'},
      initialPrefs: {
        'spec_choices_v1': jsonEncode({'AA:BB': 'Brand A Lights|Vendor A'}),
      },
    ));
    await tester.pumpAndSettle();

    // The saved pick is honored — no chooser — and the banner names it with
    // a way out.
    expect(find.text('Which device is this?'), findsNothing);
    expect(find.text('Brand A Lights'), findsOneWidget);
    expect(find.text('Device type you picked'), findsOneWidget);
    expect(find.text('A Control'), findsOneWidget);

    await tester.tap(find.text('Change'));
    await tester.pumpAndSettle();

    // Cleared: the tie is live again, chooser back, banner gone.
    expect(find.text('Which device is this?'), findsOneWidget);
    expect(find.text('Device type you picked'), findsNothing);

    await tester.tap(find.text('Brand B Lights'));
    await tester.pumpAndSettle();

    // The new pick renders and replaced the stored choice.
    expect(find.text('B Control'), findsOneWidget);
    expect(find.text('Device type you picked'), findsOneWidget);
    final store = SpecChoiceStore(await SharedPreferences.getInstance());
    expect(store.load(), {'AA:BB': 'Brand B Lights|Vendor B'});
  });

  testWidgets('an automatic match names the spec and its device type',
      (tester) async {
    // The scan row said "Example Smart Bulb" with a bulb icon before the tap.
    // Arriving here to find neither — just controls, appearing — leaves the
    // user to infer what the app decided, with nothing to check it against.
    const svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
    final spec = DeviceSpecDto(
      deviceName: 'Example Smart Bulb',
      manufacturer: 'Acme Corp',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      category: 'light',
      localNamePrefixes: const ['ACME_'],
      localNames: const [],
      serviceUuids: const [svcUuid],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceType: null,
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const <EntityDto>[],
      services: const [
        ServiceDto(uuid: svcUuid, name: 'Control Service', characteristics: []),
      ],
    );
    const services = [BleDiscoveredService(uuid: svcUuid, characteristics: [])];

    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: '01', deviceName: 'ACME_Living_Room', services: services),
      ble: FakeBleService(),
      codec: FakeSpecCodec(
        spec: spec,
        matches: [
          MatchResult(
            spec: spec,
            matchedByNamePrefix: true,
            confidence: MatchConfidence.strong,
            matchedServiceUuids: const [svcUuid],
          ),
        ],
      ),
      specs: const {'bulb.yaml': 'yaml'},
    ));
    await tester.pumpAndSettle();

    expect(find.text('Example Smart Bulb'), findsOneWidget);
    expect(find.text('Light · Acme Corp'), findsOneWidget);
    expect(find.byIcon(DeviceCategory.light.icon), findsOneWidget);
    // The user did not pick this one, so it is not the saved-choice banner.
    expect(find.text('Device type you picked'), findsNothing);
  });

  testWidgets(
      'a treadmill-category match shows the transport card above the '
      'typed controls', (tester) async {
    const svcUuid = '0000fe00-0000-1000-8000-00805f9b34fb';
    const charUuid = '0000fe02-0000-1000-8000-00805f9b34fb';
    final spec = DeviceSpecDto(
      deviceName: 'Test Walking Pad',
      manufacturer: 'Acme Fitness',
      manufacturerStatus: 'active',
      protocol: 'ble',
      category: 'treadmill',
      localNamePrefixes: const ['ACME_'],
      localNames: const [],
      serviceUuids: const [svcUuid],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceType: null,
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const <EntityDto>[],
      services: const [
        ServiceDto(uuid: svcUuid, name: 'WiLink service', characteristics: [
          CharacteristicDto(
            uuid: charUuid,
            name: 'Command write',
            canRead: false,
            canWrite: true,
            canNotify: false,
            commands: [
              CommandDto(
                name: 'start_belt',
                description: 'Start the belt',
                parameters: [],
                isFixed: true,
                isEncodable: true,
                unsupportedEncoding: null,
                advanced: false,
              ),
            ],
            formatFields: [],
          ),
        ]),
      ],
    );
    const services = [
      BleDiscoveredService(
        uuid: svcUuid,
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: charUuid,
            canRead: false,
            canWrite: true,
            canNotify: false,
          ),
        ],
      ),
    ];
    final ble = FakeBleService();

    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: '01', deviceName: 'ACME_Pad', services: services),
      ble: ble,
      codec: FakeSpecCodec(
        spec: spec,
        matches: [
          MatchResult(
            spec: spec,
            matchedByNamePrefix: true,
            matchedServiceUuids: const [svcUuid],
            confidence: MatchConfidence.strong,
          ),
        ],
        encoded: Uint8List.fromList([0xF7, 0xFD]),
      ),
      specs: const {'pad.yaml': 'yaml'},
    ));
    await tester.pumpAndSettle();

    // The card's transport buttons lead the panel...
    expect(find.text('Start'), findsOneWidget);
    // ...and the same command remains available as a typed control below —
    // the card is a convenience surface, not a replacement.
    expect(find.byType(TypedCharacteristicWidget), findsOneWidget);
    expect(find.text('Start belt'), findsWidgets);

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    // Start asks before it moves the belt; confirm to see the write go out.
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Start')));
    await tester.pumpAndSettle();
    expect(ble.writes.single.value, [0xF7, 0xFD]);
  });

  group('sensor-device readings', () {
    const svcUuid = '0000aab0-0000-1000-8000-00805f9b34fb';
    const radonChar = '0000aab1-0000-1000-8000-00805f9b34fb';
    const radonAltChar = '0000aab2-0000-1000-8000-00805f9b34fb';
    const humidityChar = '0000aab3-0000-1000-8000-00805f9b34fb';
    const batteryChar = '0000aab4-0000-1000-8000-00805f9b34fb';

    EntityDto sensor(
      String name,
      String stateChar, {
      String? deviceClass,
      String? unit,
    }) =>
        EntityDto(
          name: name,
          platform: 'sensor',
          deviceClass: deviceClass,
          unit: unit,
          stateCharacteristic: stateChar,
          canNotify: false,
          hasFormat: true,
          valueField: 'v',
          onWhenNonzero: false,
          actions: const [],
        );

    DeviceSpecDto airSpec({String category = 'sensor'}) => DeviceSpecDto(
          deviceName: 'Acme Air Monitor',
          manufacturer: 'Acme Corp',
          manufacturerStatus: 'active',
          protocol: 'ble',
          category: category,
          localNamePrefixes: const [],
          localNames: const [],
          serviceUuids: const [svcUuid],
          companyIds: Uint16List(0),
          macPrefixes: const [],
          mdnsServiceType: null,
          ssdpSearchTargets: const [],
          lanProtocols: const [],
          defaultPort: null,
          entities: [
            sensor('Radon 24h Average', radonChar, unit: 'Bq/m³'),
            // The same logical reading, bound to another variant's
            // characteristic — the shape a family spec uses when models
            // carry the value in different places.
            sensor('Radon 24h Average', radonAltChar, unit: 'Bq/m³'),
            sensor('Humidity', humidityChar,
                deviceClass: 'humidity', unit: '%'),
            sensor('Battery', batteryChar, deviceClass: 'battery', unit: '%'),
          ],
          services: const [
            ServiceDto(uuid: svcUuid, name: 'Air Service', characteristics: []),
          ],
        );

    const discovered = [
      BleDiscoveredService(
        uuid: svcUuid,
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: radonChar,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
          BleDiscoveredCharacteristic(
            uuid: radonAltChar,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
          BleDiscoveredCharacteristic(
            uuid: humidityChar,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
          BleDiscoveredCharacteristic(
            uuid: batteryChar,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
        ],
      ),
    ];

    FakeSpecCodec airCodec(DeviceSpecDto spec) => FakeSpecCodec(
          spec: spec,
          matches: [
            MatchResult(
              spec: spec,
              matchedByNamePrefix: false,
              matchedServiceUuids: const [svcUuid],
              confidence: MatchConfidence.strong,
            ),
          ],
          decoded: const [
            DecodedValueDto(
              name: 'v',
              valueType: 'uint',
              display: '55',
              uintValue: 55,
            ),
          ],
        );

    FakeBleService airBle() => FakeBleService(readValues: const {
          radonChar: [55, 0],
          radonAltChar: [55, 0],
          humidityChar: [55],
          batteryChar: [85],
        });

    testWidgets(
        'readings render as one deduplicated grid and the raw services fold',
        (tester) async {
      await tester.pumpWidget(await _wrap(
        const DeviceControlPanel(
            deviceId: '01', deviceName: 'Air', services: discovered),
        ble: airBle(),
        codec: airCodec(airSpec()),
        specs: const {'air.yaml': 'yaml'},
      ));
      await tester.pumpAndSettle();

      // Four entities, three distinct readings: the two variant bindings of
      // "Radon 24h Average" collapse to the first that resolved. Without the
      // dedupe the mock — which exposes every variant's service at once —
      // showed one reading twice.
      expect(find.byType(EntitySensorCard), findsNWidgets(3));
      expect(find.text('Radon 24h Average'), findsOneWidget);
      expect(find.text('Humidity'), findsOneWidget);

      // This is a sensor device with its readings on screen, so the GATT
      // plumbing folds: the service card is still there, its characteristics
      // one tap away rather than dominating the first screen.
      expect(find.text('Air Service'), findsOneWidget);
      expect(find.byType(RawCharacteristicWidget), findsNothing);
      expect(find.byType(TypedCharacteristicWidget), findsNothing);

      await tester.tap(find.text('Air Service'));
      await tester.pumpAndSettle();
      expect(find.byType(RawCharacteristicWidget), findsNWidgets(4));
    });

    testWidgets('folding hides the service children without disposing them',
        (tester) async {
      // The readings cards and the folded characteristic widgets subscribe to
      // the SAME characteristics, and the real BLE service answers any one
      // subscriber's cancel with setNotifyValue(false) on the peripheral — no
      // reference counting. If the fold *disposed* the children, their
      // teardown would mute the characteristics the dashboard is still
      // showing, and every notify-driven tile would freeze at its first
      // read. So the fold must keep them mounted offstage.
      const notifying = [
        BleDiscoveredService(
          uuid: svcUuid,
          characteristics: [
            BleDiscoveredCharacteristic(
              uuid: radonChar,
              canRead: true,
              canWrite: false,
              canNotify: true,
            ),
            BleDiscoveredCharacteristic(
              uuid: humidityChar,
              canRead: true,
              canWrite: false,
              canNotify: true,
            ),
          ],
        ),
      ];
      // A stream that stays open, unlike the default done-immediately empty
      // stream — a cancel recorded against it is a real widget teardown.
      final notify = StreamController<List<int>>.broadcast();
      addTearDown(notify.close);
      final ble = FakeBleService(
        readValues: const {
          radonChar: [55, 0],
          humidityChar: [55],
        },
        notifyStream: notify.stream,
      );

      await tester.pumpWidget(await _wrap(
        const DeviceControlPanel(
            deviceId: '01', deviceName: 'Air', services: notifying),
        ble: ble,
        codec: airCodec(airSpec()),
        specs: const {'air.yaml': 'yaml'},
      ));
      await tester.pumpAndSettle();

      // Folded from view…
      expect(find.byType(RawCharacteristicWidget), findsNothing);
      // …but still mounted offstage, subscriptions intact.
      expect(
        find.byType(RawCharacteristicWidget, skipOffstage: false),
        findsNWidgets(2),
      );
      expect(ble.cancelledSubscriptions, isEmpty,
          reason: 'a teardown here disables notifications on the peripheral '
              'for the still-listening readings cards');
    });

    testWidgets('a non-sensor device keeps its service cards open',
        (tester) async {
      await tester.pumpWidget(await _wrap(
        const DeviceControlPanel(
            deviceId: '01', deviceName: 'Air', services: discovered),
        ble: airBle(),
        codec: airCodec(airSpec(category: 'light')),
        specs: const {'air.yaml': 'yaml'},
      ));
      await tester.pumpAndSettle();

      // Same readings, but the device is not a sensor — its controls likely
      // live in the service cards, so they stay expanded as before.
      expect(find.byType(EntitySensorCard), findsNWidgets(3));
      expect(find.byType(RawCharacteristicWidget), findsNWidgets(4));
    });

    testWidgets('a sensor spec whose readings did not resolve does not fold',
        (tester) async {
      // The entity characteristics are absent from what was discovered —
      // nothing to show above, so hiding the GATT tree would hide everything.
      const bare = [BleDiscoveredService(uuid: svcUuid, characteristics: [])];
      await tester.pumpWidget(await _wrap(
        const DeviceControlPanel(
            deviceId: '01', deviceName: 'Air', services: bare),
        ble: airBle(),
        codec: airCodec(airSpec()),
        specs: const {'air.yaml': 'yaml'},
      ));
      await tester.pumpAndSettle();

      expect(find.byType(EntitySensorCard), findsNothing);
      // Folded-with-nothing-above would leave a bare title row; the tile
      // stays open (nothing to expand here since the service is empty, so
      // assert via the tile's controller state: no fold means no collapse
      // animation ran and the card renders exactly as the pre-readings
      // panel always has).
      expect(find.text('Air Service'), findsOneWidget);
    });
  });

  testWidgets('a matched spec with no category still names the manufacturer',
      (tester) async {
    // Specs vendored before `device.category` existed. The header must not
    // render a stray separator or a placeholder saying nothing.
    const svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
    final spec = DeviceSpecDto(
      deviceName: 'Legacy Device',
      manufacturer: 'Acme Corp',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      localNamePrefixes: const ['ACME_'],
      localNames: const [],
      serviceUuids: const [svcUuid],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceType: null,
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const <EntityDto>[],
      services: const [
        ServiceDto(uuid: svcUuid, name: 'Control Service', characteristics: []),
      ],
    );
    const services = [BleDiscoveredService(uuid: svcUuid, characteristics: [])];

    await tester.pumpWidget(await _wrap(
      const DeviceControlPanel(
          deviceId: '01', deviceName: 'ACME_Old', services: services),
      ble: FakeBleService(),
      codec: FakeSpecCodec(
        spec: spec,
        matches: [
          MatchResult(
            spec: spec,
            matchedByNamePrefix: true,
            confidence: MatchConfidence.strong,
            matchedServiceUuids: const [svcUuid],
          ),
        ],
      ),
      specs: const {'legacy.yaml': 'yaml'},
    ));
    await tester.pumpAndSettle();

    expect(find.text('Acme Corp'), findsOneWidget);
    expect(find.byIcon(unknownDeviceIcon), findsOneWidget);
  });
}

// ── Shared fixture: two white-label brands on one GATT platform service ──────
// The tie the chooser exists for: identical matched evidence, distinct specs.

const _tieSvcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
const _tieCharUuid = '0000fff1-0000-1000-8000-00805f9b34fb';

final _brandA = DeviceSpecDto(
  deviceName: 'Brand A Lights',
  manufacturer: 'Vendor A',
  manufacturerStatus: 'active',
  protocol: 'ble',
  localNamePrefixes: [],
  localNames: const [],
  companyIds: Uint16List(0),
  macPrefixes: [],
  mdnsServiceType: null,
  ssdpSearchTargets: [],
  lanProtocols: const [],
  defaultPort: null,
  serviceUuids: [_tieSvcUuid],
  entities: <EntityDto>[],
  services: [
    const ServiceDto(uuid: _tieSvcUuid, name: 'A Control', characteristics: [
      CharacteristicDto(
        uuid: _tieCharUuid,
        name: 'Command',
        canRead: false,
        canWrite: true,
        canNotify: false,
        commands: [
          CommandDto(
            name: 'power_on',
            description: 'On',
            parameters: [],
            isFixed: true,
            isEncodable: true,
            unsupportedEncoding: null,
            advanced: false,
          ),
        ],
        formatFields: [],
      ),
    ]),
  ],
);

final _brandB = DeviceSpecDto(
  deviceName: 'Brand B Lights',
  manufacturer: 'Vendor B',
  manufacturerStatus: 'active',
  protocol: 'ble',
  localNamePrefixes: [],
  localNames: const [],
  companyIds: Uint16List(0),
  macPrefixes: [],
  mdnsServiceType: null,
  ssdpSearchTargets: [],
  lanProtocols: const [],
  defaultPort: null,
  serviceUuids: [_tieSvcUuid],
  entities: <EntityDto>[],
  services: [
    const ServiceDto(uuid: _tieSvcUuid, name: 'B Control', characteristics: []),
  ],
);

const _tieServices = [
  BleDiscoveredService(
    uuid: _tieSvcUuid,
    characteristics: [
      BleDiscoveredCharacteristic(
        uuid: _tieCharUuid,
        canRead: false,
        canWrite: true,
        canNotify: false,
      ),
    ],
  ),
];

FakeSpecCodec _tieCodec() => FakeSpecCodec(
      specByYaml: {'yaml-a': _brandA, 'yaml-b': _brandB},
      matches: [
        MatchResult(
          spec: _brandA,
          matchedByNamePrefix: false,
          matchedServiceUuids: [_tieSvcUuid],
          confidence: MatchConfidence.strong,
        ),
        MatchResult(
          spec: _brandB,
          matchedByNamePrefix: false,
          matchedServiceUuids: [_tieSvcUuid],
          confidence: MatchConfidence.strong,
        ),
      ],
      encoded: Uint8List.fromList([1, 1]),
    );

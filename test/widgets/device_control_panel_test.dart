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
import 'package:liberated_bread_mobile/widgets/switch_control_card.dart';
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
    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: '01',
          deviceName: 'Dev',
          services: [],
        ),
        ble: FakeBleService(),
        codec: FakeSpecCodec(),
      ),
    );
    expect(find.text('No services found on this device.'), findsOneWidget);
  });

  testWidgets('falls back to the raw browser with well-known names when no '
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
    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: '01',
          deviceName: 'Dev',
          services: services,
        ),
        ble: FakeBleService(),
        codec: FakeSpecCodec(), // no spec -> no match -> raw fallback
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(Card), findsNWidgets(2));
    expect(find.text('Battery Service'), findsOneWidget);
    expect(find.text('Generic Access'), findsOneWidget);
    expect(find.byType(TypedCharacteristicWidget), findsNothing);
  });

  testWidgets('a service the registry does not know keeps the generic label', (
    tester,
  ) async {
    // A vendor's own 128-bit UUID is in no registry, and there is nothing
    // true to say about it here — identifying it is the spec matcher's job
    // one level up.
    const services = [
      BleDiscoveredService(
        uuid: '6e400001-b5a3-f393-e0a9-e50e24dcca9e',
        characteristics: [],
      ),
    ];
    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: '01',
          deviceName: 'Dev',
          services: services,
        ),
        ble: FakeBleService(),
        codec: FakeSpecCodec(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Service'), findsOneWidget);
  });

  testWidgets('two instances of one service UUID each get their own card', (
    tester,
  ) async {
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
    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: 'AA:BB',
          deviceName: 'Dual',
          services: duplicated,
        ),
        ble: ble,
        codec: FakeSpecCodec(),
      ),
    );
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

  testWidgets('a family spec shows the model in front of you, not both', (
    tester,
  ) async {
    // seeblue-motorcycle-led is the shape this exists for: TWO lights, BOTH
    // named "Motorcycle LEDs", one per command dialect, told apart only by the
    // advertised name. Before variant narrowing both crossed the FFI and the
    // panel's name dedupe kept whichever the spec declared first — so a
    // LEDGlowV2 was driven with the Direct dialect's frames, silently.
    //
    // The name is deliberately the same on both here. A test using different
    // names would pass against a narrowing keyed on names, which is the
    // implementation that does not work.
    const svcUuid = '0000ffe0-0000-1000-8000-00805f9b34fb';
    const charUuid = '0000ffe1-0000-1000-8000-00805f9b34fb';
    EntityDto light(String variant, String command) => EntityDto(
      name: 'Motorcycle LEDs',
      variants: [variant],
      platform: 'light',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      options: const [],
      actions: [
        EntityActionDto(
          role: 'turn_on',
          commandName: command,
          serviceUuid: svcUuid,
          characteristicUuid: charUuid,
          userParams: const [],
        ),
      ],
    );

    final spec = DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
      deviceName: 'SeeBlue Motorcycle LEDs',
      manufacturer: 'SeeBlue',
      manufacturerStatus: 'active',
      protocol: 'ble',
      category: 'light',
      localNamePrefixes: const ['LEDGlow'],
      localNames: const [],
      serviceUuids: const [svcUuid],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: [light('Direct', 'direct_on'), light('LEDGlow-V2', 'v2_on')],
      services: const [
        ServiceDto(
          uuid: svcUuid,
          name: 'Control',
          characteristics: [
            CharacteristicDto(
              uuid: charUuid,
              name: 'Write',
              canRead: false,
              canWrite: true,
              canNotify: false,
              commands: [],
              formatFields: [],
            ),
          ],
        ),
      ],
    );

    final ble = FakeBleService();
    final codec =
        FakeSpecCodec(
            spec: spec,
            matches: [
              MatchResult(
                spec: spec,
                matchedByNamePrefix: true,
                matchedServiceUuids: const [svcUuid],
                confidence: MatchConfidence.strong,
              ),
            ],
          )
          // What the real narrowing answers for a device advertising LEDGlowV2.
          ..bleVariantNames = (name, uuids) => const ['LEDGlow-V2'];

    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: 'AA:BB',
          deviceName: 'LEDGlowV2',
          services: [
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
          ],
        ),
        ble: ble,
        codec: codec,
        specs: const {'seeblue': 'yaml'},
      ),
    );
    await tester.pumpAndSettle();

    // One light — but the count alone proves nothing, because the panel's name
    // dedupe collapses the two anyway. WHICH dialect is on screen is the whole
    // question, so press it and read what the codec was asked to encode.
    expect(find.text('Motorcycle LEDs'), findsOneWidget);
    await tester.tap(find.widgetWithText(OutlinedButton, 'On'));
    await tester.pumpAndSettle();

    final sent = codec.encodeCalls.map((c) => c.commandName).toList();
    expect(sent, contains('v2_on'));
    expect(
      sent,
      isNot(contains('direct_on')),
      reason: 'the Direct dialect belongs to the other model',
    );

    // And the other model's light is not counted as a missing control either:
    // an entity belonging to another model does not exist here, it is not
    // hidden. Counting it would put a permanent "1 control is not available"
    // on every family device.
    expect(find.textContaining('not available on this device'), findsNothing);
  });

  testWidgets('renders typed controls for a matched characteristic', (
    tester,
  ) async {
    const svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
    const charUuid = '0000fff1-0000-1000-8000-00805f9b34fb';
    // `final`, not `const`: DeviceSpecDto.companyIds is a Uint16List, which has
    // no const form.
    final spec = DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
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
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const <EntityDto>[],
      services: const [
        ServiceDto(
          uuid: svcUuid,
          name: 'Control Service',
          characteristics: [
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
          ],
        ),
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

    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: '01',
          deviceName: 'ACME_Living_Room',
          services: services,
        ),
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
          'vendor/protocol-specs/device-specs/examples/example-bulb.yaml':
              'dummy',
        },
      ),
    );
    await tester.pumpAndSettle();

    // Service card uses the spec name, and a typed command control renders.
    expect(find.text('Control Service'), findsOneWidget);
    expect(find.byType(TypedCharacteristicWidget), findsOneWidget);
    expect(find.text('Power on'), findsWidgets);
  });

  testWidgets(
    'equally-matched specs show the chooser; picking one persists and '
    'renders its typed controls',
    (tester) async {
      await tester.pumpWidget(
        await _wrap(
          const DeviceControlPanel(
            deviceId: 'AA:BB',
            deviceName: 'Mystery',
            services: _tieServices,
          ),
          ble: FakeBleService(),
          codec: _tieCodec(),
          specs: const {'a.yaml': 'yaml-a', 'b.yaml': 'yaml-b'},
        ),
      );
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
    },
  );

  testWidgets('a slot appearing above the service list does not resubscribe', (
    tester,
  ) async {
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
    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: 'AA:BB',
          deviceName: 'Mystery',
          services: notifying,
        ),
        ble: ble,
        codec: _tieCodec(),
        specs: const {'a.yaml': 'yaml-a', 'b.yaml': 'yaml-b'},
      ),
    );
    // First frame: no leading slot yet, every service card mounts.
    await tester.pump();
    expect(ble.subscriptions, hasLength(1));

    // The match resolves and the chooser takes slot 0, shifting every service
    // card down by one.
    await tester.pumpAndSettle();
    expect(find.text('Which device is this?'), findsOneWidget);
    expect(
      ble.subscriptions,
      hasLength(1),
      reason:
          'the shifted card must be carried to its new index, not '
          'destroyed and re-inflated',
    );

    // And again in the other direction, when answering the chooser removes it.
    await tester.tap(find.text('Brand A Lights'));
    await tester.pumpAndSettle();
    expect(ble.subscriptions, hasLength(1));
  });

  testWidgets(
    'a saved choice shows the banner; Change reopens the chooser and a '
    'new pick replaces the stored choice',
    (tester) async {
      await tester.pumpWidget(
        await _wrap(
          const DeviceControlPanel(
            deviceId: 'AA:BB',
            deviceName: 'Mystery',
            services: _tieServices,
          ),
          ble: FakeBleService(),
          codec: _tieCodec(),
          specs: const {'a.yaml': 'yaml-a', 'b.yaml': 'yaml-b'},
          initialPrefs: {
            'spec_choices_v1': jsonEncode({'AA:BB': 'Brand A Lights|Vendor A'}),
          },
        ),
      );
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
    },
  );

  testWidgets('an automatic match names the spec and its device type', (
    tester,
  ) async {
    // The scan row said "Example Smart Bulb" with a bulb icon before the tap.
    // Arriving here to find neither — just controls, appearing — leaves the
    // user to infer what the app decided, with nothing to check it against.
    const svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
    final spec = DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
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
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const <EntityDto>[],
      services: const [
        ServiceDto(uuid: svcUuid, name: 'Control Service', characteristics: []),
      ],
    );
    const services = [BleDiscoveredService(uuid: svcUuid, characteristics: [])];

    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: '01',
          deviceName: 'ACME_Living_Room',
          services: services,
        ),
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
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Example Smart Bulb'), findsOneWidget);
    expect(find.text('Light · Acme Corp'), findsOneWidget);
    expect(find.byIcon(DeviceCategory.light.icon), findsOneWidget);
    // The user did not pick this one, so it is not the saved-choice banner.
    expect(find.text('Device type you picked'), findsNothing);
  });

  testWidgets('a treadmill-category match shows the transport card above the '
      'typed controls', (tester) async {
    const svcUuid = '0000fe00-0000-1000-8000-00805f9b34fb';
    const charUuid = '0000fe02-0000-1000-8000-00805f9b34fb';
    final spec = DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
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
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const <EntityDto>[],
      services: const [
        ServiceDto(
          uuid: svcUuid,
          name: 'WiLink service',
          characteristics: [
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
          ],
        ),
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

    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: '01',
          deviceName: 'ACME_Pad',
          services: services,
        ),
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
      ),
    );
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
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Start'),
      ),
    );
    await tester.pumpAndSettle();
    expect(ble.writes.single.value, [0xF7, 0xFD]);
  });

  testWidgets('a verb the treadmill card draws is not listed again under '
      'Controls', (tester) async {
    // KingSmith and UREVO declare Start/Stop/Target Speed as entities, and
    // the panel listed them as generic control cards right under the card
    // that already draws them as its big buttons.
    const svcUuid = '0000fe00-0000-1000-8000-00805f9b34fb';
    const charUuid = '0000fe02-0000-1000-8000-00805f9b34fb';
    final spec = DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
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
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const <EntityDto>[
        EntityDto(
          options: [],
          name: 'Start',
          key: 'start',
          platform: 'button',
          canNotify: false,
          hasFormat: false,
          onWhenNonzero: false,
          actions: [
            EntityActionDto(
              role: 'press',
              serviceUuid: svcUuid,
              characteristicUuid: charUuid,
              commandName: 'start_belt',
              userParams: [],
            ),
          ],
          variants: [],
        ),
      ],
      services: const [
        ServiceDto(
          uuid: svcUuid,
          name: 'WiLink service',
          characteristics: [
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
          ],
        ),
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

    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: '01',
          deviceName: 'ACME_Pad',
          services: services,
        ),
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
      ),
    );
    await tester.pumpAndSettle();

    // One Start: the card's. The entity it resolved from is not drawn a
    // second time as a generic control under it.
    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Controls'), findsNothing);
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
    }) => EntityDto(
      options: const [],
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
      variants: const [],
    );

    DeviceSpecDto airSpec({String category = 'sensor'}) => DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
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
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: [
        sensor('Radon 24h Average', radonChar, unit: 'Bq/m³'),
        // The same logical reading, bound to another variant's
        // characteristic — the shape a family spec uses when models
        // carry the value in different places.
        sensor('Radon 24h Average', radonAltChar, unit: 'Bq/m³'),
        sensor('Humidity', humidityChar, deviceClass: 'humidity', unit: '%'),
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
          rawNumber: 55.0,
          decodedNumber: 55.0,
          decodedText: '55',
          decimals: 0,
        ),
      ],
    );

    FakeBleService airBle() => FakeBleService(
      readValues: const {
        radonChar: [55, 0],
        radonAltChar: [55, 0],
        humidityChar: [55],
        batteryChar: [85],
      },
    );

    testWidgets(
      'readings render as one deduplicated grid and the raw services fold',
      (tester) async {
        await tester.pumpWidget(
          await _wrap(
            const DeviceControlPanel(
              deviceId: '01',
              deviceName: 'Air',
              services: discovered,
            ),
            ble: airBle(),
            codec: airCodec(airSpec()),
            specs: const {'air.yaml': 'yaml'},
          ),
        );
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
      },
    );

    testWidgets('folding hides the service children without disposing them', (
      tester,
    ) async {
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

      await tester.pumpWidget(
        await _wrap(
          const DeviceControlPanel(
            deviceId: '01',
            deviceName: 'Air',
            services: notifying,
          ),
          ble: ble,
          codec: airCodec(airSpec()),
          specs: const {'air.yaml': 'yaml'},
        ),
      );
      await tester.pumpAndSettle();

      // Folded from view…
      expect(find.byType(RawCharacteristicWidget), findsNothing);
      // …but still mounted offstage, subscriptions intact.
      expect(
        find.byType(RawCharacteristicWidget, skipOffstage: false),
        findsNWidgets(2),
      );
      expect(
        ble.cancelledSubscriptions,
        isEmpty,
        reason:
            'a teardown here disables notifications on the peripheral '
            'for the still-listening readings cards',
      );
    });

    testWidgets('a non-sensor device keeps its service cards open', (
      tester,
    ) async {
      await tester.pumpWidget(
        await _wrap(
          const DeviceControlPanel(
            deviceId: '01',
            deviceName: 'Air',
            services: discovered,
          ),
          ble: airBle(),
          codec: airCodec(airSpec(category: 'light')),
          specs: const {'air.yaml': 'yaml'},
        ),
      );
      await tester.pumpAndSettle();

      // Same readings, but the device is not a sensor — its controls likely
      // live in the service cards, so they stay expanded as before.
      expect(find.byType(EntitySensorCard), findsNWidgets(3));
      expect(find.byType(RawCharacteristicWidget), findsNWidgets(4));
    });

    testWidgets('a sensor spec whose readings did not resolve does not fold', (
      tester,
    ) async {
      // The entity characteristics are absent from what was discovered —
      // nothing to show above, so hiding the GATT tree would hide everything.
      //
      // The service therefore has to have a CHILD for the fold to hide. This
      // used to discover an empty service and then assert that the service
      // title was on screen, which is true folded and unfolded alike — the
      // folded case two tests up asserts the very same title. An unbound
      // characteristic is what makes the two states different: unfolded it is
      // on screen, folded it would be offstage like the fold test's children.
      const strayChar = '0000aab9-0000-1000-8000-00805f9b34fb';
      const bare = [
        BleDiscoveredService(
          uuid: svcUuid,
          characteristics: [
            BleDiscoveredCharacteristic(
              uuid: strayChar,
              canRead: true,
              canWrite: false,
              canNotify: false,
            ),
          ],
        ),
      ];
      await tester.pumpWidget(
        await _wrap(
          const DeviceControlPanel(
            deviceId: '01',
            deviceName: 'Air',
            services: bare,
          ),
          ble: airBle(),
          codec: airCodec(airSpec()),
          specs: const {'air.yaml': 'yaml'},
        ),
      );
      await tester.pumpAndSettle();

      // No reading resolved: the spec's entity characteristics were not
      // discovered, so there is nothing above the GATT tree.
      expect(find.byType(EntitySensorCard), findsNothing);
      expect(find.text('Air Service'), findsOneWidget);
      // ...so the tree itself must be the thing on screen, expanded, with no
      // tap needed. Folding here would leave a title row and nothing else.
      expect(find.byType(RawCharacteristicWidget), findsOneWidget);
    });
  });

  testWidgets('a matched spec with no category still names the manufacturer', (
    tester,
  ) async {
    // Specs vendored before `device.category` existed. The header must not
    // render a stray separator or a placeholder saying nothing.
    const svcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
    final spec = DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
      deviceName: 'Legacy Device',
      manufacturer: 'Acme Corp',
      manufacturerStatus: 'abandoned',
      protocol: 'ble',
      localNamePrefixes: const ['ACME_'],
      localNames: const [],
      serviceUuids: const [svcUuid],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const <EntityDto>[],
      services: const [
        ServiceDto(uuid: svcUuid, name: 'Control Service', characteristics: []),
      ],
    );
    const services = [BleDiscoveredService(uuid: svcUuid, characteristics: [])];

    await tester.pumpWidget(
      await _wrap(
        const DeviceControlPanel(
          deviceId: '01',
          deviceName: 'ACME_Old',
          services: services,
        ),
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
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Acme Corp'), findsOneWidget);
    expect(find.byIcon(unknownDeviceIcon), findsOneWidget);
  });

  // The panel decides isLock and isPrinter from the matched spec's category
  // (and, for a lock, which switch is the bolt). The card tests pass both
  // flags by hand, so a spec rename or a category plumbing change would put
  // "Off" back on the button that opens a door with every one of them green.
  // These drive the flags the way production does: through the panel.
  group('category-driven controls', () {
    // Scoped to the switch card: the typed command widgets further down
    // list the same lock/unlock commands by name.
    Finder inSwitchCard(String text) => find.descendant(
      of: find.byType(SwitchControlCard),
      matching: find.text(text),
    );

    testWidgets('a lock-category spec draws its Lock switch as Lock/Unlock', (
      tester,
    ) async {
      await _pumpCategorySpec(
        tester,
        _categorySpec(category: 'lock', entities: [_switchEntity('Lock')]),
      );

      expect(inSwitchCard('Unlock'), findsOneWidget);
      expect(inSwitchCard('Off'), findsNothing);
      expect(inSwitchCard('On'), findsNothing);
    });

    testWidgets('any other switch on a lock stays an ordinary On/Off', (
      tester,
    ) async {
      // key and deviceClass left null too, so this also proves the other two
      // legs of the bolt test stay quiet, not just the name leg.
      await _pumpCategorySpec(
        tester,
        _categorySpec(category: 'lock', entities: [_switchEntity('Auto-lock')]),
      );

      expect(inSwitchCard('On'), findsOneWidget);
      expect(inSwitchCard('Off'), findsOneWidget);
      expect(inSwitchCard('Unlock'), findsNothing);
    });

    testWidgets('a switch named Lock on a non-lock device stays On/Off', (
      tester,
    ) async {
      await _pumpCategorySpec(
        tester,
        _categorySpec(category: 'light', entities: [_switchEntity('Lock')]),
      );

      expect(inSwitchCard('Off'), findsOneWidget);
      expect(inSwitchCard('Unlock'), findsNothing);
    });

    testWidgets('a printer-category spec with an image surface says Print', (
      tester,
    ) async {
      await _pumpCategorySpec(
        tester,
        _categorySpec(category: 'printer', imageUpload: _paper),
      );

      expect(find.text('Print an image'), findsOneWidget);
      expect(find.text('LED image'), findsNothing);
      expect(find.text('Print'), findsOneWidget);
      expect(find.text('Send to device'), findsNothing);
    });

    testWidgets('the same image surface on an LED panel says LED image', (
      tester,
    ) async {
      await _pumpCategorySpec(
        tester,
        _categorySpec(category: 'light', imageUpload: _paper),
      );

      expect(find.text('LED image'), findsOneWidget);
      expect(find.text('Send to device'), findsOneWidget);
      expect(find.text('Print'), findsNothing);
    });
  });

  group('screenshot review', () {
    const lightSvc = '0000fff0-0000-1000-8000-00805f9b34fb';
    const lightChar = '0000fff1-0000-1000-8000-00805f9b34fb';
    const batterySvc = '0000180f-0000-1000-8000-00805f9b34fb';
    const batteryChar = '00002a19-0000-1000-8000-00805f9b34fb';

    const bulb = EntityDto(
      name: 'Bulb',
      variants: [],
      platform: 'light',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      options: [],
      actions: [
        EntityActionDto(
          role: 'turn_on',
          commandName: 'power_on',
          serviceUuid: lightSvc,
          characteristicUuid: lightChar,
          userParams: [],
        ),
      ],
    );

    DeviceSpecDto lightSpecWith(List<EntityDto> entities) => DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
      deviceName: 'Example Smart Bulb',
      manufacturer: 'Acme Corp',
      manufacturerStatus: 'active',
      protocol: 'ble',
      category: 'light',
      localNamePrefixes: const ['ACME_'],
      localNames: const [],
      serviceUuids: const [lightSvc],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: entities,
      services: const [
        ServiceDto(
          uuid: lightSvc,
          name: 'Control Service',
          characteristics: [
            CharacteristicDto(
              uuid: lightChar,
              name: 'Command',
              canRead: false,
              canWrite: true,
              canNotify: false,
              commands: [],
              formatFields: [],
            ),
          ],
        ),
      ],
    );

    final lightSpec = lightSpecWith(const [bulb]);

    const services = [
      BleDiscoveredService(
        uuid: lightSvc,
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: lightChar,
            canRead: false,
            canWrite: true,
            canNotify: false,
          ),
        ],
      ),
      BleDiscoveredService(
        uuid: batterySvc,
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: batteryChar,
            canRead: true,
            canWrite: false,
            canNotify: false,
          ),
        ],
      ),
    ];

    Future<void> pumpLight(
      WidgetTester tester, {
      Widget? header,
      DeviceSpecDto? spec,
      List<BleDiscoveredService> discovered = services,
    }) async {
      final matched = spec ?? lightSpec;
      await tester.pumpWidget(
        await _wrap(
          DeviceControlPanel(
            deviceId: '01',
            deviceName: 'ACME_Living_Room',
            services: discovered,
            header: header,
          ),
          ble: FakeBleService(
            readValues: const {
              batteryChar: [85],
            },
          ),
          codec: FakeSpecCodec(
            spec: matched,
            encoded: Uint8List.fromList([1]),
            decoded: const [
              DecodedValueDto(
                name: 'v',
                valueType: 'uint',
                display: '85',
                uintValue: 85,
                rawNumber: 85.0,
                decodedNumber: 85.0,
                decodedText: '85',
                decimals: 0,
              ),
            ],
            matches: [
              MatchResult(
                spec: matched,
                matchedByNamePrefix: true,
                matchedServiceUuids: const [lightSvc],
                confidence: MatchConfidence.strong,
              ),
            ],
          ),
          specs: const {'bulb.yaml': 'yaml'},
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('a service the light card draws starts folded, and only that '
        'one', (tester) async {
      await pumpLight(tester);

      expect(find.text('Bulb'), findsOneWidget);
      // The light's Control Service repeated the card's verbs as generic
      // command cards. Folded, not removed: still mounted, one tap away.
      expect(find.text('Control Service'), findsOneWidget);
      expect(find.byType(TypedCharacteristicWidget), findsNothing);
      expect(
        find.byType(TypedCharacteristicWidget, skipOffstage: false),
        findsOneWidget,
      );
      // A service the light does not bind keeps its card open.
      expect(find.byType(RawCharacteristicWidget), findsOneWidget);

      await tester.tap(find.text('Control Service'));
      await tester.pumpAndSettle();
      expect(find.byType(TypedCharacteristicWidget), findsOneWidget);
    });

    testWidgets('a service whose every characteristic is an on-screen '
        'reading starts folded', (tester) async {
      // The Battery Service repeated the Readings card's "Battery 85 %" as
      // an expanded raw value, one screen apart. Folded like the light's
      // service: mounted, one tap away. Fails on the old panel, which only
      // folded a sensor device's services.
      await pumpLight(
        tester,
        spec: lightSpecWith(const [
          bulb,
          EntityDto(
            name: 'Battery',
            variants: [],
            platform: 'sensor',
            deviceClass: 'battery',
            unit: '%',
            stateCharacteristic: batteryChar,
            canNotify: false,
            hasFormat: true,
            valueField: 'v',
            onWhenNonzero: false,
            options: [],
            actions: [],
          ),
        ]),
      );

      expect(find.byType(EntitySensorCard), findsOneWidget);
      expect(find.text('Battery Service'), findsOneWidget);
      expect(find.byType(RawCharacteristicWidget), findsNothing);

      await tester.tap(find.text('Battery Service'));
      await tester.pumpAndSettle();
      expect(find.byType(RawCharacteristicWidget), findsOneWidget);
    });

    testWidgets('a light keeps the brightness the user sent when its card '
        'scrolls out of the list and back', (tester) async {
      // The controls section is one item of a lazy list: scrolled away it was
      // disposed, and the rebuilt light card re-seeded to full brightness —
      // "80%" for a light the user had just set to 13%. Fails without the
      // keep-alive: the slider is back at its maximum.
      const dimmable = EntityDto(
        name: 'Bulb',
        variants: [],
        platform: 'light',
        canNotify: false,
        hasFormat: false,
        onWhenNonzero: false,
        options: [],
        actions: [
          EntityActionDto(
            role: 'set_brightness',
            commandName: 'set_brightness',
            serviceUuid: lightSvc,
            characteristicUuid: lightChar,
            userParams: ['brightness'],
            min: 0,
            max: 100,
          ),
        ],
      );
      // Enough raw services below the controls to scroll them far past the
      // list's cache extent.
      final many = [
        ...services,
        for (var i = 0; i < 40; i++)
          BleDiscoveredService(
            uuid:
                '0000ee${i.toString().padLeft(2, '0')}'
                '-0000-1000-8000-00805f9b34fb',
            characteristics: const [
              BleDiscoveredCharacteristic(
                uuid: '0000eeff-0000-1000-8000-00805f9b34fb',
                canRead: false,
                canWrite: false,
                canNotify: false,
              ),
            ],
          ),
      ];
      await pumpLight(
        tester,
        spec: lightSpecWith(const [dimmable]),
        discovered: many,
      );

      double sliderValue() => tester.widget<Slider>(find.byType(Slider)).value;
      expect(sliderValue(), 100);
      await tester.drag(find.byType(Slider), const Offset(-1000, 0));
      await tester.pumpAndSettle();
      expect(sliderValue(), 0);

      await tester.drag(find.byType(ListView), const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(find.byType(Slider), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, 6000));
      await tester.pumpAndSettle();

      expect(sliderValue(), 0);
    });

    testWidgets('service cards draw no edge-to-edge dividers when open', (
      tester,
    ) async {
      await pumpLight(tester);
      for (final tile in tester.widgetList<ExpansionTile>(
        find.byType(ExpansionTile),
      )) {
        expect(tile.shape, const Border());
        expect(tile.collapsedShape, const Border());
      }
    });

    testWidgets('the header is the first item of the scrolling list', (
      tester,
    ) async {
      await pumpLight(tester, header: const Text('HEADER'));
      expect(
        find.ancestor(of: find.text('HEADER'), matching: find.byType(ListView)),
        findsOneWidget,
      );
      expect(
        tester.getTopLeft(find.text('HEADER')).dy,
        lessThan(tester.getTopLeft(find.text('Bulb')).dy),
      );
    });

    testWidgets('a device with no services still shows the header', (
      tester,
    ) async {
      await tester.pumpWidget(
        await _wrap(
          const DeviceControlPanel(
            deviceId: '01',
            deviceName: 'X',
            services: [],
            header: Text('HEADER'),
          ),
          ble: FakeBleService(),
          codec: FakeSpecCodec(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('HEADER'), findsOneWidget);
      expect(find.text('No services found on this device.'), findsOneWidget);
    });
  });
}

// ── Fixture: one spec per category, driven through the panel ─────────────────

const _catSvcUuid = '0000fd00-0000-1000-8000-00805f9b34fb';
const _catCharUuid = '0000fd01-0000-1000-8000-00805f9b34fb';

const _paper = ImageUploadDto(
  encodable: true,
  resolutionDeviceReported: false,
  animation: false,
  maxWidth: 8,
  maxHeight: 8,
);

/// A stateless switch the way the vendored lock specs declare their bolt:
/// platform switch, a display name, turn_on/turn_off commands, and no key or
/// device_class.
EntityDto _switchEntity(String name) => EntityDto(
  options: const [],
  name: name,
  platform: 'switch',
  canNotify: false,
  hasFormat: false,
  onWhenNonzero: false,
  actions: [
    for (final (role, command) in const [
      ('turn_on', 'lock'),
      ('turn_off', 'unlock'),
    ])
      EntityActionDto(
        role: role,
        serviceUuid: _catSvcUuid,
        characteristicUuid: _catCharUuid,
        commandName: command,
        userParams: const [],
      ),
  ],
  variants: const [],
);

DeviceSpecDto _categorySpec({
  required String category,
  List<EntityDto> entities = const [],
  ImageUploadDto? imageUpload,
}) => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Test $category',
  manufacturer: 'Acme',
  manufacturerStatus: 'active',
  protocol: 'ble',
  category: category,
  localNamePrefixes: const ['ACME_'],
  localNames: const [],
  serviceUuids: const [_catSvcUuid],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: entities,
  imageUpload: imageUpload,
  services: [
    ServiceDto(
      uuid: _catSvcUuid,
      name: 'Command service',
      characteristics: [
        CharacteristicDto(
          uuid: _catCharUuid,
          name: 'Command write',
          canRead: false,
          canWrite: true,
          canNotify: false,
          commands: [
            for (final name in const ['lock', 'unlock'])
              CommandDto(
                name: name,
                description: name,
                parameters: const [],
                isFixed: true,
                isEncodable: true,
                unsupportedEncoding: null,
                advanced: false,
              ),
          ],
          formatFields: const [],
        ),
      ],
    ),
  ],
);

Future<void> _pumpCategorySpec(WidgetTester tester, DeviceSpecDto spec) async {
  const services = [
    BleDiscoveredService(
      uuid: _catSvcUuid,
      characteristics: [
        BleDiscoveredCharacteristic(
          uuid: _catCharUuid,
          canRead: false,
          canWrite: true,
          canNotify: false,
        ),
      ],
    ),
  ];
  await tester.pumpWidget(
    await _wrap(
      const DeviceControlPanel(
        deviceId: '01',
        deviceName: 'ACME_Device',
        services: services,
      ),
      ble: FakeBleService(),
      codec: FakeSpecCodec(
        spec: spec,
        matches: [
          MatchResult(
            spec: spec,
            matchedByNamePrefix: true,
            matchedServiceUuids: const [_catSvcUuid],
            confidence: MatchConfidence.strong,
          ),
        ],
        encoded: Uint8List.fromList([0x0A]),
      ),
      specs: const {'category.yaml': 'yaml'},
    ),
  );
  await tester.pumpAndSettle();
}

// ── Shared fixture: two white-label brands on one GATT platform service ──────
// The tie the chooser exists for: identical matched evidence, distinct specs.

const _tieSvcUuid = '0000fff0-0000-1000-8000-00805f9b34fb';
const _tieCharUuid = '0000fff1-0000-1000-8000-00805f9b34fb';

final _brandA = DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Brand A Lights',
  manufacturer: 'Vendor A',
  manufacturerStatus: 'active',
  protocol: 'ble',
  localNamePrefixes: [],
  localNames: const [],
  companyIds: Uint16List(0),
  macPrefixes: [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: [],
  lanProtocols: const [],
  defaultPort: null,
  serviceUuids: [_tieSvcUuid],
  entities: <EntityDto>[],
  services: [
    const ServiceDto(
      uuid: _tieSvcUuid,
      name: 'A Control',
      characteristics: [
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
      ],
    ),
  ],
);

final _brandB = DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Brand B Lights',
  manufacturer: 'Vendor B',
  manufacturerStatus: 'active',
  protocol: 'ble',
  localNamePrefixes: [],
  localNames: const [],
  companyIds: Uint16List(0),
  macPrefixes: [],
  mdnsServiceTypes: const [],
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

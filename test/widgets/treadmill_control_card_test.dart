// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/treadmill_control_card.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_spec_codec.dart';

const _svc = '0000fe00-0000-1000-8000-00805f9b34fb';
const _char = '0000fe02-0000-1000-8000-00805f9b34fb';

// A KingSmith WiLink-shaped spec: a fixed start command, a speed command with
// presentation metadata (raw counts at 0.1 km/h) beside an encoder-filled
// checksum byte, and the shared stop-or-pause opcode whose action byte splits
// Stop (1) from Pause (2).
final _treadmillSpec = DeviceSpecDto(
  deviceName: 'Test Walking Pad',
  manufacturer: 'Acme Fitness',
  manufacturerStatus: 'active',
  protocol: 'ble',
  category: 'treadmill',
  localNamePrefixes: const [],
  serviceUuids: const [_svc],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceType: null,
  ssdpSearchTargets: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: const [
    ServiceDto(uuid: _svc, name: 'WiLink treadmill service', characteristics: [
      CharacteristicDto(
        uuid: _char,
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
          CommandDto(
            name: 'set_speed',
            description: 'Set belt speed',
            isFixed: false,
            isEncodable: true,
            unsupportedEncoding: null,
            advanced: false,
            parameters: [
              ParameterDto(
                name: 'speed',
                valueType: 'uint8',
                min: 0,
                max: 60,
                scale: 0.1,
                unit: 'km/h',
              ),
              ParameterDto(
                  name: 'checksum', valueType: 'uint8', auto: 'checksum'),
            ],
          ),
          CommandDto(
            name: 'stop_or_pause',
            description: 'Stop or pause',
            isFixed: false,
            isEncodable: true,
            unsupportedEncoding: null,
            advanced: false,
            parameters: [
              ParameterDto(name: 'action', valueType: 'uint8', min: 1, max: 2),
            ],
          ),
        ],
        formatFields: [],
      ),
    ]),
  ],
);

const _treadmillServices = [
  BleDiscoveredService(
    uuid: _svc,
    characteristics: [
      BleDiscoveredCharacteristic(
        uuid: _char,
        canRead: false,
        canWrite: true,
        canNotify: false,
      ),
    ],
  ),
];

Widget _wrap({
  required FakeBleService ble,
  required FakeSpecCodec codec,
  // Nullable because _treadmillSpec is `final` (Uint16List has no const
  // form), and a default value must be const.
  DeviceSpecDto? spec,
  List<BleDiscoveredService> services = _treadmillServices,
}) =>
    ProviderScope(
      overrides: [
        bleServiceProvider.overrideWithValue(ble),
        specCodecProvider.overrideWithValue(codec),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: TreadmillControlCard(
              deviceId: 'd',
              specYaml: 'yaml',
              spec: spec ?? _treadmillSpec,
              services: services,
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('renders the transport buttons and the speed control',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    // The speed control presents in decoded units, seeded at range bottom.
    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('0.0 km/h'), findsOneWidget);
    expect(find.byType(Slider), findsOneWidget);
  });

  testWidgets('Start encodes the fixed command and writes it', (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xA7]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();

    // Start never fires from one tap: it sets a belt moving under a person,
    // so the card asks first, every time.
    expect(find.text('Start the belt?'), findsOneWidget);
    expect(codec.encodeCalls, isEmpty);
    await tester.tap(find.descendant(
        of: find.byType(AlertDialog), matching: find.text('Start')));
    await tester.pumpAndSettle();

    final call =
        codec.encodeCalls.firstWhere((c) => c.commandName == 'start_belt');
    expect(call.params, isEmpty);
    expect(call.charUuid, _char);
    expect(ble.writes.single.value, [0xF7, 0xA7]);
    // Status line and snackbar both announce the send.
    expect(find.text('Sent Start belt'), findsWidgets);
  });

  testWidgets(
      'the shared stop-or-pause opcode splits into Pause and Stop '
      'through its action byte', (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x08, 0x02]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    var call =
        codec.encodeCalls.firstWhere((c) => c.commandName == 'stop_or_pause');
    expect(call.params, {'action': 2.0});

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    call = codec.encodeCalls.lastWhere((c) => c.commandName == 'stop_or_pause');
    expect(call.params, {'action': 1.0});
    expect(ble.writes, hasLength(2));
  });

  testWidgets('Stop stays live while another write is in flight',
      (tester) async {
    // A speed write can stall for many seconds behind the BLE stack; that is
    // exactly when the belt is moving under someone, so the one control that
    // halts it must not grey out with the rest.
    final gate = Completer<void>();
    final ble = FakeBleService(writeGate: gate.future);
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x08, 0x01]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    // Hold a speed write in flight.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump();
    expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull,
        reason: 'the ordinary controls disable during a send');

    await tester.tap(find.text('Stop'));
    await tester.pump();
    // Both writes resolve once the stack unblocks; Stop queued behind the
    // stalled speed write rather than being refused.
    gate.complete();
    await tester.pumpAndSettle();
    expect(ble.writes, hasLength(2));
    expect(
        codec.encodeCalls.map((c) => c.commandName), contains('stop_or_pause'));
  });

  testWidgets('the speed stepper commits immediately, in raw wire units',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    // 0.0 -> 0.5 km/h on tap, which is raw 5 at scale 0.1 — and the
    // encoder-filled checksum parameter is never supplied by the card.
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('0.5 km/h'), findsOneWidget);
    final call =
        codec.encodeCalls.firstWhere((c) => c.commandName == 'set_speed');
    expect(call.params, {'speed': 5.0});
    expect(ble.writes.single.value, [0xF7, 0xFD]);
  });

  testWidgets('the slider commits on release, not on every drag tick',
      (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    final slider = tester.widget<Slider>(find.byType(Slider));
    // Display space: 0..6.0 km/h. Dragging updates the label but sends
    // nothing — each commit is a BLE write to a moving belt.
    expect(slider.min, closeTo(0.0, 1e-9));
    expect(slider.max, closeTo(6.0, 1e-9));
    slider.onChanged!(3.0);
    await tester.pump();
    expect(find.text('3.0 km/h'), findsOneWidget);
    expect(codec.encodeCalls, isEmpty);

    slider.onChangeEnd!(3.0);
    await tester.pumpAndSettle();
    final call =
        codec.encodeCalls.firstWhere((c) => c.commandName == 'set_speed');
    expect(call.params, {'speed': 30.0});
  });

  testWidgets(
      'an encode failure surfaces as the status text; nothing is '
      'written and no value is fabricated', (tester) async {
    // The graceful path for a speed command with a second caller-owned
    // parameter (a slope byte): the encoder refuses with ParameterMissing
    // rather than the card inventing a value.
    final ble = FakeBleService();
    final codec =
        FakeSpecCodec(encodeError: StateError('ParameterMissing: slope'));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(
        find.text('The treadmill did not accept that command.'), findsWidgets);
    expect(find.textContaining('ParameterMissing'), findsNothing);
    expect(ble.writes, isEmpty);
  });

  testWidgets('renders nothing when no verb resolves for the spec',
      (tester) async {
    // A treadmill-category spec whose commands use none of the known
    // spellings: the card steps aside and the per-characteristic command
    // widgets below remain the control surface.
    final spec = DeviceSpecDto(
      deviceName: 'Odd Treadmill',
      manufacturer: 'Acme Fitness',
      manufacturerStatus: 'active',
      protocol: 'ble',
      category: 'treadmill',
      localNamePrefixes: const [],
      serviceUuids: const [_svc],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceType: null,
      ssdpSearchTargets: const [],
      defaultPort: null,
      entities: const <EntityDto>[],
      services: const [
        ServiceDto(uuid: _svc, name: 'Service', characteristics: [
          CharacteristicDto(
            uuid: _char,
            name: 'Command write',
            canRead: false,
            canWrite: true,
            canNotify: false,
            commands: [
              CommandDto(
                name: 'query_status',
                description: 'Poll',
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
    await tester.pumpWidget(_wrap(
      ble: FakeBleService(),
      codec: FakeSpecCodec(),
      spec: spec,
    ));

    expect(find.text('Start'), findsNothing);
    expect(find.text('Stop'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets(
      'commands on characteristics the device does not carry do not '
      'resolve', (tester) async {
    // The spec describes the full WiLink command set, but this unit's GATT
    // table has no such service — same discovery check the panel applies to
    // entity actions.
    await tester.pumpWidget(_wrap(
      ble: FakeBleService(),
      codec: FakeSpecCodec(),
      services: const [],
    ));

    expect(find.text('Start'), findsNothing);
    expect(find.byType(Card), findsNothing);
  });
}

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
// Stop (1) from Pause (2). [advancedSpeed] flags set_speed advanced, so the
// card's once-per-command warning stands in front of it.
final _treadmillSpec = _treadmillSpecWith();

DeviceSpecDto _treadmillSpecWith({bool advancedSpeed = false}) => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Test Walking Pad',
  manufacturer: 'Acme Fitness',
  manufacturerStatus: 'active',
  protocol: 'ble',
  category: 'treadmill',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [_svc],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: [
    ServiceDto(
      uuid: _svc,
      name: 'WiLink treadmill service',
      characteristics: [
        CharacteristicDto(
          uuid: _char,
          name: 'Command write',
          canRead: false,
          canWrite: true,
          canNotify: false,
          commands: [
            const CommandDto(
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
              advanced: advancedSpeed,
              advancedReason: 'Test: speed is advanced.',
              parameters: const [
                ParameterDto(
                  name: 'speed',
                  valueType: 'uint8',
                  min: 0,
                  max: 60,
                  scale: 0.1,
                  unit: 'km/h',
                  userSettable: true,
                ),
                ParameterDto(
                  name: 'checksum',
                  valueType: 'uint8',
                  auto: 'checksum',
                  userSettable: false,
                ),
              ],
            ),
            const CommandDto(
              name: 'stop_or_pause',
              description: 'Stop or pause',
              isFixed: false,
              isEncodable: true,
              unsupportedEncoding: null,
              advanced: false,
              parameters: [
                ParameterDto(
                  name: 'action',
                  valueType: 'uint8',
                  min: 1,
                  max: 2,
                  userSettable: true,
                ),
              ],
            ),
          ],
          formatFields: const [],
        ),
      ],
    ),
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
  // The variant-narrowed entities the panel hands over. Defaults to the whole
  // spec's, which is what a single-generation device gets.
  List<EntityDto>? entities,
}) => ProviderScope(
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
          entities: entities ?? (spec ?? _treadmillSpec).entities,
        ),
      ),
    ),
  ),
);

void main() {
  group('R-112: the presentation transform is stated once', () {
    // The card used to spell `scale == null || scale == 0 ? 1.0 : scale!`
    // out three times — mapping the range, mapping a dialled speed back, and
    // counting decimals — so a fix to one was a fix to one. The arithmetic
    // now runs through `displayValueFor`/`rawValueFor`; the only thing left
    // here is which scale to use.
    ParameterDto param({double? scale}) => ParameterDto(
      name: 'speed',
      valueType: 'uint16',
      scale: scale,
      userSettable: true,
    );

    test('a declared scale is used as declared', () {
      expect(speedScaleOf(param(scale: 0.1)), 0.1);
      expect(speedScaleOf(param(scale: -0.5)), -0.5);
    });

    test('no scale is the identity', () {
      expect(speedScaleOf(param()), 1.0);
    });

    test('a malformed zero scale is the identity, never a divisor', () {
      // Dividing a dialled speed by it would hand the encoder Infinity.
      expect(speedScaleOf(param(scale: 0)), 1.0);
    });
  });

  testWidgets('renders the transport buttons and the speed control', (
    tester,
  ) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    expect(find.byIcon(Icons.pause), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);
    // With no live reading and nothing sent yet, the speed is unknown — not
    // the bottom of the range dressed up as a reading.
    expect(find.text('Speed'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('0.0 km/h'), findsNothing);
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
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Start'),
      ),
    );
    await tester.pumpAndSettle();

    final call = codec.encodeCalls.firstWhere(
      (c) => c.commandName == 'start_belt',
    );
    expect(call.params, isEmpty);
    expect(call.charUuid, _char);
    expect(ble.writes.single.value, [0xF7, 0xA7]);
    // Status line and snackbar both announce the send.
    expect(find.text('Sent Start belt'), findsWidgets);
  });

  testWidgets('the shared stop-or-pause opcode splits into Pause and Stop '
      'through its action byte', (tester) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x08, 0x02]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    await tester.tap(find.text('Pause'));
    await tester.pumpAndSettle();
    var call = codec.encodeCalls.firstWhere(
      (c) => c.commandName == 'stop_or_pause',
    );
    expect(call.params, {'action': 2.0});

    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    call = codec.encodeCalls.lastWhere((c) => c.commandName == 'stop_or_pause');
    expect(call.params, {'action': 1.0});
    expect(ble.writes, hasLength(2));
  });

  testWidgets('Stop stays live while another write is in flight', (
    tester,
  ) async {
    // A speed write can stall for many seconds behind the BLE stack; that is
    // exactly when the belt is moving under someone, so the one control that
    // halts it must not grey out with the rest.
    final gate = Completer<void>();
    final ble = FakeBleService(writeGate: gate.future);
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x08, 0x01]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    // Hold a speed write in flight.
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(2.0);
    await tester.pump();
    expect(
      tester.widget<Slider>(find.byType(Slider)).onChanged,
      isNull,
      reason: 'the ordinary controls disable during a send',
    );

    await tester.tap(find.text('Stop'));
    await tester.pump();
    // Both writes resolve once the stack unblocks; Stop queued behind the
    // stalled speed write rather than being refused.
    gate.complete();
    await tester.pumpAndSettle();
    expect(ble.writes, hasLength(2));
    expect(
      codec.encodeCalls.map((c) => c.commandName),
      contains('stop_or_pause'),
    );
  });

  testWidgets('the speed stepper commits immediately, in raw wire units', (
    tester,
  ) async {
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    // A committed 3.0 km/h is the baseline; 3.0 -> 3.5 km/h on tap, which
    // is raw 35 at scale 0.1 — and the encoder-filled checksum parameter is
    // never supplied by the card.
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(3.0);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.text('3.5 km/h'), findsOneWidget);
    final call = codec.encodeCalls.lastWhere(
      (c) => c.commandName == 'set_speed',
    );
    expect(call.params, {'speed': 35.0});
    expect(ble.writes.last.value, [0xF7, 0xFD]);
  });

  testWidgets('the slider commits on release, not on every drag tick', (
    tester,
  ) async {
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
    final call = codec.encodeCalls.firstWhere(
      (c) => c.commandName == 'set_speed',
    );
    expect(call.params, {'speed': 30.0});
  });

  testWidgets('an encode failure surfaces as the status text; nothing is '
      'written and no value is fabricated', (tester) async {
    // The graceful path for a speed command with a second caller-owned
    // parameter (a slope byte): the encoder refuses with ParameterMissing
    // rather than the card inventing a value.
    final ble = FakeBleService();
    final codec = FakeSpecCodec(
      encodeError: StateError('ParameterMissing: slope'),
    );
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(2.0);
    await tester.pumpAndSettle();

    expect(
      find.text('The treadmill did not accept that command.'),
      findsWidgets,
    );
    expect(find.textContaining('ParameterMissing'), findsNothing);
    expect(ble.writes, isEmpty);
  });

  testWidgets('renders nothing when no verb resolves for the spec', (
    tester,
  ) async {
    // A treadmill-category spec whose commands use none of the known
    // spellings: the card steps aside and the per-characteristic command
    // widgets below remain the control surface.
    final spec = DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
      deviceName: 'Odd Treadmill',
      manufacturer: 'Acme Fitness',
      manufacturerStatus: 'active',
      protocol: 'ble',
      category: 'treadmill',
      localNamePrefixes: const [],
      localNames: const [],
      serviceUuids: const [_svc],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const <EntityDto>[],
      services: const [
        ServiceDto(
          uuid: _svc,
          name: 'Service',
          characteristics: [
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
          ],
        ),
      ],
    );
    await tester.pumpWidget(
      _wrap(ble: FakeBleService(), codec: FakeSpecCodec(), spec: spec),
    );

    expect(find.text('Start'), findsNothing);
    expect(find.text('Stop'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets('commands on characteristics the device does not carry do not '
      'resolve', (tester) async {
    // The spec describes the full WiLink command set, but this unit's GATT
    // table has no such service — same discovery check the panel applies to
    // entity actions.
    await tester.pumpWidget(
      _wrap(ble: FakeBleService(), codec: FakeSpecCodec(), services: const []),
    );

    expect(find.text('Start'), findsNothing);
    expect(find.byType(Card), findsNothing);
  });

  testWidgets("KingSmith's stop_belt resolves as the Stop verb", (
    tester,
  ) async {
    // The WiLink belt has no stop opcode; stop_belt is the speed-0 frame the
    // spec names so the card has a Stop to bind to.
    final spec = _spedSpec(const [
      CommandDto(
        name: 'start_belt',
        description: 'Start',
        parameters: [],
        isFixed: true,
        isEncodable: true,
        unsupportedEncoding: null,
        advanced: false,
      ),
      CommandDto(
        name: 'stop_belt',
        description: 'Stop',
        parameters: [],
        isFixed: true,
        isEncodable: true,
        unsupportedEncoding: null,
        advanced: false,
      ),
    ]);
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xA3]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec, spec: spec));

    expect(find.text('Stop'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();

    final call = codec.encodeCalls.single;
    expect(call.commandName, 'stop_belt');
    expect(ble.writes.single.value, [0xF7, 0xA3]);
  });

  testWidgets("UREVO's proprietary verbs drive the card", (tester) async {
    // The FT/UR classes name start/pause/stop/speed differently; the card
    // resolves them so a UREVO pad gets real buttons, not raw hex.
    final spec = _spedSpec(const [
      CommandDto(
        name: 'ur_training_prepared',
        description: 'Start',
        parameters: [],
        isFixed: true,
        isEncodable: true,
        unsupportedEncoding: null,
        advanced: false,
      ),
      CommandDto(
        name: 'ur_training_pause',
        description: 'Pause',
        parameters: [],
        isFixed: true,
        isEncodable: true,
        unsupportedEncoding: null,
        advanced: false,
      ),
      CommandDto(
        name: 'ur_training_stop',
        description: 'Stop',
        parameters: [],
        isFixed: true,
        isEncodable: true,
        unsupportedEncoding: null,
        advanced: false,
      ),
      CommandDto(
        name: 'ur_set_speed_and_slope',
        description: 'Set speed and slope',
        isFixed: false,
        isEncodable: true,
        unsupportedEncoding: null,
        advanced: false,
        parameters: [
          ParameterDto(
            name: 'speed',
            valueType: 'uint8',
            min: 0,
            max: 255,
            userSettable: true,
          ),
          // The slope defaults to 0 in the spec, so the card sends speed alone.
          ParameterDto(
            name: 'slope',
            valueType: 'uint8',
            min: 0,
            max: 255,
            userSettable: true,
          ),
          ParameterDto(
            name: 'checksum',
            valueType: 'uint8',
            auto: 'checksum',
            userSettable: false,
          ),
        ],
      ),
    ]);
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x02, 0x53]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec, spec: spec));

    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Pause'), findsOneWidget);
    expect(find.text('Stop'), findsOneWidget);
    expect(
      find.byType(Slider),
      findsOneWidget,
      reason: 'the speed+slope write is the card speed control',
    );

    // Stop resolves to the UR stop, and it is not gated behind a confirm.
    await tester.tap(find.text('Stop'));
    await tester.pumpAndSettle();
    expect(codec.encodeCalls.single.commandName, 'ur_training_stop');

    // The speed control sends only the speed param; the slope rides its spec
    // default, so nothing here fabricates an incline the pad does not have.
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(10);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    final speedCall = codec.encodeCalls.lastWhere(
      (c) => c.commandName == 'ur_set_speed_and_slope',
    );
    expect(speedCall.params.keys, ['speed']);
  });
  testWidgets('an entity-bound verb beats the command-name list', (
    tester,
  ) async {
    // The spec binds Start through its entity layer to a command of its own
    // naming — while ALSO declaring a command called start_belt that the
    // historical name list would pick. The entity binding must win.
    final spec = DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
      deviceName: 'Keyed Pad',
      manufacturer: 'Acme Fitness',
      manufacturerStatus: 'active',
      protocol: 'ble',
      category: 'treadmill',
      localNamePrefixes: const [],
      localNames: const [],
      serviceUuids: const [_svc],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const [
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
              serviceUuid: _svc,
              characteristicUuid: _char,
              commandName: 'vendor_go',
              userParams: [],
            ),
          ],
          variants: [],
        ),
      ],
      services: const [
        ServiceDto(
          uuid: _svc,
          name: 'svc',
          characteristics: [
            CharacteristicDto(
              uuid: _char,
              name: 'Command write',
              canRead: false,
              canWrite: true,
              canNotify: false,
              formatFields: [],
              commands: [
                CommandDto(
                  name: 'start_belt',
                  description: 'The decoy the name list would pick',
                  parameters: [],
                  isFixed: true,
                  isEncodable: true,
                  unsupportedEncoding: null,
                  advanced: false,
                ),
                CommandDto(
                  name: 'vendor_go',
                  description: 'The entity-bound start',
                  parameters: [],
                  isFixed: true,
                  isEncodable: true,
                  unsupportedEncoding: null,
                  advanced: false,
                ),
              ],
            ),
          ],
        ),
      ],
    );
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x01]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec, spec: spec));

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Start'),
      ),
    );
    await tester.pumpAndSettle();

    expect(codec.encodeCalls.single.commandName, 'vendor_go');
  });

  testWidgets('a two-generation pad is driven by the generation in front of us', (
    tester,
  ) async {
    // The KingSmith shape, and the bug this card had. One spec covers two
    // protocol generations — the private 0xFE00 `WiLink` service and the
    // standard `FTMS` Fitness Machine Service — and declares a Start for EACH,
    // both called "Start". Indexing all of them takes whichever the spec listed
    // first, so an FTMS belt was driven from WiLink's entity: its
    // characteristic is not on the device, the verb resolved to nothing, and
    // the card fell back to guessing a command name out of a hardcoded list.
    //
    // The panel narrows by the advertised service UUID before handing the
    // entities over — exactly the axis these generations differ on — so what
    // arrives here is one generation's controls.
    const ftmsSvc = '00001826-0000-1000-8000-00805f9b34fb';
    const ftmsChar = '00002ad9-0000-1000-8000-00805f9b34fb';

    EntityDto start(
      String commandName,
      String svc,
      String chr,
      String variant,
    ) => EntityDto(
      options: const [],
      name: 'Start',
      key: 'start',
      platform: 'button',
      canNotify: false,
      hasFormat: false,
      onWhenNonzero: false,
      actions: [
        EntityActionDto(
          role: 'press',
          serviceUuid: svc,
          characteristicUuid: chr,
          commandName: commandName,
          userParams: const [],
        ),
      ],
      variants: [variant],
    );

    final wilinkStart = start('wilink_start', _svc, _char, 'WiLink');
    final ftmsStart = start('ftms_start', ftmsSvc, ftmsChar, 'FTMS');

    CommandDto command(String name) => CommandDto(
      name: name,
      description: name,
      parameters: const [],
      isFixed: true,
      isEncodable: true,
      unsupportedEncoding: null,
      advanced: false,
    );

    final spec = DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
      deviceName: 'Two-Generation Pad',
      manufacturer: 'KingSmith',
      manufacturerStatus: 'active',
      protocol: 'ble',
      category: 'treadmill',
      localNamePrefixes: const [],
      localNames: const [],
      serviceUuids: const [_svc, ftmsSvc],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      // WiLink first, which is what made the old index pick it.
      entities: [wilinkStart, ftmsStart],
      services: [
        ServiceDto(
          uuid: _svc,
          name: 'wilink',
          characteristics: [
            CharacteristicDto(
              uuid: _char,
              name: 'WiLink write',
              canRead: false,
              canWrite: true,
              canNotify: false,
              formatFields: const [],
              commands: [command('wilink_start')],
            ),
          ],
        ),
        ServiceDto(
          uuid: ftmsSvc,
          name: 'ftms',
          characteristics: [
            CharacteristicDto(
              uuid: ftmsChar,
              name: 'Treadmill Control Point',
              canRead: false,
              canWrite: true,
              canNotify: false,
              formatFields: const [],
              commands: [command('ftms_start')],
            ),
          ],
        ),
      ],
    );

    // The device in front of us is an FTMS unit: only its service is
    // discovered, and the panel narrowed the entities to that generation.
    const services = [
      BleDiscoveredService(
        uuid: ftmsSvc,
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: ftmsChar,
            canRead: false,
            canWrite: true,
            canWriteWithoutResponse: true,
            canNotify: false,
          ),
        ],
      ),
    ];

    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x01]));
    await tester.pumpWidget(
      _wrap(
        ble: ble,
        codec: codec,
        spec: spec,
        services: services,
        entities: [ftmsStart],
      ),
    );

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Start'),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      codec.encodeCalls.single.commandName,
      'ftms_start',
      reason: 'the belt in front of us is the FTMS generation',
    );
  });

  testWidgets('the steppers never nudge from an invented baseline', (
    tester,
  ) async {
    // The card has no live speed reading. It used to open at the range
    // bottom and step from there, so on a belt already running at 5 km/h
    // 'Speed up' sent 0.5 km/h. Old code: the tap sent {'speed': 5.0}.
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
    await tester.pumpWidget(_wrap(ble: ble, codec: codec));

    IconButton stepper(String tip) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(tip == 'Speed up' ? Icons.add : Icons.remove),
        matching: find.byType(IconButton),
      ),
    );
    expect(stepper('Speed up').onPressed, isNull);
    expect(stepper('Slow down').onPressed, isNull);
    await tester.tap(find.byIcon(Icons.add), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(codec.encodeCalls, isEmpty);
    expect(ble.writes, isEmpty);

    // An absolute target from the slider is a real baseline.
    tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(4.0);
    await tester.pumpAndSettle();
    expect(stepper('Speed up').onPressed, isNotNull);
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(codec.encodeCalls.last.params, {'speed': 45.0});
  });

  group('the stepper baseline is only a speed the belt was sent', () {
    // Old code set the baseline before sending and never cleared it, so
    // after Stop/Start, a declined prompt or a failed write the headline
    // showed a speed the belt was not at and 'Speed up' sent old + 0.5 —
    // to a belt that a fresh Start may have at its minimum.
    IconButton stepper(WidgetTester tester, IconData icon) =>
        tester.widget<IconButton>(
          find.ancestor(
            of: find.byIcon(icon),
            matching: find.byType(IconButton),
          ),
        );

    Future<void> commit(WidgetTester tester, double v) async {
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(v);
      await tester.pumpAndSettle();
    }

    testWidgets('Stop drops it', (tester) async {
      final ble = FakeBleService();
      final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
      await tester.pumpWidget(_wrap(ble: ble, codec: codec));

      await commit(tester, 4.0);
      expect(find.text('4.0 km/h'), findsOneWidget);
      await tester.tap(find.text('Stop'));
      await tester.pumpAndSettle();

      // Old code: still '4.0 km/h' with both steppers live.
      expect(find.text('4.0 km/h'), findsNothing);
      expect(find.text('—'), findsOneWidget);
      expect(stepper(tester, Icons.add).onPressed, isNull);
      expect(stepper(tester, Icons.remove).onPressed, isNull);
    });

    testWidgets('a confirmed Start drops it', (tester) async {
      final ble = FakeBleService();
      final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
      await tester.pumpWidget(_wrap(ble: ble, codec: codec));

      await commit(tester, 4.0);
      await tester.tap(find.text('Start'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Start'),
        ),
      );
      await tester.pumpAndSettle();

      // Old code: 'Speed up' was live and sent {'speed': 45.0}.
      expect(stepper(tester, Icons.add).onPressed, isNull);
      expect(find.text('—'), findsOneWidget);
    });

    testWidgets('a declined advanced prompt does not set it', (tester) async {
      final ble = FakeBleService();
      final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
      await tester.pumpWidget(
        _wrap(
          ble: ble,
          codec: codec,
          spec: _treadmillSpecWith(advancedSpeed: true),
        ),
      );

      await commit(tester, 3.0);
      expect(find.text('Continue'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // Nothing was sent, so nothing is a baseline. Old code: headline
      // '3.0 km/h' and live steppers.
      expect(ble.writes, isEmpty);
      expect(find.text('3.0 km/h'), findsNothing);
      expect(find.text('—'), findsOneWidget);
      expect(stepper(tester, Icons.add).onPressed, isNull);
    });

    testWidgets('a failed BLE write drops it: the write may have landed', (
      tester,
    ) async {
      // A write-with-response timeout can still reach the pad. Old code
      // snapped the headline back to '3.0 km/h' over a belt that may be at
      // 5.0, and 'Speed up' then sent 35 — slowing the belt down.
      final ble = _FlakyWriteBle();
      final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xFD]));
      await tester.pumpWidget(_wrap(ble: ble, codec: codec));

      await commit(tester, 3.0);
      ble.failWrites = true;
      await commit(tester, 5.0);
      ble.failWrites = false;

      expect(find.text('3.0 km/h'), findsNothing);
      expect(find.text('5.0 km/h'), findsNothing);
      expect(find.text('—'), findsOneWidget);
      expect(stepper(tester, Icons.add).onPressed, isNull);
      expect(stepper(tester, Icons.remove).onPressed, isNull);

      // Only the slider's absolute value re-establishes a baseline.
      await commit(tester, 4.0);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(codec.encodeCalls.last.params, {'speed': 45.0});
    });

    testWidgets('an encode failure snaps back: nothing reached the pad', (
      tester,
    ) async {
      final ble = FakeBleService();
      final codec = _FlakyEncodeCodec(
        encoded: Uint8List.fromList([0xF7, 0xFD]),
      );
      await tester.pumpWidget(_wrap(ble: ble, codec: codec));

      await commit(tester, 3.0);
      codec.failEncodes = true;
      await commit(tester, 5.0);
      codec.failEncodes = false;

      // Headline '5.0 km/h' here would claim a speed never sent.
      expect(ble.writes, hasLength(1));
      expect(find.text('3.0 km/h'), findsOneWidget);
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();
      expect(codec.encodeCalls.last.params, {'speed': 35.0});
      expect(find.text('3.5 km/h'), findsOneWidget);
    });
  });

  testWidgets("the slider's screen-reader text uses the spec's unit and "
      'precision', (tester) async {
    // Old code announced 'Speed 3.0 km/h' whatever the spec declared.
    final spec = _spedSpec(const [
      CommandDto(
        name: 'set_speed',
        description: 'Set speed',
        isFixed: false,
        isEncodable: true,
        unsupportedEncoding: null,
        advanced: false,
        parameters: [
          ParameterDto(
            name: 'speed',
            valueType: 'uint16',
            min: 0,
            max: 800,
            scale: 0.01,
            unit: 'mph',
            userSettable: true,
          ),
        ],
      ),
    ]);
    await tester.pumpWidget(
      _wrap(ble: FakeBleService(), codec: FakeSpecCodec(), spec: spec),
    );
    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.semanticFormatterCallback!(3), 'Speed 3.00 mph');
  });

  testWidgets("an FTMS pad's slider stops at the entity's decoded 12 km/h, "
      'not the raw parameter bound', (tester) async {
    // kingsmith-walkingpad.yaml FTMS: set_target_speed.speed is uint16,
    // scale 0.01, max 2500 RAW (25 km/h); the 'Target Speed' entity clamps at
    // 12. The action DTO's min/max are RAW, so the old clamp compared 2500
    // against 25 km/h, kept 25, and let the card send raw 2500.
    const ftmsSvc = '00001826-0000-1000-8000-00805f9b34fb';
    const ftmsChar = '00002ad9-0000-1000-8000-00805f9b34fb';
    final spec = DeviceSpecDto(
      nameMatchers: const [],
      platformFallbackTypes: const [],
      txtMatchGroups: const [],
      hiddenEntityNames: const [],
      deviceName: 'FTMS Pad',
      manufacturer: 'KingSmith',
      manufacturerStatus: 'active',
      protocol: 'ble',
      category: 'treadmill',
      localNamePrefixes: const [],
      localNames: const [],
      serviceUuids: const [ftmsSvc],
      companyIds: Uint16List(0),
      macPrefixes: const [],
      mdnsServiceTypes: const [],
      ssdpSearchTargets: const [],
      lanProtocols: const [],
      defaultPort: null,
      entities: const [
        EntityDto(
          options: [],
          name: 'Target Speed',
          key: 'speed',
          platform: 'number',
          canNotify: false,
          hasFormat: false,
          onWhenNonzero: false,
          setpointMin: 0,
          setpointMax: 12,
          actions: [
            EntityActionDto(
              role: 'set_value',
              serviceUuid: ftmsSvc,
              characteristicUuid: ftmsChar,
              commandName: 'set_target_speed',
              userParams: ['speed'],
              min: 0,
              max: 2500,
            ),
          ],
          variants: [],
        ),
      ],
      services: const [
        ServiceDto(
          uuid: ftmsSvc,
          name: 'ftms',
          characteristics: [
            CharacteristicDto(
              uuid: ftmsChar,
              name: 'Treadmill Control Point',
              canRead: false,
              canWrite: true,
              canNotify: false,
              formatFields: [],
              commands: [
                CommandDto(
                  name: 'set_target_speed',
                  description: 'Set target speed',
                  isFixed: false,
                  isEncodable: true,
                  unsupportedEncoding: null,
                  advanced: false,
                  parameters: [
                    ParameterDto(
                      name: 'speed',
                      valueType: 'uint16',
                      min: 0,
                      max: 2500,
                      scale: 0.01,
                      unit: 'km/h',
                      userSettable: true,
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ],
    );
    const services = [
      BleDiscoveredService(
        uuid: ftmsSvc,
        characteristics: [
          BleDiscoveredCharacteristic(
            uuid: ftmsChar,
            canRead: false,
            canWrite: true,
            canNotify: false,
          ),
        ],
      ),
    ];
    final ble = FakeBleService();
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0x02]));
    await tester.pumpWidget(
      _wrap(ble: ble, codec: codec, spec: spec, services: services),
    );

    final slider = tester.widget<Slider>(find.byType(Slider));
    expect(slider.max, closeTo(12.0, 1e-9));

    // Speed up from the top stops at raw 1200, never above.
    slider.onChangeEnd!(12.0);
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();
    expect(
      codec.encodeCalls.map((c) => c.params['speed']),
      everyElement(lessThanOrEqualTo(1200.0)),
    );
    expect(codec.encodeCalls.last.params, {'speed': 1200.0});
  });

  // F-055: the sent-status line used a Colors.green literal, which fails
  // contrast on the light surface and ignores dark mode.
  testWidgets('the sent status uses the theme role, not a literal', (
    tester,
  ) async {
    final codec = FakeSpecCodec(encoded: Uint8List.fromList([0xF7, 0xA7]));
    await tester.pumpWidget(_wrap(ble: FakeBleService(), codec: codec));

    await tester.tap(find.text('Start'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Start'),
      ),
    );
    await tester.pumpAndSettle();

    final scheme = Theme.of(tester.element(find.byType(Scaffold))).colorScheme;
    final status = find.descendant(
      of: find.byType(TreadmillControlCard),
      matching: find.text('Sent Start belt'),
    );
    expect(tester.widget<Text>(status).style?.color, scheme.tertiary);
  });
}

/// A treadmill-category spec whose one write characteristic carries [commands]
/// — the shape most of these tests need with a different command set each.
DeviceSpecDto _spedSpec(List<CommandDto> commands) => DeviceSpecDto(
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'Treadmill',
  manufacturer: 'Acme Fitness',
  manufacturerStatus: 'active',
  protocol: 'ble',
  category: 'treadmill',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [_svc],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [],
  defaultPort: null,
  entities: const <EntityDto>[],
  services: [
    ServiceDto(
      uuid: _svc,
      name: 'Service',
      characteristics: [
        CharacteristicDto(
          uuid: _char,
          name: 'Command write',
          canRead: false,
          canWrite: true,
          canNotify: false,
          commands: commands,
          formatFields: const [],
        ),
      ],
    ),
  ],
);

/// A BLE fake whose writes fail while [failWrites] is set, for the path
/// where a speed write never reaches the pad.
class _FlakyWriteBle extends FakeBleService {
  bool failWrites = false;

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    if (failWrites) throw StateError('GATT write failed');
    return super.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
  }
}

/// A codec whose encodes fail while [failEncodes] is set, for the path where
/// a speed write fails before any byte reaches the BLE stack.
class _FlakyEncodeCodec extends FakeSpecCodec {
  _FlakyEncodeCodec({required super.encoded});

  bool failEncodes = false;

  @override
  Future<Uint8List> encodeCommand({
    String? specYaml,
    String? serviceUuid,
    required String charUuid,
    required String commandName,
    required Map<String, double> params,
  }) {
    if (failEncodes) {
      return Future.error(StateError('ParameterMissing: slope'));
    }
    return super.encodeCommand(
      specYaml: specYaml,
      serviceUuid: serviceUuid,
      charUuid: charUuid,
      commandName: commandName,
      params: params,
    );
  }
}

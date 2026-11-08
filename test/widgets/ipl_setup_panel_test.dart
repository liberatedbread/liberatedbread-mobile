// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/ipl_codec_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/widgets/ipl_setup_panel.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_ipl_codec.dart';
import '../fakes/fake_spec_codec.dart';
import '../helpers/ipl_fixture.dart';

const _security = '00000a10-0000-1000-8000-00805f9b34fb';
const _sw = '00002a28-0000-1000-8000-00805f9b34fb';
const _activation = '00000a20-0000-1000-8000-00805f9b34fb';
const _wakeup = '00000a30-0000-1000-8000-00805f9b34fb';
const _command = 'a0f03c00-5047-4d53-8208-4f72616c2d42';
const _read = 'a0f03c01-5047-4d53-8208-4f72616c2d42';
const _status = 'a0f03c03-5047-4d53-8208-4f72616c2d42';
const _push = 'a0f03c04-5047-4d53-8208-4f72616c2d42';

Widget _wrap({
  required String handler,
  required FakeBleService ble,
  required FakeSpecCodec specCodec,
  required FakeIplCodec iplCodec,
}) => ProviderScope(
  overrides: [
    bleServiceProvider.overrideWithValue(ble),
    specCodecProvider.overrideWithValue(specCodec),
    iplCodecProvider.overrideWithValue(iplCodec),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: IplSetupPanel(
          deviceId: 'AA:BB:CC:DD:EE:FF',
          specYaml: 'yaml',
          spec: iplSpec(handler),
          services: iplDiscovered(
            handler == 'ipl_foreo'
                ? const [_security, _sw, _activation, _wakeup]
                : const [_command, _read, _status, _push],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  testWidgets('FOREO activation happens only on tap and finishes visibly', (
    tester,
  ) async {
    final ble = FakeBleService(
      readValues: Map.of({
        _activation: [0],
        _wakeup: [0],
      }),
    );
    await tester.pumpWidget(
      _wrap(
        handler: 'ipl_foreo',
        ble: ble,
        specCodec: FakeSpecCodec(),
        iplCodec: FakeIplCodec(),
      ),
    );
    for (var index = 0; index < 6; index++) {
      await tester.pump();
    }
    expect(find.text('Activate device'), findsOneWidget);
    expect(ble.writes.map((write) => write.charUuid), [_security]);

    ble.readValues[_activation] = [1];
    ble.readValues[_wakeup] = [1];
    await tester.tap(find.text('Activate device'));
    for (var index = 0; index < 6; index++) {
      await tester.pump();
    }
    expect(find.text('Activated · wake-up enabled'), findsOneWidget);
    expect(ble.writes.map((write) => write.charUuid), [
      _security,
      _activation,
      _wakeup,
    ]);
  });

  testWidgets('patch test asks before sending anything, then acknowledges', (
    tester,
  ) async {
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final specCodec = FakeSpecCodec(
      decodedFor: (charUuid, _) {
        if (charUuid == _status) {
          return [
            decodedInt('opcode', 0xC3),
            decodedInt('cmd_id', 11),
            decodedInt('status', 0),
          ];
        }
        if (charUuid == _push) {
          return [decodedInt('command', 11), decodedInt('reason', 1)];
        }
        return [decodedInt('operation_state', 9)];
      },
    );
    await tester.pumpWidget(
      _wrap(
        handler: 'ipl_braun',
        ble: FakeBleService(notifyStream: notify.stream),
        specCodec: specCodec,
        iplCodec: FakeIplCodec(),
      ),
    );
    for (var index = 0; index < 4; index++) {
      await tester.pump();
    }
    await tester.tap(find.text('Start patch test'));
    await tester.pumpAndSettle();
    expect(find.text('Start a patch test?'), findsOneWidget);
    expect(specCodec.encodeCalls, isEmpty);

    await tester.tap(find.widgetWithText(FilledButton, 'Start patch test'));
    await tester.pump();
    notify.add([0xC3, 11, 0]);
    notify.add([0x00, 11, 0x10, 0x01]);
    for (var index = 0; index < 8; index++) {
      await tester.pump();
    }
    expect(specCodec.encodeCalls.map((call) => call.commandName), [
      'start_patch_test',
      'get_session_data',
    ]);
    expect(
      find.text(
        'Patch-test command acknowledged. Follow the device instructions for the observation period.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('Braun raw skin-tone result is not turned into a category', (
    tester,
  ) async {
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final specCodec = FakeSpecCodec(
      decodedFor: (charUuid, _) {
        if (charUuid == _status) {
          return [
            decodedInt('opcode', 0xC3),
            decodedInt('cmd_id', 5),
            decodedInt('status', 0),
          ];
        }
        if (charUuid == _push) {
          return [decodedInt('command', 5), decodedInt('reason', 1)];
        }
        return [
          decodedInt('operation_state', 7),
          decodedInt('skin_tone', 321),
          decodedInt('energy_level', 1),
        ];
      },
    );
    await tester.pumpWidget(
      _wrap(
        handler: 'ipl_braun',
        ble: FakeBleService(notifyStream: notify.stream),
        specCodec: specCodec,
        iplCodec: FakeIplCodec(),
      ),
    );
    for (var index = 0; index < 4; index++) {
      await tester.pump();
    }
    await tester.tap(find.text('Measure skin tone'));
    await tester.pump();
    notify.add([0xC3, 5, 0]);
    notify.add([0x00, 5, 0x10, 0x01]);
    for (var index = 0; index < 8; index++) {
      await tester.pump();
    }
    expect(find.text('Raw skin tone 321'), findsOneWidget);
    expect(find.textContaining('without a tone category'), findsOneWidget);
  });
}

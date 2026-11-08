// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/ipl_setup_session.dart';

import '../fakes/fake_ble_service.dart';
import '../fakes/fake_ipl_codec.dart';
import '../fakes/fake_spec_codec.dart';
import '../helpers/ipl_fixture.dart';

const _security = '00000a10-0000-1000-8000-00805f9b34fb';
const _sw = '00002a28-0000-1000-8000-00805f9b34fb';
const _activation = '00000a20-0000-1000-8000-00805f9b34fb';
const _wakeup = '00000a30-0000-1000-8000-00805f9b34fb';
const _lock = '12345678-9012-3456-7890-123456789033';
const _command = 'a0f03c00-5047-4d53-8208-4f72616c2d42';
const _read = 'a0f03c01-5047-4d53-8208-4f72616c2d42';
const _status = 'a0f03c03-5047-4d53-8208-4f72616c2d42';

IplSetupSession _session(
  String handler,
  FakeBleService ble,
  FakeSpecCodec specCodec,
  FakeIplCodec iplCodec,
) => IplSetupSession(
  ble: ble,
  specCodec: specCodec,
  iplCodec: iplCodec,
  deviceId: 'AA:BB:CC:DD:EE:FF',
  specYaml: 'yaml',
  spec: iplSpec(handler),
  discoveredServices: iplDiscovered(switch (handler) {
    'ipl_foreo' => [_security, _sw, _activation, _wakeup],
    'ipl_silkn' => [_lock],
    _ => [_command, _read, _status],
  }),
);

Future<void> _settle() async {
  for (var index = 0; index < 8; index++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test(
    'FOREO checks before activating, then verifies activation and wake-up',
    () async {
      final ble = FakeBleService(
        readValues: Map.of({
          _activation: [0],
          _wakeup: [0],
        }),
      );
      final specCodec = FakeSpecCodec();
      final session = _session('ipl_foreo', ble, specCodec, FakeIplCodec());
      addTearDown(session.dispose);
      session.start();
      await _settle();

      expect(session.state.phase, IplSetupPhase.needsAction);
      expect(session.state.locked, isTrue);
      expect(session.state.wakeupEnabled, isFalse);
      expect(ble.writes.map((write) => write.charUuid), [_security]);

      ble.readValues[_activation] = [1];
      ble.readValues[_wakeup] = [1];
      await session.activate();
      expect(session.state.phase, IplSetupPhase.ready);
      expect(session.state.locked, isFalse);
      expect(session.state.wakeupEnabled, isTrue);
      expect(ble.writes.map((write) => write.charUuid), [
        _security,
        _activation,
        _wakeup,
      ]);
      expect(specCodec.encodeCalls.single.commandName, 'set_wakeup');
    },
  );

  test('an already activated FOREO gets no activation write', () async {
    final ble = FakeBleService(
      readValues: const {
        _activation: [1],
        _wakeup: [1],
      },
    );
    final session = _session('ipl_foreo', ble, FakeSpecCodec(), FakeIplCodec());
    addTearDown(session.dispose);
    session.start();
    await _settle();
    expect(session.state.phase, IplSetupPhase.ready);
    expect(ble.writes.map((write) => write.charUuid), [_security]);
  });

  test('a CoreBluetooth UUID fails before any FOREO write', () async {
    final ble = FakeBleService();
    final session = IplSetupSession(
      ble: ble,
      specCodec: FakeSpecCodec(),
      iplCodec: FakeIplCodec(rejectAddress: true),
      deviceId: '123e4567-e89b-12d3-a456-426614174000',
      specYaml: 'yaml',
      spec: iplSpec('ipl_foreo'),
      discoveredServices: iplDiscovered(const [
        _security,
        _sw,
        _activation,
        _wakeup,
      ]),
    );
    addTearDown(session.dispose);
    session.start();
    await _settle();
    expect(session.state.phase, IplSetupPhase.error);
    expect(session.state.error, contains('six-byte BLE MAC'));
    expect(ble.writes, isEmpty);
  });

  test(
    'Silk’n unlocks only on request and verifies Released + Unlocked',
    () async {
      var lockState = 0x31;
      final specCodec = FakeSpecCodec(
        decodedFor: (_, _) => [
          decodedInt('mode', lockState == 0x31 ? 0x31 : 0x30),
          decodedInt('state', lockState),
        ],
      );
      final session = _session(
        'ipl_silkn',
        FakeBleService(),
        specCodec,
        FakeIplCodec(),
      );
      addTearDown(session.dispose);
      session.start();
      await _settle();
      expect(session.state.phase, IplSetupPhase.needsAction);
      expect(specCodec.encodeCalls, isEmpty);

      lockState = 0x30;
      await session.activate();
      expect(session.state.phase, IplSetupPhase.ready);
      expect(session.state.locked, isFalse);
      expect(specCodec.encodeCalls.single.commandName, 'release_and_unlock');
    },
  );

  test(
    'Braun waits for its acknowledgement and returns raw session data',
    () async {
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
          return [
            decodedInt('operation_state', 6),
            decodedInt('skin_tone', 321),
            decodedInt('energy_level', 1),
            decodedInt('mounted_head', 33),
            decodedInt('flashes_this_session', 4),
          ];
        },
      );
      final session = _session(
        'ipl_braun',
        FakeBleService(notifyStream: notify.stream),
        specCodec,
        FakeIplCodec(),
      );
      addTearDown(session.dispose);
      session.start();
      await _settle();
      expect(session.state.phase, IplSetupPhase.ready);

      unawaited(
        Future<void>.delayed(Duration.zero, () => notify.add([0xC3, 5, 0])),
      );
      await session.measureSkinTone();
      expect(session.state.phase, IplSetupPhase.ready);
      expect(session.state.skinTone, 321);
      expect(session.state.energyLevel, 1);
      expect(session.state.mountedHead, 33);
      expect(session.state.flashes, 4);
      expect(session.state.notice, contains('without a tone category'));
      expect(specCodec.encodeCalls.map((call) => call.commandName), [
        'measure_skin_tone',
        'get_session_data',
      ]);
    },
  );

  test('Braun patch-test command waits for its own acknowledgement', () async {
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
        return [decodedInt('operation_state', 9)];
      },
    );
    final session = _session(
      'ipl_braun',
      FakeBleService(notifyStream: notify.stream),
      specCodec,
      FakeIplCodec(),
    );
    addTearDown(session.dispose);
    session.start();
    await _settle();

    unawaited(
      Future<void>.delayed(Duration.zero, () => notify.add([0xC3, 11, 0])),
    );
    await session.startPatchTest();
    expect(session.state.phase, IplSetupPhase.ready);
    expect(session.state.notice, contains('observation period'));
    expect(specCodec.encodeCalls.map((call) => call.commandName), [
      'start_patch_test',
      'get_session_data',
    ]);
  });

  test('Braun BUSY is an error, not a fabricated result', () async {
    final notify = StreamController<List<int>>.broadcast();
    addTearDown(notify.close);
    final specCodec = FakeSpecCodec(
      decodedFor: (_, _) => [
        decodedInt('opcode', 0xC3),
        decodedInt('cmd_id', 5),
        decodedInt('status', 1),
      ],
    );
    final session = _session(
      'ipl_braun',
      FakeBleService(notifyStream: notify.stream),
      specCodec,
      FakeIplCodec(),
    );
    addTearDown(session.dispose);
    session.start();
    await _settle();

    unawaited(
      Future<void>.delayed(Duration.zero, () => notify.add([0xC3, 5, 1])),
    );
    await session.measureSkinTone();
    expect(session.state.phase, IplSetupPhase.error);
    expect(session.state.error, contains('busy'));
    expect(session.state.skinTone, isNull);
    expect(specCodec.encodeCalls.map((call) => call.commandName), [
      'measure_skin_tone',
    ]);
  });
}

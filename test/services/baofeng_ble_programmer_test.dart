// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The real driver, the real BleService, an emulated radio.
//
// This plugs in at flutter_blue_plus's platform seam, so everything but the
// radio is the shipping code: the GATT calls, the notification reassembly,
// the framing, the substitution and the codeplug codec. It is the closest a
// test gets to programming a UV-5R Mini, and it runs under a plain
// `flutter test`.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/src/rust/api/radio_api.dart' as rust;

import '../fakes/emulated_ble.dart';
import '../fakes/emulated_radio.dart';
import '../helpers/host_rust_lib.dart';

const _deviceId = 'AA:BB:CC:DD:EE:99';

void main() {
  late EmulatedBleAdapter ble;
  late RealBleService service;
  late BaofengBleProgrammer programmer;
  late bool rustReady;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    ble = EmulatedBleAdapter.install();
    rustReady = await initHostRustLib();
  });

  setUp(() async {
    await ble.reset();
    service = RealBleService();
    programmer = BaofengBleProgrammer(service);
  });

  Future<EmulatedRadio> radio({Uint8List? image}) async {
    final emulated = await EmulatedRadio.create(id: _deviceId, image: image);
    ble.add(emulated.peripheral);
    return emulated;
  }

  Future<RadioCodeplug> read(RadioProfile profile) async {
    RadioCodeplug? result;
    await programmer
        .readCodeplug(
          deviceId: _deviceId,
          profile: profile,
          onResult: (codeplug) => result = codeplug,
        )
        .drain<void>();
    return result!;
  }

  test('supports the Bluetooth family and nothing else', () {
    expect(programmer.supports(uv5rMiniProfile), isTrue);
    expect(programmer.supports(uv5gMiniProfile), isTrue);
    // A radio whose family has no transport in this build.
    expect(programmer.supports(uv5rProfile), isFalse);
    expect(programmer.supports(uv17rPlusProfile), isFalse);
  });

  test('refuses a radio it cannot drive rather than trying', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    await radio();
    await expectLater(
      programmer
          .readCodeplug(
            deviceId: _deviceId,
            profile: uv5rProfile,
            onResult: (_) {},
          )
          .drain<void>(),
      throwsA(isA<RadioUnsupportedException>()),
    );
  });

  test('reads a whole codeplug back byte for byte', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final emulated = await radio();

    final codeplug = await read(uv5rMiniProfile);

    expect(codeplug.length, 0x8240);
    expect(codeplug.image, emulated.image,
        reason: 'the image read back must be the one the radio holds');
    expect(codeplug.modelId, 'uv-5r-mini');
  });

  test('the conversation runs in the documented order', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final emulated = await radio();
    await read(uv5rMiniProfile);

    // Ident magic, three handshake steps, then reads.
    expect(emulated.commands.first, hasLength(16));
    expect(emulated.commands[1], [0x46]);
    expect(emulated.commands[2], [0x4D]);
    expect(emulated.commands[3].length, 25);
    expect(emulated.commands[4][0], 0x52);
  });

  test('reassembles replies that arrive in pieces', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    // A 0x44-byte reply at the BLE minimum MTU arrives in three
    // notifications. This is the case the inbox exists for, and the smaller
    // the chunk the more of them there are.
    for (final chunk in [20, 7, 1, 200]) {
      await ble.reset();
      service = RealBleService();
      programmer = BaofengBleProgrammer(service);
      final emulated = await radio();
      emulated.notificationChunk = chunk;

      final codeplug = await read(uv5rMiniProfile);
      expect(codeplug.image, emulated.image, reason: 'chunk size $chunk');
    }
  });

  test('reports progress from zero to one', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    await radio();

    final events = await programmer
        .readCodeplug(
          deviceId: _deviceId,
          profile: uv5rMiniProfile,
          onResult: (_) {},
        )
        .toList();

    expect(events.first.stage, RadioProgressStage.connecting);
    expect(events.last.stage, RadioProgressStage.done);
    expect(events.last.progress, 1);
    final reading =
        events.where((e) => e.stage == RadioProgressStage.reading).toList();
    expect(reading, isNotEmpty);
    // Monotonic, which is what stops a progress bar going backwards.
    for (var i = 1; i < reading.length; i++) {
      expect(
          reading[i].progress, greaterThanOrEqualTo(reading[i - 1].progress!));
    }
  });

  test('disconnects when the session ends', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final emulated = await radio();
    await read(uv5rMiniProfile);
    expect(emulated.peripheral.isConnected, isFalse,
        reason: 'a radio left connected blocks the next thing that wants it');
  });

  test('disconnects when a read fails part way through', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final emulated = await radio();
    emulated.goSilentAt = 0x1000;

    await expectLater(
      programmer
          .readCodeplug(
            deviceId: _deviceId,
            profile: uv5rMiniProfile,
            onResult: (_) {},
          )
          .drain<void>(),
      throwsA(isA<RadioTimeoutException>()),
    );
    expect(emulated.peripheral.isConnected, isFalse);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('a radio that refuses the ident is reported clearly', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    // A peripheral with the right service that answers nothing: the shape of
    // a radio that is on but not in programming mode.
    ble.add(EmulatedPeripheral(
      id: _deviceId,
      name: 'Silent',
      mtu: 23,
      services: [
        EmulatedService(
          uuid: baofengUartService,
          characteristics: [
            EmulatedCharacteristic(
              uuid: baofengUartCharacteristic,
              canWriteWithoutResponse: true,
              canNotify: true,
            ),
          ],
        ),
      ],
    ));

    await expectLater(
      programmer
          .readCodeplug(
            deviceId: _deviceId,
            profile: uv5rMiniProfile,
            onResult: (_) {},
          )
          .drain<void>(),
      throwsA(isA<RadioTimeoutException>()),
    );
  }, timeout: const Timeout(Duration(seconds: 60)));

  group('writing', () {
    test('writes every block and the radio ends up holding the plan', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final emulated = await radio();
      final base = await read(uv5rMiniProfile);

      await programmer.writeChannels(
        deviceId: _deviceId,
        profile: uv5rMiniProfile,
        base: base,
        channels: const [
          RadioChannel(
            name: 'W1AW',
            rxFreqHz: 146940000,
            txFreqHz: 146340000,
            txTone: ToneSetting.ctcss(1000),
          ),
          RadioChannel.receiveOnly(name: 'WX1', freqHz: 162550000),
        ],
      ).drain<void>();

      // Reassemble what the radio received and decode it: the round trip that
      // matters is plan in, channels out.
      final plan = await rust.radioWritePlan(
        modelId: 'uv-5r-mini',
        blockSize: await rust.radioBleWriteBlockSize(),
      );
      final rebuilt = <int>[];
      for (final block in plan) {
        rebuilt
            .addAll(await emulated.plaintextWrittenAt(block.addr, block.len));
      }

      final channels = await rust.radioDecodeChannels(
        image: rebuilt,
        modelId: 'uv-5r-mini',
      );
      expect(channels, hasLength(2));
      expect(channels[0].name, 'W1AW');
      expect(channels[0].rxFreqHz, 146940000);
      expect(channels[0].txTone.ctcssTenthHz, 1000);
      expect(channels[1].name, 'WX1');
      expect(channels[1].rxOnly, isTrue);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('uses the larger block size the tunnel expects', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final emulated = await radio();
      final base = await read(uv5rMiniProfile);
      emulated.commands.clear();

      await programmer.writeChannels(
        deviceId: _deviceId,
        profile: uv5rMiniProfile,
        base: base,
        channels: const [],
      ).drain<void>();

      final writeCommands =
          emulated.commands.where((c) => c.isNotEmpty && c[0] == 0x57);
      expect(writeCommands, isNotEmpty);
      // 0x80 over Bluetooth, not the 0x40 a cable uses.
      expect(writeCommands.first[3], 0x80);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a refused block stops the write and says what happened', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final emulated = await radio();
      final base = await read(uv5rMiniProfile);
      emulated.failWriteAt = 0x0080;

      await expectLater(
        programmer.writeChannels(
          deviceId: _deviceId,
          profile: uv5rMiniProfile,
          base: base,
          channels: const [],
        ).drain<void>(),
        throwsA(
          isA<RadioProtocolException>().having(
            (e) => e.message,
            'message',
            contains('restore your backup'),
          ),
        ),
      );
      expect(emulated.peripheral.isConnected, isFalse);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('an image of the wrong size is refused before anything is sent',
        () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final emulated = await radio();
      emulated.commands.clear();

      await expectLater(
        programmer
            .restoreCodeplug(
              deviceId: _deviceId,
              profile: uv5rMiniProfile,
              codeplug: RadioCodeplug(
                modelId: 'uv-5r-mini',
                image: Uint8List(0x100),
                readAt: DateTime.now(),
              ),
            )
            .drain<void>(),
        throwsA(isA<RadioProtocolException>()),
      );
      expect(emulated.commands, isEmpty,
          reason: 'nothing should reach a radio before the size is checked');
    });

    test('restore puts back exactly what was backed up', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final emulated = await radio();
      final backup = await read(uv5rMiniProfile);

      await programmer
          .restoreCodeplug(
            deviceId: _deviceId,
            profile: uv5rMiniProfile,
            codeplug: backup,
          )
          .drain<void>();

      final plan = await rust.radioWritePlan(
        modelId: 'uv-5r-mini',
        blockSize: await rust.radioBleWriteBlockSize(),
      );
      final rebuilt = <int>[];
      for (final block in plan) {
        rebuilt
            .addAll(await emulated.plaintextWrittenAt(block.addr, block.len));
      }
      expect(rebuilt, backup.image);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });
}

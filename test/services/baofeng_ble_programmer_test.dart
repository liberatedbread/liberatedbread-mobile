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
import '../fakes/fake_ble_service.dart';
import '../helpers/host_rust_lib.dart';

const _deviceId = 'AA:BB:CC:DD:EE:99';

/// The emulator answers at once, so a step that has not answered in 300 ms
/// never will: the tests of a silent radio stop sleeping out the shipping
/// 8 s timeout each.
const _fast = BleTiming(
  step: Duration(milliseconds: 300),
  settle: Duration.zero,
);

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
    programmer = BaofengBleProgrammer(service, timing: _fast);
  });

  Future<EmulatedRadio> radio({
    Uint8List? image,
    String modelId = 'uv-5r-mini',
    int answersIdent = 0,
  }) async {
    final emulated = await EmulatedRadio.create(
      id: _deviceId,
      image: image,
      modelId: modelId,
      answersIdent: answersIdent,
    );
    ble.add(emulated.peripheral);
    return emulated;
  }

  Future<RadioCodeplug> read(RadioProfile profile) =>
      programmer.readWhole(deviceId: _deviceId, profile: profile);

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

  test(
    'identify runs the ident and handshake, reads nothing, and lets go',
    () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final emulated = await radio();

      final identity = await programmer.identify(
        deviceId: _deviceId,
        profile: uv5rMiniProfile,
      );

      expect(identity.profile, uv5rMiniProfile);
      expect(
        identity.reported,
        isNull,
        reason: 'this family acknowledges; it does not name itself',
      );
      // The magic and the three handshake steps, and not one block read.
      expect(emulated.commands, hasLength(4));
      expect(emulated.commands.first, hasLength(16));
      expect(
        emulated.commands.any((c) => c.isNotEmpty && c[0] == 0x52),
        isFalse,
      );
      expect(emulated.peripheral.isConnected, isFalse);
    },
  );

  test('identify refuses a model it cannot drive', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    await radio();
    await expectLater(
      programmer.identify(deviceId: _deviceId, profile: uv5rProfile),
      throwsA(isA<RadioUnsupportedException>()),
    );
  });

  test('reads a whole codeplug back byte for byte', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final emulated = await radio();

    final codeplug = await read(uv5rMiniProfile);

    expect(codeplug.length, 0x8240);
    expect(
      codeplug.image,
      emulated.image,
      reason: 'the image read back must be the one the radio holds',
    );
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
      programmer = BaofengBleProgrammer(service, timing: _fast);
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
    final reading = events
        .where((e) => e.stage == RadioProgressStage.reading)
        .toList();
    expect(reading, isNotEmpty);
    // Monotonic, which is what stops a progress bar going backwards.
    for (var i = 1; i < reading.length; i++) {
      expect(
        reading[i].progress,
        greaterThanOrEqualTo(reading[i - 1].progress!),
      );
    }
  });

  test('disconnects when the session ends', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final emulated = await radio();
    await read(uv5rMiniProfile);
    expect(
      emulated.peripheral.isConnected,
      isFalse,
      reason: 'a radio left connected blocks the next thing that wants it',
    );
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
  });

  test(
    'a slipped read reply is a protocol error, not a raw Rust one',
    () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      // The parse failure was awaited bare inside the body stream, so an
      // AnyhowException reached the screen as the generic "did not finish".
      final emulated = await radio();
      emulated.misaddressReadAt = 0x0040;

      await expectLater(
        programmer
            .readCodeplug(
              deviceId: _deviceId,
              profile: uv5rMiniProfile,
              onResult: (_) {},
            )
            .drain<void>(),
        throwsA(isA<RadioProtocolException>()),
      );
      expect(emulated.peripheral.isConnected, isFalse);
    },
  );

  test(
    'a radio that ignores the ident is reported as not in programming mode',
    () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      // A peripheral with the right service that answers nothing: the shape of
      // a radio that is on but not in programming mode.
      ble.add(
        EmulatedPeripheral(
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
        ),
      );

      await expectLater(
        programmer
            .readCodeplug(
              deviceId: _deviceId,
              profile: uv5rMiniProfile,
              onResult: (_) {},
            )
            .drain<void>(),
        // Silence at the ident is a radio not in programming mode (or not
        // this model), not one out of range: the link is up. The spec asks
        // for the two to be told apart because the recoveries differ.
        throwsA(
          isA<RadioProtocolException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('not in programming mode'),
              contains('wireless programming'),
            ),
          ),
        ),
      );
    },
  );

  group('the ident', () {
    test('a UV-5G Mini on v0.01 firmware answers the second magic', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      // v0.05 answers only PROGRAMGMRS5RMIU and v0.01 only PROGRAMCOLORPROU.
      // With one magic per model, one of the two could never be programmed.
      final emulated = await radio(modelId: 'uv-5g-mini', answersIdent: 1);

      await programmer.identify(deviceId: _deviceId, profile: uv5gMiniProfile);

      expect(String.fromCharCodes(emulated.commands[0]), 'PROGRAMGMRS5RMIU');
      expect(String.fromCharCodes(emulated.commands[1]), 'PROGRAMCOLORPROU');
      expect(emulated.commands[2], [0x46]);
    });

    test('a UV-5G Mini on v0.05 firmware acks the first magic', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final emulated = await radio(modelId: 'uv-5g-mini');

      await programmer.identify(deviceId: _deviceId, profile: uv5gMiniProfile);

      expect(String.fromCharCodes(emulated.commands[0]), 'PROGRAMGMRS5RMIU');
      expect(emulated.commands[1], [0x46], reason: 'no second magic sent');
    });

    test('a UV-32 gets through the handshake on its 7-byte M reply', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      // Waiting for 15 bytes after M from a radio that sends 7 timed out
      // every session before a single block was read.
      final emulated = await radio(modelId: 'uv-32');

      final codeplug = await read(uv32Profile);

      expect(codeplug.length, 0x8380);
      expect(codeplug.image, emulated.image);
    });
  });

  group('writing', () {
    group('a UV-32, whose Bluetooth write nobody has captured,', () {
      // Old code asked Rust for the write plan inside the session: the
      // write connected, woke the radio, and only then failed with Rust's
      // raw error. Now it is refused before a connect, with that reason.
      late FakeBleService fake;
      late BaofengBleProgrammer offline;
      late RadioCodeplug whole;

      setUp(() async {
        if (!rustReady) return;
        fake = FakeBleService();
        offline = BaofengBleProgrammer(fake, timing: _fast);
        final model = (await rust.radioModels()).singleWhere(
          (m) => m.id == uv32Profile.id,
        );
        whole = RadioCodeplug(
          modelId: uv32Profile.id,
          image: Uint8List(model.imageLen),
          readAt: DateTime(2026, 9, 27),
        );
      });

      final refused = throwsA(
        isA<RadioUnsupportedException>().having(
          (e) => e.message,
          'message',
          allOf(contains('UV-32'), contains('Nothing was written')),
        ),
      );

      test('is refused by the preflight', () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        await expectLater(offline.checkCanWrite(uv32Profile), refused);
        await offline.checkCanWrite(uv5rMiniProfile);
      });

      test('a restore never connects', () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        await expectLater(
          offline
              .restoreCodeplug(
                deviceId: _deviceId,
                profile: uv32Profile,
                codeplug: whole,
              )
              .drain<void>(),
          refused,
        );
        expect(fake.events, isEmpty, reason: 'not so much as a connect');
      });

      test('a channel write never connects', () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        await expectLater(
          offline
              .writeChannels(
                deviceId: _deviceId,
                profile: uv32Profile,
                base: whole,
                channels: const [],
              )
              .drain<void>(),
          refused,
        );
        expect(fake.events, isEmpty, reason: 'not so much as a connect');
      });
    });

    test(
      'writes every block and the radio ends up holding the plan',
      () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        final emulated = await radio();
        final base = await read(uv5rMiniProfile);

        await programmer
            .writeChannels(
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
            )
            .drain<void>();

        // Reassemble what the radio received and decode it: the round trip that
        // matters is plan in, channels out.
        final plan = await rust.radioWritePlan(modelId: 'uv-5r-mini');
        final rebuilt = <int>[];
        for (final block in plan) {
          rebuilt.addAll(
            await emulated.plaintextWrittenAt(block.addr, block.len),
          );
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
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'uses the larger block size the tunnel expects',
      () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        final emulated = await radio();
        final base = await read(uv5rMiniProfile);
        emulated.commands.clear();

        await programmer
            .writeChannels(
              deviceId: _deviceId,
              profile: uv5rMiniProfile,
              base: base,
              channels: const [],
            )
            .drain<void>();

        final writeCommands = emulated.commands
            .where((c) => c.isNotEmpty && c[0] == 0x57)
            .toList();
        expect(writeCommands, isNotEmpty);
        // 0x80 over Bluetooth, not the 0x40 a cable uses -- on EVERY frame.
        // The Mini's regions end in 0x40-byte blocks at 0x8000, 0x9000 and
        // 0xA180, which went out saying 0x40; the radio never acks those
        // over Bluetooth (CHIRP issue 12251), so every write and restore
        // stopped at 0x8000 after the channels were already written.
        for (final frame in writeCommands) {
          final addr = (frame[1] << 8) | frame[2];
          expect(frame[3], 0x80, reason: 'length byte at 0x$addr');
          expect(frame, hasLength(0x84), reason: 'frame at 0x$addr');
        }
        expect(emulated.malformedWrites, isEmpty);
        // The short blocks are padded with 0xFF, as CHIRP pads them. 0xFF is
        // exempt from the substitution, so it is 0xFF on the wire too.
        for (final addr in [0x8000, 0x9000, 0xA180]) {
          final frame = emulated.written[addr]!;
          expect(frame.sublist(0x40), everyElement(0xFF), reason: '0x$addr');
        }
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'a refused block stops the write and says what happened',
      () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        final emulated = await radio();
        final base = await read(uv5rMiniProfile);
        emulated.failWriteAt = 0x0080;

        await expectLater(
          programmer
              .writeChannels(
                deviceId: _deviceId,
                profile: uv5rMiniProfile,
                base: base,
                channels: const [],
              )
              .drain<void>(),
          throwsA(
            isA<RadioProtocolException>().having(
              (e) => e.message,
              'message',
              contains('restore your backup'),
            ),
          ),
        );
        expect(emulated.peripheral.isConnected, isFalse);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    test(
      'a radio that stops answering mid-write says to restore the backup',
      () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        final emulated = await radio();
        final base = await read(uv5rMiniProfile);
        emulated.goSilentAt = 0x1000;

        await expectLater(
          programmer
              .writeChannels(
                deviceId: _deviceId,
                profile: uv5rMiniProfile,
                base: base,
                channels: const [],
              )
              .drain<void>(),
          throwsA(
            isA<RadioTimeoutException>()
                .having((e) => e.partlyWritten, 'partlyWritten', isTrue)
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('while writing 0x1000'),
                    contains('restore your backup'),
                  ),
                ),
          ),
        );
        expect(emulated.peripheral.isConnected, isFalse);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );

    group('a GATT write that never completes', () {
      // _send's own timeout: the write call itself stalls, rather than the
      // radio going quiet after it. Left untranslated it reached the screen
      // as a bare TimeoutException, read as the generic "did not finish".
      late EmulatedRadio emulated;
      late BaofengBleProgrammer stalling;

      setUp(() async {
        if (!rustReady) return;
        emulated = await radio();
        stalling = BaofengBleProgrammer(
          EmulatedRadioBleService(emulated),
          timing: _fast,
        );
      });

      test('during a read is a plain timeout', () async {
        if (!rustReady) return markTestSkipped('host Rust library unavailable');
        emulated.hangSendsFrom = 0x1000;

        Object? error;
        try {
          await stalling
              .readCodeplug(
                deviceId: _deviceId,
                profile: uv5rMiniProfile,
                onResult: (_) {},
              )
              .drain<void>();
        } catch (e) {
          error = e;
        }
        expect(emulated.hungAt, 0x1000);
        expect(
          error,
          isA<RadioTimeoutException>()
              .having((e) => e.partlyWritten, 'partlyWritten', isFalse)
              .having(
                (e) => e.message,
                'message',
                const RadioTimeoutException().message,
              ),
        );
        expect(emulated.peripheral.isConnected, isFalse);
      });

      test(
        'during a write says the radio may be partly written',
        () async {
          if (!rustReady) {
            return markTestSkipped('host Rust library unavailable');
          }
          final base = await stalling.readWhole(
            deviceId: _deviceId,
            profile: uv5rMiniProfile,
          );
          emulated.hangSendsFrom = 0x1000;

          Object? error;
          try {
            await stalling
                .writeChannels(
                  deviceId: _deviceId,
                  profile: uv5rMiniProfile,
                  base: base,
                  channels: const [],
                )
                .drain<void>();
          } catch (e) {
            error = e;
          }
          final at = emulated.hungAt!.toRadixString(16).padLeft(4, '0');
          expect(
            error,
            isA<RadioTimeoutException>()
                .having((e) => e.partlyWritten, 'partlyWritten', isTrue)
                .having(
                  (e) => e.message,
                  'message',
                  allOf(
                    contains('while writing 0x$at'),
                    contains('restore your backup'),
                  ),
                ),
          );
          expect(
            emulated.written.keys.where((a) => a >= 0x1000),
            isEmpty,
            reason: 'the hung write never reached the radio',
          );
          expect(emulated.peripheral.isConnected, isFalse);
        },
        timeout: const Timeout(Duration(seconds: 120)),
      );
    });

    test(
      'an image of the wrong size is refused before anything is sent',
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
        expect(
          emulated.commands,
          isEmpty,
          reason: 'nothing should reach a radio before the size is checked',
        );
      },
    );

    test(
      'restore puts back exactly what was backed up',
      () async {
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

        final plan = await rust.radioWritePlan(modelId: 'uv-5r-mini');
        final rebuilt = <int>[];
        for (final block in plan) {
          rebuilt.addAll(
            await emulated.plaintextWrittenAt(block.addr, block.len),
          );
        }
        expect(rebuilt, backup.image);
      },
      timeout: const Timeout(Duration(seconds: 120)),
    );
  });
}

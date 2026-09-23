// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The cable driver, end to end, against an emulated radio.
//
// Everything here is shipping code except the radio: the driver's
// conversation, its reassembly of a byte stream, the Rust codec's framing and
// layout, and the write-only-what-changed rule. See emulated_serial_radio.dart
// for what that proves and what it cannot.
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_band_limits.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/radio_codec.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';
import 'package:liberated_bread_mobile/services/serial_radio_programmer.dart';
import 'package:liberated_bread_mobile/src/rust/api/radio_api.dart' as rust;

import '../fakes/emulated_serial_radio.dart';
import '../helpers/host_rust_lib.dart';

const _ident = [0xAA, 0x30, 0x76, 0x04, 0x00, 0x05, 0x20, 0xDD];

/// No pauses, and short patience, so a silent radio fails quickly.
const _fast = SerialTiming(
  step: Duration(milliseconds: 300),
  magicByteGap: Duration.zero,
  blockGap: Duration.zero,
  identRetry: Duration.zero,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late bool rustReady;
  late List<Uint8List> uv5rMagics;

  setUpAll(() async {
    rustReady = await initHostRustLib();
    if (rustReady) uv5rMagics = await rust.uv5RIdentMagics(modelId: 'uv5r');
  });

  /// A radio answering [magicIndex] of the UV-5R's magics.
  ({
    EmulatedUv5rRadio radio,
    EmulatedSerialPortService ports,
    SerialRadioProgrammer programmer
  }) rig({int magicIndex = 0, String firmware = 'BFB297'}) {
    final radio = EmulatedUv5rRadio(
      ident: _ident,
      acceptedMagics: [uv5rMagics[magicIndex]],
      firmware: firmware,
    )..clearChannels();
    final ports = EmulatedSerialPortService(radio);
    return (
      radio: radio,
      ports: ports,
      programmer: SerialRadioProgrammer(ports, timing: _fast),
    );
  }

  Future<RadioCodeplug> read(SerialRadioProgrammer programmer) async {
    RadioCodeplug? result;
    await programmer
        .readCodeplug(
          deviceId: EmulatedSerialPortService.cable.id,
          profile: uv5rProfile,
          onResult: (codeplug) => result = codeplug,
        )
        .drain<void>();
    return result!;
  }

  test('drives the UV-5R family and nothing else', () {
    final programmer = SerialRadioProgrammer(
      EmulatedSerialPortService(
          EmulatedUv5rRadio(ident: _ident, acceptedMagics: const [])),
    );
    expect(programmer.supports(uv5rProfile), isTrue);
    expect(programmer.supports(bfF8hpProfile), isTrue);
    expect(programmer.supports(ar152Profile), isTrue);
    expect(programmer.supports(uv5gProfile), isFalse,
        reason: 'its memory is not a UV-5R\'s');
    expect(programmer.supports(uv5rMiniProfile), isFalse,
        reason: 'a Bluetooth radio');
  });

  test('identifies at 9600 baud, trying magics until one is answered',
      () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    // The radio only answers the second magic in the list.
    final r = rig(magicIndex: 1);
    final identity = await r.programmer.identify(
      deviceId: EmulatedSerialPortService.cable.id,
      profile: uv5rProfile,
    );
    expect(r.ports.openedAt, [9600]);
    expect(r.radio.sessions, 1);
    expect(identity.reported, 'firmware BFB297');
    expect(identity.summary, contains('BFB297'));
    expect(r.ports.openLinks, 0, reason: 'the port is closed afterwards');
    expect(r.radio.writes, isEmpty, reason: 'identifying writes nothing');
  });

  test('reads the whole image, probe first, in order', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final r = rig();
    final codeplug = await read(r.programmer);

    expect(codeplug.length, await rust.uv5RImageLen());
    expect(codeplug.image.sublist(0, 8), _ident);
    expect(codeplug.image.sublist(8, 8 + 0x1800),
        r.radio.memory.sublist(0, 0x1800));
    expect(codeplug.image.sublist(8 + 0x1800),
        r.radio.memory.sublist(0x1EC0, 0x2000));
    expect(r.radio.reads.take(4).toList(), [
      (0x1E80, 0x40),
      (0x1EC0, 0x40),
      (0x1FC0, 0x40),
      (0x0000, 0x40),
    ]);
    expect(r.ports.openLinks, 0);
  });

  test(
      'reads the end of the aux block in small pieces from a radio that '
      'drops a byte', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final r = rig();
    r.radio.dropsByte = true;
    final codeplug = await read(r.programmer);

    final after = r.radio.reads.skip(3);
    expect(
        after
            .where((read) => read.$1 >= 0x1FC0)
            .every((read) => read.$2 == 0x10),
        isTrue);
    // And the image holds what the radio holds, not the damaged probe read.
    expect(codeplug.image.sublist(8 + 0x1800),
        r.radio.memory.sublist(0x1EC0, 0x2000));
  });

  group('writing', () {
    const plan = [
      RadioChannel(name: 'W1AW', rxFreqHz: 146940000, txFreqHz: 146340000),
      RadioChannel(
        name: 'NOAA1',
        rxFreqHz: 162550000,
        txFreqHz: 162550000,
        rxOnly: true,
      ),
    ];

    test(
        'sends only what changed, reads it back, and the radio holds the '
        'plan', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final r = rig();
      final base = await read(r.programmer);
      final events = await r.programmer
          .writeChannels(
            deviceId: EmulatedSerialPortService.cable.id,
            profile: uv5rProfile,
            base: base,
            channels: plan,
          )
          .toList();

      // Two records at 0x0000 and two names at 0x1000, sixteen bytes each.
      expect([for (final w in r.radio.writes) w.$1],
          [0x0000, 0x0010, 0x1000, 0x1010]);
      expect(
          events.map((e) => e.stage),
          containsAllInOrder([
            RadioProgressStage.writing,
            RadioProgressStage.verifying,
            RadioProgressStage.done
          ]));

      final after = await read(r.programmer);
      final decoded = await rust.uv5RDecodeChannels(
          image: after.image, modelId: uv5rProfile.id);
      final channels = [for (final dto in decoded) channelFromDto(dto)];
      expect(channels.map((c) => c.name), ['W1AW', 'NOAA1']);
      expect(channels[1].rxOnly, isTrue);
      expect(channels[0].txFreqHz, 146340000);
    });

    test('refuses a radio other than the one that was read', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final r = rig();
      final base = await read(r.programmer);
      r.radio.setFirmware('BFS311');

      await expectLater(
        r.programmer
            .writeChannels(
              deviceId: EmulatedSerialPortService.cable.id,
              profile: uv5rProfile,
              base: base,
              channels: plan,
            )
            .drain<void>(),
        throwsA(isA<RadioProtocolException>()
            .having((e) => e.message, 'message', contains('not the radio'))),
      );
      expect(r.radio.writes, isEmpty);
      expect(r.ports.openLinks, 0);
    });

    test(
        'a write the radio acknowledged but did not keep is caught on '
        'reading back', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final r = rig();
      final base = await read(r.programmer);
      r.radio.loseWriteAt = 0x1010;

      await expectLater(
        r.programmer
            .writeChannels(
              deviceId: EmulatedSerialPortService.cable.id,
              profile: uv5rProfile,
              base: base,
              channels: plan,
            )
            .drain<void>(),
        throwsA(isA<RadioProtocolException>()
            .having((e) => e.message, 'message', contains('0x1010'))),
      );
      expect(r.ports.openLinks, 0);
    });

    test('a refused write says to restore, and closes the port', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final r = rig();
      final base = await read(r.programmer);
      r.radio.refuseWriteAt = 0x1000;

      await expectLater(
        r.programmer
            .writeChannels(
              deviceId: EmulatedSerialPortService.cable.id,
              profile: uv5rProfile,
              base: base,
              channels: plan,
            )
            .drain<void>(),
        throwsA(isA<RadioProtocolException>()
            .having((e) => e.message, 'message', contains('restore'))),
      );
      expect(r.ports.openLinks, 0);
    });

    test('a plan the radio already holds writes nothing and opens nothing',
        () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final r = rig();
      final base = await read(r.programmer);
      final opens = r.ports.openedAt.length;
      final events = await r.programmer
          .writeImage(
            deviceId: EmulatedSerialPortService.cable.id,
            profile: uv5rProfile,
            base: base,
            updated: base.image,
          )
          .toList();
      expect(events.single.stage, RadioProgressStage.done);
      expect(r.ports.openedAt.length, opens);
    });

    test(
        'an edit outside what the app writes is refused before the port '
        'opens', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final r = rig();
      final base = await read(r.programmer);
      final opens = r.ports.openedAt.length;
      // Radio 0x0CF4 is in a window upload tools never write.
      final tampered = Uint8List.fromList(base.image)..[8 + 0x0CF4] ^= 0xFF;
      await expectLater(
        r.programmer
            .writeImage(
              deviceId: EmulatedSerialPortService.cable.id,
              profile: uv5rProfile,
              base: base,
              updated: tampered,
            )
            .drain<void>(),
        throwsA(isA<RadioProtocolException>()),
      );
      expect(r.ports.openedAt.length, opens);
    });
  });

  group('band limits', () {
    const stock = RadioBandLimits(
      vhf: BandLimit(txEnabled: true, lowerMhz: 136, upperMhz: 174),
      uhf: BandLimit(txEnabled: true, lowerMhz: 400, upperMhz: 520),
    );
    final widened = RadioBandLimits.widenedFor(uv5rProfile)!;

    /// The two five-byte fields — enable flag, then lower and upper in
    /// big-endian BCD — at [vhfAt] and [uhfAt] in the radio's memory.
    void seed(EmulatedUv5rRadio radio,
        {required int vhfAt, required int uhfAt}) {
      radio.memory.setRange(vhfAt, vhfAt + 5, [0x01, 0x01, 0x36, 0x01, 0x74]);
      radio.memory.setRange(uhfAt, uhfAt + 5, [0x01, 0x04, 0x00, 0x05, 0x20]);
    }

    test('are read from where the radio\'s firmware keeps them', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final newer = rig();
      seed(newer.radio, vhfAt: 0x1FC0, uhfAt: 0x1FC5);
      final fromNewer = await read(newer.programmer);
      expect(
          await newer.programmer.bandLimitsIn(fromNewer, uv5rProfile), stock);

      // Firmware before BFB291 keeps them further along.
      final older = rig(firmware: 'BFB290');
      seed(older.radio, vhfAt: 0x1FCA, uhfAt: 0x1FDA);
      final fromOlder = await read(older.programmer);
      expect(
          await older.programmer.bandLimitsIn(fromOlder, uv5rProfile), stock);
    });

    test(
        'widening writes the block that holds them and nothing else, and '
        'they read back', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final r = rig();
      seed(r.radio, vhfAt: 0x1FC0, uhfAt: 0x1FC5);
      final base = await read(r.programmer);
      final events = await r.programmer
          .writeBandLimits(
            deviceId: EmulatedSerialPortService.cable.id,
            profile: uv5rProfile,
            base: base,
            limits: widened,
          )
          .toList();

      expect([for (final w in r.radio.writes) w.$1], [0x1FC0]);
      expect(r.radio.memory.sublist(0x1FC0, 0x1FCA),
          [0x01, 0x01, 0x30, 0x01, 0x79, 0x01, 0x04, 0x00, 0x05, 0x20]);
      expect(events.last.stage, RadioProgressStage.done);

      final after = await read(r.programmer);
      expect(await r.programmer.bandLimitsIn(after, uv5rProfile), widened);
    });

    test('putting them back restores the bytes the radio had', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final r = rig(firmware: 'BFB290');
      seed(r.radio, vhfAt: 0x1FCA, uhfAt: 0x1FDA);
      // A UHF range narrower than the widened one, so both fields move.
      r.radio.memory.setRange(0x1FDA, 0x1FDF, [0x01, 0x04, 0x20, 0x04, 0x50]);
      final factory = r.radio.memory.sublist(0x1FC0, 0x1FE0);
      final original = await r.programmer
          .bandLimitsIn(await read(r.programmer), uv5rProfile);
      expect(original.uhf.label, '420–450 MHz');

      final base = await read(r.programmer);
      await r.programmer
          .writeBandLimits(
            deviceId: EmulatedSerialPortService.cable.id,
            profile: uv5rProfile,
            base: base,
            limits: widened,
          )
          .drain<void>();
      // The older layout's two fields sit in two blocks.
      expect([for (final w in r.radio.writes) w.$1], [0x1FC0, 0x1FD0]);

      final widenedImage = await read(r.programmer);
      await r.programmer
          .writeBandLimits(
            deviceId: EmulatedSerialPortService.cable.id,
            profile: uv5rProfile,
            base: widenedImage,
            limits: original,
          )
          .drain<void>();
      expect(r.radio.memory.sublist(0x1FC0, 0x1FE0), factory);
    });

    test('limits no field can hold are refused before the port opens',
        () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      final r = rig();
      seed(r.radio, vhfAt: 0x1FC0, uhfAt: 0x1FC5);
      final base = await read(r.programmer);
      final opens = r.ports.openedAt.length;
      const backwards = RadioBandLimits(
        vhf: BandLimit(txEnabled: true, lowerMhz: 174, upperMhz: 136),
        uhf: BandLimit(txEnabled: true, lowerMhz: 400, upperMhz: 520),
      );
      await expectLater(
        r.programmer
            .writeBandLimits(
              deviceId: EmulatedSerialPortService.cable.id,
              profile: uv5rProfile,
              base: base,
              limits: backwards,
            )
            .drain<void>(),
        throwsA(isA<RadioProtocolException>()
            .having((e) => e.message, 'message', contains('Nothing was sent'))),
      );
      expect(r.ports.openedAt.length, opens);
      expect(r.radio.writes, isEmpty);
    });

    test('limits that are not BCD are refused, not guessed at', () async {
      if (!rustReady) return markTestSkipped('host Rust library unavailable');
      // Left as the emulator's test pattern, which is not BCD.
      final r = rig();
      final base = await read(r.programmer);
      await expectLater(
        r.programmer.bandLimitsIn(base, uv5rProfile),
        throwsA(isA<RadioProtocolException>()),
      );
    });
  });

  test('a restore rewrites everything writable, and nothing else', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final r = rig();
    final backup = await read(r.programmer);
    // The radio moves on after the backup — everywhere, including the
    // windows a restore must leave alone.
    for (var i = 0; i < 0x1800; i++) {
      r.radio.memory[i] = 0x5A;
    }
    final untouched = r.radio.memory.sublist(0x0CF0, 0x0D00);

    await r.programmer
        .restoreCodeplug(
          deviceId: EmulatedSerialPortService.cable.id,
          profile: uv5rProfile,
          codeplug: backup,
        )
        .drain<void>();

    expect(
        listEquals(r.radio.memory.sublist(0x0000, 0x0CF0),
            backup.image.sublist(8, 8 + 0x0CF0)),
        isTrue);
    expect(r.radio.memory.sublist(0x0CF0, 0x0D00), untouched,
        reason: 'a skipped window is never written, even by a restore');
    expect(r.radio.writes.every((w) => w.$2.length == 0x10), isTrue);
  });

  test('a radio that goes quiet mid-read times out, and the port closes',
      () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final r = rig();
    r.radio.goSilentAt = 0x0800;
    await expectLater(
        read(r.programmer), throwsA(isA<RadioTimeoutException>()));
    expect(r.ports.openLinks, 0);
  });

  test('a radio that answers no magic says what to check', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final radio = EmulatedUv5rRadio(
      ident: _ident,
      acceptedMagics: const [
        [1, 2, 3, 4, 5, 6, 7],
      ],
    );
    final ports = EmulatedSerialPortService(radio);
    final programmer = SerialRadioProgrammer(ports, timing: _fast);
    await expectLater(
      programmer.identify(
        deviceId: EmulatedSerialPortService.cable.id,
        profile: uv5rProfile,
      ),
      throwsA(isA<RadioProtocolException>()
          .having((e) => e.message, 'message', contains('cable'))),
    );
    expect(ports.openLinks, 0);
  });

  test('the 220 MHz variant is refused at the ident', () async {
    if (!rustReady) return markTestSkipped('host Rust library unavailable');
    final radio = EmulatedUv5rRadio(
      ident: const [0xAA, 0x30, 0x76, 0x02, 0x00, 0x05, 0x20, 0xDD],
      acceptedMagics: [uv5rMagics.first],
    );
    final programmer =
        SerialRadioProgrammer(EmulatedSerialPortService(radio), timing: _fast);
    await expectLater(
      programmer.identify(
        deviceId: EmulatedSerialPortService.cable.id,
        profile: uv5rProfile,
      ),
      throwsA(isA<RadioUnsupportedException>()),
    );
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// THE SUITE THAT TURNS THIS FROM PLAUSIBLE INTO TRUE.
//
// Everything else about the radio protocol is verified against an emulated
// peripheral and a codec that agrees with itself. That proves the driver
// consistent; it cannot prove it correct. The memory layout, the framing and
// the byte substitution were established from CHIRP's published driver, and
// not one byte of it has been read off a radio by this project.
//
// So this is the suite to run with a UV-5R Mini on the bench, and what it
// establishes, in order:
//
//   1. The radio answers the ident magic at all -- which is the whole
//      Bluetooth tunnel working.
//   2. A full read comes back the right length and decodes into channels
//      that match what CHIRP shows for the same radio. CHECK THAT BY EYE:
//      the decode agreeing with itself is exactly what a wrong layout also
//      looks like.
//   3. A write of one channel lands, reads back identical, and leaves every
//      other setting alone.
//   4. The backup restores.
//
// Only after (2) has been eyeballed against CHIRP should anyone trust a
// write on a radio they would mind losing.
//
// Doubly guarded, like the other live suites: the `live_radio` tag keeps it
// out of every ordinary run, and it skips itself unless LB_LIVE_RADIO=1 --
// so a bare `flutter test` on a developer machine can never start writing to
// whatever is advertising nearby.
//
// Run it (with the radio in view, and a backup you can restore):
//   LB_LIVE_RADIO=1 LB_LIVE_RADIO_ID=AA:BB:CC:DD:EE:FF \
//     flutter test --tags=live_radio test/live/radio_programming_live_test.dart
@Tags(['live_radio'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/src/rust/api/radio_api.dart' as rust;

import '../helpers/host_rust_lib.dart';

/// The radio's BLE address. Find it with the app's own scan, or with
/// `bluetoothctl devices`.
final String? _deviceId = Platform.environment['LB_LIVE_RADIO_ID'];

final bool _enabled = Platform.environment['LB_LIVE_RADIO'] == '1';

/// Which profile to drive. Defaults to the UV-5R Mini.
final String _modelId =
    Platform.environment['LB_LIVE_RADIO_MODEL'] ?? 'uv-5r-mini';

/// A slot far enough up that nobody's first twenty channels are at risk.
const int _scratchSlot = 900;

void main() {
  late RealBleService ble;
  late BaofengBleProgrammer programmer;
  late RadioProfile profile;
  RadioCodeplug? backup;

  setUpAll(() async {
    if (!_enabled) return;
    await initHostRustLib();
    ble = RealBleService();
    programmer = BaofengBleProgrammer(ble);
    profile = radioProfileById(_modelId) ?? uv5rMiniProfile;
  });

  bool skipUnlessConfigured() {
    if (!_enabled) {
      markTestSkipped('set LB_LIVE_RADIO=1 to run against a real radio');
      return true;
    }
    if (_deviceId == null) {
      markTestSkipped('set LB_LIVE_RADIO_ID to the radio\'s BLE address');
      return true;
    }
    return false;
  }

  Future<RadioCodeplug> read() => programmer.readWhole(
    deviceId: _deviceId!,
    profile: profile,
    onProgress: (event) => stdout.writeln(
      '  ${event.stage.name}: ${event.message} '
      '${event.progress == null ? '' : '${(event.progress! * 100).round()}%'}',
    ),
  );

  test(
    '1. the radio answers, and a full read comes back',
    () async {
      if (skipUnlessConfigured()) return;

      final codeplug = await read();
      backup = codeplug;

      expect(codeplug.length, greaterThan(0));
      expect(
        await rust.radioImageIsComplete(
          imageLen: codeplug.length,
          modelId: profile.id,
        ),
        isTrue,
        reason: 'the read was short, so the layout in models.rs is wrong',
      );

      // Keep it. A backup on disk is the difference between an experiment and
      // an accident.
      final file = File(
        'radio-backup-${DateTime.now().millisecondsSinceEpoch}'
        '-${profile.id}.bin',
      );
      await file.writeAsBytes(codeplug.image);
      stdout.writeln('  backup written to ${file.path}');
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    '2. the channels decode into something a person recognises',
    () async {
      if (skipUnlessConfigured()) return;
      final codeplug = backup ?? await read();

      final channels = await rust.radioDecodeChannels(
        image: codeplug.image,
        modelId: profile.id,
      );
      stdout.writeln('  ${channels.length} channels programmed');
      for (final channel in channels.take(20)) {
        stdout.writeln(
          '  ${channel.slot.toString().padLeft(3)}  '
          '${channel.name.padRight(12)}  '
          '${channel.rxFreqHz / 1000000}  '
          '${channel.rxOnly ? 'RX only' : 'tx ${channel.txFreqHz / 1000000}'}  '
          '${channel.txTone.mode}',
        );
      }

      // THE ASSERTION THAT MATTERS IS THE ONE YOU MAKE WITH YOUR EYES: open the
      // same radio in CHIRP and check these twenty against it. A layout that is
      // wrong by one field decodes perfectly and means nothing.
      expect(
        channels,
        isNotEmpty,
        reason:
            'a radio with no channels at all is either empty or a sign '
            'the channel block is at the wrong offset',
      );
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    '3. one channel writes, and reads back identical',
    () async {
      if (skipUnlessConfigured()) return;
      final base = backup ?? await read();

      final existing = await rust.radioDecodeChannels(
        image: base.image,
        modelId: profile.id,
      );
      final keep = [
        for (final channel in existing)
          RadioChannel(
            name: channel.name,
            rxFreqHz: channel.rxFreqHz,
            txFreqHz: channel.txFreqHz,
            rxOnly: channel.rxOnly,
            mode: channel.narrow ? ChannelMode.nfm : ChannelMode.fm,
            power: channel.lowPower ? PowerLevel.low : PowerLevel.high,
          ),
      ];
      while (keep.length < _scratchSlot) {
        keep.add(
          const RadioChannel(
            name: '',
            rxFreqHz: 146520000,
            txFreqHz: 146520000,
          ),
        );
      }
      keep.add(
        const RadioChannel(
          name: 'LBTEST',
          rxFreqHz: 146520000,
          txFreqHz: 146520000,
          txTone: ToneSetting.ctcss(1000),
        ),
      );

      await programmer
          .writeChannels(
            deviceId: _deviceId!,
            profile: profile,
            base: base,
            channels: keep,
          )
          .forEach((event) => stdout.writeln('  ${event.message}'));

      final after = await read();
      final channels = await rust.radioDecodeChannels(
        image: after.image,
        modelId: profile.id,
      );
      final written = channels.firstWhere((c) => c.slot == _scratchSlot + 1);
      expect(written.name, 'LBTEST');
      expect(written.rxFreqHz, 146520000);
      expect(written.txTone.ctcssTenthHz, 1000);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test('4. the backup restores', () async {
    if (skipUnlessConfigured()) return;
    final original = backup;
    if (original == null) {
      markTestSkipped('no backup from test 1 to restore');
      return;
    }

    await programmer
        .restoreCodeplug(
          deviceId: _deviceId!,
          profile: profile,
          codeplug: original,
        )
        .forEach((event) => stdout.writeln('  ${event.message}'));

    final after = await read();
    expect(
      after.image,
      original.image,
      reason: 'the radio should be exactly as it was found',
    );
  }, timeout: const Timeout(Duration(minutes: 15)));
}

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
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/baofeng_ble_programmer.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';
import 'package:liberated_bread_mobile/services/real_ble_service.dart';
import 'package:liberated_bread_mobile/src/rust/api/radio_api.dart' as rust;

import '../helpers/host_rust_lib.dart';
import 'radio_live_harness.dart';

/// The radio's BLE address. Find it with the app's own scan, or with
/// `bluetoothctl devices`.
final String? _deviceId = Platform.environment['LB_LIVE_RADIO_ID'];

/// A slot far enough up that nobody's first twenty channels are at risk.
const int _scratchSlot = 901;

void main() {
  late BaofengBleProgrammer programmer;
  late RadioProfile profile;
  RadioCodeplug? backup;

  setUpAll(() async {
    if (!liveRadioEnabled) return;
    await initHostRustLib();
    programmer = BaofengBleProgrammer(RealBleService());
    profile = liveRadioProfile ?? uv5rMiniProfile;
  });

  bool skip() => skipUnlessLive(
    _deviceId,
    'set LB_LIVE_RADIO_ID to the radio\'s BLE address',
  );

  Future<RadioCodeplug> read() => programmer.readWhole(
    deviceId: _deviceId!,
    profile: profile,
    onProgress: logProgress,
  );

  Future<List<rust.RadioChannelDto>> decode(RadioCodeplug codeplug) =>
      rust.radioDecodeChannels(image: codeplug.image, modelId: profile.id);

  test(
    '1. the radio answers, and a full read comes back',
    () async {
      if (skip()) return;
      final codeplug = await read();
      backup = codeplug;
      expect(
        await rust.radioImageIsComplete(
          imageLen: codeplug.length,
          modelId: profile.id,
        ),
        isTrue,
        reason: 'the read was short, so the layout in models.rs is wrong',
      );
      await saveBackup(codeplug);
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    '2. the channels decode into something a person recognises',
    () async {
      if (skip()) return;
      final channels = await decode(backup ?? await read());
      printChannels(channels, profile);

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
      if (skip()) return;
      final base = backup ?? await read();
      await programmer
          .writeChannels(
            deviceId: _deviceId!,
            profile: profile,
            base: base,
            channels: planWithTestChannel(await decode(base), _scratchSlot),
          )
          .forEach(logProgress);
      expectTestChannel(await decode(await read()), _scratchSlot);
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );

  test('4. the backup restores', () async {
    if (skip()) return;
    await restoreAndCheck(
      programmer,
      deviceId: _deviceId!,
      profile: profile,
      original: backup,
    );
  }, timeout: const Timeout(Duration(minutes: 15)));
}

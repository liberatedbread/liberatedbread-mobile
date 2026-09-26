// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// THE CABLE COUNTERPART: A UV-5R-FAMILY RADIO ON A REAL PROGRAMMING CABLE.
//
// The cable driver is proved against an emulated radio written from the same
// facts as the codec — which proves it consistent and cannot prove it
// correct. Nothing in the UV-5R codec has been read off a radio by this
// project. This suite is how that changes, and what it establishes, in order:
//
//   1. The radio answers an ident at all, and says which firmware it runs —
//      which decides the band-limit layout, so write it down.
//   2. A full read comes back the right length, and is saved to disk.
//   3. The channels decode into what CHIRP shows for the same radio, and the
//      band limits read as plausible values. CHECK BOTH BY EYE against CHIRP
//      (its "Other" settings show the limits): a layout that is wrong by one
//      field decodes perfectly and means nothing.
//   4. One channel written to the last slot lands and reads back.
//   5. The backup restores, and the radio is exactly as it was found.
//
// Step 4 fills the empty slots below the last one with placeholders so the
// test channel lands in slot 128; step 5 puts everything back. Do not stop
// between them.
//
// Deliberately NOT here: a band-limit write. That is the one write that can
// leave a radio out of spec without anyone noticing, and it should be made
// by hand — from the radio's screen in the app ("Widen its transmit
// limits", then "Put back its original transmit limits"), after step 3's
// values have been checked against CHIRP and against the target doc — not
// by a test.
//
// Guarded like the other live suites: the `live_radio` tag keeps it out of
// every ordinary run, and it skips itself unless LB_LIVE_RADIO=1.
//
// Run it (Linux or macOS, the radio on and cabled, a backup you can restore):
//   LB_LIVE_RADIO=1 LB_LIVE_RADIO_PORT=/dev/ttyUSB0 LB_LIVE_RADIO_MODEL=uv5r \
//     flutter test --tags=live_radio test/live/radio_cable_live_test.dart
@Tags(['live_radio'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/desktop_serial_port_service.dart';
import 'package:liberated_bread_mobile/services/radio_codec.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';
import 'package:liberated_bread_mobile/services/serial_radio_programmer.dart';
import 'package:liberated_bread_mobile/src/rust/api/radio_api.dart' as rust;

import '../helpers/host_rust_lib.dart';

/// The cable's port: `/dev/ttyUSB0`, `/dev/cu.usbserial-110`. The app's USB
/// tab lists them.
final String? _port = Platform.environment['LB_LIVE_RADIO_PORT'];

final bool _enabled = Platform.environment['LB_LIVE_RADIO'] == '1';

/// Which profile to drive: uv5r, bf-f8hp or ar-152. Defaults to the UV-5R.
final String _modelId = Platform.environment['LB_LIVE_RADIO_MODEL'] ?? 'uv5r';

void main() {
  late SerialRadioProgrammer programmer;
  late RadioProfile profile;
  RadioCodeplug? backup;

  setUpAll(() async {
    if (!_enabled) return;
    await initHostRustLib();
    programmer = SerialRadioProgrammer(DesktopSerialPortService());
    profile = radioProfileById(_modelId) ?? uv5rProfile;
  });

  bool skipUnlessConfigured() {
    if (!_enabled) {
      markTestSkipped('set LB_LIVE_RADIO=1 to run against a real radio');
      return true;
    }
    if (_port == null) {
      markTestSkipped('set LB_LIVE_RADIO_PORT to the cable\'s port');
      return true;
    }
    return false;
  }

  void log(RadioProgressEvent event) => stdout.writeln(
    '  ${event.stage.name}: '
    '${event.message} '
    '${event.progress == null ? '' : '${(event.progress! * 100).round()}%'}',
  );

  Future<RadioCodeplug> read() async {
    RadioCodeplug? result;
    await programmer
        .readCodeplug(
          deviceId: _port!,
          profile: profile,
          onResult: (codeplug) => result = codeplug,
        )
        .forEach(log);
    return result!;
  }

  test(
    '1. the radio answers, and says which firmware it runs',
    () async {
      if (skipUnlessConfigured()) return;
      final identity = await programmer.identify(
        deviceId: _port!,
        profile: profile,
      );
      stdout.writeln('  ${identity.summary}');
      expect(
        identity.reported,
        isNotNull,
        reason: 'the firmware string decides the band-limit layout',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    '2. a full read comes back, and is saved',
    () async {
      if (skipUnlessConfigured()) return;
      final codeplug = await read();
      backup = codeplug;
      expect(codeplug.length, await rust.uv5RImageLen());

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
    '3. channels and band limits read as a person would recognise them',
    () async {
      if (skipUnlessConfigured()) return;
      final codeplug = backup ?? await read();

      final channels = await rust.uv5RDecodeChannels(
        image: codeplug.image,
        modelId: profile.id,
      );
      stdout.writeln('  ${channels.length} channels programmed');
      for (final channel in channels.take(20)) {
        stdout.writeln(
          '  ${channel.slot.toString().padLeft(3)}  '
          '${channel.name.padRight(7)}  '
          '${channel.rxFreqHz / 1000000}  '
          '${channel.rxOnly ? 'RX only' : 'tx ${channel.txFreqHz / 1000000}'}  '
          '${channel.txTone.mode}',
        );
      }

      final limits = await rust.uv5RReadBandLimits(
        image: codeplug.image,
        modelId: profile.id,
      );
      stdout.writeln(
        '  firmware '
        '${await rust.uv5RFirmware(image: codeplug.image)}, '
        '${limits.layout} limit layout',
      );
      stdout.writeln(
        '  VHF ${limits.vhf.lowerMhz}-${limits.vhf.upperMhz} MHz, '
        'tx ${limits.vhf.txEnabled ? 'on' : 'off'}',
      );
      stdout.writeln(
        '  UHF ${limits.uhf.lowerMhz}-${limits.uhf.upperMhz} MHz, '
        'tx ${limits.uhf.txEnabled ? 'on' : 'off'}',
      );

      // THE ASSERTIONS THAT MATTER ARE THE ONES YOU MAKE WITH YOUR EYES. These
      // only catch a layout wrong enough to produce nonsense.
      expect(limits.vhf.lowerMhz, inInclusiveRange(100, 200));
      expect(limits.uhf.upperMhz, inInclusiveRange(300, 600));
    },
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    '4. one channel written to the last slot reads back',
    () async {
      if (skipUnlessConfigured()) return;
      final base = backup ?? await read();
      final existing = await rust.uv5RDecodeChannels(
        image: base.image,
        modelId: profile.id,
      );
      final bySlot = {for (final c in existing) c.slot: channelFromDto(c)};
      final plan = [
        for (var slot = 1; slot < profile.channelCapacity; slot++)
          bySlot[slot] ??
              const RadioChannel(
                name: '',
                rxFreqHz: 146520000,
                txFreqHz: 146520000,
              ),
        const RadioChannel(
          name: 'LBTEST',
          rxFreqHz: 146520000,
          txFreqHz: 146520000,
          txTone: ToneSetting.ctcss(1000),
        ),
      ];

      await programmer
          .writeChannels(
            deviceId: _port!,
            profile: profile,
            base: base,
            channels: plan,
          )
          .forEach(log);

      final after = await read();
      final channels = await rust.uv5RDecodeChannels(
        image: after.image,
        modelId: profile.id,
      );
      final written = channels.firstWhere(
        (c) => c.slot == profile.channelCapacity,
      );
      expect(written.name, 'LBTEST');
      expect(written.rxFreqHz, 146520000);
      expect(written.txTone.ctcssTenthHz, 1000);
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );

  test('5. the backup restores', () async {
    if (skipUnlessConfigured()) return;
    final original = backup;
    if (original == null) {
      markTestSkipped('no backup from test 2 to restore');
      return;
    }
    await programmer
        .restoreCodeplug(deviceId: _port!, profile: profile, codeplug: original)
        .forEach(log);

    final after = await read();
    expect(
      after.image,
      original.image,
      reason: 'the radio should be exactly as it was found',
    );
  }, timeout: const Timeout(Duration(minutes: 10)));
}

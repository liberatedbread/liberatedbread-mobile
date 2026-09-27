// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// What the two live radio suites share: the guard, the backup, the test
// channel and the restore.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/radio_codec.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';
import 'package:liberated_bread_mobile/src/rust/api/radio_api.dart';

/// LB_LIVE_RADIO=1: the second guard, after the `live_radio` tag.
final bool liveRadioEnabled = Platform.environment['LB_LIVE_RADIO'] == '1';

/// The model LB_LIVE_RADIO_MODEL names, if it names one.
final RadioProfile? liveRadioProfile = radioProfileById(
  Platform.environment['LB_LIVE_RADIO_MODEL'] ?? '',
);

/// Skip, saying why, unless the suite is switched on and [target] — the
/// radio's address or port — is set; [unset] says how to set it. True when
/// the test was skipped.
bool skipUnlessLive(String? target, String unset) {
  if (!liveRadioEnabled) {
    markTestSkipped('set LB_LIVE_RADIO=1 to run against a real radio');
    return true;
  }
  if (target == null) {
    markTestSkipped(unset);
    return true;
  }
  return false;
}

void logProgress(RadioProgressEvent event) => stdout.writeln(
  '  ${event.stage.name}: ${event.message} '
  '${event.progress == null ? '' : '${(event.progress! * 100).round()}%'}',
);

/// Keep [codeplug] on disk. A backup there is the difference between an
/// experiment and an accident.
Future<void> saveBackup(RadioCodeplug codeplug) async {
  final file = File(
    'radio-backup-${DateTime.now().millisecondsSinceEpoch}'
    '-${codeplug.modelId}.bin',
  );
  await file.writeAsBytes(codeplug.image);
  stdout.writeln('  backup written to ${file.path}');
}

/// The first twenty channels, one per line, to check by eye against what
/// CHIRP shows for the same radio.
void printChannels(List<RadioChannelDto> channels, RadioProfile profile) {
  stdout.writeln('  ${channels.length} channels programmed');
  for (final channel in channels.take(20)) {
    stdout.writeln(
      '  ${channel.slot.toString().padLeft(3)}  '
      '${channel.name.padRight(profile.nameLength)}  '
      '${channel.rxFreqHz / 1000000}  '
      '${channel.rxOnly ? 'RX only' : 'tx ${channel.txFreqHz / 1000000}'}  '
      '${channel.txTone.mode}',
    );
  }
}

const _testChannel = RadioChannel(
  name: 'LBTEST',
  rxFreqHz: 146520000,
  txFreqHz: 146520000,
  txTone: ToneSetting.ctcss(1000),
);

/// What is on the radio, with the test channel in [slot].
///
/// Every channel stays in its own slot, since a plan is written by
/// position and anything past its end is cleared. Empty slots up to the
/// last one used take a placeholder; the restore after takes them out.
List<RadioChannel> planWithTestChannel(
  List<RadioChannelDto> existing,
  int slot,
) {
  final bySlot = {for (final c in existing) c.slot: channelFromDto(c)};
  final last = bySlot.keys.fold(slot, (a, b) => a > b ? a : b);
  return [
    for (var s = 1; s <= last; s++)
      if (s == slot)
        _testChannel
      else
        bySlot[s] ??
            const RadioChannel(
              name: '',
              rxFreqHz: 146520000,
              txFreqHz: 146520000,
            ),
  ];
}

/// That [slot] reads back as the test channel.
void expectTestChannel(List<RadioChannelDto> channels, int slot) {
  final written = channels.firstWhere((c) => c.slot == slot);
  expect(written.name, _testChannel.name);
  expect(written.rxFreqHz, _testChannel.rxFreqHz);
  expect(written.txTone.ctcssTenthHz, 1000);
}

/// Put [original] back, and check the radio reads exactly as it was found.
Future<void> restoreAndCheck(
  RadioProgrammer programmer, {
  required String deviceId,
  required RadioProfile profile,
  required RadioCodeplug? original,
}) async {
  if (original == null) {
    markTestSkipped('no backup from the first read to restore');
    return;
  }
  await programmer
      .restoreCodeplug(deviceId: deviceId, profile: profile, codeplug: original)
      .forEach(logProgress);
  final after = await programmer.readWhole(
    deviceId: deviceId,
    profile: profile,
    onProgress: logProgress,
  );
  expect(
    after.image,
    original.image,
    reason: 'the radio should be exactly as it was found',
  );
}

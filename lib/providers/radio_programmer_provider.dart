// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import '../models/radio_target.dart';
import '../services/baofeng_ble_programmer.dart';
import '../services/mock_radio_programmer.dart';
import '../services/radio_codec.dart';
import '../services/radio_programmer.dart';
import 'ble_provider.dart';

/// The radio programmer: the real one, or the mock in demo mode.
///
/// Mirrors [bleServiceProvider] exactly, and for the same reason -- demo mode
/// is a shipped feature, not a test double, and the Radio tab has to work in
/// it without a radio anywhere near.
final radioProgrammerProvider = Provider<RadioProgrammer>((ref) {
  if (isMockMode) return MockRadioProgrammer();
  return BaofengBleProgrammer(ref.watch(bleServiceProvider));
});

/// Decodes read images into channels. Overridden in screen tests, which
/// cannot make native calls from inside their fake-async zone.
final codeplugDecoderProvider =
    Provider<CodeplugDecoder>((ref) => const CodeplugDecoder());

/// The programmer for a radio reached over [RadioTransport].
///
/// Screens that hold a [RadioTarget] go through this rather than
/// [radioProgrammerProvider], so the transport — not the screen — decides
/// which driver runs. Watching [radioProgrammerProvider] for Bluetooth keeps
/// every existing override of it working.
final radioProgrammerForTransportProvider =
    Provider.family<RadioProgrammer, RadioTransport>(
  (ref, transport) => switch (transport) {
    RadioTransport.ble => ref.watch(radioProgrammerProvider),
    RadioTransport.usb => const _NoCableProgrammer(),
  },
);

/// Stands in for the cable driver until there is one: supports nothing, so
/// a screen reports "cannot program that radio yet" instead of handing a
/// port name to the Bluetooth driver.
class _NoCableProgrammer implements RadioProgrammer {
  const _NoCableProgrammer();

  @override
  bool supports(RadioProfile profile) => false;

  @override
  Future<RadioIdentity> identify({
    required String deviceId,
    required RadioProfile profile,
  }) =>
      Future.error(const RadioUnsupportedException());

  @override
  Stream<RadioProgressEvent> readCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required void Function(RadioCodeplug) onResult,
  }) =>
      Stream.error(const RadioUnsupportedException());

  @override
  Stream<RadioProgressEvent> writeChannels({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required List<RadioChannel> channels,
  }) =>
      Stream.error(const RadioUnsupportedException());

  @override
  Stream<RadioProgressEvent> restoreCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug codeplug,
  }) =>
      Stream.error(const RadioUnsupportedException());
}

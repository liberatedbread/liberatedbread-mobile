// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:liberated_bread_mobile/models/radio_band_limits.dart';
import 'package:liberated_bread_mobile/models/radio_channel.dart';
import 'package:liberated_bread_mobile/models/radio_profile.dart';
import 'package:liberated_bread_mobile/services/radio_programmer.dart';

/// Limits as a UV-5R commonly ships with them.
const stockBandLimits = RadioBandLimits(
  vhf: BandLimit(txEnabled: true, lowerMhz: 136, upperMhz: 174),
  uhf: BandLimit(txEnabled: true, lowerMhz: 400, upperMhz: 520),
);

/// A programmer that answers whatever a screen test needs.
class FakeRadioProgrammer implements BandLimitProgrammer {
  /// Thrown by whichever operation runs next.
  Object? error;

  /// Progress events to emit before finishing.
  List<RadioProgressEvent> events;

  /// The image handed back by a read.
  Uint8List image;

  final List<List<RadioChannel>> written = [];
  final List<RadioCodeplug> restored = [];
  int readCalls = 0;
  int identifyCalls = 0;

  /// What the radio reports when identified, beyond acknowledging.
  String? reported;

  /// The device ids every operation was aimed at, in order.
  final List<String> deviceIds = [];

  /// When set, [identify] waits on it — a session a test can hold open.
  Completer<void>? hold;

  /// Whether [supports] answers true.
  bool supported;

  /// The transmit limits the radio holds, which a read reports.
  RadioBandLimits bandLimits = stockBandLimits;

  /// Every set of limits written, in order.
  final List<RadioBandLimits> writtenLimits = [];

  /// Thrown by a limit write only, after the read before it succeeded.
  Object? limitWriteError;

  FakeRadioProgrammer({
    this.error,
    this.supported = true,
    Uint8List? image,
    List<RadioProgressEvent>? events,
  }) : image = image ?? Uint8List(0x8240),
       events =
           events ??
           const [
             RadioProgressEvent(
               stage: RadioProgressStage.connecting,
               message: 'Connecting to the radio…',
             ),
             RadioProgressEvent(
               stage: RadioProgressStage.done,
               message: 'Done.',
               progress: 1,
             ),
           ];

  @override
  bool supports(RadioProfile profile) => supported;

  @override
  Future<RadioIdentity> identify({
    required String deviceId,
    required RadioProfile profile,
  }) async {
    identifyCalls++;
    deviceIds.add(deviceId);
    await hold?.future;
    final failure = error;
    if (failure != null) throw failure;
    return RadioIdentity(profile: profile, reported: reported);
  }

  @override
  Stream<RadioProgressEvent> readCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required void Function(RadioCodeplug) onResult,
  }) async* {
    readCalls++;
    deviceIds.add(deviceId);
    final failure = error;
    if (failure != null) throw failure;
    yield* Stream.fromIterable(events);
    onResult(
      RadioCodeplug(modelId: profile.id, image: image, readAt: DateTime.now()),
    );
  }

  @override
  Stream<RadioProgressEvent> writeChannels({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required List<RadioChannel> channels,
  }) async* {
    deviceIds.add(deviceId);
    final failure = error;
    if (failure != null) throw failure;
    written.add(channels);
    yield* Stream.fromIterable(events);
  }

  @override
  Stream<RadioProgressEvent> restoreCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug codeplug,
  }) async* {
    deviceIds.add(deviceId);
    final failure = error;
    if (failure != null) throw failure;
    restored.add(codeplug);
    yield* Stream.fromIterable(events);
  }

  @override
  Future<RadioBandLimits> bandLimitsIn(
    RadioCodeplug codeplug,
    RadioProfile profile,
  ) async => bandLimits;

  @override
  Stream<RadioProgressEvent> writeBandLimits({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required RadioBandLimits limits,
  }) async* {
    deviceIds.add(deviceId);
    final failure = error ?? limitWriteError;
    if (failure != null) throw failure;
    writtenLimits.add(limits);
    bandLimits = limits;
    yield* Stream.fromIterable(events);
  }
}

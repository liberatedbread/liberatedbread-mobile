// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A radio that is not there.

import 'dart:async';
import 'dart:typed_data';

import '../models/radio_band_limits.dart';
import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import 'radio_codec.dart';
import 'radio_programmer.dart';

/// The programmer demo mode uses.
///
/// Holds an image in memory and walks the same stages the real driver does,
/// so the screens can be built and tested without hardware -- and so demo
/// mode shows a working flow rather than an error.
///
/// Every write goes through the real codec, so a read after "Write
/// complete" decodes to what was written and not to what was there before.
/// Demo mode is a shipped feature, and a write that reported success and
/// changed nothing would misreport the one thing it is there to show.
class MockRadioProgrammer implements BandLimitProgrammer {
  /// How long each simulated stage takes. Zero in tests.
  final Duration stepDelay;

  /// Puts channels into an image, and makes the blank one a first read
  /// hands back. The native codec unless a test says otherwise.
  final CodeplugEncoder encoder;

  /// What each mock radio holds, by profile id.
  ///
  /// One image per model rather than one for the mock, because the codecs
  /// check an image's length against the model's -- a UV-5R Mini's 0x8240
  /// bytes are refused as a UV-5R's 0x1948 -- and demo mode reaches this
  /// same mock for every radio in the catalogue. Seeded blank on the first
  /// read of each model, since that is when its length is first needed.
  final Map<String, Uint8List> images = {};

  /// The transmit limits the mock radio holds: a UV-5R's, as commonly
  /// shipped. Kept beside [images] rather than in them, since the app never
  /// reads them out of the image here.
  RadioBandLimits bandLimits = const RadioBandLimits(
    vhf: BandLimit(txEnabled: true, lowerMhz: 136, upperMhz: 174),
    uhf: BandLimit(txEnabled: true, lowerMhz: 400, upperMhz: 520),
  );

  MockRadioProgrammer({
    this.stepDelay = const Duration(milliseconds: 40),
    this.encoder = const CodeplugEncoder(),
  });

  @override
  bool supports(RadioProfile profile) => profile.isProgrammable;

  @override
  Future<RadioIdentity> identify({
    required String deviceId,
    required RadioProfile profile,
  }) async {
    await _stages(
      RadioProgressStage.identifying,
      'Waking the radio…',
    ).drain<void>();
    return RadioIdentity(profile: profile);
  }

  @override
  Stream<RadioProgressEvent> readCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required void Function(RadioCodeplug) onResult,
  }) async* {
    // Sized before any progress is reported, as writeChannels encodes
    // first: a model the codec cannot size fails here, not at 100%.
    final held = images[profile.id] ??= await encoder.blankImage(profile);
    yield* _stages(RadioProgressStage.reading, 'Reading the radio…');
    onResult(
      RadioCodeplug(
        modelId: profile.id,
        // A copy: what a caller does to its read must not reach the radio
        // without a write, here as anywhere.
        image: Uint8List.fromList(held),
        readAt: DateTime.now(),
      ),
    );
    yield const RadioProgressEvent(
      stage: RadioProgressStage.done,
      message: 'Read complete.',
      progress: 1,
    );
  }

  @override
  Stream<RadioProgressEvent> writeChannels({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required List<RadioChannel> channels,
  }) async* {
    // Encoded before anything is "sent", as the real drivers do it: a plan
    // the codec refuses fails here, with the radio untouched.
    final image = await encoder.encode(base, profile, channels);
    yield* _stages(
      RadioProgressStage.writing,
      'Writing to the radio — do not turn it off…',
    );
    images[profile.id] = image;
    yield const RadioProgressEvent(
      stage: RadioProgressStage.done,
      message: 'Write complete.',
      progress: 1,
    );
  }

  @override
  Stream<RadioProgressEvent> restoreCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug codeplug,
  }) async* {
    yield* _stages(RadioProgressStage.writing, 'Restoring the backup…');
    images[profile.id] = Uint8List.fromList(codeplug.image);
    yield const RadioProgressEvent(
      stage: RadioProgressStage.done,
      message: 'Restore complete.',
      progress: 1,
    );
  }

  /// What the mock radio holds now — which is what a copy just read from
  /// it holds, the only kind of copy this is asked about.
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
    yield* _stages(
      RadioProgressStage.writing,
      'Writing to the radio — do not turn it off…',
    );
    bandLimits = limits;
    yield const RadioProgressEvent(
      stage: RadioProgressStage.done,
      message: 'Write complete.',
      progress: 1,
    );
  }

  Stream<RadioProgressEvent> _stages(
    RadioProgressStage stage,
    String message,
  ) async* {
    yield const RadioProgressEvent(
      stage: RadioProgressStage.connecting,
      message: 'Connecting to the radio…',
    );
    await Future<void>.delayed(stepDelay);
    yield const RadioProgressEvent(
      stage: RadioProgressStage.identifying,
      message: 'Waking the radio…',
    );
    await Future<void>.delayed(stepDelay);
    for (var step = 1; step <= 4; step++) {
      yield RadioProgressEvent(
        stage: stage,
        message: message,
        progress: step / 4,
      );
      await Future<void>.delayed(stepDelay);
    }
  }
}

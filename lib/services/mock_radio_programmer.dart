// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A radio that is not there.

import 'dart:async';
import 'dart:typed_data';

import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import 'radio_programmer.dart';

/// The programmer demo mode uses.
///
/// Holds an image in memory and walks the same stages the real driver does,
/// so the screens can be built and tested without hardware -- and so demo
/// mode shows a working flow rather than an error.
class MockRadioProgrammer implements RadioProgrammer {
  /// How long each simulated stage takes. Zero in tests.
  final Duration stepDelay;

  /// The image the mock radio is holding.
  Uint8List image;

  /// Every write the mock has accepted, so a test can assert what landed.
  final List<Uint8List> writes = [];

  MockRadioProgrammer({
    this.stepDelay = const Duration(milliseconds: 40),
    Uint8List? image,
  }) : image = image ?? Uint8List(_defaultImageLen);

  /// The size a UV-5R Mini reads back. Only a default -- a caller with a real
  /// image passes it in.
  static const int _defaultImageLen = 0x8240;

  @override
  bool supports(RadioProfile profile) => profile.isProgrammable;

  @override
  Stream<RadioProgressEvent> readCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required void Function(RadioCodeplug) onResult,
  }) async* {
    yield* _stages(RadioProgressStage.reading, 'Reading the radio…');
    onResult(RadioCodeplug(
      modelId: profile.id,
      image: Uint8List.fromList(image),
      readAt: DateTime.now(),
    ));
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
    yield* _stages(
      RadioProgressStage.writing,
      'Writing to the radio — do not turn it off…',
    );
    image = Uint8List.fromList(base.image);
    writes.add(Uint8List.fromList(image));
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
    image = Uint8List.fromList(codeplug.image);
    writes.add(Uint8List.fromList(image));
    yield const RadioProgressEvent(
      stage: RadioProgressStage.done,
      message: 'Restore complete.',
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

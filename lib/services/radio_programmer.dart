// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Reading a radio's memory, and writing it back.

import 'dart:typed_data';

import '../core/error_text.dart';
import '../models/radio_band_limits.dart';
import '../models/radio_channel.dart';
import '../models/radio_profile.dart';

/// What stage a programming session has reached.
enum RadioProgressStage {
  connecting,
  identifying,
  reading,
  writing,
  verifying,
  done,
}

/// One step of a programming session, for the UI to render.
class RadioProgressEvent {
  final RadioProgressStage stage;

  /// 0..1, or null where there is nothing to measure yet.
  final double? progress;

  final String message;

  const RadioProgressEvent({
    required this.stage,
    required this.message,
    this.progress,
  });
}

/// The radio said something that is not part of the conversation.
class RadioProtocolException implements UserFacingException {
  @override
  final String message;
  const RadioProtocolException(
      [this.message = 'The radio did not answer the way this app expects. '
          'Disconnect it, turn it off and on, and try again.']);

  @override
  String toString() => message;
}

/// The radio stopped answering.
class RadioTimeoutException implements UserFacingException {
  @override
  final String message;
  const RadioTimeoutException(
      [this.message = 'The radio stopped responding. Check it is still on '
          'and in range, then try again.']);

  @override
  String toString() => message;
}

/// This build cannot program the selected radio.
class RadioUnsupportedException implements UserFacingException {
  @override
  final String message;
  const RadioUnsupportedException(
      [this.message = 'This app cannot program that radio yet. You can still '
          'export a plan as a CHIRP file.']);

  @override
  String toString() => message;
}

/// A full copy of a radio's memory.
///
/// Held as bytes rather than as channels because it is the whole thing: the
/// settings, the DTMF codes, everything the channel codec does not model. It
/// is what a backup restores and what a write is built on top of.
class RadioCodeplug {
  final String modelId;
  final Uint8List image;
  final DateTime readAt;

  const RadioCodeplug({
    required this.modelId,
    required this.image,
    required this.readAt,
  });

  int get length => image.length;
}

/// What a radio said when asked to start a programming session.
class RadioIdentity {
  /// The model the session was asked for — and answered.
  final RadioProfile profile;

  /// Anything the radio reported beyond acknowledging, verbatim: a variant
  /// or firmware string. Null when it reported nothing, which is the
  /// UV-17Pro family's normal answer: it accepts a request and names nothing.
  final String? reported;

  const RadioIdentity({required this.profile, this.reported});

  /// One line for the screen, claiming no more than the radio said.
  String get summary {
    final said = reported;
    if (said != null) return 'The radio answered: $said.';
    return 'The radio answered, and accepted a ${profile.displayName} '
        'programming session. Radios in this family share one request, so '
        'that confirms the family rather than the exact model.';
  }
}

/// Reads and writes a radio.
///
/// An interface so the screens can be driven by a mock with no hardware, and
/// so a second transport -- a USB cable -- slots in beside the Bluetooth one
/// without the UI knowing.
abstract class RadioProgrammer {
  /// Whether this programmer can drive [profile].
  bool supports(RadioProfile profile);

  /// Connect, ask the radio to start a session as a [profile], and let go.
  ///
  /// Nothing on the radio changes. It is the cheapest proof that the link
  /// works and the model is right, and the moment a radio counts as having
  /// answered.
  Future<RadioIdentity> identify({
    required String deviceId,
    required RadioProfile profile,
  });

  /// Read the radio's whole memory.
  ///
  /// Emits progress as it goes; the last event carries the result through
  /// [readCodeplug]'s returned future rather than through the stream, so a
  /// caller that only wants the bytes does not have to filter events.
  Stream<RadioProgressEvent> readCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required void Function(RadioCodeplug) onResult,
  });

  /// Write [channels] into the radio, on top of [base].
  ///
  /// [base] is a codeplug just read from this radio. It is required rather
  /// than optional: writing channels into an image the app invented would
  /// wipe every setting the owner has, and making the caller produce one
  /// means the read always happens first.
  Stream<RadioProgressEvent> writeChannels({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required List<RadioChannel> channels,
  });

  /// Write a whole image back, byte for byte. What "restore my backup" runs.
  Stream<RadioProgressEvent> restoreCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug codeplug,
  });
}

/// A programmer that can also set the transmit limits a radio stores.
///
/// Only the older serial family stores any, so this is a capability a
/// programmer has or lacks rather than a method every programmer would have
/// to refuse.
abstract class BandLimitProgrammer implements RadioProgrammer {
  /// The limits held in [codeplug], a copy just read from a [profile] radio.
  ///
  /// Asks the radio nothing: the limits are in the copy.
  Future<RadioBandLimits> bandLimitsIn(
    RadioCodeplug codeplug,
    RadioProfile profile,
  );

  /// Put [limits] on the radio [base] was read from, change nothing else,
  /// and read them back.
  Stream<RadioProgressEvent> writeBandLimits({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required RadioBandLimits limits,
  });
}

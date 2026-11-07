// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Reading a radio's memory, and writing it back.

import 'dart:typed_data';

import '../core/error_text.dart';
import '../models/radio_band_limits.dart';
import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import '../models/svc_report.dart' show SvcReportResponse;

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

/// A radio failure the user can choose to report: what the radio said that
/// the programmer did not expect, described for a protocol author. Carried
/// by [RadioProtocolException] and [RadioUnsupportedException] when the
/// throw site knows it; the radio screen turns it into the "unexpected
/// response" banner.
///
/// PRIVACY: never codeplug contents — those are the owner's channels. The
/// ident a radio answers with (a model and firmware string), a reply's
/// header, an acknowledgement byte and block addresses are what may go in a
/// [SvcReportResponse.sample]; see [RadioDiagnostics].
typedef RadioDiagnostic = SvcReportResponse;

/// Builders for [RadioDiagnostic]s, one per thing a radio can get wrong, so
/// every throw site describes the same failure the same way.
abstract final class RadioDiagnostics {
  static String _hex(int addr) => '0x${addr.toRadixString(16).padLeft(4, '0')}';

  /// The radio answered the ident request with something no profile knows.
  static RadioDiagnostic unrecognizedIdent(List<int> reply) =>
      SvcReportResponse(
        problem: 'unrecognized_ident',
        where: 'radio:ident',
        detail: '${reply.length}-byte ident reply',
        sample: SvcReportResponse.hexSample(reply),
      );

  /// The radio answered the session request, but not with an acceptance.
  static RadioDiagnostic sessionRefused(List<int> reply) => SvcReportResponse(
    problem: 'session_refused',
    where: 'radio:session',
    detail: '${reply.length}-byte answer instead of an acknowledgement',
    sample: SvcReportResponse.hexSample(reply.take(4).toList()),
  );

  /// A read reply that did not parse. Only its header goes in the sample:
  /// the rest is the radio's memory.
  static RadioDiagnostic badReadReply(
    int addr,
    int len,
    List<int> reply,
    Object error,
  ) => SvcReportResponse(
    problem: 'bad_read_reply',
    where: 'radio:read@${_hex(addr)}',
    detail: 'asked for $len bytes, got ${reply.length}; $error',
    sample: SvcReportResponse.hexSample(reply.take(4).toList()),
  );

  /// The radio answered a block write with something other than an ack.
  static RadioDiagnostic writeRefused(int addr, List<int> ack) =>
      SvcReportResponse(
        problem: 'write_refused',
        where: 'radio:write@${_hex(addr)}',
        detail: 'answered a write with ${ack.length} byte(s), not an ack',
        sample: SvcReportResponse.hexSample(ack.take(4).toList()),
      );

  /// Reading back a written block gave different bytes. The bytes stay on
  /// the phone; the address is enough to find the region.
  static RadioDiagnostic verifyMismatch(int addr) => SvcReportResponse(
    problem: 'verify_mismatch',
    where: 'radio:verify@${_hex(addr)}',
    detail: 'read-back differs from what was written',
  );

  /// A whole read came back the wrong size.
  static RadioDiagnostic shortImage(int got, int want) => SvcReportResponse(
    problem: 'short_image',
    where: 'radio:read',
    detail: 'image is $got bytes, expected $want',
  );
}

/// The radio said something that is not part of the conversation.
class RadioProtocolException implements UserFacingException {
  @override
  final String message;

  /// What went wrong, for the report banner, when the throw site knows.
  final RadioDiagnostic? diagnostic;

  const RadioProtocolException([
    this.message =
        'The radio did not answer the way this app expects. '
        'Disconnect it, turn it off and on, and try again.',
  ]) : diagnostic = null;

  /// [RadioProtocolException] carrying [diagnostic]. [message] is what the
  /// screen says, unchanged by the diagnostic.
  const RadioProtocolException.diagnosed(
    this.diagnostic, [
    this.message =
        'The radio did not answer the way this app expects. '
        'Disconnect it, turn it off and on, and try again.',
  ]);

  @override
  String toString() => message;
}

/// The radio stopped answering.
class RadioTimeoutException implements UserFacingException {
  @override
  final String message;

  /// Whether this cut a write off after blocks had gone out, so the radio
  /// may hold part of the new codeplug and part of the old.
  ///
  /// When set, [message] already says so and says to restore the backup;
  /// a caller adds only which backup, never the warning again.
  final bool partlyWritten;

  const RadioTimeoutException([
    this.message =
        'The radio stopped responding. Check it is still on '
        'and in range, then try again.',
  ]) : partlyWritten = false;

  /// The radio stopped answering during the write of the block at [addr].
  ///
  /// Shared by every transport, so the warning reads the same whichever
  /// link dropped.
  RadioTimeoutException.midWrite(int addr)
    : partlyWritten = true,
      message =
          'The radio stopped responding while writing '
          '0x${addr.toRadixString(16).padLeft(4, '0')}. It may now hold a '
          'partly written codeplug — restore your backup before using it.';

  @override
  String toString() => message;
}

/// This build cannot program the selected radio.
class RadioUnsupportedException implements UserFacingException {
  @override
  final String message;

  /// What the radio said, when it answered as a model no profile knows —
  /// the report a protocol author needs to add the variant.
  final RadioDiagnostic? diagnostic;

  const RadioUnsupportedException([
    this.message =
        'This app cannot program that radio yet. You can still '
        'export a plan as a CHIRP file.',
  ]) : diagnostic = null;

  const RadioUnsupportedException.diagnosed(this.diagnostic, this.message);

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
  /// Emits progress as it goes, and hands the image to [onResult] before the
  /// last event. [ReadWhole.readWhole] is the same read as one call.
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

/// A read as one call, for a caller that wants the image.
extension ReadWhole on RadioProgrammer {
  /// Read the radio's whole memory and return it, passing each progress
  /// event to [onProgress].
  ///
  /// Throws [RadioProtocolException] if the read ends without an image: a
  /// session that finished without saying what went wrong still failed.
  Future<RadioCodeplug> readWhole({
    required String deviceId,
    required RadioProfile profile,
    void Function(RadioProgressEvent event)? onProgress,
  }) async {
    RadioCodeplug? result;
    await readCodeplug(
      deviceId: deviceId,
      profile: profile,
      onResult: (codeplug) => result = codeplug,
    ).forEach(onProgress ?? (_) {});
    return result ?? (throw const RadioProtocolException());
  }
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

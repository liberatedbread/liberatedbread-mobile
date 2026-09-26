// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Reading and writing a radio over a programming cable.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show listEquals;

import '../core/log.dart';
import '../models/radio_band_limits.dart';
import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import '../models/radio_target.dart';
import '../src/rust/api/radio_api.dart' as rust;
import 'radio_codec.dart';
import 'radio_programmer.dart';
import 'serial_port_service.dart';

/// How patient the cable conversation is.
///
/// A class rather than constants so the emulated radio in the tests can
/// run the whole conversation without real delays. The shipping values are
/// the ones the older family is known to want: it is reported to be
/// sensitive to pacing on some cables, and the pauses here are what other
/// programming tools leave.
class SerialTiming {
  /// How long any one answer may take.
  final Duration step;

  /// Between the bytes of an ident magic, which are sent one at a time.
  final Duration magicByteGap;

  /// Between blocks.
  final Duration blockGap;

  /// After a magic the radio did not answer, before trying the next one.
  final Duration identRetry;

  const SerialTiming({
    this.step = const Duration(seconds: 2),
    this.magicByteGap = const Duration(milliseconds: 10),
    this.blockGap = const Duration(milliseconds: 50),
    this.identRetry = const Duration(seconds: 2),
  });
}

/// Programs the UV-5R family over a USB-serial cable.
///
/// Built like [BaofengBleProgrammer]: an `async*` stream per operation, a
/// timeout on every answer, and the port closed in a `finally` that also
/// runs when a listener cancels mid-session. The conversation is the older
/// family's, from the frames `uv5r_*` computes.
///
/// Every write sends only the blocks that changed from an image just read
/// from this radio, checks first that the radio is the one that image came
/// from, and reads every written block back afterwards.
class SerialRadioProgrammer implements BandLimitProgrammer {
  final SerialPortService _ports;
  final SerialTiming timing;

  SerialRadioProgrammer(this._ports, {this.timing = const SerialTiming()});

  @override
  bool supports(RadioProfile profile) =>
      profile.programmingFamily == ProgrammingFamily.serialUv5r &&
      profile.programsOver(RadioTransport.usb);

  @override
  Future<RadioIdentity> identify({
    required String deviceId,
    required RadioProfile profile,
  }) async {
    String? firmware;
    await _session(deviceId, profile, (session, ident, probe) async* {
      firmware = probe.firmware;
    }).drain<void>();
    final said = firmware;
    return RadioIdentity(
      profile: profile,
      reported: said == null || said.isEmpty ? null : 'firmware $said',
    );
  }

  @override
  Stream<RadioProgressEvent> readCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required void Function(RadioCodeplug) onResult,
  }) => _session(deviceId, profile, (session, ident, probe) async* {
    final plan = await rust.uv5RReadPlan(dropsByte: probe.dropsByte);
    final image = BytesBuilder(copy: false)..add(ident);
    yield const RadioProgressEvent(
      stage: RadioProgressStage.reading,
      message: 'Reading the radio…',
      progress: 0,
    );
    for (var i = 0; i < plan.length; i++) {
      image.add(await session.readBlock(plan[i].addr, plan[i].len));
      if (i % 8 == 0 || i == plan.length - 1) {
        yield RadioProgressEvent(
          stage: RadioProgressStage.reading,
          message: 'Reading the radio…',
          progress: (i + 1) / plan.length,
        );
      }
    }
    final bytes = image.toBytes();
    if (bytes.length != await rust.uv5RImageLen()) {
      throw const RadioProtocolException(
        'The radio sent back less memory than it should have. Nothing '
        'was changed; try again.',
      );
    }
    onResult(
      RadioCodeplug(modelId: profile.id, image: bytes, readAt: DateTime.now()),
    );
    yield const RadioProgressEvent(
      stage: RadioProgressStage.done,
      message: 'Read complete.',
      progress: 1,
    );
  });

  @override
  Stream<RadioProgressEvent> writeChannels({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required List<RadioChannel> channels,
  }) async* {
    if (!supports(profile)) throw const RadioUnsupportedException();
    final updated = await rust.uv5REncodeChannels(
      image: base.image,
      channels: [
        for (var i = 0; i < channels.length; i++)
          channelToDto(channels[i], slot: i + 1),
      ],
      modelId: profile.id,
    );
    yield* writeImage(
      deviceId: deviceId,
      profile: profile,
      base: base,
      updated: updated,
    );
  }

  /// Put [updated] on the radio [base] was read from, sending only the
  /// blocks that differ.
  ///
  /// What a channel write and a band-limit write both come down to. The
  /// codec refuses a change anywhere the app never writes, so an [updated]
  /// that is not an edit of [base] fails before the port is opened.
  Stream<RadioProgressEvent> writeImage({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required Uint8List updated,
  }) async* {
    if (!supports(profile)) throw const RadioUnsupportedException();
    final List<rust.CodeplugBlockDto> blocks;
    try {
      blocks = await rust.uv5RChangedBlocks(
        base: base.image,
        updated: updated,
        modelId: profile.id,
      );
    } catch (error) {
      Log.radio.warning('refused to plan a write', error: error);
      throw const RadioProtocolException(
        'That change is not one this app writes. Nothing was sent to the '
        'radio.',
      );
    }
    if (blocks.isEmpty) {
      yield const RadioProgressEvent(
        stage: RadioProgressStage.done,
        message: 'The radio already holds this; nothing needed writing.',
        progress: 1,
      );
      return;
    }
    yield* _writeBlocks(deviceId, profile, base.image, updated, blocks);
  }

  @override
  Future<RadioBandLimits> bandLimitsIn(
    RadioCodeplug codeplug,
    RadioProfile profile,
  ) async {
    if (!supports(profile)) throw const RadioUnsupportedException();
    try {
      return bandLimitsFromDto(
        await rust.uv5RReadBandLimits(
          image: codeplug.image,
          modelId: profile.id,
        ),
      );
    } catch (error) {
      Log.radio.warning('could not read band limits', error: error);
      throw const RadioProtocolException(
        'The transmit limits in what the radio sent back could not be '
        'read. Nothing was changed.',
      );
    }
  }

  /// Band limits come down to a write like any other: the fields change in
  /// a copy of [base], and [writeImage] sends the one or two blocks that
  /// hold them — checking first that this is the radio [base] came from, and
  /// reading them back after.
  @override
  Stream<RadioProgressEvent> writeBandLimits({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required RadioBandLimits limits,
  }) async* {
    if (!supports(profile) || !profile.txUnlock.supported) {
      throw const RadioUnsupportedException();
    }
    final Uint8List updated;
    try {
      updated = await rust.uv5RApplyBandLimits(
        image: base.image,
        limits: bandLimitsToDto(limits),
        modelId: profile.id,
      );
    } catch (error) {
      Log.radio.warning('refused band limits', error: error);
      throw RadioProtocolException(
        '${limits.label} is not something this '
        'radio can hold. Nothing was sent to the radio.',
      );
    }
    yield* writeImage(
      deviceId: deviceId,
      profile: profile,
      base: base,
      updated: updated,
    );
  }

  @override
  Stream<RadioProgressEvent> restoreCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug codeplug,
  }) async* {
    if (!supports(profile)) throw const RadioUnsupportedException();
    final blocks = await rust.uv5RRestorePlan(
      image: codeplug.image,
      modelId: profile.id,
    );
    yield* _writeBlocks(
      deviceId,
      profile,
      codeplug.image,
      codeplug.image,
      blocks,
    );
  }

  /// Write [blocks] of [image] and read them back, on a radio that answers
  /// with [expected]'s ident and firmware.
  Stream<RadioProgressEvent> _writeBlocks(
    String deviceId,
    RadioProfile profile,
    Uint8List expected,
    Uint8List image,
    List<rust.CodeplugBlockDto> blocks,
  ) => _session(deviceId, profile, (session, ident, probe) async* {
    // The image was read from one radio; this had better be it, or at
    // least one answering exactly as it did.
    final firmware = await rust.uv5RFirmware(image: expected);
    if (!listEquals(ident, expected.sublist(0, ident.length)) ||
        probe.firmware != firmware) {
      throw const RadioProtocolException(
        'This is not the radio that copy was read from. Nothing was '
        'written. Read this radio first, then write.',
      );
    }

    yield const RadioProgressEvent(
      stage: RadioProgressStage.writing,
      message: 'Writing to the radio — do not turn it off or unplug it…',
      progress: 0,
    );
    for (var i = 0; i < blocks.length; i++) {
      final block = blocks[i];
      await session.writeBlock(
        block.addr,
        image.sublist(block.imageOffset, block.imageOffset + block.len),
      );
      yield RadioProgressEvent(
        stage: RadioProgressStage.writing,
        message: 'Writing to the radio — do not turn it off or unplug it…',
        progress: (i + 1) / blocks.length,
      );
    }

    yield const RadioProgressEvent(
      stage: RadioProgressStage.verifying,
      message: 'Checking what landed…',
    );
    final checks = await rust.uv5RVerifyPlan(
      changed: blocks,
      dropsByte: probe.dropsByte,
    );
    // A check reads a whole block, which can span bytes that were never
    // written — a window no write touches, a setting the radio keeps for
    // itself. Only the written blocks inside it are compared.
    for (final check in checks) {
      final got = await session.readBlock(check.addr, check.len);
      for (final block in blocks) {
        if (block.addr < check.addr || block.addr >= check.addr + check.len) {
          continue;
        }
        final at = block.addr - check.addr;
        final want = image.sublist(
          block.imageOffset,
          block.imageOffset + block.len,
        );
        if (!listEquals(got.sublist(at, at + block.len), want)) {
          throw RadioProtocolException(
            'The radio does not hold what was written at '
            '0x${block.addr.toRadixString(16).padLeft(4, '0')}. '
            'Restore your backup before using it.',
          );
        }
      }
    }
    yield const RadioProgressEvent(
      stage: RadioProgressStage.done,
      message: 'Written and checked.',
      progress: 1,
    );
  });

  /// Open the cable, wake the radio, probe it, hand off to [body], and always
  /// close the port.
  Stream<RadioProgressEvent> _session(
    String deviceId,
    RadioProfile profile,
    Stream<RadioProgressEvent> Function(
      _Uv5rSession session,
      Uint8List ident,
      rust.Uv5rProbeDto probe,
    )
    body,
  ) async* {
    if (!supports(profile)) throw const RadioUnsupportedException();

    yield const RadioProgressEvent(
      stage: RadioProgressStage.connecting,
      message: 'Opening the cable…',
    );
    final link = await _ports.open(
      SerialPortInfo(id: deviceId, name: deviceId),
      baudRate: await rust.uv5RBaudRate(),
    );
    try {
      final session = _Uv5rSession(link, timing);
      yield const RadioProgressEvent(
        stage: RadioProgressStage.identifying,
        message: 'Waking the radio…',
      );
      final ident = await session.identify(
        await rust.uv5RIdentMagics(modelId: profile.id),
      );
      final probe = await session.probe();
      yield* body(session, ident, probe);
    } finally {
      try {
        await link.close();
      } catch (error) {
        Log.radio.debug('closing the cable failed', error: error);
      }
    }
  }
}

const int _ack = 0x06;

/// One cable conversation with a radio of the older family.
class _Uv5rSession {
  final SerialLink link;
  final SerialTiming timing;

  _Uv5rSession(this.link, this.timing);

  /// Exactly [count] bytes, or [RadioTimeoutException].
  ///
  /// Translated here rather than by the session's caller: a timeout inside a
  /// body stream reaches an `async*` caller as an error event, not as
  /// something it can catch and rename.
  Future<List<int>> _take(int count) async {
    try {
      return await link.read(count, timeout: timing.step);
    } on TimeoutException {
      throw const RadioTimeoutException();
    }
  }

  Future<void> _pause(Duration duration) async {
    if (duration > Duration.zero) await Future<void>.delayed(duration);
  }

  /// Try each magic until one is answered, and return the eight-byte ident.
  Future<Uint8List> identify(List<Uint8List> magics) async {
    for (var i = 0; i < magics.length; i++) {
      // A radio that heard the wrong magic needs a moment before the next.
      if (i > 0) await _pause(timing.identRetry);
      await link.discardInput();
      for (final byte in magics[i]) {
        await link.write([byte]);
        await _pause(timing.magicByteGap);
      }
      final List<int> ack;
      try {
        ack = await link.read(1, timeout: timing.step);
      } on TimeoutException {
        continue;
      }
      if (ack.single != _ack) continue;

      await link.write([await rust.uv5RIdentRequest()]);
      final reply = <int>[];
      while (!await rust.uv5RIdentReplyComplete(reply: reply)) {
        try {
          reply.addAll(await link.read(1, timeout: timing.step));
        } on TimeoutException {
          // An eight-byte ident need not end in the terminator; silence
          // after eight is the end of it.
          break;
        }
      }
      final Uint8List ident;
      try {
        ident = await rust.uv5RParseIdent(reply: reply);
      } catch (error) {
        Log.radio.warning('unrecognised ident', error: error);
        throw const RadioUnsupportedException(
          'The radio answered, but not as a model this app programs — it '
          'may be a variant such as the 220 MHz one. Check the model, or '
          'export the plan for CHIRP.',
        );
      }
      await link.write([_ack]);
      final accepted = await _take(1);
      if (accepted.single != _ack) {
        throw const RadioProtocolException(
          'The radio would not start a programming session. Turn it off '
          'and on, and try again.',
        );
      }
      return ident;
    }
    throw const RadioProtocolException(
      'The radio did not answer. Check the cable is pushed fully into the '
      'radio, that the radio is on, and that the right model is chosen.',
    );
  }

  /// The reads made before anything else, and what they found.
  Future<rust.Uv5rProbeDto> probe() async {
    final reads = await rust.uv5RProbeReads();
    final blocks = <List<int>>[];
    for (final read in reads) {
      blocks.add(await readBlock(read.addr, read.len));
    }
    return rust.uv5RParseProbe(firmwareBlock: blocks[1], dropBlock: blocks[2]);
  }

  /// One read, acknowledged.
  ///
  /// The radio answers each of the host's acknowledgements with one of its
  /// own, so every answer after the first read arrives behind a stray 0x06.
  /// Reading one byte and looking tells the two cases apart: 0x06 is that
  /// acknowledgement, and the answer itself always starts `X`.
  Future<List<int>> readBlock(int addr, int len) async {
    await link.write(await rust.uv5RReadCommand(addr: addr, len: len));
    var first = await _take(1);
    if (first.single == _ack) first = await _take(1);
    final replyLen = await rust.uv5RReadReplyLen(len: len);
    final reply = [...first, ...await _take(replyLen - 1)];
    final Uint8List data;
    try {
      data = await rust.uv5RParseReadReply(reply: reply, addr: addr, len: len);
    } catch (error) {
      Log.radio.warning('bad read reply at $addr', error: error);
      throw const RadioProtocolException();
    }
    await link.write([_ack]);
    await _pause(timing.blockGap);
    return data;
  }

  /// One write, acknowledged.
  ///
  /// Anything already waiting is discarded first — the radio's answer to the
  /// last read's acknowledgement, if there was one — so the byte read after
  /// the write is the write's own answer.
  Future<void> writeBlock(int addr, List<int> data) async {
    await _pause(timing.blockGap);
    await link.discardInput();
    await link.write(await rust.uv5RWriteCommand(addr: addr, data: data));
    final ack = await _take(1);
    if (ack.single != _ack) {
      throw RadioProtocolException(
        'The radio refused a write at '
        '0x${addr.toRadixString(16).padLeft(4, '0')}. It may now hold a '
        'partly written memory — restore your backup before using it.',
      );
    }
  }
}

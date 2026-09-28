// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Programming a Baofeng over its own Bluetooth.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_rust_bridge/flutter_rust_bridge.dart'
    show AnyhowException;

import '../core/log.dart';
import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import '../src/rust/api/radio_api.dart' as rust;
import 'ble_connect_within.dart';
import 'ble_service.dart';
import 'byte_inbox.dart';
import 'radio_codec.dart';
import 'radio_programmer.dart';

/// The HM-10-style GATT UART these radios expose.
///
/// One service, one characteristic, write-without-response out and notify
/// back, no pairing. The whole serial protocol is tunnelled through it.
const String baofengUartService = '0000ffe0-0000-1000-8000-00805f9b34fb';
const String baofengUartCharacteristic = '0000ffe1-0000-1000-8000-00805f9b34fb';

/// How patient the Bluetooth conversation is.
///
/// A class rather than constants so the emulated radio in the tests can
/// fail a step in milliseconds: with the shipping 8 s fixed, every test of a
/// silent radio slept out the real timeout.
class BleTiming {
  /// How long any one command may take before the session is abandoned.
  final Duration step;

  /// How long the connection may take.
  final Duration connect;

  /// The radio needs a moment after the ident magic before it will answer,
  /// and after a magic it ignored before it will hear the next.
  final Duration settle;

  const BleTiming({
    this.step = const Duration(seconds: 8),
    this.connect = const Duration(seconds: 20),
    this.settle = const Duration(milliseconds: 200),
  });
}

/// A programmer that can say, without touching the radio, that it will
/// refuse to write a model it otherwise reads.
///
/// For the caller that reads (and backs up) before it writes: without the
/// question, a write the programmer was always going to refuse still cost a
/// connect and a full read first, and then failed.
abstract interface class RadioWritePreflight {
  /// Completes when [profile] can be written; throws a
  /// [RadioUnsupportedException] naming why when it cannot.
  Future<void> checkCanWrite(RadioProfile profile);
}

/// Reads and writes a Baofeng over the FFE0/FFE1 tunnel.
///
/// Structured like [GroupRunner]: an `async*` stream with per-step timeouts
/// and the disconnect in a `finally`, which also runs when a listener cancels
/// mid-session. Leaving a radio connected and half-written is the one outcome
/// worth designing against.
class BaofengBleProgrammer implements RadioProgrammer, RadioWritePreflight {
  final BleService _ble;
  final BleTiming timing;

  /// The one encode path the demo programmer shares, so what the demo
  /// shows is what this radio would be sent, not a copy that drifts.
  final CodeplugEncoder encoder;

  BaofengBleProgrammer(
    this._ble, {
    this.timing = const BleTiming(),
    this.encoder = const CodeplugEncoder(),
  });

  @override
  bool supports(RadioProfile profile) =>
      profile.programmingFamily == ProgrammingFamily.bleUv17Pro &&
      profile.isProgrammable;

  @override
  Future<RadioIdentity> identify({
    required String deviceId,
    required RadioProfile profile,
  }) async {
    // The session is the whole of it: connecting, the ident and the
    // handshake all happen before a body runs, and the disconnect after.
    await _session(
      deviceId,
      profile,
      (_) => const Stream.empty(),
    ).drain<void>();
    return RadioIdentity(profile: profile);
  }

  @override
  Stream<RadioProgressEvent> readCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required void Function(RadioCodeplug) onResult,
  }) async* {
    yield* _session(deviceId, profile, (session) async* {
      final image = <int>[];
      final plan = await rust.radioReadPlan(modelId: profile.id);

      yield const RadioProgressEvent(
        stage: RadioProgressStage.reading,
        message: 'Reading the radio…',
        progress: 0,
      );

      for (var i = 0; i < plan.length; i++) {
        final block = plan[i];
        final bytes = await session.readBlock(block.addr, block.len);
        image.addAll(bytes);
        if (i % 16 == 0 || i == plan.length - 1) {
          yield RadioProgressEvent(
            stage: RadioProgressStage.reading,
            message: 'Reading the radio…',
            progress: (i + 1) / plan.length,
          );
        }
      }

      if (!await rust.radioImageIsComplete(
        imageLen: image.length,
        modelId: profile.id,
      )) {
        // A short read written back would leave the radio holding half a
        // codeplug, so it is refused here rather than at the write.
        throw const RadioProtocolException(
          'The radio sent back less memory than it should have. Nothing '
          'was changed; try again.',
        );
      }

      onResult(
        RadioCodeplug(
          modelId: profile.id,
          image: Uint8List.fromList(image),
          readAt: DateTime.now(),
        ),
      );
      yield const RadioProgressEvent(
        stage: RadioProgressStage.done,
        message: 'Read complete.',
        progress: 1,
      );
    });
  }

  @override
  Stream<RadioProgressEvent> writeChannels({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required List<RadioChannel> channels,
  }) async* {
    // Refused before the encode, so the reason given is the real one.
    await checkCanWrite(profile);
    final image = await encoder.encode(base, profile, channels);
    yield* restoreCodeplug(
      deviceId: deviceId,
      profile: profile,
      codeplug: RadioCodeplug(
        modelId: profile.id,
        image: Uint8List.fromList(image),
        readAt: base.readAt,
      ),
    );
  }

  /// Asks Rust for the write plan, which is pure and refuses a model whose
  /// Bluetooth write frame nobody has captured (the UV-32).
  ///
  /// The plan used to be asked for only inside the session, so a UV-32
  /// write connected, woke the radio and only then failed with Rust's raw
  /// error text.
  @override
  Future<void> checkCanWrite(RadioProfile profile) async {
    await _writePlan(profile);
  }

  Future<List<rust.CodeplugBlockDto>> _writePlan(RadioProfile profile) async {
    if (!supports(profile)) throw const RadioUnsupportedException();
    try {
      return await rust.radioWritePlan(modelId: profile.id);
    } on AnyhowException catch (error) {
      // Rust's message already says which radio and that nothing was
      // written.
      throw RadioUnsupportedException(error.message);
    }
  }

  @override
  Stream<RadioProgressEvent> restoreCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug codeplug,
  }) async* {
    // Before the size check and the session: a model this cannot write is
    // refused without a connect.
    final plan = await _writePlan(profile);
    if (!await rust.radioImageIsComplete(
      imageLen: codeplug.length,
      modelId: profile.id,
    )) {
      throw const RadioProtocolException(
        'That codeplug is not the right size for this radio. Nothing was '
        'written.',
      );
    }

    yield* _session(deviceId, profile, (session) async* {
      yield const RadioProgressEvent(
        stage: RadioProgressStage.writing,
        message: 'Writing to the radio — do not turn it off…',
        progress: 0,
      );

      for (var i = 0; i < plan.length; i++) {
        final block = plan[i];
        final start = block.imageOffset;
        final end = start + block.len;
        await session.writeBlock(
          block.addr,
          codeplug.image.sublist(start, end),
        );
        if (i % 8 == 0 || i == plan.length - 1) {
          yield RadioProgressEvent(
            stage: RadioProgressStage.writing,
            message: 'Writing to the radio — do not turn it off…',
            progress: (i + 1) / plan.length,
          );
        }
      }

      yield const RadioProgressEvent(
        stage: RadioProgressStage.done,
        message: 'Write complete.',
        progress: 1,
      );
    });
  }

  /// Connect, hand off to [body], and always disconnect.
  Stream<RadioProgressEvent> _session(
    String deviceId,
    RadioProfile profile,
    Stream<RadioProgressEvent> Function(_RadioSession session) body,
  ) async* {
    if (!supports(profile)) throw const RadioUnsupportedException();

    yield const RadioProgressEvent(
      stage: RadioProgressStage.connecting,
      message: 'Connecting to the radio…',
    );

    var connected = false;
    StreamSubscription<List<int>>? notifications;
    try {
      // connectWithin, not a bare timeout: a connect that landed after this
      // gave up took a claim nothing released, and the radio stayed
      // connected — and stopped advertising — until the app died.
      await connectWithin(_ble, deviceId, timing.connect);
      connected = true;
      await _ble.discoverServices(deviceId).timeout(timing.step);

      // A 0x44-byte reply arrives as three notifications at the minimum
      // MTU; the inbox reassembles them.
      final inbox = ByteInbox();
      notifications = _ble
          .subscribeCharacteristic(
            deviceId,
            baofengUartService,
            baofengUartCharacteristic,
          )
          // A failed notify setup (a refused CCCD write, a pairing demand)
          // arrives as an error on this stream. Unhandled, it went to the
          // zone and the session sent magic after magic into a
          // characteristic that would never answer, then blamed the
          // radio's programming mode. In the inbox, the next read throws
          // the real cause at once. The stream only ends on its own when
          // the link does, and a cancel does not end it.
          .listen(
            inbox.add,
            onError: inbox.fail,
            onDone: () => inbox.fail(const BleLinkDroppedException()),
          );

      final session = _RadioSession(
        ble: _ble,
        deviceId: deviceId,
        inbox: inbox,
        timing: timing,
      );

      yield const RadioProgressEvent(
        stage: RadioProgressStage.identifying,
        message: 'Waking the radio…',
      );
      await session.identify(profile.id);

      yield* body(session);
    } on TimeoutException {
      throw const RadioTimeoutException();
    } finally {
      await notifications?.cancel();
      // A radio left connected blocks the next thing that wants the link,
      // and this runs on a cancelled listener too.
      if (connected) {
        try {
          await _ble.disconnect(deviceId);
        } catch (error) {
          Log.radio.debug('disconnect after session failed', error: error);
        }
      }
    }
  }
}

/// One connected conversation with a radio.
class _RadioSession {
  final BleService ble;
  final String deviceId;
  final ByteInbox inbox;
  final BleTiming timing;

  _RadioSession({
    required this.ble,
    required this.deviceId,
    required this.inbox,
    required this.timing,
  });

  // Both timeouts are translated here, not by the session's catch: a
  // timeout in a block read or write happens inside the session's body
  // stream, and an `async*` function forwards an inner stream's errors as
  // events rather than throwing them where it could catch them. Left raw, a
  // stalled send reached the screen as a bare TimeoutException and read as
  // the generic "did not finish".

  /// A reply of exactly [count] bytes.
  Future<List<int>> _take(int count) async {
    try {
      return await inbox.take(count, timing.step);
    } on TimeoutException {
      throw const RadioTimeoutException();
    }
  }

  Future<void> _send(List<int> bytes) async {
    try {
      await ble
          .writeCharacteristic(
            deviceId,
            baofengUartService,
            baofengUartCharacteristic,
            bytes,
          )
          .timeout(timing.step);
    } on TimeoutException {
      throw const RadioTimeoutException();
    }
  }

  Future<void> _pause(Duration duration) async {
    if (duration > Duration.zero) await Future<void>.delayed(duration);
  }

  /// The ident magic, then the model's three-step handshake.
  ///
  /// A model can have more than one magic (a UV-5G Mini answers a
  /// different one on each firmware), and a radio ignores one it does not
  /// answer to, so each is tried in turn, with the inbox cleared first so a
  /// late byte from the last attempt is not read as this one's ack.
  Future<void> identify(String modelId) async {
    final magics = await rust.radioIdentMagics(modelId: modelId);
    var accepted = false;
    var sawData = false;
    for (var i = 0; i < magics.length && !accepted; i++) {
      if (i > 0) await _pause(timing.settle);
      inbox.clear();
      await _send(magics[i]);
      final List<int> ack;
      try {
        ack = await inbox.take(1, timing.step);
      } on TimeoutException {
        continue;
      }
      sawData = true;
      accepted = await rust.radioIsAck(reply: ack);
    }
    if (!accepted) {
      if (sawData) {
        throw const RadioProtocolException(
          'The radio did not accept the programming request. Make sure it '
          'is the model selected, and that nothing else is connected to it.',
        );
      }
      // Silence here is not "out of range": the link is up, so the radio
      // is on and near. It is almost always a radio not in programming
      // mode, or a different model that ignores this one's magic. Saying
      // "stopped responding" sent people walking towards the radio.
      throw const RadioProtocolException(
        'The radio did not answer the programming request, so it is not in '
        'programming mode. Turn on wireless programming in the radio\'s '
        'menu, and check the model selected is the one printed on it.',
      );
    }
    await _pause(timing.settle);

    for (final step in await rust.radioHandshakeSteps(modelId: modelId)) {
      await _send(step.request);
      // The reply is read and discarded: what matters is that the radio
      // answered with the right number of bytes, which is how the two ends
      // stay in step.
      await _take(step.expectedReplyLen);
    }
  }

  Future<List<int>> readBlock(int addr, int len) async {
    await _send(await rust.radioReadCommand(addr: addr, len: len));
    final expected = await rust.radioReadReplyLen(len: len);
    final reply = await _take(expected);
    try {
      return await rust.radioParseReadReply(reply: reply, addr: addr, len: len);
    } catch (error) {
      // A reply for the wrong address means the conversation slipped; the
      // Rust error is for the log, the screen gets something it can say.
      Log.radio.warning('bad read reply at $addr', error: error);
      throw const RadioProtocolException();
    }
  }

  /// One block of a write. [data] may be shorter than the frame at the end
  /// of a region; Rust pads it.
  Future<void> writeBlock(int addr, List<int> data) async {
    final List<int> ack;
    try {
      await _send(await rust.radioWriteCommand(addr: addr, data: data));
      ack = await _take(1);
    } on RadioTimeoutException {
      // A write that stopped part way leaves the radio half-programmed,
      // which "check it is in range" alone does not tell anyone.
      throw RadioTimeoutException.midWrite(addr);
    } on BleLinkDroppedException {
      throw RadioTimeoutException.midWrite(addr);
    }
    if (!await rust.radioIsAck(reply: ack)) {
      throw RadioProtocolException(
        'The radio refused a write at 0x${addr.toRadixString(16)}. It may '
        'now hold a partly written codeplug — restore your backup before '
        'using it.',
      );
    }
  }
}

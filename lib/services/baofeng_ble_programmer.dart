// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Programming a Baofeng over its own Bluetooth.

import 'dart:async';
import 'dart:typed_data';

import '../core/log.dart';
import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import '../src/rust/api/radio_api.dart' as rust;
import 'ble_service.dart';
import 'radio_programmer.dart';

/// The HM-10-style GATT UART these radios expose.
///
/// One service, one characteristic, write-without-response out and notify
/// back, no pairing. The whole serial protocol is tunnelled through it.
const String baofengUartService = '0000ffe0-0000-1000-8000-00805f9b34fb';
const String baofengUartCharacteristic = '0000ffe1-0000-1000-8000-00805f9b34fb';

/// Names these radios advertise under, lower-cased for matching.
///
/// Deliberately loose: the advertised name is a discovery hint, not an
/// identity. What settles which radio this is, is the ident exchange.
const List<String> baofengAdvertisedNamePrefixes = [
  'uv-5r',
  'uv5r',
  'uv-5g',
  'uv5g',
  'mini',
  'uv-32',
  'uv32',
  'baofeng',
];

/// Reads and writes a Baofeng over the FFE0/FFE1 tunnel.
///
/// Structured like [GroupRunner]: an `async*` stream with per-step timeouts
/// and the disconnect in a `finally`, which also runs when a listener cancels
/// mid-session. Leaving a radio connected and half-written is the one outcome
/// worth designing against.
class BaofengBleProgrammer implements RadioProgrammer {
  final BleService _ble;

  /// How long any one command may take before the session is abandoned.
  static const Duration stepTimeout = Duration(seconds: 8);
  static const Duration connectTimeout = Duration(seconds: 20);

  /// The radio needs a moment after the ident magic before it will answer.
  static const Duration settleDelay = Duration(milliseconds: 200);

  BaofengBleProgrammer(this._ble);

  @override
  bool supports(RadioProfile profile) =>
      profile.programmingFamily == ProgrammingFamily.bleUv17Pro &&
      profile.isProgrammable;

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
            'was changed; try again.');
      }

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
    });
  }

  @override
  Stream<RadioProgressEvent> writeChannels({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug base,
    required List<RadioChannel> channels,
  }) async* {
    final image = await rust.radioEncodeChannels(
      image: base.image,
      channels: [
        for (var i = 0; i < channels.length; i++)
          _toDto(channels[i], slot: i + 1),
      ],
      modelId: profile.id,
    );
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

  @override
  Stream<RadioProgressEvent> restoreCodeplug({
    required String deviceId,
    required RadioProfile profile,
    required RadioCodeplug codeplug,
  }) async* {
    if (!await rust.radioImageIsComplete(
      imageLen: codeplug.length,
      modelId: profile.id,
    )) {
      throw const RadioProtocolException(
          'That codeplug is not the right size for this radio. Nothing was '
          'written.');
    }

    yield* _session(deviceId, profile, (session) async* {
      final blockSize = await rust.radioBleWriteBlockSize();
      final plan = await rust.radioWritePlan(
        modelId: profile.id,
        blockSize: blockSize,
      );

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
      await _ble.connect(deviceId).timeout(connectTimeout);
      connected = true;
      await _ble.discoverServices(deviceId).timeout(stepTimeout);

      final inbox = _Inbox();
      notifications = _ble
          .subscribeCharacteristic(
            deviceId,
            baofengUartService,
            baofengUartCharacteristic,
          )
          .listen(inbox.add);

      final session = _RadioSession(
        ble: _ble,
        deviceId: deviceId,
        inbox: inbox,
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

  static rust.RadioChannelDto _toDto(RadioChannel channel,
      {required int slot}) {
    rust.ToneDto tone(ToneSetting setting) => rust.ToneDto(
          mode: switch (setting.mode) {
            ToneMode.none => 'none',
            ToneMode.ctcss => 'ctcss',
            ToneMode.dcs => 'dcs',
          },
          ctcssTenthHz: setting.ctcssTenthHz,
          dcsCode: setting.dcsCode,
          dcsInverted: setting.dcsInverted,
        );

    return rust.RadioChannelDto(
      slot: slot,
      name: channel.name,
      rxFreqHz: channel.rxFreqHz,
      txFreqHz: channel.txFreqHz,
      rxOnly: channel.rxOnly,
      txTone: tone(channel.txTone),
      rxTone: tone(channel.rxTone),
      narrow: channel.mode == ChannelMode.nfm,
      lowPower: channel.power == PowerLevel.low,
      skip: false,
    );
  }
}

/// Reassembles notifications into whole replies.
///
/// A 0x44-byte read reply arrives as three notifications at the BLE minimum
/// MTU, so "wait for N bytes" is the only workable read: there is no framing
/// inside the tunnel and no terminator to look for.
class _Inbox {
  final List<int> _buffer = [];
  Completer<void>? _waiter;

  void add(List<int> chunk) {
    _buffer.addAll(chunk);
    final waiter = _waiter;
    if (waiter != null && !waiter.isCompleted) waiter.complete();
  }

  /// Take exactly [count] bytes, waiting for them to arrive.
  Future<List<int>> take(int count, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (_buffer.length < count) {
      final remaining = deadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw const RadioTimeoutException();
      }
      final waiter = Completer<void>();
      _waiter = waiter;
      await waiter.future.timeout(
        remaining,
        onTimeout: () => throw const RadioTimeoutException(),
      );
      _waiter = null;
    }
    final out = _buffer.sublist(0, count);
    _buffer.removeRange(0, count);
    return out;
  }

  /// Drop anything left over, so one command's tail cannot be read as the
  /// next command's reply.
  void clear() => _buffer.clear();
}

/// One connected conversation with a radio.
class _RadioSession {
  final BleService ble;
  final String deviceId;
  final _Inbox inbox;

  _RadioSession({
    required this.ble,
    required this.deviceId,
    required this.inbox,
  });

  Future<void> _send(List<int> bytes) => ble
      .writeCharacteristic(
        deviceId,
        baofengUartService,
        baofengUartCharacteristic,
        bytes,
      )
      .timeout(BaofengBleProgrammer.stepTimeout);

  /// The ident magic, then the three-step handshake.
  Future<void> identify(String modelId) async {
    inbox.clear();
    final magic = await rust.radioIdentMagic(modelId: modelId);
    await _send(magic);

    final ack = await inbox.take(1, BaofengBleProgrammer.stepTimeout);
    if (!await rust.radioIsAck(reply: ack)) {
      throw const RadioProtocolException(
          'The radio did not accept the programming request. Make sure it is '
          'the model selected, and that nothing else is connected to it.');
    }
    await Future<void>.delayed(BaofengBleProgrammer.settleDelay);

    for (final step in await rust.radioHandshakeSteps()) {
      await _send(step.request);
      // The reply is read and discarded: what matters is that the radio
      // answered with the right number of bytes, which is how the two ends
      // stay in step.
      await inbox.take(
        step.expectedReplyLen,
        BaofengBleProgrammer.stepTimeout,
      );
    }
  }

  Future<List<int>> readBlock(int addr, int len) async {
    await _send(await rust.radioReadCommand(addr: addr, len: len));
    final expected = await rust.radioExpectedReplyLen(len: len);
    final reply = await inbox.take(expected, BaofengBleProgrammer.stepTimeout);
    return rust.radioParseReadReply(reply: reply, addr: addr, len: len);
  }

  Future<void> writeBlock(int addr, List<int> data) async {
    await _send(await rust.radioWriteCommand(addr: addr, data: data));
    final ack = await inbox.take(1, BaofengBleProgrammer.stepTimeout);
    if (!await rust.radioIsAck(reply: ack)) {
      throw RadioProtocolException(
          'The radio refused a write at 0x${addr.toRadixString(16)}. It may '
          'now hold a partly written codeplug — restore your backup before '
          'using it.');
    }
  }
}

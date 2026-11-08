// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/error_text.dart';
import '../core/hex.dart';
import '../core/log.dart';
import '../src/rust/api/enphase_api.dart';
import '../src/rust/protocol/enphase.dart';
import 'ble_service.dart';
import 'ble_write_plan_runner.dart';

const _serviceUuid = '53da53b9-0447-425a-b9ea-9837505eb59a';
const _txUuid = '7dddca00-3e05-4651-9254-44074792c590';
const _rxUuid = 'f9279ee9-2cd0-410c-81cc-adf11e4e5aea';

class EnphaseException implements UserFacingException {
  @override
  final String message;

  const EnphaseException(this.message);

  @override
  String toString() => message;
}

abstract interface class EnphaseClient {
  Future<EnphaseSessionReport> unlockAndRead();
  Future<void> close();
}

@immutable
class EnphaseStatusReply {
  final int type;
  final int sourceInterface;
  final List<int> payload;

  const EnphaseStatusReply({
    required this.type,
    required this.sourceInterface,
    required this.payload,
  });

  String get payloadHex => bytesToHex(payload);
}

@immutable
class EnphaseSessionReport {
  final List<EnphaseStatusReply> replies;

  const EnphaseSessionReport({required this.replies});
}

abstract interface class EnphaseCrypto {
  Future<Uint8List> clientEphemeral(Uint8List privateKey);

  Future<EnphaseProofDto> processChallenge({
    required Uint8List privateKey,
    required Uint8List publicA,
    required Uint8List salt,
    required Uint8List publicB,
  });

  Future<XBeeFrameDto> decodeFrame(List<int> bytes);

  Future<Uint8List> encodeFrame(int type, int step, List<int> payload);

  Future<Uint8List> applyCipher({
    required List<int> key,
    required List<int> nonce,
    required int offset,
    required List<int> data,
  });
}

class RustEnphaseCrypto implements EnphaseCrypto {
  @override
  Future<Uint8List> clientEphemeral(Uint8List privateKey) =>
      enphaseClientEphemeral(privateKey: privateKey);

  @override
  Future<EnphaseProofDto> processChallenge({
    required Uint8List privateKey,
    required Uint8List publicA,
    required Uint8List salt,
    required Uint8List publicB,
  }) => enphaseProcessChallenge(
    privateKey: privateKey,
    publicA: publicA,
    salt: salt,
    publicB: publicB,
    username: 'apiservice',
    password: 'password',
  );

  @override
  Future<XBeeFrameDto> decodeFrame(List<int> bytes) =>
      xbeeDecodeFrame(bytes: bytes);

  @override
  Future<Uint8List> encodeFrame(int type, int step, List<int> payload) =>
      xbeeEncodeFrame(frameType: type, step: step, payload: payload);

  @override
  Future<Uint8List> applyCipher({
    required List<int> key,
    required List<int> nonce,
    required int offset,
    required List<int> data,
  }) => enphaseApplyCipher(
    key: key,
    nonce: nonce,
    offset: BigInt.from(offset),
    data: data,
  );
}

class EnphaseBleClient implements EnphaseClient {
  final BleService ble;
  final String deviceId;
  final EnphaseCrypto crypto;

  final List<int> _buffer = [];
  final List<XBeeFrameDto> _pending = [];
  final _events = StreamController<XBeeFrameDto>.broadcast();
  StreamSubscription<List<int>>? _subscription;
  Future<void> _receiveQueue = Future<void>.value();
  bool _closed = false;
  bool _unlocked = false;
  Uint8List? _key;
  Uint8List? _txNonce;
  Uint8List? _rxNonce;
  var _txOffset = 0;
  var _rxOffset = 0;

  EnphaseBleClient({
    required this.ble,
    required this.deviceId,
    EnphaseCrypto? crypto,
  }) : crypto = crypto ?? RustEnphaseCrypto();

  @override
  Future<EnphaseSessionReport> unlockAndRead() async {
    try {
      await ble.connect(deviceId);
      await ble.discoverServices(deviceId);
      _subscription = ble
          .subscribeCharacteristic(deviceId, _serviceUuid, _rxUuid)
          .listen(_onBytes);
      final privateKey = Uint8List.fromList(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)),
      );
      final publicA = await crypto.clientEphemeral(privateKey);
      await _writePlain(await crypto.encodeFrame(0x2c, 1, publicA));
      final challenge = await _next(type: 0xac, step: 2);
      final saltLength = challenge.payload.length - 128;
      if (saltLength <= 0) {
        throw const EnphaseException(
          'The XBee returned an incomplete unlock challenge.',
        );
      }
      final proof = await crypto.processChallenge(
        privateKey: privateKey,
        publicA: publicA,
        salt: Uint8List.fromList(challenge.payload.sublist(0, saltLength)),
        publicB: Uint8List.fromList(challenge.payload.sublist(saltLength)),
      );
      await _writePlain(await crypto.encodeFrame(0x2c, 3, proof.m1));
      final proofReply = await _next(type: 0xac, step: 4);
      if (proofReply.payload.length != 56 ||
          !listEquals(proofReply.payload.sublist(0, 32), proof.expectedM2)) {
        throw const EnphaseException(
          'The XBee rejected the session proof. Try unlocking again.',
        );
      }
      _key = proof.sessionKey;
      _txNonce = Uint8List.fromList(proofReply.payload.sublist(32, 44));
      _rxNonce = Uint8List.fromList(proofReply.payload.sublist(44));
      _unlocked = true;
      Log.ble.info('XBee SRP-6a unlock succeeded for $deviceId');

      final replies = <EnphaseStatusReply>[];
      for (final type in const [4, 5, 8]) {
        await _writeEncrypted(await crypto.encodeFrame(0x2d, 1, [type, 0]));
        final reply = await _next(type: 0xad, payloadType: type);
        replies.add(
          EnphaseStatusReply(
            type: type,
            sourceInterface: reply.payload[0],
            payload: reply.payload.sublist(1),
          ),
        );
      }
      return EnphaseSessionReport(replies: replies);
    } finally {
      await close();
    }
  }

  void _onBytes(List<int> bytes) {
    if (_closed) return;
    final encrypted = _unlocked;
    final key = _key;
    final nonce = _rxNonce;
    final offset = _rxOffset;
    if (encrypted) _rxOffset += bytes.length;
    final copy = Uint8List.fromList(bytes);
    _receiveQueue = _receiveQueue
        .then(
          (_) => _processBytes(
            copy,
            encrypted: encrypted,
            key: key,
            nonce: nonce,
            offset: offset,
          ),
        )
        .catchError((Object e) {
          Log.ble.warning('XBee receive failed for $deviceId', error: e);
          if (!_events.isClosed) _events.addError(e);
        });
  }

  Future<void> _processBytes(
    List<int> bytes, {
    required bool encrypted,
    required Uint8List? key,
    required Uint8List? nonce,
    required int offset,
  }) async {
    final plain = encrypted
        ? await crypto.applyCipher(
            key: key!,
            nonce: nonce!,
            offset: offset,
            data: bytes,
          )
        : bytes;
    _buffer.addAll(plain);
    while (_buffer.length >= 5) {
      final length = ((_buffer[1] << 8) | _buffer[2]) + 4;
      if (length < 6 || length > 4096) {
        throw EnphaseException('Invalid XBee frame length $length');
      }
      if (_buffer.length < length) return;
      final packet = _buffer.sublist(0, length);
      _buffer.removeRange(0, length);
      final frame = await crypto.decodeFrame(packet);
      if (frame.frameType == 0xac && frame.step >= 0x80) {
        throw EnphaseException(
          'The XBee returned unlock error 0x${frame.step.toRadixString(16)}.',
        );
      }
      _pending.add(frame);
      _events.add(frame);
    }
  }

  Future<XBeeFrameDto> _next({
    required int type,
    int? step,
    int? payloadType,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    bool matches(XBeeFrameDto frame) {
      if (frame.frameType != type) return false;
      if (step != null && frame.step != step) return false;
      if (payloadType != null &&
          (frame.payload.length < 2 || frame.payload[1] != payloadType)) {
        return false;
      }
      return true;
    }

    final existing = _pending.indexWhere(matches);
    if (existing >= 0) return _pending.removeAt(existing);
    final completer = Completer<XBeeFrameDto>();
    late final StreamSubscription<XBeeFrameDto> subscription;
    subscription = _events.stream.listen(
      (frame) {
        if (matches(frame) && !completer.isCompleted) {
          _pending.remove(frame);
          completer.complete(frame);
        }
      },
      onError: (Object error) {
        if (!completer.isCompleted) completer.completeError(error);
      },
    );
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      throw EnphaseException(
        'The XBee did not answer ${step == null ? 'the relay request' : 'unlock step $step'} '
        'in time. Keep the unit powered and try again.',
      );
    } finally {
      await subscription.cancel();
    }
  }

  Future<void> _writePlain(Uint8List frame) async {
    final mtu = await ble.mtu(deviceId);
    final payload = writePayloadForMtu(mtu);
    final packets = [
      for (var offset = 0; offset < frame.length; offset += payload)
        frame.sublist(
          offset,
          offset + payload < frame.length ? offset + payload : frame.length,
        ),
    ];
    if (ble case BlePacketWriter writer) {
      await writer.writeCharacteristicPackets(
        deviceId,
        _serviceUuid,
        _txUuid,
        packets,
      );
      return;
    }
    for (final packet in packets) {
      await ble.writeCharacteristic(deviceId, _serviceUuid, _txUuid, packet);
    }
  }

  Future<void> _writeEncrypted(Uint8List frame) async {
    final encrypted = await crypto.applyCipher(
      key: _key!,
      nonce: _txNonce!,
      offset: _txOffset,
      data: frame,
    );
    await _writePlain(encrypted);
    _txOffset += frame.length;
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    await _receiveQueue;
    await _events.close();
    await ble.disconnect(deviceId).catchError((Object _) {});
  }
}

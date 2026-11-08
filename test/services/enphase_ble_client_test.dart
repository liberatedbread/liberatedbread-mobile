// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/enphase_ble_client.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/enphase.dart';

import '../fakes/fake_ble_service.dart';
import '../helpers/host_rust_lib.dart';

const _rxUuid = 'f9279ee9-2cd0-410c-81cc-adf11e4e5aea';
final _key = Uint8List.fromList(List.generate(32, (i) => i));
final _txNonce = Uint8List.fromList(List.generate(12, (i) => i + 1));
final _rxNonce = Uint8List.fromList(List.generate(12, (i) => i + 21));
final _expectedM2 = Uint8List.fromList(List.generate(32, (i) => 0x30 + i));

Uint8List _frame(int type, int step, List<int> payload) {
  final length = payload.length + 2;
  final bytes = <int>[0x7e, length >> 8, length & 0xff, type, step, ...payload];
  final sum = bytes.skip(3).fold<int>(0, (sum, byte) => (sum + byte) & 0xff);
  return Uint8List.fromList([...bytes, 0xff - sum]);
}

class _Crypto implements EnphaseCrypto {
  final publicA = Uint8List.fromList(List.generate(128, (i) => i));
  final publicB = Uint8List.fromList(List.generate(128, (i) => 0xff - i));
  final salt = Uint8List.fromList(const [1, 2, 3, 4]);
  final cipherOffsets = <int>[];

  @override
  Future<Uint8List> clientEphemeral(Uint8List privateKey) =>
      Future.value(publicA);

  @override
  Future<EnphaseProofDto> processChallenge({
    required Uint8List privateKey,
    required Uint8List publicA,
    required Uint8List salt,
    required Uint8List publicB,
  }) {
    expect(publicA, this.publicA);
    expect(salt, this.salt);
    expect(publicB, this.publicB);
    return Future.value(
      EnphaseProofDto(
        m1: Uint8List.fromList(const [9, 8, 7]),
        sessionKey: _key,
        expectedM2: _expectedM2,
      ),
    );
  }

  @override
  Future<XBeeFrameDto> decodeFrame(List<int> bytes) => Future.value(
    XBeeFrameDto(
      frameType: bytes[3],
      step: bytes[4],
      payload: Uint8List.fromList(bytes.sublist(5, bytes.length - 1)),
    ),
  );

  @override
  Future<Uint8List> encodeFrame(int type, int step, List<int> payload) =>
      Future.value(_frame(type, step, payload));

  @override
  Future<Uint8List> applyCipher({
    required List<int> key,
    required List<int> nonce,
    required int offset,
    required List<int> data,
  }) {
    cipherOffsets.add(offset);
    return Future.value(
      Uint8List.fromList([
        for (var i = 0; i < data.length; i++)
          data[i] ^ ((offset + i) * 37 + 0x5a) & 0xff,
      ]),
    );
  }
}

class _ScriptedXBee extends FakeBleService {
  final _Crypto crypto;
  final StreamController<List<int>> notifications;
  final bool badProof;
  final bool shortChallenge;
  final relayPayloads = <List<int>>[];
  final incoming = <int>[];
  var unlocked = false;
  var txOffset = 0;
  var rxOffset = 0;

  factory _ScriptedXBee(
    _Crypto crypto, {
    bool badProof = false,
    bool shortChallenge = false,
  }) => _ScriptedXBee._(
    crypto,
    StreamController<List<int>>.broadcast(),
    badProof,
    shortChallenge,
  );

  _ScriptedXBee._(
    this.crypto,
    this.notifications,
    this.badProof,
    this.shortChallenge,
  ) : super(notifyStream: notifications.stream, mtuToReturn: 23);

  @override
  Stream<List<int>> subscribeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
  ) {
    events.add('subscribe');
    return super.subscribeCharacteristic(deviceId, serviceUuid, charUuid);
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    await super.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
    events.add('write');
    final plain = unlocked
        ? await crypto.applyCipher(
            key: _key,
            nonce: _txNonce,
            offset: txOffset,
            data: value,
          )
        : value;
    if (unlocked) txOffset += value.length;
    incoming.addAll(plain);
    if (incoming.length < 3) return;
    final length = ((incoming[1] << 8) | incoming[2]) + 4;
    if (incoming.length < length) return;
    if (incoming.length != length) throw StateError('more than one TX frame');
    final packet = Uint8List.fromList(incoming);
    incoming.clear();
    if (packet[3] == 0x2c && packet[4] == 1) {
      _sendPlain(
        _frame(0xac, 2, [
          if (!shortChallenge) ...[...crypto.salt, ...crypto.publicB] else 1,
        ]),
      );
    } else if (packet[3] == 0x2c && packet[4] == 3) {
      unlocked = true;
      _sendPlain(
        _frame(0xac, 4, [..._expectedM2, ..._txNonce, ..._rxNonce]),
        damageProof: badProof,
      );
    } else {
      await _answerRelay(packet);
    }
  }

  Future<void> _answerRelay(List<int> plain) async {
    final frame = await crypto.decodeFrame(plain);
    expect(frame.frameType, 0x2d);
    expect(frame.step, 1);
    expect(frame.payload, hasLength(2));
    expect(frame.payload[1], 0);
    expect(frame.payload[0], anyOf(4, 5, 8));
    final type = frame.payload[0];
    relayPayloads.add(List<int>.of(frame.payload));
    final reply = _frame(0xad, 0, [0, type, 0xa0 + type, 0]);
    final encryptedReply = await crypto.applyCipher(
      key: _key,
      nonce: _rxNonce,
      offset: rxOffset,
      data: reply,
    );
    rxOffset += reply.length;
    var offset = 0;
    for (final size in const [1, 2, 4, 3, 5]) {
      if (offset >= encryptedReply.length) break;
      final end = offset + size < encryptedReply.length
          ? offset + size
          : encryptedReply.length;
      notifications.add(encryptedReply.sublist(offset, end));
      offset = end;
    }
    if (offset < encryptedReply.length) {
      notifications.add(encryptedReply.sublist(offset));
    }
  }

  void _sendPlain(Uint8List frame, {bool damageProof = false}) {
    if (damageProof) frame[5] ^= 1;
    for (var offset = 0; offset < frame.length; offset += 3) {
      notifications.add(
        frame.sublist(
          offset,
          offset + 3 < frame.length ? offset + 3 : frame.length,
        ),
      );
    }
  }
}

void main() {
  test('unlock precedes only the three safe, encrypted status reads', () async {
    final crypto = _Crypto();
    final ble = _ScriptedXBee(crypto);
    addTearDown(ble.notifications.close);
    final client = EnphaseBleClient(ble: ble, deviceId: 'dev', crypto: crypto);

    final report = await client.unlockAndRead();

    expect(report.replies.map((reply) => reply.type), [4, 5, 8]);
    expect(report.replies.map((reply) => reply.sourceInterface), [0, 0, 0]);
    expect(report.replies[0].payload, [4, 0xa4, 0]);
    expect(report.replies[1].payload, [5, 0xa5, 0]);
    expect(report.replies[2].payload, [8, 0xa8, 0]);
    expect(ble.relayPayloads, [
      [4, 0],
      [5, 0],
      [8, 0],
    ]);
    expect(ble.txOffset, greaterThan(3 * 7));
    expect(ble.rxOffset, greaterThan(3 * 8));
    expect(ble.subscriptions, [_rxUuid]);
    expect(ble.liveSubscriberCount[_rxUuid], 0);
    expect(ble.disconnectedIds, ['dev']);
    expect(
      ble.events.indexOf('subscribe'),
      lessThan(ble.events.indexOf('write')),
    );
  });

  test('a wrong server proof stops before any relay request', () async {
    final crypto = _Crypto();
    final ble = _ScriptedXBee(crypto, badProof: true);
    addTearDown(ble.notifications.close);
    final client = EnphaseBleClient(ble: ble, deviceId: 'dev', crypto: crypto);

    await expectLater(
      client.unlockAndRead(),
      throwsA(
        isA<EnphaseException>().having(
          (error) => error.message,
          'message',
          contains('rejected the session proof'),
        ),
      ),
    );
    expect(ble.relayPayloads, isEmpty);
    expect(ble.disconnectedIds, ['dev']);
  });

  test('a truncated unlock challenge has a useful error', () async {
    final crypto = _Crypto();
    final ble = _ScriptedXBee(crypto, shortChallenge: true);
    addTearDown(ble.notifications.close);
    final client = EnphaseBleClient(ble: ble, deviceId: 'dev', crypto: crypto);

    await expectLater(
      client.unlockAndRead(),
      throwsA(
        isA<EnphaseException>().having(
          (error) => error.message,
          'message',
          contains('incomplete unlock challenge'),
        ),
      ),
    );
    expect(ble.relayPayloads, isEmpty);
  });

  test('the Rust codec is callable through the generated bindings', () async {
    final loaded = await initHostRustLib();
    if (!loaded) return;
    final crypto = RustEnphaseCrypto();
    final public = await crypto.clientEphemeral(
      Uint8List.fromList([...List.filled(31, 0), 1]),
    );
    expect(public, hasLength(128));
    final frame = await crypto.encodeFrame(0x2d, 1, [4, 0]);
    final decoded = await crypto.decodeFrame(frame);
    expect(decoded.frameType, 0x2d);
    expect(decoded.step, 1);
    expect(decoded.payload, [4, 0]);
  });
}

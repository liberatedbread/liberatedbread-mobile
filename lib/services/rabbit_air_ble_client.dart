// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import '../core/error_text.dart';
import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import 'ble_service.dart';
import 'spec_codec.dart';

/// The BLE conversation half of the Rabbit Air protocol, as the provisioning
/// service and the BLE control path both drive it: connect, then exchange
/// payloads — the same bytes a UDP datagram would carry — over the single
/// command characteristic.
abstract class RabbitAirBleLink {
  /// Connect, locate the service/characteristic and subscribe to
  /// indications. Idempotent: re-connecting an attached client is a no-op.
  Future<void> connect(String deviceId);

  /// Send one payload (cleartext setup JSON or an encrypted datagram's
  /// bytes) and return the reassembled reply payload. Throws
  /// [RabbitAirBleException] on a device that never completes an answer.
  Future<List<int>> sendCommand(List<int> payload);

  /// Cancel the notification subscription and drop the connection if this
  /// client opened it. Safe to call when never connected.
  Future<void> disconnect();
}

/// The Rabbit Air BLE transport: JSON envelopes (cleartext during setup,
/// AES-128-CBC after) over the GATT command characteristic
/// `53ef7d7d-…` of service `366048ae-…`. The characteristic's
/// server-to-client leg is ATT INDICATIONS, not notifications (properties
/// 0x28, hardware-verified 2026-08-15) — [BleService.subscribeCharacteristic]
/// already does the right thing for either.
///
/// All protocol logic lives in the Rust codec (length-prefix framing, chunk
/// sizing, the announced reply length); this client owns what the codec must
/// not: the connection lifecycle, the sequential writes, the indication
/// reassembly, and the 7-second response window the vendor app allows.
///
/// An exchange is one request in flight: requests serialize, and the reply is
/// matched by position, not by the envelope `id` (the JSON layers above match
/// that). Notifications accumulate payload bytes — the first chunk's 2-byte
/// little-endian prefix announces the total, and only that first chunk's
/// prefix is skipped — until the announced count arrives. A sub-2-byte
/// notification while no message is being reassembled is ignored, as the
/// vendor client ignores it.
class RabbitAirBleClient implements RabbitAirBleLink {
  final BleService _ble;
  final SpecCodec _codec;

  /// How long one exchange waits for the reply to complete, as the vendor
  /// app sets it. Injectable so a test does not wait real seconds.
  final Duration responseTimeout;

  RabbitAirBleClient(
    this._ble,
    this._codec, {
    this.responseTimeout = const Duration(seconds: 7),
  });

  String? _deviceId;
  String? _serviceUuid;
  String? _characteristicUuid;

  /// Whether [connect] opened the link (vs. [attach] borrowing one the
  /// caller owns — the device screen's connection). Only an owned link is
  /// disconnected by [disconnect].
  bool _ownsConnection = false;

  /// Chunk size for writes, from the MTU the link reports at connect.
  int _chunkSize = 0;

  /// Cancelled by [disconnect], which every path that drops the link funnels
  /// through; the lint only knows how to see a cancel in the function that
  /// opened the subscription.
  // ignore: cancel_subscriptions
  StreamSubscription<List<int>>? _notifySub;

  // Reassembly state for the one in-flight exchange.
  int? _expected;
  final List<int> _buffer = [];
  Completer<List<int>>? _pending;

  /// Chunks are handled through this chain: the length announcement is read
  /// through the (async) codec, and without a chain two notifications could
  /// interleave their handling.
  Future<void> _chunkChain = Future<void>.value();

  /// Exchanges serialize: one request in flight, its reply matched by
  /// position.
  Future<void> _exchangeChain = Future<void>.value();

  @override
  Future<void> connect(String deviceId) async {
    if (_deviceId == deviceId) return;
    await disconnect();
    await _ble.connect(deviceId);
    _ownsConnection = true;
    try {
      await attach(deviceId);
    } catch (_) {
      // A half-attached client must not keep the link it opened.
      await disconnect();
      rethrow;
    }
  }

  /// Bind to an already-connected device: locate the command
  /// service/characteristic among [services] (discovered fresh when not
  /// supplied), size chunks from the reported MTU, and subscribe to
  /// notifications. The connection itself stays the caller's — the BLE device
  /// screen's — and [disconnect] only releases the subscription.
  Future<void> attach(
    String deviceId, {
    List<BleDiscoveredService>? services,
  }) async {
    if (_deviceId == deviceId) return;
    _deviceId = deviceId;

    // The MTU the link actually carries, minus the 5 bytes of ATT overhead
    // the codec prices in. The BleService owns negotiation at connect (the
    // platform may refuse the request or not support making one — Apple
    // platforms negotiate on their own), so whatever it reports here is the
    // truth to size for; a tiny or implausible report floors at the smallest
    // chunk that still carries an ATT write, slow but correct.
    final mtu = await _ble.mtu(deviceId).catchError((_) => 23);
    _chunkSize = mtu - 5 >= 18 ? mtu - 5 : 18;

    final serviceUuid = (await _codec.rabbitAirBleServiceUuid()).toLowerCase();
    final charUuid =
        (await _codec.rabbitAirBleCommandCharacteristicUuid()).toLowerCase();
    final discovered = services ?? await _ble.discoverServices(deviceId);
    for (final service in discovered) {
      if (normalizeUuid(service.uuid) != normalizeUuid(serviceUuid)) continue;
      for (final characteristic in service.characteristics) {
        if (normalizeUuid(characteristic.uuid) == normalizeUuid(charUuid)) {
          _serviceUuid = service.uuid;
          _characteristicUuid = characteristic.uuid;
        }
      }
    }
    if (_serviceUuid == null || _characteristicUuid == null) {
      throw const RabbitAirBleException(
          'the device does not offer the Rabbit Air command characteristic — '
          'is it a Rabbit Air purifier?');
    }
    _notifySub = _ble
        .subscribeCharacteristic(deviceId, _serviceUuid!, _characteristicUuid!)
        .listen(_enqueueChunk, onError: _failPending);
  }

  @override
  Future<List<int>> sendCommand(List<int> payload) {
    final deviceId = _deviceId;
    final serviceUuid = _serviceUuid;
    final charUuid = _characteristicUuid;
    if (deviceId == null || serviceUuid == null || charUuid == null) {
      throw StateError('RabbitAirBleClient.sendCommand before connect');
    }
    final result = _exchangeChain
        .then((_) => _exchangeNow(deviceId, serviceUuid, charUuid, payload));
    _exchangeChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future<List<int>> _exchangeNow(String deviceId, String serviceUuid,
      String charUuid, List<int> payload) async {
    final chunks =
        await _codec.rabbitAirBleFrame(payload: payload, chunkSize: _chunkSize);
    _expected = null;
    _buffer.clear();
    final pending = Completer<List<int>>();
    _pending = pending;
    try {
      for (final chunk in chunks) {
        await _ble.writeCharacteristic(deviceId, serviceUuid, charUuid, chunk);
      }
      return await pending.future.timeout(
        responseTimeout,
        onTimeout: () =>
            throw RabbitAirBleException('the purifier did not answer within '
                '${responseTimeout.inSeconds}s'),
      );
    } finally {
      _pending = null;
      _expected = null;
      _buffer.clear();
    }
  }

  void _enqueueChunk(List<int> chunk) {
    _chunkChain = _chunkChain.then((_) => _processChunk(chunk));
  }

  Future<void> _processChunk(List<int> chunk) async {
    final pending = _pending;
    if (pending == null || pending.isCompleted) return;
    if (_expected == null) {
      // A new message: the 2-byte little-endian prefix announces the total
      // payload length. Shorter chunks are noise — ignored, as the vendor
      // client ignores them.
      final expected =
          await _codec.rabbitAirBleExpectedPayloadLen(firstChunk: chunk);
      if (expected == null) return;
      _expected = expected;
      _buffer.addAll(chunk.length > 2 ? chunk.sublist(2) : const <int>[]);
    } else {
      _buffer.addAll(chunk);
    }
    final expected = _expected!;
    if (_buffer.length >= expected) {
      _expected = null;
      pending.complete(_buffer.sublist(0, expected));
    }
  }

  void _failPending(Object error) {
    final pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(error);
    }
  }

  @override
  Future<void> disconnect() async {
    final sub = _notifySub;
    _notifySub = null;
    if (sub != null) await sub.cancel();
    _failPending(const RabbitAirBleException('disconnected mid-exchange'));
    _expected = null;
    _buffer.clear();
    final deviceId = _deviceId;
    _deviceId = null;
    _serviceUuid = null;
    _characteristicUuid = null;
    if (deviceId != null && _ownsConnection) {
      _ownsConnection = false;
      await _ble.disconnect(deviceId).catchError((_) {});
    }
  }
}

/// The Rabbit Air BLE conversation failed: no command characteristic, or no
/// complete answer inside the response window.
class RabbitAirBleException implements UserFacingException {
  @override
  final String message;
  const RabbitAirBleException(this.message);
  @override
  String toString() => 'RabbitAirBleException: $message';
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import '../core/log.dart';
import '../models/ble_discovered_service.dart';
import 'rabbit_air_ble_client.dart';
import 'rabbit_air_control_service.dart';
import 'rabbit_air_control_transport.dart';
import 'rabbit_air_key_store.dart';
import 'spec_codec.dart';

/// The BLE transport for the shared Rabbit Air controls panel: the SAME
/// encrypted envelopes the LAN speaks, framed onto the GATT command
/// characteristic instead of UDP datagrams.
///
/// Two things the LAN path never has to do live here:
///
/// - Key discovery. The BLE identity says nothing about which Thing ID this
///   purifier is, so [userKey] tries every stored Rabbit Air key quietly —
///   a candidate wins when the time-sync reply decrypts under it and echoes
///   the request id — before falling back to the key-entry card.
/// - Thing-ID adoption. After the first successful handshake the info
///   command (cmd 255, `data.name`) reveals the Thing ID, and the key is
///   re-saved under it so the LAN path — which keys by mDNS hostname —
///   finds the same credential.
///
/// The link is the device screen's own connection, borrowed via
/// [RabbitAirBleClient.attach]; disposing this transport never disconnects
/// the device out from under the screen.
class RabbitAirBleControl implements RabbitAirControlTransport {
  final RabbitAirBleClient client;
  final SpecCodec codec;
  final RabbitAirKeyStore keyStore;
  final String deviceId;
  final String specYaml;

  /// The services the device screen already discovered, so [attach] skips a
  /// second discovery round-trip.
  final List<BleDiscoveredService>? services;

  final Random _random;

  RabbitAirBleControl({
    required this.client,
    required this.codec,
    required this.keyStore,
    required this.deviceId,
    required this.specYaml,
    this.services,
    Random? random,
  }) : _random = random ?? Random.secure();

  /// The BLE-side scope a key is filed under until the Thing ID is known.
  String get bleScope => 'ble-$deviceId';

  Future<void>? _attaching;
  String? _sessionKey;
  int? _clockOffset;
  String? _syncedKey;
  bool _thingIdAdopted = false;

  Future<void> _ensureAttached() =>
      _attaching ??= client.attach(deviceId, services: services);

  static int _nowSecs() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  @override
  int nextRequestId() => _random.nextInt(0x1000000);

  @override
  int deviceTs() => _nowSecs() + (_clockOffset ?? 0);

  @override
  Future<String?> userKey() async {
    final session = _sessionKey;
    if (session != null) return session;
    for (final key in await keyStore.candidateKeys(preferredScope: bleScope)) {
      try {
        await syncClock(specYaml: specYaml, userKey: key);
        _sessionKey = key;
        return key;
      } catch (e) {
        // Not this purifier's key — a wrong key simply does not decrypt.
        Log.ble.debug('rabbit air BLE key candidate did not answer: $e');
      }
    }
    return null;
  }

  @override
  Future<void> saveUserKey(String key) async {
    await keyStore.saveUserKey(bleScope, key);
    _sessionKey = key;
    _thingIdAdopted = false;
  }

  @override
  Future<void> syncClock(
      {required String specYaml, required String userKey}) async {
    if (_clockOffset != null && _syncedKey == userKey) return;
    final request = await codec.renderNetworkRabbitAirStateRequest(
      specYaml: specYaml,
      stateCommand: 'time_sync',
      requestId: nextRequestId(),
      deviceTs: deviceTs(),
    );
    final reply = await send(request, userKey: userKey);
    _clockOffset = await codec.rabbitAirTimeSyncOffset(
        replyJson: reply, localNowSecs: _nowSecs());
    _syncedKey = userKey;
    if (!_thingIdAdopted) {
      _thingIdAdopted = true;
      unawaited(_adoptThingId(userKey));
    }
  }

  @override
  Future<String> send(RabbitAirRequestDto request,
      {required String userKey}) async {
    await _ensureAttached();
    final datagram = await codec.rabbitAirEncryptDatagram(
        userKey: userKey, plaintext: request.json);
    try {
      final replyBytes = await client.sendCommand(datagram);
      final reply = await codec.rabbitAirDecryptDatagram(
          userKey: userKey, datagram: replyBytes);
      if (rabbitAirReplyId(reply) != request.requestId) {
        throw RabbitAirControlException(
            'the reply did not echo request ${request.requestId}');
      }
      return reply;
    } catch (_) {
      // A failed exchange drops the learned offset, the LAN client's
      // socket-recreation rule one transport over: the next exchange
      // re-syncs.
      _clockOffset = null;
      _syncedKey = null;
      rethrow;
    }
  }

  /// Learn the Thing ID over the encrypted channel and file the key under
  /// it, so the LAN path finds the same credential by the device's mDNS
  /// hostname. Best-effort: a purifier that does not answer cmd 255 over BLE
  /// keeps the BLE-scoped key and loses nothing this path needs. A unit with
  /// no Thing ID (local-only provisioning — `data.name` is "") falls back to
  /// its `RabbitAir-<WIFI MAC>.local` hostname, derived from cmd 255's
  /// `data.mac` (hardware-verified 2026-08-15).
  ///
  /// The envelope is spelled out here rather than rendered by the codec
  /// because the spec's command set does not declare cmd 255 as a LAN
  /// command — it is the setup info command, answered post-setup too. The
  /// shape is the same `{id, cmd, ts}` the renderer produces for cmd 9.
  Future<void> _adoptThingId(String userKey) async {
    try {
      final id = nextRequestId();
      final reply = await send(
        RabbitAirRequestDto(
            json: '{"id":$id,"cmd":255,"ts":${deviceTs()}}', requestId: id),
        userKey: userKey,
      );
      final decoded = jsonDecode(reply);
      final data = decoded is Map ? decoded['data'] : null;
      final name = data is Map ? data['name'] : null;
      final mac = data is Map ? data['mac'] : null;
      final scope = (name is String && name.isNotEmpty)
          ? name
          : rabbitAirFallbackHostname(mac is String ? mac : null);
      if (scope != null && scope != bleScope) {
        await keyStore.saveUserKey(scope, userKey);
      }
    } catch (e) {
      Log.ble.debug('rabbit air thing-id adoption failed: $e');
    }
  }
}

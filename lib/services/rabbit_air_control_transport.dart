// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'rabbit_air_control_service.dart';
import 'rabbit_air_key_store.dart';
import 'spec_codec.dart';

/// What the shared Rabbit Air controls panel needs from a transport: the
/// stored user key, a clock-synced encrypted exchange, and the per-send
/// envelope values. The LAN implementation wraps [RabbitAirControlClient]
/// (UDP 9009); the BLE implementation drives the same envelopes over the
/// GATT command characteristic. The panel renders one control surface over
/// either, so a purifier is the same screen whichever link carried it.
abstract class RabbitAirControlTransport {
  /// The user key this transport can drive the device under, or null when
  /// none works — which is what brings up the key-entry card. Implementations
  /// may probe stored keys (the BLE path must: it meets the purifier before
  /// learning its Thing ID), so this is allowed to cost exchanges.
  Future<String?> userKey();

  /// Persist a key the user entered.
  Future<void> saveUserKey(String key);

  /// Sync the device clock, once per session — the no-op rule lives in the
  /// implementation, as it does in [RabbitAirControlClient.syncClock].
  Future<void> syncClock({required String specYaml, required String userKey});

  /// The next request nonce (the reply echoes it) and the device-clock
  /// timestamp to stamp — both delegated to the transport because the clock
  /// offset is session state it owns.
  int nextRequestId();
  int deviceTs();

  /// Send one rendered request, return the matching reply's decrypted JSON.
  Future<String> send(RabbitAirRequestDto request, {required String userKey});
}

/// The LAN transport: one [RabbitAirControlClient] against host:port, the
/// key stored under [keyScope] (the Thing ID — the mDNS hostname — or the
/// host when discovery carried no hostname). This is exactly what
/// NetworkDeviceScreen did inline before the panel extraction.
class RabbitAirLanTransport implements RabbitAirControlTransport {
  final String host;
  final int port;
  final String keyScope;
  final RabbitAirControlClient client;
  final RabbitAirKeyStore keyStore;

  RabbitAirLanTransport({
    required this.host,
    required this.port,
    required this.keyScope,
    required this.client,
    required this.keyStore,
  });

  @override
  Future<String?> userKey() => keyStore.userKey(keyScope);

  @override
  Future<void> saveUserKey(String key) => keyStore.saveUserKey(keyScope, key);

  @override
  Future<void> syncClock({required String specYaml, required String userKey}) =>
      client.syncClock(host, port, specYaml: specYaml, userKey: userKey);

  @override
  int nextRequestId() => client.nextRequestId();

  @override
  int deviceTs() => client.deviceTs(host);

  @override
  Future<String> send(RabbitAirRequestDto request, {required String userKey}) =>
      client.send(host, port, request, userKey: userKey);
}

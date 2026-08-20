// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import '../core/log.dart';
import 'rabbit_air_ble_client.dart';
import 'rabbit_air_key_store.dart';
import 'spec_codec.dart';

/// Where the provisioning conversation stands, in the order the vendor app
/// walks it. [failed] carries the step it failed AT, so the UI can offer to
/// retry from there.
enum RabbitAirProvisionStep {
  connecting,
  readingInfo,
  fetchingNetworks,
  awaitingNetworkChoice,
  joining,
  pushingKey,
  leaving,
  verifying,
  done,
  failed,
}

/// One network the purifier reports seeing: the SSID to join and the
/// `security` value the join command must echo back verbatim.
class RabbitAirNetwork {
  final String ssid;
  final int security;
  const RabbitAirNetwork({required this.ssid, required this.security});
}

/// The state the UI renders. Which fields are set depends on [step]:
/// [networks] at [RabbitAirProvisionStep.awaitingNetworkChoice], [thingId]
/// and [verified] at [RabbitAirProvisionStep.done], [message] at
/// [RabbitAirProvisionStep.failed].
class RabbitAirProvisionState {
  final RabbitAirProvisionStep step;
  final List<RabbitAirNetwork> networks;
  final String? thingId;
  final bool verified;
  final String? message;

  const RabbitAirProvisionState(
    this.step, {
    this.networks = const [],
    this.thingId,
    this.verified = false,
    this.message,
  });

  RabbitAirProvisionState copyWith({
    RabbitAirProvisionStep? step,
    List<RabbitAirNetwork>? networks,
    String? thingId,
    bool? verified,
    String? message,
  }) =>
      RabbitAirProvisionState(
        step ?? this.step,
        networks: networks ?? this.networks,
        thingId: thingId ?? this.thingId,
        verified: verified ?? this.verified,
        message: message ?? this.message,
      );
}

/// The best-effort LAN confirmation after the purifier leaves setup mode:
/// true when it answered on the home network with the key just pushed. The
/// default watches the network scan for the Thing ID's mDNS hostname and runs
/// a clock sync + state read; a timeout is NOT a failure — the join may still
/// be in flight — so the seam answers false rather than throwing.
typedef RabbitAirVerifier = Future<bool> Function({
  required String thingId,
  required String userKey,
});

/// Drives the Rabbit Air BLE provisioning conversation, the setup sibling of
/// [AdoptService]: what to send comes from the codec (cleartext
/// `{"id","cmd"[,"data"]}` envelopes, no timestamp, no encryption), this
/// class only sequences the moves and owns the per-connection id counter.
///
/// The conversation, as the vendor app runs it: connect and read the info
/// command (cmd 255 — `data.name` is the Thing ID, `data.mcu` the Wi-Fi
/// firmware version) with a cmd 4 sanity read, poll the network list (cmd 0)
/// until the radio has seen something, join the chosen network (cmd 1,
/// echoing its `security`), push a freshly generated user key (cmd 5, type
/// 4), leave setup mode (cmd 2) — then the unit joins Wi-Fi and advertises
/// `_rabbitair._udp.local`. The key is stored under the unit's mDNS
/// hostname so the LAN control path finds it: the Thing ID when the vendor
/// cloud flow ran, `RabbitAir-<WIFI MAC>.local` when it did not — cmd 255's
/// `data.mac` supplies the MAC (hardware-verified 2026-08-15).
///
/// The Wi-Fi firmware must be v24 or newer to accept a user key; an older
/// unit fails at [RabbitAirProvisionStep.pushingKey] with a message that
/// says so, not a generic error.
class RabbitAirProvisionService {
  final SpecCodec codec;
  final RabbitAirKeyStore keyStore;
  final RabbitAirBleLink Function() _linkFactory;
  final RabbitAirVerifier? _verifier;

  /// Between cmd 0 polls while the network list is still empty — the vendor
  /// app re-polls up to [networkPollAttempts] times.
  final Duration networkPollInterval;
  final int networkPollAttempts;

  /// How long the post-join LAN confirmation watches before settling for
  /// "done, unverified". Injectable so a test does not wait real seconds.
  final Duration verifyTimeout;

  RabbitAirProvisionService({
    required this.codec,
    required this.keyStore,
    required RabbitAirBleLink Function() linkFactory,
    RabbitAirVerifier? verifier,
    this.networkPollInterval = const Duration(milliseconds: 1500),
    this.networkPollAttempts = 15,
    this.verifyTimeout = const Duration(seconds: 50),
  })  : _linkFactory = linkFactory,
        _verifier = verifier;

  /// The oldest Wi-Fi firmware that accepts a user key (cmd 5, type 4).
  static const keyPushMinMcu = 24;

  /// Broadcast so a screen can listen per mount; sync so a state published
  /// mid-conversation is rendered from the same event-loop turn rather than
  /// racing the next step's work.
  final StreamController<RabbitAirProvisionState> _states =
      StreamController<RabbitAirProvisionState>.broadcast(sync: true);

  /// The state stream the UI renders; replays nothing, so read [state] for
  /// the current position.
  Stream<RabbitAirProvisionState> get states => _states.stream;

  RabbitAirProvisionState _state =
      const RabbitAirProvisionState(RabbitAirProvisionStep.connecting);
  RabbitAirProvisionState get state => _state;

  RabbitAirBleLink? _link;
  String? _deviceId;
  int _nextId = 0;
  String? _thingId;
  String? _fallbackHostname;
  int? _mcu;

  /// Subclasses (and test fakes) publish through here.
  void emit(RabbitAirProvisionState state) {
    _state = state;
    if (!_states.isClosed) _states.add(state);
  }

  /// Connect to [deviceId] and read as far as the network list: info, the
  /// sanity read, then the cmd 0 poll loop. Ends at
  /// [RabbitAirProvisionStep.awaitingNetworkChoice] or
  /// [RabbitAirProvisionStep.failed].
  Future<void> begin(String deviceId) async {
    emit(const RabbitAirProvisionState(RabbitAirProvisionStep.connecting));
    await cancelLink();
    _deviceId = deviceId;
    _nextId = 0;
    final link = _link = _linkFactory();
    try {
      await link.connect(deviceId);
      emit(_state.copyWith(step: RabbitAirProvisionStep.readingInfo));
      final info = await _exchange(255);
      final name = info?['name'];
      _thingId = name is String && name.isNotEmpty ? name : null;
      // A unit provisioned without the vendor cloud has no Thing ID — its
      // mDNS hostname falls back to RabbitAir-<WIFI MAC>.local, and cmd 255
      // carries that Wi-Fi MAC (hardware-verified 2026-08-15). Learn it now
      // so the key lands where the LAN control path will look.
      final mac = info?['mac'];
      _fallbackHostname = rabbitAirFallbackHostname(mac is String ? mac : null);
      final mcu = info?['mcu'];
      _mcu = mcu is int ? mcu : int.tryParse('$mcu');
      await _exchange(4); // sanity read; its state payload is unused here

      emit(_state.copyWith(step: RabbitAirProvisionStep.fetchingNetworks));
      List<RabbitAirNetwork> networks = const [];
      for (var attempt = 0; attempt < networkPollAttempts; attempt++) {
        if (attempt > 0) await Future<void>.delayed(networkPollInterval);
        networks = await _readNetworks();
        if (networks.isNotEmpty) break;
      }
      if (networks.isEmpty) {
        throw const RabbitAirProvisionException(
            'the purifier reports no Wi-Fi networks nearby. Move it closer '
            'to your router and try again.');
      }
      emit(RabbitAirProvisionState(RabbitAirProvisionStep.awaitingNetworkChoice,
          networks: networks));
    } catch (e) {
      _fail(e);
    }
  }

  /// Join the chosen network, push a fresh user key, leave setup mode, then
  /// watch for the unit on the LAN. Ends at [RabbitAirProvisionStep.done] or
  /// [RabbitAirProvisionStep.failed].
  Future<void> join({
    required String ssid,
    required String passphrase,
    required int security,
  }) async {
    try {
      emit(_state.copyWith(step: RabbitAirProvisionStep.joining));
      await _exchange(1, {
        'ssid': ssid,
        'passphrase': passphrase,
        'security': security,
      });

      final key = await codec.rabbitAirGenerateUserKey();
      emit(_state.copyWith(step: RabbitAirProvisionStep.pushingKey));
      final mcu = _mcu;
      if (mcu != null && mcu < keyPushMinMcu) {
        throw RabbitAirProvisionException(
            "this purifier's Wi-Fi firmware (v$mcu) is too old to accept a "
            'user key — update it to v$keyPushMinMcu or newer with the '
            'Rabbit Air app, then set up again.');
      }
      await _exchange(5, {'type': 4, 'value': key});

      emit(_state.copyWith(step: RabbitAirProvisionStep.leaving));
      await _exchange(2);

      // The key is the whole point of the exercise: file it where the LAN
      // control path looks — under the mDNS hostname, which is the Thing ID
      // when the vendor cloud flow ran, and RabbitAir-<WIFI MAC>.local when
      // it did not (hardware-verified). A purifier that answered cmd 255
      // with neither name nor mac falls back to the BLE identity, which
      // strands the key from LAN use but keeps BLE control working.
      final scope = _thingId ?? _fallbackHostname ?? 'ble-$_deviceId';
      await keyStore.saveUserKey(scope, key);

      var verified = false;
      final verifier = _verifier;
      final discoveryName = _thingId ?? _fallbackHostname;
      if (verifier != null && discoveryName != null) {
        emit(_state.copyWith(step: RabbitAirProvisionStep.verifying));
        try {
          verified = await verifier(thingId: discoveryName, userKey: key)
              .timeout(verifyTimeout, onTimeout: () => false);
        } catch (e) {
          Log.ble.debug('rabbit air verification failed: $e');
        }
      }
      emit(RabbitAirProvisionState(RabbitAirProvisionStep.done,
          thingId: _thingId, verified: verified));
    } catch (e) {
      _fail(e);
    }
  }

  void _fail(Object error) {
    final message = error is RabbitAirProvisionException
        ? error.message
        : 'the purifier did not answer as expected ($error). Check it is '
            'still in setup mode and try again.';
    Log.ble.warning('rabbit air provisioning failed at ${_state.step}: $error');
    emit(
        _state.copyWith(step: RabbitAirProvisionStep.failed, message: message));
  }

  /// Read the network list once: cmd 0's `data.networks`, each entry's
  /// `security` kept for the join command to echo.
  Future<List<RabbitAirNetwork>> _readNetworks() async {
    final data = await _exchange(0);
    final list = data?['networks'];
    if (list is! List) return const [];
    return [
      for (final entry in list)
        if (entry is Map && entry['ssid'] is String)
          RabbitAirNetwork(
            ssid: entry['ssid'] as String,
            security: switch (entry['security']) {
              final int s => s,
              final other => int.tryParse('$other') ?? 0,
            },
          ),
    ];
  }

  /// One cleartext setup exchange: render the envelope with the next id,
  /// send it, parse the reply's `data`. A reply carrying a truthy `error` is
  /// the device refusing the step — surfaced with the step's state, since
  /// the id is positional here (one exchange in flight).
  Future<Map<String, Object?>?> _exchange(int cmd,
      [Map<String, Object?>? data]) async {
    final link = _link;
    if (link == null) {
      throw StateError('RabbitAirProvisionService.join before begin');
    }
    final id = _nextId++;
    final envelope = await codec.renderRabbitAirSetupEnvelope(
      id: id,
      cmd: cmd,
      dataJson: data == null ? null : jsonEncode(data),
    );
    final replyBytes = await link.sendCommand(utf8.encode(envelope));
    final Object? decoded = jsonDecode(utf8.decode(replyBytes));
    if (decoded is! Map) {
      throw const RabbitAirProvisionException(
          'the purifier answered with something that is not JSON');
    }
    final error = decoded['error'];
    if (error != null && error != false) {
      throw RabbitAirProvisionException(
          'the purifier refused command $cmd (error: $error)');
    }
    final replyData = decoded['data'];
    return replyData is Map ? replyData.cast() : null;
  }

  /// Drop the BLE link without touching the published state — the screen's
  /// exit path, and [begin]'s clean slate.
  Future<void> cancelLink() async {
    final link = _link;
    _link = null;
    if (link != null) await link.disconnect();
  }

  Future<void> dispose() async {
    await cancelLink();
    await _states.close();
  }
}

/// A provisioning step failed, with text safe to show the user.
class RabbitAirProvisionException implements Exception {
  final String message;
  const RabbitAirProvisionException(this.message);
  @override
  String toString() => 'RabbitAirProvisionException: $message';
}

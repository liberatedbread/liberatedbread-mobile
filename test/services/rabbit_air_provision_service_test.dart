// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Unit tests for the Rabbit Air BLE provisioning conversation: the command
// sequence and id counter, the cmd 0 re-poll, the key push's firmware gate,
// and where the key lands. Driven against a scripted link — no radio, no
// codec native library (the fake codec renders the real cleartext envelopes).

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_ble_client.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_key_store.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_provision_service.dart';

import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

/// A stand-in purifier in setup mode: answers each cleartext setup command
/// from a script, recording every envelope it was sent.
class _FakeLink implements RabbitAirBleLink {
  String? thingId = 'abcdef1234_000000000000000000';
  String? mac = 'a1:b2:c3:d4:e5:f6';
  int mcu = 24;
  int emptyNetworkPolls = 0;
  bool refuseCmd5 = false;

  /// The leave-setup ack never arrives: cmd 2 fails the way the client's
  /// response window does when the indication is lost.
  bool failCmd2 = false;

  /// When set, cmd 2 is held open on this completer — [disconnect] fails it
  /// the way [RabbitAirBleClient.disconnect] fails an exchange in flight.
  Completer<List<int>>? holdCmd2;

  final sent = <Map<String, Object?>>[];
  int connects = 0;
  int disconnects = 0;
  int _polls = 0;

  List<int> get cmds => [for (final request in sent) request['cmd'] as int];

  static List<int> _json(Map<String, Object?> body) =>
      utf8.encode(jsonEncode(body));

  @override
  Future<void> connect(String deviceId) async {
    connects++;
  }

  @override
  Future<void> disconnect() async {
    disconnects++;
    final held = holdCmd2;
    if (held != null && !held.isCompleted) {
      held.completeError(
          const RabbitAirBleException('disconnected mid-exchange'));
    }
  }

  @override
  Future<List<int>> sendCommand(List<int> payload) async {
    final request = jsonDecode(utf8.decode(payload)) as Map<String, Object?>;
    sent.add(request);
    final id = request['id'];
    switch (request['cmd']) {
      case 255:
        return _json({
          'id': id,
          'data': {'name': thingId, 'mcu': mcu, 'mac': mac},
        });
      case 4:
        return _json({'id': id, 'data': <String, Object?>{}});
      case 0:
        _polls++;
        return _json({
          'id': id,
          'data': {
            'networks': _polls > emptyNetworkPolls
                ? [
                    {'ssid': 'Cottage', 'security': 3},
                  ]
                : <Object?>[],
          },
        });
      case 1:
        return _json({'id': id});
      case 5:
        if (refuseCmd5) return _json({'id': id, 'error': 3});
        return _json({'id': id});
      case 2:
        if (failCmd2) {
          throw const RabbitAirBleException(
              'the purifier did not answer within 7s');
        }
        final held = holdCmd2;
        if (held != null) return held.future;
        return _json({'id': id});
    }
    throw StateError('unexpected command ${request['cmd']}');
  }
}

void main() {
  late _FakeLink link;
  late InMemorySettingsStore store;
  late RabbitAirProvisionService service;
  late List<RabbitAirProvisionState> states;

  void setUpService({
    bool verified = true,
    int networkPollAttempts = 15,
  }) {
    link = _FakeLink();
    store = InMemorySettingsStore();
    states = [];
    service = RabbitAirProvisionService(
      codec: FakeSpecCodec(),
      keyStore: RabbitAirKeyStore(store),
      linkFactory: () => link,
      verifier: ({required thingId, required userKey}) async => verified,
      networkPollInterval: Duration.zero,
      networkPollAttempts: networkPollAttempts,
      verifyTimeout: const Duration(seconds: 2),
    );
    service.states.listen(states.add);
  }

  tearDown(() => service.dispose());

  test(
      'the happy path walks the whole conversation and files the key under '
      'the Thing ID', () async {
    setUpService();
    await service.begin('01');

    expect(service.state.step, RabbitAirProvisionStep.awaitingNetworkChoice);
    expect(service.state.networks.single.ssid, 'Cottage');
    expect(service.state.networks.single.security, 3);

    await service.join(ssid: 'Cottage', passphrase: 'hunter2', security: 3);

    expect(service.state.step, RabbitAirProvisionStep.done);
    expect(service.state.thingId, 'abcdef1234_000000000000000000');
    expect(service.state.verified, isTrue);

    // The vendor conversation: info, sanity read, network list, join, key
    // push, leave — with the id counter starting at 0 and climbing.
    expect(link.cmds, [255, 4, 0, 1, 5, 2]);
    expect(link.sent.first['id'], 0);
    expect(link.sent.last['id'], 5);

    // The join echoes the network's security value verbatim.
    expect(link.sent[3]['data'],
        {'ssid': 'Cottage', 'passphrase': 'hunter2', 'security': 3});

    // The pushed key is the fake codec's documented 32-char hex, filed where
    // the LAN control path looks: under the Thing ID.
    final key = link.sent[4]['data']! as Map<String, Object?>;
    expect(key['type'], 4);
    expect(key['value'], matches(RegExp(r'^[0-9A-F]{32}$')));
    expect(
        await RabbitAirKeyStore(store).userKey('abcdef1234_000000000000000000'),
        isNotNull);
  });

  test('cmd 0 re-polls until the network list is non-empty', () async {
    setUpService();
    link.emptyNetworkPolls = 2;

    await service.begin('01');

    expect(service.state.step, RabbitAirProvisionStep.awaitingNetworkChoice);
    expect(link.cmds.where((c) => c == 0).length, 3);
  });

  test('a purifier that never sees networks fails at fetchingNetworks',
      () async {
    setUpService(networkPollAttempts: 3);
    link.emptyNetworkPolls = 99;

    await service.begin('01');

    expect(service.state.step, RabbitAirProvisionStep.failed);
    expect(service.state.message, contains('no Wi-Fi networks'));
    expect(link.cmds.where((c) => c == 0).length, 3);
  });

  test(
      'the key push is gated on Wi-Fi firmware v24, with a message that '
      'says so', () async {
    setUpService();
    link.mcu = 23;

    await service.begin('01');
    await service.join(ssid: 'Cottage', passphrase: 'hunter2', security: 3);

    expect(service.state.step, RabbitAirProvisionStep.failed);
    expect(service.state.message, contains('too old'));
    expect(service.state.message, contains('v23'));
    // The key was never pushed and never stored.
    expect(link.cmds, isNot(contains(5)));
    expect(store.values, isEmpty);
  });

  test('a refused key push fails cleanly and stores nothing', () async {
    setUpService();
    link.refuseCmd5 = true;

    await service.begin('01');
    await service.join(ssid: 'Cottage', passphrase: 'hunter2', security: 3);

    expect(service.state.step, RabbitAirProvisionStep.failed);
    expect(service.state.message, contains('refused'));
    expect(store.values, isEmpty);
    // And the purifier was never told to leave setup mode.
    expect(link.cmds, isNot(contains(2)));
  });

  /// Once cmd 5 is acknowledged the purifier REQUIRES the key, and the key
  /// exists nowhere but in this join. It must be on disk before cmd 2 goes
  /// out: with the old order a lost leave-setup ack left a unit that had left
  /// setup mode with a key nobody stored — a factory reset to recover.
  test('the key is stored before leaving setup, so a lost cmd 2 ack keeps it',
      () async {
    setUpService();
    link.failCmd2 = true;

    await service.begin('01');
    await service.join(ssid: 'Cottage', passphrase: 'hunter2', security: 3);

    expect(service.state.step, RabbitAirProvisionStep.failed);
    expect(states.map((s) => s.step), contains(RabbitAirProvisionStep.leaving),
        reason: 'the failure is reported at the step that failed');
    expect(link.cmds, contains(5), reason: 'the purifier holds the key');
    expect(
        await RabbitAirKeyStore(store).userKey('abcdef1234_000000000000000000'),
        isNotNull,
        reason: 'the key the purifier now requires must not be lost with it');
  });

  /// The setup screen's dispose drops the link (cancelLink) — backing out
  /// during "leaving" fails the exchange in flight exactly like a lost ack.
  test('backing out while leaving setup still leaves the key stored', () async {
    setUpService();
    link.holdCmd2 = Completer<List<int>>();

    await service.begin('01');
    final joining =
        service.join(ssid: 'Cottage', passphrase: 'hunter2', security: 3);
    await pumpEventQueue();
    expect(link.cmds, contains(2), reason: 'held at the leave-setup step');

    await service.cancelLink();
    await joining;

    expect(service.state.step, RabbitAirProvisionStep.failed);
    expect(
        await RabbitAirKeyStore(store).userKey('abcdef1234_000000000000000000'),
        isNotNull);
  });

  test('an unconfirmed join still ends done, verified false', () async {
    setUpService(verified: false);

    await service.begin('01');
    await service.join(ssid: 'Cottage', passphrase: 'hunter2', security: 3);

    expect(service.state.step, RabbitAirProvisionStep.done);
    expect(service.state.verified, isFalse);
    // The key is filed either way — the join may simply be slow.
    expect(
        await RabbitAirKeyStore(store).userKey('abcdef1234_000000000000000000'),
        isNotNull);
  });

  test(
      'a purifier with no Thing ID files the key under its RabbitAir-<MAC> '
      'fallback hostname', () async {
    setUpService();
    link.thingId = '';

    await service.begin('01');
    await service.join(ssid: 'Cottage', passphrase: 'hunter2', security: 3);

    expect(service.state.step, RabbitAirProvisionStep.done);
    expect(service.state.thingId, isNull);
    // The unit announces RabbitAir-<WIFI MAC>.local (hardware-verified), so
    // the key lands exactly where the LAN control path will look it up —
    // and LAN verification runs against that hostname.
    expect(
        await RabbitAirKeyStore(store).userKey('RabbitAir-A1B2C3D4E5F6.local'),
        isNotNull);
    expect(service.state.verified, isTrue);
  });

  test('a purifier with neither Thing ID nor MAC falls back to the BLE scope',
      () async {
    setUpService();
    link.thingId = '';
    link.mac = null;

    await service.begin('01');
    await service.join(ssid: 'Cottage', passphrase: 'hunter2', security: 3);

    expect(service.state.step, RabbitAirProvisionStep.done);
    expect(service.state.thingId, isNull);
    // Unverifiable without a hostname — done, not failed.
    expect(service.state.verified, isFalse);
    expect(await RabbitAirKeyStore(store).userKey('ble-01'), isNotNull);
  });

  test('the state stream narrates the stages in order', () async {
    setUpService();
    await service.begin('01');
    await service.join(ssid: 'Cottage', passphrase: 'hunter2', security: 3);

    expect(
      states.map((s) => s.step),
      containsAllInOrder([
        RabbitAirProvisionStep.connecting,
        RabbitAirProvisionStep.readingInfo,
        RabbitAirProvisionStep.fetchingNetworks,
        RabbitAirProvisionStep.awaitingNetworkChoice,
        RabbitAirProvisionStep.joining,
        RabbitAirProvisionStep.pushingKey,
        RabbitAirProvisionStep.leaving,
        RabbitAirProvisionStep.verifying,
        RabbitAirProvisionStep.done,
      ]),
    );
  });
}

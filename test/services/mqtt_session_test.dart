// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The device-blind MQTT session. What the Roomba's own suite cannot cover: the
// cases a spec-driven device hits and a robot never does — a broker that wants
// no credentials, a named topic rather than `#`, a publish with a rendered
// payload, and the generic wording of a refusal.
//
// The Roomba suite still owns the session's hard parts (partial frames, the
// chunk pump, hang-ups) because it exercised them first and they are the same
// code; duplicating them here would be two tests for one behaviour.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/mqtt_session.dart';

import '../fakes/fake_spec_codec.dart';

/// A scripted broker on the other end of the socket seam.
class _ScriptedBroker implements MqttSocket {
  final _out = StreamController<Uint8List>();
  final List<List<int>> written = [];
  var closed = false;

  @override
  Stream<Uint8List> get incoming => _out.stream;

  @override
  void add(List<int> bytes) => written.add(List.of(bytes));

  @override
  Future<void> close() async {
    closed = true;
    if (!_out.isClosed) await _out.close();
  }

  void send(List<int> bytes) => _out.add(Uint8List.fromList(bytes));

  Future<void> hangUp() async {
    if (!_out.isClosed) await _out.close();
  }
}

void main() {
  late FakeSpecCodec codec;

  setUp(() => codec = FakeSpecCodec());

  /// A session already past CONNACK, with the broker that accepted it.
  Future<(MqttSession, _ScriptedBroker)> connected({
    String clientId = 'client-1',
    String? username = 'user',
    String? password = 'secret',
  }) async {
    final broker = _ScriptedBroker();
    final session = MqttSession(
      codec: codec,
      connect: (host, port, timeout) async {
        // CONNACK, accepted — scheduled so it lands after the CONNECT write.
        scheduleMicrotask(() => broker.send([0x20, 0x02, 0x00, 0x00]));
        return broker;
      },
    );
    await session.connect('10.0.0.5', 1883,
        clientId: clientId, username: username, password: password);
    return (session, broker);
  }

  test('connects with the credentials it was given', () async {
    final (session, _) = await connected();
    addTearDown(session.dispose);

    expect(session.isConnected, isTrue);
    expect(codec.mqttConnectArgs?.clientId, 'client-1');
    expect(codec.mqttConnectArgs?.username, 'user');
    expect(codec.mqttConnectArgs?.password, 'secret');
  });

  /// A Dyson purifier's broker is on 1883 in the clear and a Hisense set's
  /// takes a static login; neither is the Roomba's shape, and a CONNECT
  /// carrying two empty strings is refused by some brokers and read as an
  /// empty username by others.
  test('a broker that wants no credentials gets a CONNECT that says so',
      () async {
    final (session, broker) = await connected(username: null, password: null);
    addTearDown(session.dispose);

    expect(codec.mqttConnectArgs?.username, isNull);
    expect(codec.mqttConnectArgs?.password, isNull);
    // Flags byte: clean session only, neither credential flag set.
    expect(broker.written.first[9], 0x02);
  });

  test('subscribes to the topic it is asked for, not a wildcard', () async {
    final (session, broker) = await connected();
    addTearDown(session.dispose);

    await session.subscribe('438/SERIAL/status/current');
    expect(
      broker.written.last,
      await codec.mqttSubscribePacket(
          topic: '438/SERIAL/status/current', packetId: 1),
    );
  });

  test('publishes a topic and payload verbatim', () async {
    final (session, broker) = await connected();
    addTearDown(session.dispose);

    await session.publish(
        '/remoteapp/tv/remote_service/c/actions/sendkey', 'KEY_POWER');
    expect(
      broker.written.last,
      await codec.mqttPublishPacket(
        topic: '/remoteapp/tv/remote_service/c/actions/sendkey',
        payload: 'KEY_POWER',
      ),
    );
  });

  /// The session hands PUBLISHes on unchanged: what a payload MEANS is the
  /// caller's, read from the spec. A device-specific flattening here is
  /// exactly the drift this extraction removed.
  test('delivers what the broker published, topic and all', () async {
    final (session, broker) = await connected();
    addTearDown(session.dispose);

    final received = session.messages.first;
    broker.send(await codec.mqttPublishPacket(
      topic: 'state/current',
      payload: '{"fpwr":"ON"}',
    ));

    final message = await received;
    expect(message.topic, 'state/current');
    expect(message.payload, '{"fpwr":"ON"}');
  });

  test('a refusal names the code and does not read as a network problem',
      () async {
    final broker = _ScriptedBroker();
    final session = MqttSession(
      codec: codec,
      connect: (host, port, timeout) async {
        // 4 = bad username or password.
        scheduleMicrotask(() => broker.send([0x20, 0x02, 0x00, 0x04]));
        return broker;
      },
    );
    addTearDown(session.dispose);

    await expectLater(
      session.connect('10.0.0.5', 1883, clientId: 'c'),
      throwsA(isA<MqttRefusedException>()
          .having((e) => e.code, 'code', 4)
          .having((e) => e.message, 'message', contains('username'))),
    );
    // The socket is released, so a later connect() genuinely reconnects
    // instead of handing back a session the broker never authenticated.
    expect(session.isConnected, isFalse);
  });

  test('a hang-up surfaces on the message stream', () async {
    final (session, broker) = await connected();
    addTearDown(session.dispose);

    final failure = session.messages.first;
    await broker.hangUp();

    await expectLater(failure, throwsA(isA<MqttConnectionException>()));
  });

  /// A device that knows what its own hang-up means says so. The Roomba does:
  /// it serves one local client, so a close means something else took it.
  test('a caller can say what a hang-up means', () async {
    final (session, broker) = await connected();
    addTearDown(session.dispose);
    session.onHangUp =
        () => const MqttConnectionException('Something else took the device.');

    final failure = session.messages.first;
    await broker.hangUp();

    await expectLater(
      failure,
      throwsA(isA<MqttConnectionException>().having(
          (e) => e.message, 'message', 'Something else took the device.')),
    );
  });

  test('publishing before connecting is refused, not silently dropped',
      () async {
    final session = MqttSession(codec: codec);
    addTearDown(session.dispose);

    await expectLater(
      session.publish('t', 'p'),
      throwsA(isA<MqttConnectionException>()),
    );
  });

  test('close is idempotent and safe on a session that never connected',
      () async {
    final session = MqttSession(codec: codec);
    await session.close();
    await session.close();
    expect(session.isConnected, isFalse);
    await session.dispose();
  });

  test('close sends DISCONNECT and lets go of the socket', () async {
    final (session, broker) = await connected();

    await session.close();
    expect(broker.written.last, await codec.mqttDisconnectPacket());
    expect(broker.closed, isTrue);
    expect(session.isConnected, isFalse);
    await session.dispose();
  });
}

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
import 'dart:io';
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

  /// A broker that accepts TCP and then says nothing is a different problem
  /// from one that never accepted, and callers translate it — the Roomba's
  /// means the iRobot app holds the one local slot. Flagged rather than left
  /// to the message text so no caller has to string-match this wording.
  test('a broker that never sends CONNACK times out, flagged as such',
      () async {
    final broker = _ScriptedBroker();
    final session = MqttSession(
      codec: codec,
      // Accepts the socket, then silence.
      connect: (host, port, timeout) async => broker,
      ackWait: const Duration(milliseconds: 50),
    );
    addTearDown(session.dispose);

    await expectLater(
      session.connect('10.0.0.5', 1883, clientId: 'c'),
      throwsA(isA<MqttConnectionException>()
          .having((e) => e.ackTimedOut, 'ackTimedOut', isTrue)),
    );
    // The socket is released, so a later connect really reconnects rather
    // than returning early over a session the broker never authenticated.
    expect(session.isConnected, isFalse);
    expect(broker.closed, isTrue);
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

  /// The hang-up must not just SURFACE — it must tear the session down, or
  /// `isConnected` stays true and every later send publishes into a corpse
  /// while the screen claims a live stream. The next send's reopen depends
  /// on this.
  test('a hang-up tears the session down and the next connect reopens',
      () async {
    final brokers = <_ScriptedBroker>[];
    final session = MqttSession(
      codec: codec,
      connect: (host, port, timeout) async {
        // Closed by the session (or by the hang-up the test performs).
        // ignore: close_sinks
        final broker = _ScriptedBroker();
        brokers.add(broker);
        scheduleMicrotask(() => broker.send([0x20, 0x02, 0x00, 0x00]));
        return broker;
      },
    );
    addTearDown(session.dispose);
    await session.connect('10.0.0.5', 1883, clientId: 'c');
    final errors = <Object>[];
    final sub = session.messages.listen((_) {}, onError: errors.add);
    addTearDown(sub.cancel);

    await brokers.single.hangUp();
    await pumpEventQueue();

    expect(session.isConnected, isFalse,
        reason: 'a dead socket must not be served to the next send');
    expect(errors, hasLength(1));

    await session.connect('10.0.0.5', 1883, clientId: 'c');
    expect(brokers, hasLength(2), reason: 'the reopen dialled a fresh socket');
    await session.publish('t', 'p');
    expect(brokers.last.written, isNotEmpty);
  });

  /// One banner per failure, not one per aftermath event: the queued chunks
  /// draining after a failure must not each add their own error.
  test('the receive bound fails the session once and tears it down', () async {
    final (session, broker) = await connected();
    addTearDown(session.dispose);
    final errors = <Object>[];
    final sub = session.messages.listen((_) {}, onError: errors.add);
    addTearDown(sub.cancel);

    broker.send(List.filled((1 << 20) + 1, 0));
    broker.send(List.filled(8, 0));
    await pumpEventQueue();

    expect(session.isConnected, isFalse);
    expect(errors, hasLength(1),
        reason: 'aftermath chunks must not re-report the failure');
  });

  /// A wedged peer with a zero receive window never drains a flush. close()
  /// waits a bounded courtesy interval for the DISCONNECT to leave, then
  /// destroys anyway — unbounded, this await hung connect()'s own error path.
  test('close gives up on a flush the peer never drains', () async {
    // destroy() is this socket's close, and the assertion below proves it ran.
    // ignore: close_sinks
    final socket = _WedgedSocket();
    final adapter =
        SocketAdapter(socket, flushDeadline: const Duration(milliseconds: 50));

    await adapter.close().timeout(const Duration(seconds: 5));

    expect(socket.destroyed, isTrue,
        reason: 'destroy must follow even when flush never completes');
  });

  group('mqttConnectorFor', () {
    // The connector production actually uses is chosen by port (the sender
    // injects none), so assert the choice by function identity — a plaintext
    // 1883 broker (Dyson) must not get the TLS handshake that used to kill it.
    test('port 1883 gets the plaintext connector', () {
      expect(identical(mqttConnectorFor(1883), plainConnect), isTrue);
    });

    test('TLS broker ports keep the TLS connector', () {
      // 8883 = Roomba/Bambu (TLS today), 36669 = Hisense TLS generations.
      expect(identical(mqttConnectorFor(8883), tlsConnect), isTrue);
      expect(identical(mqttConnectorFor(36669), tlsConnect), isTrue);
    });
  });
}

/// A socket whose flush never completes — the shape of a wedged peer with a
/// zero receive window. Only the members `SocketAdapter.close` touches are
/// real; anything else failing loudly is a feature.
class _WedgedSocket implements Socket {
  var destroyed = false;

  @override
  Future<void> flush() => Completer<void>().future;

  @override
  void destroy() => destroyed = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

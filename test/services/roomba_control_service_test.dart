// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/roomba_control_service.dart';
import 'package:liberated_bread_mobile/services/roomba_controller.dart';
import 'package:liberated_bread_mobile/services/roomba_credential_store.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

/// A scripted robot on the other end of the TLS seam.
///
/// The fake codec carries the same MQTT framing as the Rust codec, so a whole
/// connect → subscribe → publish → parse cycle runs here with no native
/// library and no socket — the same trick `kasa_control_service_test` plays
/// with the XOR cipher.
class _ScriptedRobot implements RoombaTlsSocket {
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

  /// Push bytes as if the robot sent them.
  void send(List<int> bytes) => _out.add(Uint8List.fromList(bytes));

  /// Push bytes one at a time — the worst case a TLS stream can produce, and
  /// the reason the parser reports how much it consumed.
  Future<void> sendByteByByte(List<int> bytes) async {
    for (final byte in bytes) {
      _out.add(Uint8List.fromList([byte]));
      await Future<void>.delayed(Duration.zero);
    }
  }

  Future<void> hangUp() async {
    if (!_out.isClosed) await _out.close();
  }
}

/// A codec whose parse takes a real turn of the event loop, like the one in
/// production does.
///
/// [FakeSpecCodec.roombaParseIncoming] is `async` but completes within a single
/// microtask, so a second chunk can never arrive mid-decode and the fake hides
/// concurrency bugs the real codec exposes. The real one is a
/// flutter_rust_bridge call that crosses to a Rust worker, which takes several
/// turns. This models that, and nothing else.
class _SlowParseCodec extends FakeSpecCodec {
  @override
  Future<RoombaParsedDto> roombaParseIncoming({required List<int> buffer}) async {
    // A timer, not a microtask: it puts the completion behind pending stream
    // deliveries, which is exactly where the real codec's completion sits.
    await Future<void>.delayed(Duration.zero);
    return super.roombaParseIncoming(buffer: buffer);
  }
}

/// A disclosure reply whose password starts at [offset] of the whole reply,
/// with non-printable filler in the gap — the shape the spec's extraction rule
/// is stated against.
List<int> _passwordReply(String password, {int offset = 13}) {
  final encoded = utf8.encode(password);
  final gap = offset - 2;
  return [
    0xf0,
    encoded.length + gap,
    for (var i = 1; i <= gap; i++) i % 0x20,
    ...encoded,
  ];
}

void main() {
  final codec = FakeSpecCodec();
  const password = ':1:1486937829:gktkDoYpWaDxCfGh';

  group('RoombaPasswordService', () {
    test('writes the probe and returns the whole disclosed password', () async {
      final robot = _ScriptedRobot();
      String? sawHost;
      int? sawPort;

      final service = RoombaPasswordService(
        codec: codec,
        connect: (host, port, timeout) async {
          sawHost = host;
          sawPort = port;
          scheduleMicrotask(() => robot.send(_passwordReply(password)));
          return robot;
        },
      );

      expect(await service.fetchPassword('10.0.0.7'), password);
      expect(sawHost, '10.0.0.7');
      expect(sawPort, roombaPort, reason: '8883, the robot\'s own broker port');
      expect(robot.written.single, await codec.roombaPasswordProbe());
      expect(robot.closed, isTrue,
          reason: 'the disclosure socket is released either way');
    });

    /// The inviting mistake: Roomba passwords start with ':' and contain ':',
    /// and a client that trims or splits one sends a credential the broker
    /// refuses without explaining why.
    test('keeps the leading colon and every separator', () async {
      final robot = _ScriptedRobot();
      final service = RoombaPasswordService(
        codec: codec,
        connect: (_, __, ___) async {
          scheduleMicrotask(() => robot.send(_passwordReply(password)));
          return robot;
        },
      );

      final recovered = await service.fetchPassword('10.0.0.7');
      expect(recovered.startsWith(':'), isTrue);
      expect(':'.allMatches(recovered).length, 3);
    });

    /// j-series firmware is reported to reset the first connection or two
    /// before answering. A client that gives up after one reset tells the user
    /// their robot cannot do something it can.
    test('retries a refused connection inside the disclosure window', () async {
      final attempts = <int>[];
      var connects = 0;

      final service = RoombaPasswordService(
        codec: codec,
        connect: (_, __, ___) async {
          connects++;
          if (connects < 3) {
            throw const RoombaConnectionException('connection reset');
          }
          final robot = _ScriptedRobot();
          scheduleMicrotask(() => robot.send(_passwordReply(password)));
          return robot;
        },
      );

      final recovered = await service.fetchPassword(
        '10.0.0.7',
        onAttempt: attempts.add,
      );

      expect(recovered, password);
      expect(connects, 3);
      expect(attempts, [1, 2, 3],
          reason: 'the wizard drives progress off this');
    });

    /// A cipher failure fails identically every time, so retrying only burns
    /// the user's short disclosure window. It has to escape the loop.
    test('does not retry a legacy-TLS failure, and says what it is', () async {
      var connects = 0;
      final service = RoombaPasswordService(
        codec: codec,
        connect: (_, __, ___) async {
          connects++;
          throw const RoombaConnectionException(
            'handshake failed',
            legacyTlsSuspected: true,
          );
        },
      );

      await expectLater(
        service.fetchPassword('10.0.0.7'),
        throwsA(isA<RoombaConnectionException>()
            .having((e) => e.legacyTlsSuspected, 'legacyTlsSuspected', isTrue)),
      );
      expect(connects, 1, reason: 'retrying a cipher gap cannot help');
    });

    /// A model that cannot disclose locally will never disclose locally, so
    /// spending four retry intervals on it is only a slower way to reach the
    /// same dead end. The Rust codec names the account route in that error;
    /// `rust/tests/roomba_control.rs` pins the other end of this coupling.
    test('does not retry a robot that says it cannot disclose locally',
        () async {
      var connects = 0;
      final service = RoombaPasswordService(
        codec: codec,
        connect: (_, __, ___) async {
          connects++;
          final robot = _ScriptedRobot();
          // The documented "unsupported" reply.
          scheduleMicrotask(
              () => robot.send([0xf0, 0x05, 0xef, 0xcc, 0x3b, 0x29, 0x03]));
          return robot;
        },
      );

      await expectLater(
        service.fetchPassword('10.0.0.7'),
        throwsA(isA<RoombaPasswordException>()
            .having((e) => e.retryable, 'retryable', isFalse)
            .having((e) => e.message, 'message', contains('account'))),
      );
      expect(connects, 1, reason: 'no point asking again');
    });

    /// The failure users actually hit: they did not hold HOME long enough. The
    /// message has to name that, or they go looking at their network.
    test('a short reply reports that the robot was not disclosing', () async {
      final service = RoombaPasswordService(
        codec: codec,
        connect: (_, __, ___) async {
          final robot = _ScriptedRobot();
          // A COMPLETE frame that is simply too short to carry a password:
          // 0xf0, a declared payload length of 1, then that one byte. The read
          // loop finishes immediately and the length check rejects it — which
          // is the real robot's behaviour, and keeps this test off the
          // ten-second socket timeout.
          scheduleMicrotask(() => robot.send([0xf0, 0x01, 0x00]));
          return robot;
        },
      );

      await expectLater(
        service.fetchPassword('10.0.0.7', attempts: 2),
        throwsA(isA<RoombaPasswordException>()
            .having((e) => e.message, 'message', contains('HOME'))),
      );
    });
  });

  group('RoombaMqttClient', () {
    const credentials = RoombaCredentials(
      blid: '3193C60472324700',
      password: password,
    );

    Future<(RoombaMqttClient, _ScriptedRobot)> connected(
        {SpecCodec? using}) async {
      final robot = _ScriptedRobot();
      final client = RoombaMqttClient(
        codec: using ?? codec,
        connect: (_, __, ___) async {
          // CONNACK, accepted.
          scheduleMicrotask(() => robot.send([0x20, 0x02, 0x00, 0x00]));
          return robot;
        },
      );
      await client.connect('10.0.0.7', credentials);
      return (client, robot);
    }

    test('sends CONNECT then subscribes to everything', () async {
      final (client, robot) = await connected();
      addTearDown(client.dispose);

      expect(
        robot.written.first,
        await codec.roombaConnectPacket(
          blid: credentials.blid,
          password: credentials.password,
        ),
      );
      // '#', not a named topic: which shape a firmware publishes locally is
      // not settled, so subscribing to everything is the only reading that
      // works on all of them.
      expect(
          robot.written[1],
          await codec.roombaSubscribePacket(
            topic: '#',
            packetId: 1,
          ));
      expect(client.isConnected, isTrue);
    });

    test('publishes a rendered command with the caller\'s clock', () async {
      final (client, robot) = await connected();
      addTearDown(client.dispose);

      final at = DateTime.utc(2025, 8, 13, 23, 20);
      await client.sendCommand(
        specYaml: 'unused-by-the-fake',
        commandName: 'clean',
        now: at,
      );

      final expected = await codec.roombaPublishPacket(
        topic: 'cmd',
        payload: jsonEncode({
          'command': 'clean',
          'time': at.millisecondsSinceEpoch ~/ 1000,
          'initiator': 'localApp',
        }),
      );
      expect(robot.written.last, expected);
    });

    /// A TLS stream splits and coalesces wherever it likes. Treating one read
    /// as one packet is the bug the parser's consumed count exists to prevent,
    /// and this drives the pathological case.
    test('reassembles a state push delivered one byte at a time', () async {
      final (client, robot) = await connected();
      addTearDown(client.dispose);

      const payload = '{"state":{"reported":{"batPct":94,'
          '"bin":{"full":false},'
          '"cleanMissionStatus":{"phase":"run"}}}}';
      final push = await codec.roombaPublishPacket(
        topic: 'delta',
        payload: payload,
      );

      final seen = client.state.first;
      await robot.sendByteByByte(push);

      final fields = await seen;
      expect(fields['state.reported.batPct'], '94');
      expect(fields['state.reported.cleanMissionStatus.phase'], 'run');
      // false -> "0", so the binary_sensor's `on_when: nonzero` reads it.
      expect(fields['state.reported.bin.full'], '0');
    });

    /// Two chunks arriving before the first has finished decoding.
    ///
    /// `Stream.listen` does not await an async callback, so the receive path
    /// has to serialize itself. Without that, both chunks reach the decoder
    /// and interleave at its await: each snapshots the shared buffer, then
    /// each trims what IT consumed from a buffer the other already trimmed.
    /// The second trim runs off the end — and because a stream discards the
    /// future its callback returns, the `RangeError` never surfaces anywhere.
    /// The second push is just lost. So this asserts the COUNT: contents alone
    /// pass happily while half the robot's state quietly goes missing.
    ///
    /// Pushing back-to-back with no await between the two `add`s is what makes
    /// the events land in the same turn; a delay would hide the bug entirely.
    test('two pushes arriving together are decoded once each, in order',
        () async {
      final (client, robot) = await connected(using: _SlowParseCodec());
      addTearDown(client.dispose);

      String pushFor(int battery, String phase) => '{"state":{"reported":'
          '{"batPct":$battery,"cleanMissionStatus":{"phase":"$phase"}}}}';

      final first =
          await codec.roombaPublishPacket(topic: 'delta', payload: pushFor(94, 'run'));
      final second =
          await codec.roombaPublishPacket(topic: 'delta', payload: pushFor(93, 'hmMidMsn'));

      final seen = <Map<String, String>>[];
      final errors = <Object>[];
      final sub = client.state.listen(seen.add, onError: errors.add);
      addTearDown(sub.cancel);

      robot.send(first);
      robot.send(second);
      // Let the whole chain drain — several microtask turns, since each chunk
      // awaits the codec.
      for (var i = 0; i < 10; i++) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(errors, isEmpty);
      expect(seen, hasLength(2),
          reason: 'a push was dropped or decoded twice');
      expect(seen[0]['state.reported.batPct'], '94');
      expect(seen[1]['state.reported.batPct'], '93');
      expect(seen[1]['state.reported.cleanMissionStatus.phase'], 'hmMidMsn');
    });

    /// A wrong password must not read like an unreachable robot: the fix is to
    /// redo the handshake, not to check the Wi-Fi.
    test('a refused login throws with the reason, not a timeout', () async {
      final robot = _ScriptedRobot();
      final client = RoombaMqttClient(
        codec: codec,
        connect: (_, __, ___) async {
          // 4 = bad username or password.
          scheduleMicrotask(() => robot.send([0x20, 0x02, 0x00, 0x04]));
          return robot;
        },
      );
      addTearDown(client.dispose);

      await expectLater(
        client.connect('10.0.0.7', credentials),
        throwsA(isA<RoombaAuthException>()
            .having((e) => e.code, 'code', 4)
            .having((e) => e.toString(), 'message', contains('factory reset'))),
      );
    });

    /// The robot only accepts `dock` from a paused or stopped state, so the
    /// direct path owes the same stop-then-dock sequence the rest980 path
    /// does. Asserted on the wire, because the bug this prevents is a
    /// controller forgetting to expand it.
    test('Dock publishes stop before dock', () async {
      final (client, robot) = await connected();
      addTearDown(client.dispose);

      final controller = DirectRoombaController(
        client: client,
        specYaml: 'unused-by-the-fake',
        host: '10.0.0.7',
        credentials: credentials,
      );

      final before = robot.written.length;
      await controller.sendCommand('dock');

      final commands = <String>[];
      for (final packet in robot.written.sublist(before)) {
        final parsed = await codec.roombaParseIncoming(buffer: packet);
        for (final message in parsed.packets) {
          if (message.kind != 'publish') continue;
          expect(message.topic, 'cmd');
          commands
              .add((jsonDecode(message.payload) as Map)['command'] as String);
        }
      }

      expect(commands, ['stop', 'dock'],
          reason: 'a send-home button that only sends dock does nothing '
              'while the robot is cleaning');
    });

    /// The robot serves one client at a time, so letting go is part of the
    /// protocol rather than tidiness — and DISCONNECT is how it is done
    /// politely.
    test('close sends DISCONNECT and releases the socket', () async {
      final (client, robot) = await connected();

      await client.close();

      expect(robot.written.last, await codec.roombaDisconnectPacket());
      expect(robot.closed, isTrue);
      expect(client.isConnected, isFalse);

      // Idempotent: every path out of the control screen calls it.
      await client.close();
      await client.dispose();
    });

    test('a robot that hangs up surfaces on the state stream', () async {
      final (client, robot) = await connected();
      addTearDown(client.dispose);

      final failure = client.state.first;
      await robot.hangUp();

      await expectLater(failure, throwsA(isA<RoombaConnectionException>()));
    });
  });

  group('the real connector', () {
    /// Nothing to connect to, so this exercises the error mapping rather than
    /// the happy path — specifically that an unreachable port names the 2025
    /// models, which refuse 8883 outright and are the likeliest cause.
    test('an unreachable robot is a connection error, not a crash', () async {
      final service = RoombaPasswordService(codec: codec);
      await expectLater(
        service.fetchPassword('127.0.0.1', attempts: 1, port: 1),
        throwsA(anyOf(
          isA<RoombaPasswordException>(),
          isA<RoombaConnectionException>(),
        )),
      );
    }, onPlatform: const {
      'browser': Skip('dart:io sockets are not available on the web'),
    });
  });

  test('SocketException maps to a message naming the cloud-only models', () {
    // The mapping itself, without a socket: the text is what the user reads
    // when a 2025-line robot refuses the port, and it should not read as a
    // network fault.
    const error = RoombaConnectionException(
      'Could not reach 10.0.0.7:8883 — Connection refused. A 2025-model '
      'Roomba (105, 205, Combo 405) refuses this port outright: those have no '
      'local broker.',
    );
    expect(error.toString(), contains('2025-model'));
    expect(error.legacyTlsSuspected, isFalse);
  });
}

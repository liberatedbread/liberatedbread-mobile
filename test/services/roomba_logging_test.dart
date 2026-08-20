// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// What the Roomba paths are allowed to say out loud.
//
// Two things are being held at once. The transports SHOULD log — with three of
// them now, "which path did it even use" is the first question when a robot
// goes quiet, and until recently the answer was nowhere. But a Roomba password
// is long-lived, unrevocable without a factory reset, and grants full local
// control for the life of the robot; an HA long-lived token is worse. Neither
// may ever reach a log line, at any level.
//
// So this file is the logging counterpart of the `_NoWritesAllowed` store in
// the adoption tests: it drives the paths and asserts on what came out.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/log.dart';
import 'package:liberated_bread_mobile/models/ha_config.dart';
import 'package:liberated_bread_mobile/services/ha_roomba_client.dart';
import 'package:liberated_bread_mobile/services/rest980_client.dart';
import 'package:liberated_bread_mobile/services/roomba_control_service.dart';
import 'package:liberated_bread_mobile/services/roomba_controller.dart';
import 'package:liberated_bread_mobile/services/roomba_credential_store.dart';

import '../fakes/fake_ha_api_client.dart';
import '../fakes/fake_spec_codec.dart';

/// Distinctive enough that a substring search cannot match by accident.
const _password = ':1:1486937829:gktkDoYpWaDxCfGh';
const _token = 'llat-SECRET-0123456789abcdef';

const _credentials = RoombaCredentials(
  blid: '3193C60472324700',
  password: _password,
);

class _ScriptedRobot implements RoombaTlsSocket {
  final _out = StreamController<Uint8List>();
  @override
  Stream<Uint8List> get incoming => _out.stream;
  @override
  void add(List<int> bytes) {}
  @override
  Future<void> close() async {
    if (!_out.isClosed) await _out.close();
  }

  void send(List<int> bytes) => _out.add(Uint8List.fromList(bytes));
  Future<void> hangUp() async {
    if (!_out.isClosed) await _out.close();
  }
}

void main() {
  late List<LogRecord> records;

  setUp(() {
    records = Log.captureRecords();
    // Everything, including debug: a secret leaking at debug is still a secret
    // leaking, and a developer build is where these lines actually run.
    Log.minLevel = LogLevel.debug;
  });
  tearDown(Log.reset);

  /// Every line, whatever its level or category, flattened for searching.
  String allOutput() =>
      records.map((r) => '${r.category} ${r.message}').join('\n');

  group('secrets never reach a log line', () {
    test('the direct path logs the connection without the password', () async {
      final robot = _ScriptedRobot();
      final client = RoombaMqttClient(
        codec: FakeSpecCodec(),
        connect: (_, __, ___) async {
          scheduleMicrotask(() => robot.send([0x20, 0x02, 0x00, 0x00]));
          return robot;
        },
      );
      addTearDown(client.dispose);

      await client.connect('10.0.0.7', _credentials);

      // It said something useful...
      expect(allOutput(), contains('10.0.0.7'));
      expect(allOutput(), contains(_credentials.blid));
      // ...without saying the one thing it must not.
      expect(allOutput(), isNot(contains(_password)));
      // And the redaction is visible rather than silent, so a reader can tell
      // "not logged" from "not present".
      expect(allOutput(), contains(redactedText));
    });

    /// The eviction signal. This is the failure the whole feature warns about,
    /// so it has to be greppable — and at `warning`, since the release floor
    /// drops everything below that and this is what a bug report needs.
    test('a robot that hangs up says so at warning', () async {
      final robot = _ScriptedRobot();
      final client = RoombaMqttClient(
        codec: FakeSpecCodec(),
        connect: (_, __, ___) async {
          scheduleMicrotask(() => robot.send([0x20, 0x02, 0x00, 0x00]));
          return robot;
        },
      );
      addTearDown(client.dispose);
      await client.connect('10.0.0.7', _credentials);

      client.state.listen((_) {}, onError: (Object _) {});
      await robot.hangUp();
      await Future<void>.delayed(Duration.zero);

      final evictions = records.where((r) =>
          r.level == LogLevel.warning &&
          r.message.contains('closed the connection'));
      expect(evictions, isNotEmpty,
          reason:
              'the one-client-at-a-time symptom must survive into a report');
      expect(allOutput(), isNot(contains(_password)));
    });

    test('the Home Assistant path logs the service without the token',
        () async {
      final client = HaRoombaClient(
        api: FakeHaApiClient(),
        config: const HaConfig(
          baseUrl: 'http://ha.local:8123',
          token: _token,
          deviceId: 'device',
        ),
      );

      await client.send('vacuum.dorita', 'clean');

      expect(allOutput(), contains('vacuum.start'));
      expect(allOutput(), contains('vacuum.dorita'));
      expect(allOutput(), isNot(contains(_token)));
    });
  });

  group('the transport choice is recorded', () {
    RoombaController build(RoombaCredentials credentials,
            {HaRoombaClient? ha}) =>
        roombaControllerFor(
          credentials: credentials,
          host: '10.0.0.7',
          specYaml: 'unused',
          codec: FakeSpecCodec(),
          directClient: () => RoombaMqttClient(codec: FakeSpecCodec()),
          restClient: () => Rest980Client(codec: FakeSpecCodec()),
          haClient: () => ha,
        );

    test('names each of the three paths', () {
      build(_credentials);
      expect(allOutput(), contains('direct to the robot'));

      records.clear();
      build(_credentials.copyWith(rest980BaseUrl: 'http://pi.local:3000'));
      expect(allOutput(), contains('rest980'));
      // Host and port, never the URL: Log.hub lines carry no paths, because a
      // Hue bridge puts its credential in one.
      expect(allOutput(), contains('pi.local:3000'));
      expect(allOutput(), isNot(contains('http://')));

      records.clear();
      final ha = HaRoombaClient(
        api: FakeHaApiClient(),
        config: const HaConfig(
            baseUrl: 'http://ha.local:8123', token: _token, deviceId: 'd'),
      );
      build(_credentials.copyWith(haEntityId: 'vacuum.dorita'), ha: ha);
      expect(allOutput(), contains('Home Assistant'));
      expect(allOutput(), contains('vacuum.dorita'));
    });

    /// The silent fallback: a robot configured for Home Assistant, on a phone
    /// where HA is not connected, is about to be driven a way nobody chose —
    /// and on the direct path that means contending for the robot's single
    /// client slot. Warning, not debug.
    test('warns when a Home-Assistant robot falls back', () {
      build(_credentials.copyWith(haEntityId: 'vacuum.dorita'));

      final warnings = records.where((r) => r.level == LogLevel.warning);
      expect(warnings, isNotEmpty);
      expect(allOutput(), contains('falling back'));
    });
  });
}

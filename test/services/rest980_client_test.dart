// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/services/rest980_client.dart';
import 'package:liberated_bread_mobile/services/roomba_controller.dart';

import '../fakes/fake_spec_codec.dart';

/// What rest980 answers `/api/local/info/state` with: dorita980's state
/// document, which is the robot's `reported` tree at the top level.
const _restState = '{"batPct":94,"bin":{"full":false,"present":true},'
    '"cleanMissionStatus":{"phase":"run","cycle":"clean"},"name":"Dorita"}';

/// The same facts as the robot publishes them on `delta` — wrapped in the
/// shadow envelope.
const _mqttState = '{"state":{"reported":$_restState}}';

void main() {
  final codec = FakeSpecCodec();

  group('Rest980Client', () {
    test('maps our command names onto rest980 action endpoints', () async {
      final paths = <String>[];
      final client = Rest980Client(
        codec: codec,
        client: MockClient((request) async {
          paths.add(request.url.path);
          return http.Response('{"ok":true}', 200);
        }),
      );

      for (final command in ['clean', 'pause', 'stop', 'dock', 'resume']) {
        await client.action('http://pi.local:3000', command);
      }

      // `clean` is rest980's `start`: the spec names commands after the wire,
      // rest980 after dorita980's methods, and the map is where they meet.
      expect(paths, [
        '/api/local/action/start',
        '/api/local/action/pause',
        '/api/local/action/stop',
        '/api/local/action/dock',
        '/api/local/action/resume',
      ]);
    });

    /// rest980 publishes no locate endpoint. The UI hides the button, and this
    /// is the backstop for a control that slipped through: it must fail loudly
    /// rather than quietly GET a 404.
    test('refuses `find`, because rest980 has no endpoint for it', () async {
      var called = false;
      final client = Rest980Client(
        codec: codec,
        client: MockClient((_) async {
          called = true;
          return http.Response('', 200);
        }),
      );

      expect(Rest980Client.supports('find'), isFalse);
      expect(Rest980Client.supports('clean'), isTrue);
      await expectLater(
        client.action('http://pi.local:3000', 'find'),
        throwsA(isA<Rest980Exception>()
            .having((e) => e.message, 'message', contains('directly'))),
      );
      expect(called, isFalse, reason: 'no request is sent for an unmapped one');
    });

    /// The load-bearing claim of the whole two-transport design: both paths
    /// hand the entity layer identical dotted keys, so one control screen
    /// drives either. If this drifts, half the sensors go blank in server mode
    /// and nothing else says why.
    test('flattens state to the same keys the direct path produces', () async {
      final client = Rest980Client(
        codec: codec,
        client: MockClient((_) async => http.Response(_restState, 200)),
      );

      final viaRest = await client.state('http://pi.local:3000');
      final viaMqtt = await codec.roombaStateFields(payload: _mqttState);

      expect(viaRest, viaMqtt);
      expect(viaRest['state.reported.batPct'], '94');
      expect(viaRest['state.reported.cleanMissionStatus.phase'], 'run');
      expect(viaRest['state.reported.bin.full'], '0');
    });

    test('normalizes the address people actually type', () {
      expect(Rest980Client.normalizeBaseUrl('pi.local:3000'),
          'http://pi.local:3000');
      expect(Rest980Client.normalizeBaseUrl('http://pi.local:3000/'),
          'http://pi.local:3000');
      expect(Rest980Client.normalizeBaseUrl('  https://pi.local/  '),
          'https://pi.local');
      expect(Rest980Client.normalizeBaseUrl(''), '');
    });

    /// A 404 means the address points at something that is not rest980. Saying
    /// that is the difference between a 10-second fix and an evening.
    test('a 404 says the address is wrong, not that the robot is broken',
        () async {
      final client = Rest980Client(
        codec: codec,
        client: MockClient((_) async => http.Response('Not Found', 404)),
      );

      await expectLater(
        client.state('http://pi.local:3000'),
        throwsA(isA<Rest980Exception>()
            .having((e) => e.message, 'message', contains('not a rest980'))),
      );
    });

    test('a 5xx points at the server\'s own logs', () async {
      final client = Rest980Client(
        codec: codec,
        client: MockClient((_) async => http.Response('boom', 502)),
      );

      await expectLater(
        client.state('http://pi.local:3000'),
        throwsA(isA<Rest980Exception>()
            .having((e) => e.message, 'message', contains('logs'))),
      );
    });

    test('probe returns the robot name the server reports', () async {
      final client = Rest980Client(
        codec: codec,
        client: MockClient((_) async => http.Response(_restState, 200)),
      );
      expect(await client.probe('pi.local:3000'), 'Dorita');
    });
  });

  group('roombaCommandSequence', () {
    /// The whole point: a Dock button pressed mid-clean sends nothing the
    /// robot will act on unless it stops first. The spec's `dock` description
    /// says a send-home button sends stop then dock; this is that, in one
    /// place both transports share.
    test('expands dock into stop-then-dock, and leaves the rest alone', () {
      expect(roombaCommandSequence('dock'), ['stop', 'dock']);
      for (final command in ['clean', 'pause', 'stop', 'resume', 'find']) {
        expect(roombaCommandSequence(command), [command], reason: command);
      }
    });
  });

  group('Rest980Controller', () {
    test('polls state and emits it on the stream', () async {
      var requests = 0;
      final controller = Rest980Controller(
        client: Rest980Client(
          codec: codec,
          client: MockClient((_) async {
            requests++;
            return http.Response(_restState, 200);
          }),
        ),
        baseUrl: 'http://pi.local:3000',
      );
      addTearDown(controller.dispose);

      final first = controller.state.first;
      await controller.connect();

      expect(await first, isNotEmpty);
      expect(requests, greaterThanOrEqualTo(1),
          reason: 'connect polls once up front so the screen is not blank');
    });

    /// A rest980 that has stopped answering looks exactly like a robot that
    /// has stopped reporting, and the fix is different — so the failure has to
    /// reach the screen rather than being swallowed by the poll loop.
    test('a failing poll surfaces on the stream', () async {
      final controller = Rest980Controller(
        client: Rest980Client(
          codec: codec,
          client: MockClient((_) async => http.Response('nope', 500)),
        ),
        baseUrl: 'http://pi.local:3000',
      );
      addTearDown(controller.dispose);

      final failure = controller.state.first;
      await controller.connect();

      await expectLater(failure, throwsA(isA<Rest980Exception>()));
    });

    /// Both transports owe the sequence. Asserted on the wire rather than on
    /// the helper, because the bug this prevents is a controller forgetting to
    /// call it.
    test('sends stop before dock', () async {
      final paths = <String>[];
      final controller = Rest980Controller(
        client: Rest980Client(
          codec: codec,
          client: MockClient((request) async {
            paths.add(request.url.path);
            return http.Response('{}', 200);
          }),
        ),
        baseUrl: 'http://pi.local:3000',
      );
      addTearDown(controller.dispose);

      await controller.sendCommand('dock');

      expect(paths, [
        '/api/local/action/stop',
        '/api/local/action/dock',
      ]);
    });

    test('reports which commands it can send', () {
      final controller = Rest980Controller(
        client: Rest980Client(
          codec: codec,
          client: MockClient((_) async => http.Response('{}', 200)),
        ),
        baseUrl: 'http://pi.local:3000',
      );
      expect(controller.supports('clean'), isTrue);
      expect(controller.supports('find'), isFalse);
    });
  });

  group('the state envelope', () {
    /// rest980 returns the reported tree bare; the robot publishes it wrapped.
    /// Re-wrapping in the client rather than teaching the codec two shapes is
    /// what keeps one decoder and one set of entity paths.
    test('is what makes the two transports agree', () async {
      final bare = await codec.roombaStateFields(payload: _restState);
      final wrapped = await codec.roombaStateFields(payload: _mqttState);

      expect(bare.containsKey('batPct'), isTrue,
          reason: 'unwrapped, the keys are not the ones entities bind to');
      expect(wrapped.containsKey('state.reported.batPct'), isTrue);
      expect(bare, isNot(wrapped));
      expect(
          jsonDecode(_mqttState)['state']['reported'], jsonDecode(_restState));
    });
  });
}

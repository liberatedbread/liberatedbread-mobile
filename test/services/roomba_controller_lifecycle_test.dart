// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The polled Roomba adapters' lifecycle: what `close` ends, and what a slow
// server does to a fixed-interval poll. Both rules are invisible in normal
// use and both bite exactly when the far end is having a bad day, which is
// when the robot screen matters most.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/ha_config.dart';
import 'package:liberated_bread_mobile/services/ha_api_client.dart';
import 'package:liberated_bread_mobile/services/ha_roomba_client.dart';
import 'package:liberated_bread_mobile/services/rest980_client.dart';
import 'package:liberated_bread_mobile/services/roomba_controller.dart';

import '../fakes/fake_ha_api_client.dart';
import '../fakes/fake_spec_codec.dart';

/// A rest980 whose every state call takes [latency] and is counted.
({Rest980Client client, List<DateTime> calls}) slowRest980(Duration latency) {
  final calls = <DateTime>[];
  final client = Rest980Client(
    codec: FakeSpecCodec(),
    client: MockClient((request) async {
      calls.add(DateTime.now());
      await Future<void>.delayed(latency);
      return http.Response('{"cleanMissionStatus":{"phase":"run"}}', 200);
    }),
  );
  return (client: client, calls: calls);
}

void main() {
  test('close ends the state stream, not just the polling', () async {
    // The interface offers only `close`, and the device screen calls exactly
    // that on dispose. When `close` merely stopped the timer and left the
    // broadcast stream open, the stream was never closed by anybody: the
    // `dispose` that would have done it had no callers.
    final rest = slowRest980(Duration.zero);
    final controller = Rest980Controller(
      client: rest.client,
      baseUrl: 'http://10.0.0.5',
    );

    var done = false;
    controller.state.listen((_) {}, onError: (_) {}, onDone: () => done = true);

    await controller.connect();
    await controller.close();
    await Future<void>.delayed(Duration.zero);

    expect(
      done,
      isTrue,
      reason: 'listeners must learn the controller is spent',
    );
  });

  test('close is safe to call twice', () async {
    final rest = slowRest980(Duration.zero);
    final controller = Rest980Controller(
      client: rest.client,
      baseUrl: 'http://10.0.0.5',
    );
    await controller.connect();
    await controller.close();
    await expectLater(controller.close(), completes);
  });

  test('close during the seed read installs no poll', () {
    // The device screen closes the controller on dispose without waiting for
    // connect() to finish, and the seed read can take up to the client's
    // timeout. close() found no timer to cancel; connect() then resumed and
    // installed one that polled rest980 every two seconds for the life of
    // the process — once more per visit to the screen.
    fakeAsync((async) {
      final rest = slowRest980(const Duration(seconds: 10));
      final controller = Rest980Controller(
        client: rest.client,
        baseUrl: 'http://10.0.0.5',
      );
      controller.state.listen((_) {}, onError: (_) {});

      unawaited(controller.connect());
      async.elapse(const Duration(seconds: 1));
      expect(rest.calls, hasLength(1), reason: 'the seed read is in flight');

      unawaited(controller.close());
      // The seed read lands, then a minute passes.
      async.elapse(const Duration(seconds: 70));
      expect(
        rest.calls,
        hasLength(1),
        reason:
            'nothing may poll after close(), however late connect() '
            'resumes',
      );

      // And a connect() after close() is a no-op, not a resurrection.
      unawaited(controller.connect());
      async.elapse(const Duration(seconds: 10));
      expect(rest.calls, hasLength(1));
      async.flushTimers();
    });
  });

  test('a poll slower than the interval does not stack requests', () {
    // rest980 in front of a busy robot can answer slower than the two-second
    // tick. Unguarded, every tick queued another request and the slowest
    // reply decided the displayed state.
    fakeAsync((async) {
      final rest = slowRest980(const Duration(seconds: 7));
      final controller = Rest980Controller(
        client: rest.client,
        baseUrl: 'http://10.0.0.5',
      );
      controller.state.listen((_) {}, onError: (_) {});

      unawaited(controller.connect());
      async.elapse(const Duration(seconds: 1));
      expect(rest.calls, hasLength(1), reason: 'the seed read');

      // Three ticks pass while that first read is still on the wire.
      async.elapse(const Duration(seconds: 6));
      expect(
        rest.calls,
        hasLength(1),
        reason: 'ticks during an in-flight poll are skipped, not queued',
      );

      // Once it lands, the next tick polls again.
      async.elapse(const Duration(seconds: 3));
      expect(rest.calls, hasLength(2));

      unawaited(controller.close());
      async.flushTimers();
    });
  });

  group(
    'the Home Assistant poll asks for one entity, not the state machine',
    () {
      // `/api/states` has no domain parameter, so entitiesInDomain downloads
      // Home Assistant's WHOLE state machine — every entity, every attribute —
      // and filters in Dart. The bin-full sibling was looked up that way on
      // EVERY tick: two seconds, for as long as the screen is open, hundreds of
      // kilobytes a time on a real instance, to learn one boolean. And the Pi
      // this transport exists to be gentle on was serialising all of it.

      /// A vacuum that does not report `bin_full` itself, so the sibling lookup
      /// is needed — the only case that ever hit the whole-domain read.
      ({FakeHaApiClient api, HaRoombaClient client}) ha() {
        final api = FakeHaApiClient()
          ..entities = {
            'vacuum.dorita': const HaEntityState(
              entityId: 'vacuum.dorita',
              state: 'cleaning',
              attributes: {'battery_level': 94},
            ),
            'binary_sensor.dorita_bin_full': const HaEntityState(
              entityId: 'binary_sensor.dorita_bin_full',
              state: 'on',
            ),
          };
        return (
          api: api,
          client: HaRoombaClient(
            api: api,
            config: const HaConfig(
              baseUrl: 'http://ha.local:8123',
              token: 'llat',
              deviceId: 'device',
            ),
          ),
        );
      }

      test('the whole-domain search happens once, not once per tick', () {
        fakeAsync((async) {
          final fake = ha();
          final controller = HaRoombaController(
            client: fake.client,
            entityId: 'vacuum.dorita',
          );
          controller.state.listen((_) {}, onError: (_) {});

          unawaited(controller.connect());
          async.elapse(const Duration(seconds: 1));
          expect(
            fake.api.domainReads,
            ['binary_sensor'],
            reason:
                'finding the sibling does need the real list: HA derives an '
                'entity id from the name at creation and does not track later '
                'renames, so composing it by string surgery is a guess',
          );

          // Ten more ticks.
          async.elapse(const Duration(seconds: 20));
          expect(
            fake.api.domainReads,
            hasLength(1),
            reason:
                'the id does not change under us; every tick after the first '
                'must read the one entity',
          );
          expect(
            fake.api.entityReads.where((e) => e.startsWith('binary_sensor.')),
            everyElement('binary_sensor.dorita_bin_full'),
          );
          expect(
            fake.api.entityReads.where((e) => e.startsWith('binary_sensor.')),
            hasLength(greaterThan(5)),
            reason: 'it is still read every tick — narrowly',
          );

          unawaited(controller.close());
          async.flushTimers();
        });
      });

      test('the reading stays correct across the narrow polls', () {
        fakeAsync((async) {
          final fake = ha();
          final controller = HaRoombaController(
            client: fake.client,
            entityId: 'vacuum.dorita',
          );
          final seen = <Map<String, String>>[];
          controller.state.listen(seen.add, onError: (_) {});

          unawaited(controller.connect());
          async.elapse(const Duration(seconds: 5));
          expect(seen.last['state.reported.bin.full'], '1');

          // The bin is emptied. The narrow read must see that, not a value
          // cached from the one search.
          fake.api.entities['binary_sensor.dorita_bin_full'] =
              const HaEntityState(
                entityId: 'binary_sensor.dorita_bin_full',
                state: 'off',
              );
          async.elapse(const Duration(seconds: 5));
          expect(seen.last['state.reported.bin.full'], '0');

          unawaited(controller.close());
          async.flushTimers();
        });
      });

      test('a sensor renamed in HA is searched for again', () {
        fakeAsync((async) {
          final fake = ha();
          final controller = HaRoombaController(
            client: fake.client,
            entityId: 'vacuum.dorita',
          );
          controller.state.listen((_) {}, onError: (_) {});

          unawaited(controller.connect());
          async.elapse(const Duration(seconds: 3));
          expect(fake.api.domainReads, hasLength(1));

          // Renamed in HA while the screen is open: the id stops answering.
          // Caching "it is gone" forever would report the bin as unknown for
          // the rest of the session.
          fake.api.entities.remove('binary_sensor.dorita_bin_full');
          async.elapse(const Duration(seconds: 6));
          expect(fake.api.domainReads.length, greaterThan(1));

          unawaited(controller.close());
          async.flushTimers();
        });
      });

      test('a vacuum that reports bin_full itself never searches at all', () {
        fakeAsync((async) {
          final fake = ha();
          fake.api.entities['vacuum.dorita'] = const HaEntityState(
            entityId: 'vacuum.dorita',
            state: 'cleaning',
            attributes: {'battery_level': 94, 'bin_full': false},
          );
          final controller = HaRoombaController(
            client: fake.client,
            entityId: 'vacuum.dorita',
          );
          controller.state.listen((_) {}, onError: (_) {});

          unawaited(controller.connect());
          async.elapse(const Duration(seconds: 20));
          expect(fake.api.domainReads, isEmpty);
          expect(
            fake.api.entityReads,
            everyElement('vacuum.dorita'),
            reason: 'one request per tick, which is the whole tick',
          );

          unawaited(controller.close());
          async.flushTimers();
        });
      });
    },
  );
}

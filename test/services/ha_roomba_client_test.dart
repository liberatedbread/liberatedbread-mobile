// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Home Assistant transport: HA holds the robot, the app asks HA. What
// matters here is the translation, because the control screen is shared —
// every transport has to hand back the same dotted keys, or a Roomba driven
// through HA renders differently from the same robot driven directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ha_config.dart';
import 'package:liberated_bread_mobile/services/ha_api_client.dart';
import 'package:liberated_bread_mobile/services/ha_roomba_client.dart';
import 'package:liberated_bread_mobile/services/roomba_controller.dart';

import '../fakes/fake_ha_api_client.dart';

/// A vacuum entity shaped like the one HA's roomba integration publishes.
HaEntityState _vacuum({
  String entityId = 'vacuum.dorita',
  String state = 'cleaning',
  Map<String, dynamic> attributes = const {
    'friendly_name': 'Dorita',
    'battery_level': 94,
    'status': 'Clean',
    'supported_features': 1 | 4 | 8 | 16 | 512,
  },
}) =>
    HaEntityState(entityId: entityId, state: state, attributes: attributes);

const _config = HaConfig(
  baseUrl: 'http://ha.local:8123',
  token: 'llat',
  deviceId: 'device',
);

void main() {
  late FakeHaApiClient api;
  late HaRoombaClient client;

  setUp(() {
    api = FakeHaApiClient();
    client = HaRoombaClient(api: api, config: _config);
  });

  group('state translation', () {
    /// The three bindings the spec's entities declare. A Roomba on this
    /// transport has to fill the same ones the MQTT path does.
    test('a vacuum entity becomes the spec\'s dotted paths', () {
      final fields = HaRoombaClient.stateFields(_vacuum());

      expect(fields['state.reported.batPct'], '94');
      expect(fields['state.reported.cleanMissionStatus.phase'], 'Clean');
    });

    /// `status` is the robot's own phase text, which is what the Mission Phase
    /// entity means. HA's canonical `state` is a smaller vocabulary shared by
    /// every vacuum integration — always present, but says less.
    test('falls back to the canonical state when there is no status', () {
      final fields = HaRoombaClient.stateFields(_vacuum(
        state: 'returning',
        attributes: const {'battery_level': 55},
      ));

      expect(fields['state.reported.cleanMissionStatus.phase'], 'returning');
    });

    /// The reading that must never be invented. "Bin empty" is a fact the user
    /// acts on; absent renders as unknown, which is the truth.
    test('omits bin-full entirely when nothing reports it', () {
      final fields = HaRoombaClient.stateFields(_vacuum());

      expect(fields.containsKey('state.reported.bin.full'), isFalse);
    });

    test('reads bin-full from the sibling binary_sensor', () {
      final fields = HaRoombaClient.stateFields(
        _vacuum(),
        binFull: const HaEntityState(
          entityId: 'binary_sensor.dorita_bin_full',
          state: 'on',
        ),
      );

      // "1"/"0", so the spec's `on_when: nonzero` reads it the same way it
      // reads the MQTT path's flattened boolean.
      expect(fields['state.reported.bin.full'], '1');
    });

    test('reads bin-full off the vacuum when the integration puts it there',
        () {
      final fields = HaRoombaClient.stateFields(_vacuum(attributes: const {
        'battery_level': 94,
        'bin_full': false,
      }));

      expect(fields['state.reported.bin.full'], '0');
    });

    /// An entity HA cannot reach reports `unavailable` and empties its
    /// attributes. Publishing that as a battery of 0 would be a fabricated
    /// reading of the worst kind — one that looks like a robot in trouble.
    test('an unavailable entity yields no fields at all', () {
      final fields = HaRoombaClient.stateFields(
        _vacuum(state: 'unavailable', attributes: const {}),
      );

      expect(fields, isEmpty);
    });

    /// HA derives an entity id from the name at creation and does not track
    /// renames, so the sibling is matched against the real list rather than
    /// built by string surgery.
    test('finds the bin sensor belonging to this robot, not another', () {
      final sensors = [
        const HaEntityState(
            entityId: 'binary_sensor.downstairs_bin_full', state: 'on'),
        const HaEntityState(
            entityId: 'binary_sensor.dorita_bin_full', state: 'off'),
      ];

      final found = HaRoombaClient.binFullFor(_vacuum(), sensors);
      expect(found?.entityId, 'binary_sensor.dorita_bin_full');
    });
  });

  group('commands', () {
    test('each spec command maps onto its vacuum service', () async {
      for (final command in ['clean', 'pause', 'stop', 'dock', 'find']) {
        await client.send('vacuum.dorita', command);
      }

      expect(
        api.serviceCalls.map((c) => c.service).toList(),
        ['start', 'pause', 'stop', 'return_to_base', 'locate'],
      );
      expect(api.serviceCalls.every((c) => c.domain == 'vacuum'), isTrue);
      expect(
          api.serviceCalls.every((c) => c.entityId == 'vacuum.dorita'), isTrue);
    });

    /// The rule that does NOT carry over. The direct path sends stop before
    /// dock because the robot's own protocol refuses `dock` mid-clean;
    /// `vacuum.return_to_base` makes that transition itself, so a preceding
    /// stop here is a spurious extra command.
    test('dock sends return_to_base once, with no stop before it', () async {
      final controller = HaRoombaController(
        client: client,
        entityId: 'vacuum.dorita',
      );
      addTearDown(controller.dispose);

      await controller.sendCommand('dock');

      expect(api.serviceCalls, hasLength(1));
      expect(api.serviceCalls.single.service, 'return_to_base');
    });

    /// The direct path, for contrast — the two transports genuinely differ
    /// here, and this is what stops someone "tidying" them into one rule.
    test('the direct path still owes stop before dock', () {
      expect(roombaCommandSequence('dock'), ['stop', 'dock']);
    });
  });

  group('supported_features', () {
    test('hides what the entity does not advertise', () {
      // START | RETURN_HOME only: no pause, no stop, no locate.
      final entity = _vacuum(attributes: const {'supported_features': 1 | 16});

      expect(HaRoombaClient.supports(entity, 'clean'), isTrue);
      expect(HaRoombaClient.supports(entity, 'dock'), isTrue);
      expect(HaRoombaClient.supports(entity, 'pause'), isFalse);
      expect(HaRoombaClient.supports(entity, 'find'), isFalse);
    });

    /// Some integrations omit the attribute. Drawing no buttons at all would
    /// be a worse failure than offering one HA then refuses.
    test('an entity with no features declared keeps the core commands', () {
      final entity = _vacuum(attributes: const {'battery_level': 10});

      expect(HaRoombaClient.supports(entity, 'clean'), isTrue);
      expect(HaRoombaClient.supports(entity, 'dock'), isTrue);
      // Locate is the one nobody should assume.
      expect(HaRoombaClient.supports(entity, 'find'), isFalse);
    });
  });

  group('HaRoombaController', () {
    test('polls the entity and publishes the shared dotted keys', () async {
      api.entities = {'vacuum.dorita': _vacuum()};
      final controller = HaRoombaController(
        client: client,
        entityId: 'vacuum.dorita',
      );
      addTearDown(controller.dispose);

      final seen = controller.state.first;
      await controller.connect();

      final fields = await seen;
      expect(fields['state.reported.batPct'], '94');
      expect(fields['state.reported.cleanMissionStatus.phase'], 'Clean');
    });

    /// A robot removed or renamed in HA is a different problem from an
    /// unreachable server, and the fix is different too — so it must not read
    /// as a network failure.
    test('an entity HA no longer has says so, rather than looking offline',
        () async {
      api.entities = {};
      final controller = HaRoombaController(
        client: client,
        entityId: 'vacuum.gone',
      );
      addTearDown(controller.dispose);

      final error = controller.state.first
          .then<Object?>((_) => null, onError: (Object e) => e);
      await controller.connect();

      expect(
        (await error).toString(),
        allOf(contains('vacuum.gone'), contains('removed or renamed')),
      );
    });

    test('only fetches binary_sensors when the vacuum lacks the reading',
        () async {
      api.entities = {
        'vacuum.dorita': _vacuum(attributes: const {
          'battery_level': 94,
          'bin_full': true,
        }),
      };
      final controller = HaRoombaController(
        client: client,
        entityId: 'vacuum.dorita',
      );
      addTearDown(controller.dispose);

      final seen = controller.state.first;
      await controller.connect();

      expect((await seen)['state.reported.bin.full'], '1');
    });
  });
}

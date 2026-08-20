// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The network half of the group-op vocabulary: which ops a member's
// entities support, and the turn-off policy — discrete off sent outright,
// a toggle only ever behind a state read, and toggle-without-state
// resolving nothing at all. Pure functions, no I/O; the runner's tests
// cover the reads themselves.

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

NetworkActionDto _action(String role,
        {String transport = 'http', List<String> userParams = const []}) =>
    NetworkActionDto(
      role: role,
      commandName: 'cmd_$role',
      transport: transport,
      userParams: userParams,
      readBack: const [],
      credentials: const [],
      instanceParams: const [],
      min: 0,
      max: 100,
    );

NetworkEntityDto _entity({
  String platform = 'switch',
  String stateCommand = '',
  String? transport,
  List<NetworkActionDto> actions = const [],
}) =>
    NetworkEntityDto(
      name: 'Power',
      platform: platform,
      stateCommand: stateCommand,
      transport: transport,
      isInstanced: false,
      options: const [],
      actions: actions,
    );

void main() {
  group('supportedNetworkGroupOps', () {
    test('discrete roles support their ops', () {
      final ops = supportedNetworkGroupOps([
        _entity(actions: [_action('turn_on'), _action('turn_off')]),
      ]);
      expect(ops, {GroupOp.turnOn, GroupOp.turnOff});
    });

    test('a toggle counts toward turn-off ONLY with a readable state', () {
      expect(
        supportedNetworkGroupOps([
          _entity(actions: [_action('toggle')]),
        ]),
        isEmpty,
        reason: 'toggle with no state resolves nothing',
      );
      expect(
        supportedNetworkGroupOps([
          _entity(stateCommand: 'power_state', actions: [_action('toggle')]),
        ]),
        {GroupOp.turnOff},
      );
    });

    test('an unsendable transport supports nothing', () {
      expect(
        supportedNetworkGroupOps([
          _entity(actions: [_action('turn_off', transport: 'websocket')]),
        ]),
        isEmpty,
      );
    });

    test('brightness needs a light', () {
      expect(
        supportedNetworkGroupOps([
          _entity(actions: [
            _action('set_brightness', userParams: const ['brightness'])
          ]),
        ]),
        isEmpty,
        reason: 'a switch has no brightness op',
      );
      expect(
        supportedNetworkGroupOps([
          _entity(platform: 'light', actions: [
            _action('set_brightness', userParams: const ['brightness'])
          ]),
        ]),
        {GroupOp.setBrightness},
      );
    });

    test('non-control platforms are ignored', () {
      expect(
        supportedNetworkGroupOps([
          _entity(platform: 'button', actions: [_action('press')]),
          _entity(platform: 'sensor', stateCommand: 'reading'),
        ]),
        isEmpty,
      );
    });
  });

  group('resolveNetworkGroupPlan for turn-off', () {
    test('a discrete off is a direct send, and the toggle is not added', () {
      final plan = resolveNetworkGroupPlan(
        op: GroupOp.turnOff,
        entities: [
          _entity(stateCommand: 'power_state', actions: [
            _action('turn_off'),
            _action('toggle'),
          ]),
        ],
      );
      expect(plan.direct, hasLength(1));
      expect(plan.direct.single.action.role, 'turn_off');
      expect(plan.gated, isEmpty,
          reason: 'the discrete off makes the toggle redundant risk');
    });

    test('a toggle with readable state is gated, never direct', () {
      final plan = resolveNetworkGroupPlan(
        op: GroupOp.turnOff,
        entities: [
          _entity(stateCommand: 'power_state', actions: [_action('toggle')]),
        ],
      );
      expect(plan.direct, isEmpty);
      expect(plan.gated, hasLength(1));
    });

    test('a toggle without state resolves nothing', () {
      final plan = resolveNetworkGroupPlan(
        op: GroupOp.turnOff,
        entities: [
          _entity(actions: [_action('toggle')]),
        ],
      );
      expect(plan.isEmpty, isTrue);
    });

    test('credentialed and instanced actions never join a bulk send', () {
      const credentialed = NetworkActionDto(
        role: 'turn_off',
        commandName: 'off',
        transport: 'http',
        userParams: [],
        readBack: [],
        credentials: [
          NetworkSourceParamDto(param: 'username', name: 'username')
        ],
        instanceParams: [],
      );
      final plan = resolveNetworkGroupPlan(
        op: GroupOp.turnOff,
        entities: [
          _entity(actions: [credentialed]),
        ],
      );
      expect(plan.isEmpty, isTrue);
    });
  });

  test('brightness rescales into the action\'s own declared range', () {
    final plan = resolveNetworkGroupPlan(
      op: GroupOp.setBrightness,
      entities: [
        _entity(platform: 'light', actions: [
          _action('set_brightness', userParams: const ['brightness'])
        ]),
      ],
      brightnessPercent: 50,
    );
    expect(plan.direct.single.values, {'brightness': '50'});
  });
}

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

NetworkActionDto _action(
  String role, {
  String transport = 'http',
  List<String> userParams = const [],
  double? min = 0,
  double? max = 100,
}) => NetworkActionDto(
  role: role,
  commandName: 'cmd_$role',
  transport: transport,
  userParams: userParams,
  readBack: const [],
  credentials: const [],
  instanceParams: const [],
  min: min,
  max: max,
);

NetworkEntityDto _entity({
  String platform = 'switch',
  String stateCommand = '',
  String? transport,
  String? key,
  String? deviceClass,
  List<NetworkActionDto> actions = const [],
}) => NetworkEntityDto(
  name: 'Power',
  key: key,
  deviceClass: deviceClass,
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

    test('a switch marked as a lock binds no group command', () {
      // "Turn all off" on a lock's switch is an unlock nobody confirmed.
      for (final marked in [
        _entity(
          key: 'lock',
          actions: [_action('turn_on'), _action('turn_off')],
        ),
        _entity(
          deviceClass: 'lock',
          actions: [_action('turn_on'), _action('turn_off')],
        ),
      ]) {
        expect(supportedNetworkGroupOps([marked]), isEmpty);
      }
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
          _entity(
            actions: [
              _action('set_brightness', userParams: const ['brightness']),
            ],
          ),
        ]),
        isEmpty,
        reason: 'a switch has no brightness op',
      );
      expect(
        supportedNetworkGroupOps([
          _entity(
            platform: 'light',
            actions: [
              _action('set_brightness', userParams: const ['brightness']),
            ],
          ),
        ]),
        {GroupOp.setBrightness},
      );
    });

    // R-071: the support check and the resolver have to admit the same
    // actions. A set_brightness with no user parameter has nowhere to put the
    // level, so the resolver never sent it — while the button was offered, the
    // percentage sheet opened, and every member of the run skipped.
    test('brightness with nowhere to put the level is not offered', () {
      final entities = [
        _entity(platform: 'light', actions: [_action('set_brightness')]),
      ];
      expect(supportedNetworkGroupOps(entities), isEmpty);
      expect(
        resolveNetworkGroupPlan(
          op: GroupOp.setBrightness,
          entities: entities,
          brightnessPercent: 50,
        ).direct,
        isEmpty,
        reason: 'the resolver already refused it; the button now agrees',
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
          _entity(
            stateCommand: 'power_state',
            actions: [_action('turn_off'), _action('toggle')],
          ),
        ],
      );
      expect(plan.direct, hasLength(1));
      expect(plan.direct.single.action.role, 'turn_off');
      expect(
        plan.gated,
        isEmpty,
        reason: 'the discrete off makes the toggle redundant risk',
      );
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
          NetworkSourceParamDto(param: 'username', name: 'username'),
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
        _entity(
          platform: 'light',
          actions: [
            _action('set_brightness', userParams: const ['brightness']),
          ],
        ),
      ],
      brightnessPercent: 50,
    );
    expect(plan.direct.single.values, {'brightness': '50'});
  });

  // The group path used to default a missing max to 100 while the device
  // screen's card defaulted to 255, so a group 50% sent 50 and landed a
  // 0..255 device at about 20%.
  test('a brightness with no declared bounds spans the card\'s 0..255', () {
    final plan = resolveNetworkGroupPlan(
      op: GroupOp.setBrightness,
      entities: [
        _entity(
          platform: 'light',
          actions: [
            _action(
              'set_brightness',
              userParams: const ['brightness'],
              min: null,
              max: null,
            ),
          ],
        ),
      ],
      brightnessPercent: 50,
    );
    expect(plan.direct.single.values, {'brightness': '128'});
    expect(brightnessFromPercent(null, null, 50), 128);
  });

  group('pride mode', () {
    const rgb = ['red', 'green', 'blue'];

    test('a light taking three channels is on, then coloured', () {
      final entity = _entity(
        platform: 'light',
        actions: [
          _action('turn_on'),
          _action('set_color', userParams: rgb),
        ],
      );
      expect(supportedNetworkGroupOps([entity]), contains(GroupOp.prideMode));
      final plan = resolveNetworkGroupPlan(
        op: GroupOp.prideMode,
        entities: [entity],
        prideColor: (r: 1, g: 2, b: 3),
      );
      expect(plan.direct.map((s) => s.action.role), ['turn_on', 'set_color']);
      expect(plan.direct.last.values, {'red': '1', 'green': '2', 'blue': '3'});
    });

    test('a lone `rgb` that does not declare itself 24-bit is not packed', () {
      final entity = _entity(
        platform: 'light',
        actions: [
          _action('set_color', userParams: const ['rgb']),
        ],
      );
      expect(
        supportedNetworkGroupOps([entity]),
        isNot(contains(GroupOp.prideMode)),
      );
    });

    NetworkActionDto wired(
      String role,
      String transport, {
      List<String> params = const [],
      double? max,
    }) => NetworkActionDto(
      role: role,
      commandName: role,
      transport: transport,
      userParams: params,
      max: max,
      readBack: const [],
      credentials: const [],
      instanceParams: const [],
    );

    test('a Yeelight is on, then told its colour packed', () {
      final entity = _entity(
        platform: 'light',
        actions: [
          wired('turn_on', kYeelightTransport),
          wired(
            'set_color',
            kYeelightTransport,
            params: const ['rgb'],
            max: 16777215,
          ),
        ],
      );
      expect(supportedNetworkGroupOps([entity]), contains(GroupOp.prideMode));
      final plan = resolveNetworkGroupPlan(
        op: GroupOp.prideMode,
        entities: [entity],
        prideColor: (r: 0xE4, g: 0x03, b: 0x03),
      );
      expect(plan.direct.map((s) => s.action.role), ['turn_on', 'set_color']);
      expect(plan.direct.last.values, {'rgb': '${0xE40303}'});
    });

    test('a bridge is told its colour as a hue byte, which turns it on', () {
      // No separate turn_on: the codec sends the zone's ON ahead of the
      // colour in each of its three rounds, and three more in front would
      // be six inside a second — past the five that unlink a bulb.
      final entity = _entity(
        platform: 'light',
        actions: [
          wired('turn_on', kLimitlessledTransport),
          wired(
            'set_color',
            kLimitlessledTransport,
            params: const ['hue'],
            max: 255,
          ),
        ],
      );
      expect(supportedNetworkGroupOps([entity]), contains(GroupOp.prideMode));
      final plan = resolveNetworkGroupPlan(
        op: GroupOp.prideMode,
        entities: [entity],
        prideColor: (r: 0, g: 255, b: 0),
      );
      expect(plan.direct.map((s) => s.action.role), ['set_color']);
      expect(plan.direct.last.values, {'hue': '${0x60}'});
    });

    test('a lone `hue` on any other transport is not assumed to be this', () {
      // Degrees on one protocol, a wheel from violet on another: the same
      // number is a different colour, and the spec does not say which.
      final entity = _entity(
        platform: 'light',
        actions: [
          wired('set_color', 'http', params: const ['hue'], max: 255),
        ],
      );
      expect(
        supportedNetworkGroupOps([entity]),
        isNot(contains(GroupOp.prideMode)),
      );
    });

    test('both new transports are sendable from a group', () {
      expect(kGroupSendableTransports, contains(kYeelightTransport));
      expect(kGroupSendableTransports, contains(kLimitlessledTransport));
      final entity = _entity(
        platform: 'light',
        actions: [
          wired('turn_on', kLimitlessledTransport),
          wired('turn_off', kLimitlessledTransport),
          wired(
            'set_brightness',
            kLimitlessledTransport,
            params: const ['level'],
            max: 27,
          ),
        ],
      );
      expect(
        supportedNetworkGroupOps([entity]),
        containsAll([GroupOp.turnOn, GroupOp.turnOff, GroupOp.setBrightness]),
      );
    });

    group('limitlessledHueByte', () {
      test('lands on the spec\'s own anchors', () {
        expect(limitlessledHueByte((r: 255, g: 0, b: 0)), 0xB0, reason: 'red');
        expect(
          limitlessledHueByte((r: 0, g: 255, b: 0)),
          0x60,
          reason: 'green',
        );
        expect(
          limitlessledHueByte((r: 0, g: 0, b: 255)),
          0x10,
          reason: 'royal blue',
        );
      });

      test('runs the spec\'s way round, through violet and lavender', () {
        // 0x10 blue, then down through 0x00 violet, wrapping to 0xF0 lavender,
        // then on down to 0xB0 red.
        final violet = limitlessledHueByte((r: 128, g: 0, b: 255))!;
        expect(violet, anyOf(lessThan(0x10), greaterThan(0xB0)));
        final magenta = limitlessledHueByte((r: 255, g: 0, b: 255))!;
        expect(magenta, inInclusiveRange(0xB0, 0xFF));
      });

      test('every byte is a byte, all the way round', () {
        for (var r = 0; r <= 255; r += 51) {
          for (var g = 0; g <= 255; g += 51) {
            for (var b = 0; b <= 255; b += 51) {
              final byte = limitlessledHueByte((r: r, g: g, b: b));
              if (byte != null) expect(byte, inInclusiveRange(0, 255));
            }
          }
        }
      });

      test('a colour with no hue has no position on the wheel', () {
        expect(limitlessledHueByte((r: 255, g: 255, b: 255)), isNull);
        expect(limitlessledHueByte((r: 0, g: 0, b: 0)), isNull);
        expect(limitlessledHueByte((r: 80, g: 80, b: 80)), isNull);
      });
    });

    test('a switch has no part in it', () {
      final entity = _entity(actions: [_action('set_color', userParams: rgb)]);
      expect(
        supportedNetworkGroupOps([entity]),
        isNot(contains(GroupOp.prideMode)),
      );
    });

    test('a strip with only effects goes through the effect', () {
      final entity = _entity(
        platform: 'light',
        actions: [
          _action('turn_on'),
          _action('set_effect', userParams: const [groupEffectParam]),
        ],
      );
      expect(supportedNetworkGroupOps([entity]), contains(GroupOp.prideMode));
      final plan = resolveNetworkGroupPlan(
        op: GroupOp.prideMode,
        entities: [entity],
      );
      expect(plan.direct.single.action.role, 'turn_on');
      expect(plan.rainbowEffects.single.action.role, 'set_effect');
    });

    test('a light with a colour does not also change effect', () {
      final plan = resolveNetworkGroupPlan(
        op: GroupOp.prideMode,
        entities: [
          _entity(
            platform: 'light',
            actions: [
              _action('set_color', userParams: rgb),
              _action('set_effect', userParams: const [groupEffectParam]),
            ],
          ),
        ],
      );
      expect(plan.rainbowEffects, isEmpty);
    });

    test('the rainbow is found by name, exact over loose', () {
      expect(rainbowEffectIndex(['Solid', 'Colorloop', 'Rainbow']), 2);
      expect(rainbowEffectIndex(['Rainbow Runner', 'rainbow ']), 1);
      expect(rainbowEffectIndex(['Rainbow Runner', 'Solid']), 0);
      expect(rainbowEffectIndex(['Solid']), isNull);
      expect(rainbowEffectIndex([]), isNull);
    });
  });
}

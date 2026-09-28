// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/services/lifx_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/light_swatches.dart';
import 'package:liberated_bread_mobile/widgets/network_light_card.dart';
import 'package:liberated_bread_mobile/widgets/unclaimed_actions.dart';

import '../fakes/fake_spec_codec.dart';

/// A [LifxControlClient] that records sends and never touches a socket, so the
/// card can be driven without a strip on the network. Reads return null (a
/// write-only device), which is the card's own degraded-but-working path.
class _FakeLifxClient extends LifxControlClient {
  final List<({String host, List<int> packet})> sent = [];
  int _seq = 0;

  @override
  int nextSequence() => ++_seq;

  @override
  Future<void> send(String host, Uint8List packet, {int sends = 2}) async {
    sent.add((host: host, packet: packet));
  }

  @override
  Future<Uint8List?> request(
    String host,
    Uint8List packet, {
    required int sequence,
    Duration timeout = const Duration(seconds: 1),
    int retries = 2,
  }) async => null;
}

NetworkActionDto _action(String role, {List<String> params = const []}) =>
    NetworkActionDto(
      role: role,
      commandName: role,
      transport: 'lifx',
      userParams: params,
      readBack: const [],
      credentials: const [],
      instanceParams: const [],
    );

NetworkEntityDto _lightEntity({bool multizone = false}) => NetworkEntityDto(
  name: 'LIFX Z Multizone Strip',
  platform: 'light',
  transport: 'lifx',
  isInstanced: false,
  stateCommand: '',
  options: const [],
  actions: [
    _action('turn_on'),
    _action('turn_off'),
    _action('set_color', params: const ['red', 'green', 'blue', 'brightness']),
    _action('set_color_temperature', params: const ['kelvin']),
    if (multizone)
      _action(
        'set_zone_color',
        params: const ['zone', 'red', 'green', 'blue', 'brightness'],
      ),
  ],
);

Widget _wrap(
  NetworkEntityDto entity,
  FakeSpecCodec codec,
  _FakeLifxClient client,
) => ProviderScope(
  overrides: [
    specCodecProvider.overrideWithValue(codec),
    lifxControlClientProvider.overrideWithValue(client),
  ],
  child: MaterialApp(
    home: Scaffold(
      body: NetworkLightCard(
        entity: entity,
        specYaml: 'lifx',
        host: '192.168.1.44',
        targetMac: 'd0:73:d5:aa:bb:cc',
      ),
    ),
  ),
);

void main() {
  testWidgets('power toggle renders turn_on then turn_off over UDP', (
    tester,
  ) async {
    final codec = FakeSpecCodec();
    final client = _FakeLifxClient();
    await tester.pumpWidget(_wrap(_lightEntity(), codec, client));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(codec.renderLifxCalls.last.action, 'turn_on');
    expect(codec.renderLifxCalls.last.targetMac, 'd0:73:d5:aa:bb:cc');
    expect(client.sent.single.host, '192.168.1.44');

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(codec.renderLifxCalls.last.action, 'turn_off');
    expect(client.sent.length, 2);
  });

  testWidgets('tapping a colour swatch sends set_color with rgb params', (
    tester,
  ) async {
    final codec = FakeSpecCodec();
    final client = _FakeLifxClient();
    await tester.pumpWidget(_wrap(_lightEntity(), codec, client));
    await tester.pumpAndSettle();

    // The swatches are the only InkWells on a whole-strip light; tap the first.
    await tester.tap(find.byType(InkWell).first);
    await tester.pumpAndSettle();

    final call = codec.renderLifxCalls.last;
    expect(call.action, 'set_color');
    expect(
      call.params.keys,
      containsAll(<String>['red', 'green', 'blue', 'brightness']),
    );
    expect(client.sent, isNotEmpty);
  });

  testWidgets('a brightness slider appears only when set_color carries it', (
    tester,
  ) async {
    final codec = FakeSpecCodec();
    final client = _FakeLifxClient();
    await tester.pumpWidget(_wrap(_lightEntity(), codec, client));
    await tester.pumpAndSettle();
    // Two sliders: brightness and colour temperature.
    expect(find.byType(Slider), findsNWidgets(2));
  });
  testWidgets(
    'a non-LIFX light rides the generic sender, never the UDP client',
    (tester) async {
      // The routing bug this guards: platform == light used to imply the LIFX
      // implementation, so an http light would have had LIFX datagrams fired
      // at it. Now the transport decides, and the card presents only.
      final codec = FakeSpecCodec();
      final client = _FakeLifxClient();
      const generic = NetworkEntityDto(
        name: 'Bridge Light',
        platform: 'light',
        transport: 'http',
        isInstanced: false,
        stateCommand: '',
        options: [],
        actions: [
          NetworkActionDto(
            role: 'turn_on',
            commandName: 'light_on',
            transport: 'http',
            userParams: [],
            readBack: [],
            credentials: [],
            instanceParams: [],
          ),
          NetworkActionDto(
            role: 'turn_off',
            commandName: 'light_off',
            transport: 'http',
            userParams: [],
            readBack: [],
            credentials: [],
            instanceParams: [],
          ),
        ],
      );
      final sent = <(String, Map<String, String>)>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            specCodecProvider.overrideWithValue(codec),
            lifxControlClientProvider.overrideWithValue(client),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: NetworkLightCard(
                entity: generic,
                specYaml: 'y',
                host: '10.0.0.7',
                targetMac: '',
                sendAction: (action, values) async =>
                    sent.add((action.commandName, values)),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(sent.single.$1, 'light_on');
      expect(
        client.sent,
        isEmpty,
        reason: 'no LIFX datagram may reach a non-LIFX device',
      );
    },
  );

  group('the generic path sends only what the action can take', () {
    NetworkActionDto generic(
      String role,
      List<String> params, {
      double? min,
      double? max,
    }) => NetworkActionDto(
      role: role,
      commandName: role,
      transport: 'http',
      userParams: params,
      readBack: const [],
      credentials: const [],
      instanceParams: const [],
      min: min,
      max: max,
    );

    Future<List<(String, Map<String, String>)>> pump(
      WidgetTester tester,
      List<NetworkActionDto> actions,
    ) async {
      final sent = <(String, Map<String, String>)>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            specCodecProvider.overrideWithValue(FakeSpecCodec()),
            lifxControlClientProvider.overrideWithValue(_FakeLifxClient()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: NetworkLightCard(
                  entity: NetworkEntityDto(
                    name: 'Lamp',
                    platform: 'light',
                    transport: 'http',
                    isInstanced: false,
                    stateCommand: '',
                    options: const [],
                    actions: actions,
                  ),
                  specYaml: 'y',
                  host: '10.0.0.7',
                  targetMac: '',
                  sendAction: (action, values) async =>
                      sent.add((action.commandName, values)),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return sent;
    }

    testWidgets('colour temperature fills the spec\'s one parameter', (
      tester,
    ) async {
      // Yeelight's shape: set_color_temperature owns `ct`, beside a
      // set_brightness. Old code sent {'kelvin', 'brightness'} — two keys,
      // so the rename to `ct` never happened and `ct` was missing.
      final sent = await pump(tester, [
        generic('set_brightness', ['bright'], min: 1, max: 100),
        generic('set_color_temperature', ['ct'], min: 1700, max: 6500),
      ]);
      final slider = tester.widget<Slider>(
        find.byWidgetPredicate((w) => w is Slider && w.max == 6500),
      );
      slider.onChangeEnd!(slider.value);
      await tester.pumpAndSettle();
      expect(sent.single.$1, 'set_color_temperature');
      expect(sent.single.$2, {'ct': '3500'});
    });

    testWidgets('a one-parameter colour action draws no swatches', (
      tester,
    ) async {
      // A packed `rgb` needs an encoding the spec has not declared; the old
      // swatches sent red/green/blue and failed on every tap.
      await pump(tester, [
        generic('set_color', ['rgb']),
      ]);
      expect(find.bySemanticsLabel('Red'), findsNothing);
      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('an r/g/b colour action gets only its own names', (
      tester,
    ) async {
      final sent = await pump(tester, [
        generic('set_brightness', ['brightness'], min: 1, max: 100),
        generic('set_color', ['red', 'green', 'blue']),
      ]);
      await tester.tap(find.bySemanticsLabel('Red').first);
      await tester.pumpAndSettle();
      expect(sent.single.$1, 'set_color');
      expect(sent.single.$2.keys.toSet(), {'red', 'green', 'blue'});
    });
  });

  group('the generic path shows the device, not its own guess', () {
    // NetworkDeviceScreen._send catches every failure itself (its banner
    // reports it) and never rethrows, so on this path the card cannot tell
    // a refused command from an accepted one. It assumed the sent position
    // anyway, and only a CHANGED reading could correct it — a refused Off
    // left the poll saying On, unchanged, and the card said Off for as long
    // as the screen was open. The senders below swallow, like the screen's.
    NetworkActionDto generic(String role, [List<String> params = const []]) =>
        NetworkActionDto(
          role: role,
          commandName: role,
          transport: 'http',
          userParams: params,
          readBack: const [],
          credentials: const [],
          instanceParams: const [],
          min: role == 'set_brightness' ? 1 : null,
          max: role == 'set_brightness' ? 100 : null,
        );

    Future<List<String>> pump(
      WidgetTester tester,
      List<NetworkActionDto> actions, {
      bool? initialOn,
      double? initialBrightness,
    }) async {
      final sent = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            specCodecProvider.overrideWithValue(FakeSpecCodec()),
            lifxControlClientProvider.overrideWithValue(_FakeLifxClient()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: NetworkLightCard(
                  entity: NetworkEntityDto(
                    name: 'Kasa Bulb',
                    platform: 'light',
                    transport: 'http',
                    isInstanced: false,
                    stateCommand: '',
                    options: const [],
                    actions: actions,
                  ),
                  specYaml: 'y',
                  host: '10.0.0.7',
                  targetMac: '',
                  initialOn: initialOn,
                  initialBrightness: initialBrightness,
                  // Refused, and swallowed: completes normally, and the
                  // screen's reading does not move.
                  sendAction: (action, values) async =>
                      sent.add(action.commandName),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return sent;
    }

    testWidgets('a refused Off leaves the switch on the polled On', (
      tester,
    ) async {
      // Fails on the old card: the switch reads Off.
      final sent = await pump(tester, [
        generic('turn_on'),
        generic('turn_off'),
      ], initialOn: true);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(sent, ['turn_off']);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('a refused brightness puts the slider back on the reading', (
      tester,
    ) async {
      // Fails on the old card: the slider keeps the dragged 100.
      await pump(tester, [
        generic('set_brightness', ['brightness']),
      ], initialBrightness: 40);
      final slider = tester.widget<Slider>(find.byType(Slider));
      slider.onChanged!(100);
      await tester.pump();
      tester.widget<Slider>(find.byType(Slider)).onChangeEnd!(100);
      await tester.pumpAndSettle();

      expect(tester.widget<Slider>(find.byType(Slider)).value, 40);
    });

    testWidgets('with no reading, the sent position is the best there is', (
      tester,
    ) async {
      await pump(tester, [generic('turn_on'), generic('turn_off')]);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });
  });

  group('a role the card cannot draw is handed on, not hidden', () {
    // The card claimed set_color and the power pair whether or not it drew
    // them, so UnclaimedActions never named them: Yeelight Cube's packed
    // `rgb` and MiLight's `hue` set_color vanished, and so did a lone
    // turn_on. Each case below fails on the old card.
    NetworkActionDto generic(String role, [List<String> params = const []]) =>
        NetworkActionDto(
          role: role,
          commandName: role,
          transport: 'http',
          userParams: params,
          readBack: const [],
          credentials: const [],
          instanceParams: const [],
        );

    Future<List<String>> pump(
      WidgetTester tester,
      List<NetworkActionDto> actions,
    ) async {
      final sent = <String>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            specCodecProvider.overrideWithValue(FakeSpecCodec()),
            lifxControlClientProvider.overrideWithValue(_FakeLifxClient()),
          ],
          child: MaterialApp(
            home: Scaffold(
              body: SingleChildScrollView(
                child: NetworkLightCard(
                  entity: NetworkEntityDto(
                    name: 'Lamp',
                    platform: 'light',
                    transport: 'http',
                    isInstanced: false,
                    stateCommand: '',
                    options: const [],
                    actions: actions,
                  ),
                  specYaml: 'y',
                  host: '10.0.0.7',
                  targetMac: '',
                  sendAction: (action, values) async =>
                      sent.add(action.commandName),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return sent;
    }

    testWidgets('a packed rgb set_color is named in the note', (tester) async {
      await pump(tester, [
        generic('turn_on'),
        generic('turn_off'),
        generic('set_color', ['rgb']),
      ]);
      expect(find.byType(SwatchButton), findsNothing);
      expect(
        find.text(
          'Set color is in this device’s spec but has no control here yet.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a zone action carrying rgb draws no set_color swatches', (
      tester,
    ) async {
      // The card counted set_color as drawn when only set_zone_color carried
      // rgb, but on the generic path no zone can be picked (the zone row is
      // LIFX-only), so every swatch sent the packed set_color with its `rgb`
      // missing. Fails on the old card: 16 swatches, and no note.
      await pump(tester, [
        generic('turn_on'),
        generic('turn_off'),
        generic('set_color', ['rgb']),
        generic('set_zone_color', ['zone', 'red', 'green', 'blue']),
      ]);
      expect(find.byType(SwatchButton), findsNothing);
      expect(find.byType(UnclaimedActions), findsOneWidget);
      expect(find.textContaining('Set color'), findsOneWidget);
    });

    testWidgets('a lone turn_on becomes a button that says On', (tester) async {
      final sent = await pump(tester, [generic('turn_on')]);
      expect(find.byType(Switch), findsNothing);
      await tester.tap(find.byKey(const ValueKey('unclaimed-action:turn_on')));
      await tester.pumpAndSettle();
      expect(sent, ['turn_on']);
      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('a light that draws everything has no unclaimed row', (
      tester,
    ) async {
      await pump(tester, [
        generic('turn_on'),
        generic('turn_off'),
        generic('set_color', ['red', 'green', 'blue']),
      ]);
      expect(find.byType(SwatchButton), findsNWidgets(16));
      expect(find.byType(UnclaimedActions), findsNothing);
    });
  });

  testWidgets('zone chips are named, stateful buttons', (tester) async {
    // Old code: a bare InkWell per zone, announced as an unnamed button.
    final handle = tester.ensureSemantics();
    final codec = FakeSpecCodec()
      ..lifxZones = const LifxZonesDto(
        zonesCount: 2,
        zoneIndex: 0,
        colors: [
          LifxZoneColorDto(red: 255, green: 0, blue: 0, brightness: 255),
          LifxZoneColorDto(red: 0, green: 0, blue: 255, brightness: 255),
        ],
      );
    await tester.pumpWidget(
      _wrap(_lightEntity(multizone: true), codec, _AnsweringLifxClient()),
    );
    await tester.pumpAndSettle();

    final zone1 = find.byKey(const Key('zone-chip-0'));
    expect(tester.getSize(zone1), const Size(48, 48));
    expect(
      tester.getSemantics(zone1),
      isSemantics(label: 'Zone 1, Red', isButton: true, isSelected: false),
    );
    await tester.tap(zone1);
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(zone1),
      isSemantics(label: 'Zone 1, Red', isSelected: true),
    );
    handle.dispose();
  });
}

/// A client whose reads answer, so the zone row has live colours to show.
class _AnsweringLifxClient extends _FakeLifxClient {
  @override
  Future<Uint8List?> request(
    String host,
    Uint8List packet, {
    required int sequence,
    Duration timeout = const Duration(seconds: 1),
    int retries = 2,
  }) async => Uint8List.fromList([0]);
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/core/group_actions.dart';
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
                sendAction: (action, values) async {
                  sent.add((action.commandName, values));
                  return true;
                },
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
      String? unit,
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
      unit: unit,
    );

    Future<List<(String, Map<String, String>)>> pump(
      WidgetTester tester,
      List<NetworkActionDto> actions, {
      double? colorTemperature,
    }) async {
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
                  sendAction: (action, values) async {
                    sent.add((action.commandName, values));
                    return true;
                  },
                  initialColorTemperature: colorTemperature,
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
      slider.onChanged!(3500);
      slider.onChangeEnd!(3500);
      await tester.pumpAndSettle();
      expect(sent.single.$1, 'set_color_temperature');
      expect(sent.single.$2, {'ct': '3500'});
    });

    testWidgets('colour temperature uses the declared native unit', (
      tester,
    ) async {
      final sent = await pump(tester, [
        generic(
          'set_color_temperature',
          ['mireds'],
          min: 143,
          max: 344,
          unit: 'mired',
        ),
      ], colorTemperature: 250);
      final slider = tester.widget<Slider>(
        find.byWidgetPredicate((w) => w is Slider && w.max == 344),
      );
      expect(slider.label, '250 mired');
      expect(slider.semanticFormatterCallback!(250), contains('mired'));
      expect(slider.semanticFormatterCallback!(250), isNot(contains('kelvin')));
      slider.onChanged!(221);
      await tester.pump();
      expect(tester.widget<Slider>(find.byType(Slider)).label, '221 mired');
      slider.onChangeEnd!(221);
      await tester.pumpAndSettle();
      expect(sent.single.$2, {'mireds': '221'});
    });

    // No reading and no drag: there is no white point to show. The card
    // invented 3500 K and clamped it into the action's range, so an Elgato
    // (143..344 mired) opened pinned at "344 mired" and the screen reader
    // announced that as the light's setting — the treadmill's 45d4f6a again.
    testWidgets('colour temperature is not set until read or dragged', (
      tester,
    ) async {
      final sent = await pump(tester, [
        generic(
          'set_color_temperature',
          ['mireds'],
          min: 143,
          max: 344,
          unit: 'mired',
        ),
      ]);
      Slider slider() => tester.widget<Slider>(
        find.byWidgetPredicate((w) => w is Slider && w.max == 344),
      );
      expect(slider().value, 143, reason: 'the thumb rests at the bottom');
      expect(slider().label, isNull);
      expect(slider().semanticFormatterCallback!(143), contains('not set'));
      expect(find.text('344 mired'), findsNothing);
      expect(find.text('143 mired'), findsNothing);
      expect(find.text('—'), findsOneWidget);
      expect(sent, isEmpty);

      slider().onChanged!(200);
      await tester.pump();
      expect(slider().label, '200 mired');
      expect(slider().semanticFormatterCallback!(200), contains('200 mired'));
      expect(find.text('200 mired'), findsOneWidget);
    });

    testWidgets('a reading seeds the colour temperature and a later one moves '
        'it', (tester) async {
      final actions = [
        generic(
          'set_color_temperature',
          ['mireds'],
          min: 143,
          max: 344,
          unit: 'mired',
        ),
      ];
      await pump(tester, actions, colorTemperature: 213);
      Slider slider() => tester.widget<Slider>(
        find.byWidgetPredicate((w) => w is Slider && w.max == 344),
      );
      expect(slider().value, 213);
      expect(find.text('213 mired'), findsOneWidget);
      expect(
        slider().semanticFormatterCallback!(213),
        'Colour temperature 213 mired',
      );

      await pump(tester, actions, colorTemperature: 300);
      expect(slider().value, 300);
      expect(find.text('300 mired'), findsOneWidget);
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
                  sendAction: (action, values) async {
                    sent.add(action.commandName);
                    return true;
                  },
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

  group('the encodings a swatch can be said in', () {
    NetworkActionDto wired(
      String role,
      String transport, [
      List<String> params = const [],
      double? max,
    ]) => NetworkActionDto(
      role: role,
      commandName: role,
      transport: transport,
      userParams: params,
      max: max,
      readBack: const [],
      credentials: const [],
      instanceParams: const [],
    );

    Future<List<(String, Map<String, String>)>> pump(
      WidgetTester tester,
      String transport,
      List<NetworkActionDto> actions, {
      bool supportsSegments = false,
      bool Function()? delivers,
    }) async {
      final sent = <(String, Map<String, String>)>[];
      final deliver = delivers ?? () => true;
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
                    transport: transport,
                    isInstanced: false,
                    stateCommand: '',
                    options: const [],
                    actions: actions,
                  ),
                  specYaml: 'y',
                  host: '10.0.0.7',
                  targetMac: '',
                  supportsSegments: supportsSegments,
                  sendAction: (action, values) async {
                    sent.add((action.commandName, values));
                    return deliver();
                  },
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return sent;
    }

    Finder swatch(int argb) => find.byWidgetPredicate(
      (w) => w is SwatchButton && w.color.toARGB32() == argb,
    );

    testWidgets('a packed rgb is sent packed', (tester) async {
      final sent = await pump(tester, kYeelightTransport, [
        wired('turn_on', kYeelightTransport),
        wired('turn_off', kYeelightTransport),
        wired('set_color', kYeelightTransport, ['rgb'], 16777215),
      ]);
      expect(find.byType(SwatchButton), findsWidgets);
      expect(find.byType(UnclaimedActions), findsNothing);
      await tester.tap(swatch(0xFFFF0000));
      await tester.pumpAndSettle();
      expect(sent.single.$2, {'rgb': '16711680'});
    });

    testWidgets('a bridge sends the hue byte, and offers no white', (
      tester,
    ) async {
      final sent = await pump(tester, kLimitlessledTransport, [
        wired('turn_on', kLimitlessledTransport),
        wired('turn_off', kLimitlessledTransport),
        wired('set_color', kLimitlessledTransport, ['hue'], 255),
      ]);
      expect(swatch(0xFFFFFFFF), findsNothing);
      await tester.tap(swatch(0xFF00FF00));
      await tester.pumpAndSettle();
      expect(sent.single.$2, {'hue': '${0x60}'});
    });

    testWidgets('a bridge\'s chosen zone rides every send', (tester) async {
      final sent = await pump(tester, kLimitlessledTransport, [
        wired('turn_on', kLimitlessledTransport),
        wired('turn_off', kLimitlessledTransport),
        wired('set_color', kLimitlessledTransport, ['hue'], 255),
      ]);
      await tester.tap(find.byKey(const Key('bridge-zone-2')));
      await tester.pumpAndSettle();
      await tester.tap(swatch(0xFFFF0000));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(sent[0].$2, {'hue': '${0xB0}', 'zone': '3'});
      // The colour carried the zone's ON, so the switch's next press is Off.
      expect(sent[1].$1, 'turn_off');
      expect(sent[1].$2, {'zone': '3'});

      await tester.tap(find.byKey(const Key('bridge-zone-all')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('bridge-all-on')));
      await tester.pumpAndSettle();
      expect(sent[2].$1, 'turn_on');
      expect(sent[2].$2, isEmpty);
    });

    testWidgets('a write-only light says what was sent, not what is', (
      tester,
    ) async {
      await pump(tester, kLimitlessledTransport, [
        wired('turn_on', kLimitlessledTransport),
        wired('turn_off', kLimitlessledTransport),
      ]);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('On (sent)'), findsOneWidget);
    });

    testWidgets('a row is painted by sending all five', (tester) async {
      final sent = await pump(tester, kYeelightTransport, [
        wired('turn_on', kYeelightTransport),
        wired('turn_off', kYeelightTransport),
        wired('set_color', kYeelightTransport, ['rgb'], 16777215),
        wired('set_segments', kYeelightTransport, ['colors']),
      ], supportsSegments: true);
      await tester.tap(find.byKey(const Key('lamp-row-1')));
      await tester.pumpAndSettle();
      await tester.tap(swatch(0xFFFF0000));
      await tester.pumpAndSettle();
      expect(sent.single.$1, 'set_segments');
      expect(sent.single.$2, {'colors': '[0, 16711680, 0, 0, 0]'});

      await tester.tap(find.byKey(const Key('lamp-row-all')));
      await tester.pumpAndSettle();
      await tester.tap(swatch(0xFF00FF00));
      await tester.pumpAndSettle();
      expect(sent.last.$1, 'set_color', reason: 'All is the whole lamp');
    });

    List<NetworkActionDto> cube() => [
      wired('turn_on', kYeelightTransport),
      wired('turn_off', kYeelightTransport),
      wired('set_color', kYeelightTransport, ['rgb'], 16777215),
      wired('set_segments', kYeelightTransport, ['colors']),
    ];

    testWidgets('a row edit restates the whole-lamp colour on the others', (
      tester,
    ) async {
      final sent = await pump(
        tester,
        kYeelightTransport,
        cube(),
        supportsSegments: true,
      );
      await tester.tap(swatch(0xFFFF0000));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('lamp-row-1')));
      await tester.pumpAndSettle();
      await tester.tap(swatch(0xFF00FF00));
      await tester.pumpAndSettle();
      expect(sent.last.$1, 'set_segments');
      expect(sent.last.$2, {
        'colors': '[16711680, 65280, 16711680, 16711680, 16711680]',
      });
    });

    testWidgets('a refused whole-lamp colour does not reach the rows', (
      tester,
    ) async {
      var delivered = false;
      final sent = await pump(
        tester,
        kYeelightTransport,
        cube(),
        supportsSegments: true,
        delivers: () => delivered,
      );
      await tester.tap(swatch(0xFFFF0000));
      await tester.pumpAndSettle();
      delivered = true;
      await tester.tap(find.byKey(const Key('lamp-row-0')));
      await tester.pumpAndSettle();
      await tester.tap(swatch(0xFF00FF00));
      await tester.pumpAndSettle();
      expect(sent.last.$2, {'colors': '[65280, 0, 0, 0, 0]'});
    });

    testWidgets('a refused row edit is not restated by the next one', (
      tester,
    ) async {
      var delivered = false;
      final sent = await pump(
        tester,
        kYeelightTransport,
        cube(),
        supportsSegments: true,
        delivers: () => delivered,
      );
      await tester.tap(find.byKey(const Key('lamp-row-0')));
      await tester.pumpAndSettle();
      await tester.tap(swatch(0xFFFF0000));
      await tester.pumpAndSettle();
      expect(sent.last.$2, {'colors': '[16711680, 0, 0, 0, 0]'});

      delivered = true;
      await tester.tap(find.byKey(const Key('lamp-row-1')));
      await tester.pumpAndSettle();
      await tester.tap(swatch(0xFF00FF00));
      await tester.pumpAndSettle();
      expect(sent.last.$2, {'colors': '[0, 65280, 0, 0, 0]'});
    });

    List<NetworkActionDto> bridge() => [
      wired('turn_on', kLimitlessledTransport),
      wired('turn_off', kLimitlessledTransport),
      wired('set_brightness', kLimitlessledTransport, ['level'], 27),
      wired('set_color', kLimitlessledTransport, ['hue'], 255),
    ];

    Future<void> switchOff(WidgetTester tester) async {
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Off (sent)'), findsOneWidget);
    }

    testWidgets('a colour on a bridge turned its zone back on', (tester) async {
      await pump(tester, kLimitlessledTransport, bridge());
      await switchOff(tester);
      await tester.tap(swatch(0xFFFF0000));
      await tester.pumpAndSettle();
      expect(find.text('On (sent)'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('so did a brightness', (tester) async {
      final sent = await pump(tester, kLimitlessledTransport, bridge());
      await switchOff(tester);
      await tester.drag(find.byType(Slider), const Offset(-40, 0));
      await tester.pumpAndSettle();
      expect(sent.last.$1, 'set_brightness');
      expect(find.text('On (sent)'), findsOneWidget);
    });

    testWidgets('a bridge send that did not go leaves the switch alone', (
      tester,
    ) async {
      var delivered = true;
      await pump(
        tester,
        kLimitlessledTransport,
        bridge(),
        delivers: () => delivered,
      );
      await switchOff(tester);
      delivered = false;
      await tester.tap(swatch(0xFFFF0000));
      await tester.pumpAndSettle();
      expect(find.text('Off (sent)'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        find.text('Off (sent)'),
        findsOneWidget,
        reason: 'an On that did not go out did not turn anything on',
      );
    });

    Future<void> pick(WidgetTester tester, String chip) async {
      await tester.tap(find.byKey(Key('bridge-zone-$chip')));
      await tester.pumpAndSettle();
    }

    Future<void> flip(WidgetTester tester) async {
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
    }

    group('a bridge remembers each zone', () {
      testWidgets('one zone off under all on: All states neither', (
        tester,
      ) async {
        final sent = await pump(tester, kLimitlessledTransport, bridge());
        await flip(tester); // all on
        await pick(tester, '0');
        await flip(tester); // zone 1 off
        expect(sent.last.$2, {'zone': '1'});
        expect(find.text('Off (sent)'), findsOneWidget);

        await pick(tester, 'all');
        expect(find.byType(Switch), findsNothing);
        expect(find.text('Zones differ'), findsOneWidget);
        expect(find.text('Off (sent)'), findsNothing);
        expect(find.text('On (sent)'), findsNothing);
      });

      testWidgets('from differing zones, All reaches off', (tester) async {
        final sent = await pump(tester, kLimitlessledTransport, bridge());
        await flip(tester);
        await pick(tester, '0');
        await flip(tester);
        await pick(tester, 'all');

        await tester.tap(find.byKey(const Key('bridge-all-off')));
        await tester.pumpAndSettle();
        expect(sent.last.$1, 'turn_off');
        expect(sent.last.$2, isEmpty, reason: 'every zone');
        expect(find.text('Off (sent)'), findsOneWidget);
        expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

        await pick(tester, '2');
        expect(find.text('Off (sent)'), findsOneWidget, reason: 'all of them');
      });

      testWidgets('from differing zones, All reaches on', (tester) async {
        final sent = await pump(tester, kLimitlessledTransport, bridge());
        await flip(tester);
        await pick(tester, '0');
        await flip(tester);
        await pick(tester, 'all');

        await tester.tap(find.byKey(const Key('bridge-all-on')));
        await tester.pumpAndSettle();
        expect(sent.last.$1, 'turn_on');
        expect(sent.last.$2, isEmpty);
        expect(find.text('On (sent)'), findsOneWidget);

        await pick(tester, '0');
        expect(find.text('On (sent)'), findsOneWidget, reason: 'zone 1 too');
      });

      testWidgets('each zone shows its own, and presses by it', (tester) async {
        final sent = await pump(tester, kLimitlessledTransport, bridge());
        await flip(tester);
        await pick(tester, '0');
        await flip(tester);

        await pick(tester, '1');
        expect(find.text('On (sent)'), findsOneWidget);
        await flip(tester);
        expect(sent.last.$1, 'turn_off', reason: 'zone 2 was on');
        expect(sent.last.$2, {'zone': '2'});

        await pick(tester, '0');
        expect(find.text('Off (sent)'), findsOneWidget);
        await flip(tester);
        expect(sent.last.$1, 'turn_on', reason: 'zone 1 was off');
      });

      testWidgets('agreeing again gets the switch back', (tester) async {
        await pump(tester, kLimitlessledTransport, bridge());
        await flip(tester);
        await pick(tester, '0');
        await flip(tester);
        await flip(tester); // zone 1 back on
        await pick(tester, 'all');
        expect(find.byType(Switch), findsOneWidget);
        expect(find.text('On (sent)'), findsOneWidget);
      });

      testWidgets('a zone told something beside three told nothing differs', (
        tester,
      ) async {
        await pump(tester, kLimitlessledTransport, bridge());
        await pick(tester, '0');
        await flip(tester);
        await pick(tester, 'all');
        expect(find.text('Zones differ'), findsOneWidget);
        await pick(tester, '1');
        expect(find.text('Ready'), findsOneWidget, reason: 'told nothing yet');
      });

      testWidgets('a zone\'s colour turns on that zone and no other', (
        tester,
      ) async {
        await pump(tester, kLimitlessledTransport, bridge());
        await switchOff(tester);
        await pick(tester, '1');
        await tester.tap(swatch(0xFFFF0000));
        await tester.pumpAndSettle();
        expect(find.text('On (sent)'), findsOneWidget);

        await pick(tester, '0');
        expect(find.text('Off (sent)'), findsOneWidget);
        await pick(tester, 'all');
        expect(find.text('Zones differ'), findsOneWidget);
      });

      testWidgets('a zone\'s brightness turns on that zone and no other', (
        tester,
      ) async {
        final sent = await pump(tester, kLimitlessledTransport, bridge());
        await switchOff(tester);
        await pick(tester, '3');
        await tester.drag(find.byType(Slider), const Offset(-40, 0));
        await tester.pumpAndSettle();
        expect(sent.last.$1, 'set_brightness');
        expect(sent.last.$2['zone'], '4');
        expect(find.text('On (sent)'), findsOneWidget);

        await pick(tester, '2');
        expect(find.text('Off (sent)'), findsOneWidget);
      });

      testWidgets('a colour under All turns them all on', (tester) async {
        await pump(tester, kLimitlessledTransport, bridge());
        await flip(tester);
        await pick(tester, '0');
        await flip(tester);
        await pick(tester, 'all');
        await tester.tap(swatch(0xFFFF0000));
        await tester.pumpAndSettle();
        expect(find.text('On (sent)'), findsOneWidget);
        await pick(tester, '0');
        expect(find.text('On (sent)'), findsOneWidget);
      });

      testWidgets('a zone send that did not go changes nothing', (
        tester,
      ) async {
        var delivered = true;
        await pump(
          tester,
          kLimitlessledTransport,
          bridge(),
          delivers: () => delivered,
        );
        await flip(tester);
        delivered = false;
        await pick(tester, '0');
        await flip(tester);
        expect(find.text('On (sent)'), findsOneWidget);
        await pick(tester, 'all');
        expect(find.byType(Switch), findsOneWidget);
        expect(find.text('On (sent)'), findsOneWidget);
      });
    });

    testWidgets('a light with no zones keeps its one switch', (tester) async {
      final sent = await pump(tester, kYeelightTransport, cube());
      expect(find.byKey(const Key('bridge-zone-all')), findsNothing);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('On'), findsOneWidget);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Zones differ'), findsNothing);
      expect(find.byKey(const Key('bridge-all-on')), findsNothing);
      expect(sent.map((s) => s.$2), everyElement(isEmpty));
    });

    testWidgets('a colour says nothing about power on any other light', (
      tester,
    ) async {
      await pump(tester, kYeelightTransport, cube());
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(find.text('Off'), findsOneWidget);
      await tester.tap(swatch(0xFFFF0000));
      await tester.pumpAndSettle();
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('no rows for a unit that did not say it takes them', (
      tester,
    ) async {
      await pump(tester, kYeelightTransport, [
        wired('turn_on', kYeelightTransport),
        wired('turn_off', kYeelightTransport),
        wired('set_segments', kYeelightTransport, ['colors']),
      ]);
      expect(find.byKey(const Key('lamp-row-0')), findsNothing);
      expect(find.byType(UnclaimedActions), findsNothing);
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
                  sendAction: (action, values) async {
                    sent.add(action.commandName);
                    return true;
                  },
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

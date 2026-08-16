// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The network control screen, end to end against a fake codec and canned
// HTTP: load state, render one card per entity, and — the part that must
// never regress — send a mode change WITH the cook time read back from the
// device first, so changing the mode does not clear the timer.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/settings_store_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/network_device_screen.dart';
import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/kasa_control_service.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_control_service.dart';
import 'package:liberated_bread_mobile/services/rabbit_air_key_store.dart';
import 'package:liberated_bread_mobile/services/soap_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_ecp2_socket.dart';
import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

/// The ECP2 override for tests that assert the PLAIN path: a service that
/// never opens a session, so a refusal stays a refusal — without opening a
/// real socket to the test's fictional addresses.
Ecp2ControlService noEcp2() => Ecp2ControlService(
    connector: (host, port) async =>
        throw const Ecp2Exception('no ECP2 in this test'));

/// The ECP2 override for tests of the fallback itself: sessions run on the
/// scripted [socket], which leads with its challenge on connect like a real
/// Roku does.
Ecp2ControlService ecp2On(AutoEcp2Socket socket) =>
    Ecp2ControlService(connector: (host, port) async {
      socket.begin();
      return socket;
    });

const _setupXml = '''
<root><device>
  <deviceType>urn:Belkin:device:crockpot:1</deviceType>
  <friendlyName>Kitchen Crock-Pot</friendlyName>
  <serviceList><service>
    <serviceType>urn:Belkin:service:basicevent:1</serviceType>
    <controlURL>/upnp/control/basicevent1</controlURL>
  </service></serviceList>
</device></root>
''';

String _stateResponse({required int mode, required int time}) => '''
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body>
<u:GetCrockpotStateResponse xmlns:u="urn:Belkin:service:basicevent:1">
<mode>$mode</mode>
<time>$time</time>
<cookedTime>15</cookedTime>
</u:GetCrockpotStateResponse>
</s:Body>
</s:Envelope>
''';

const _ackResponse = '''
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
<s:Body>
<u:SetCrockpotStateResponse xmlns:u="urn:Belkin:service:basicevent:1">
</u:SetCrockpotStateResponse>
</s:Body>
</s:Envelope>
''';

final _cookerDevice = NetworkDevice(
  host: '10.0.0.5',
  name: 'Kitchen Crock-Pot',
  port: 49153,
  ssdpTargets: const ['urn:Belkin:device:crockpot:1'],
  sources: const {NetworkDiscoverySource.ssdp},
  discoveredAt: DateTime.utc(2026),
);

/// The Crock-Pot's entities as the FFI would hand them over, with the
/// mode-change action carrying its documented read-back.
const _entities = [
  NetworkEntityDto(
    isInstanced: false,
    name: 'Slow Cooker',
    platform: 'switch',
    stateCommand: 'GetCrockpotState',
    valueField: 'mode',
    options: [],
    actions: [
      NetworkActionDto(
        credentials: [],
        instanceParams: [],
        role: 'turn_on',
        transport: 'soap',
        commandName: 'crockpot_turn_on',
        userParams: [],
        readBack: [
          NetworkReadBackDto(
              param: 'time', command: 'GetCrockpotState', field: 'time'),
        ],
      ),
      NetworkActionDto(
        credentials: [],
        instanceParams: [],
        role: 'turn_off',
        transport: 'soap',
        commandName: 'crockpot_turn_off',
        userParams: [],
        readBack: [],
      ),
    ],
  ),
  NetworkEntityDto(
    isInstanced: false,
    name: 'Cook Mode',
    platform: 'select',
    stateCommand: 'GetCrockpotState',
    valueField: 'mode',
    options: [
      NetworkOptionDto(raw: '0', label: 'off'),
      NetworkOptionDto(raw: '50', label: 'warm'),
      NetworkOptionDto(raw: '51', label: 'low'),
      NetworkOptionDto(raw: '52', label: 'high'),
    ],
    actions: [
      NetworkActionDto(
        credentials: [],
        instanceParams: [],
        role: 'select_option',
        transport: 'soap',
        commandName: 'set_cook_mode',
        userParams: ['mode'],
        readBack: [
          NetworkReadBackDto(
              param: 'time', command: 'GetCrockpotState', field: 'time'),
        ],
      ),
    ],
  ),
  NetworkEntityDto(
    isInstanced: false,
    name: 'Cooked Time',
    platform: 'sensor',
    unit: 'min',
    stateCommand: 'GetCrockpotState',
    valueField: 'cookedTime',
    options: [],
    actions: [],
  ),
];

NetworkReadingDto? _readCooker(String entity, Map<String, String> returned) {
  switch (entity) {
    case 'Slow Cooker':
      final mode = returned['mode'];
      if (mode == null) return null;
      final on = mode != '0';
      return NetworkReadingDto(
          kind: NetworkReadingKind.onOff, isOn: on, raw: on ? '1' : '0');
    case 'Cook Mode':
      const labels = {'0': 'off', '50': 'warm', '51': 'low', '52': 'high'};
      final mode = returned['mode'];
      if (mode == null) return null;
      final label = labels[mode];
      return label == null
          ? NetworkReadingDto(kind: NetworkReadingKind.unknownOption, raw: mode)
          : NetworkReadingDto(
              kind: NetworkReadingKind.option, label: label, raw: mode);
    case 'Cooked Time':
      final cooked = returned['cookedTime'];
      if (cooked == null) return null;
      return NetworkReadingDto(
          kind: NetworkReadingKind.number,
          number: double.parse(cooked),
          raw: cooked);
  }
  return null;
}

void main() {
  late FakeSpecCodec codec;
  late List<http.Request> posts;

  /// The virtual Crock-Pot: serves its description, answers the state call,
  /// and acknowledges writes. Mode/time move when a Set arrives, like the
  /// appliance's do.
  MockClient cooker({int mode = 0, int time = 0}) {
    var currentMode = mode;
    var currentTime = time;
    return MockClient((request) async {
      if (request.url.path == '/setup.xml') {
        return http.Response(_setupXml, 200);
      }
      posts.add(request);
      final action = request.headers['SOAPACTION'] ?? '';
      if (action.contains('GetCrockpotState')) {
        return http.Response(
            _stateResponse(mode: currentMode, time: currentTime), 200);
      }
      if (action.contains('set_cook_mode') ||
          action.contains('crockpot_turn')) {
        final body = request.body;
        final modeMatch = RegExp('<mode>(\\d+)</mode>').firstMatch(body);
        final timeMatch = RegExp('<time>(\\d+)</time>').firstMatch(body);
        if (modeMatch != null) currentMode = int.parse(modeMatch.group(1)!);
        if (timeMatch != null) currentTime = int.parse(timeMatch.group(1)!);
        return http.Response(_ackResponse, 200);
      }
      return http.Response('unexpected', 500);
    });
  }

  Widget screen(MockClient http) {
    codec = FakeSpecCodec(
      networkEntities: (_) => _entities,
      networkReading: _readCooker,
    );
    // Commands render with the command name in the SOAPACTION so the virtual
    // device — and the assertions — can tell requests apart, and with the
    // values spelled as SetCrockpotState arguments so the device can apply
    // them. What the REAL renderer produces is pinned by the Rust tests
    // against the spec's published bodies; this fake only has to be honest
    // about carrying the values it was handed.
    codec.networkRequest = (name, values) => SoapRequestDto(
          service: 'urn:Belkin:service:basicevent:1',
          action: name,
          soapAction: '"urn:Belkin:service:basicevent:1#$name"',
          path: null,
          body: switch (name) {
            'GetCrockpotState' => '<get/>',
            // The real renderer bakes the fixed commands' literals in; the
            // fake mirrors the published bodies so the virtual device can
            // apply them.
            'crockpot_turn_off' => '<set><mode>0</mode><time>0</time></set>',
            'crockpot_turn_on' =>
              '<set><mode>52</mode><time>${values['time'] ?? '0'}</time></set>',
            _ => '<set>'
                '${values.containsKey('mode') ? '<mode>${values['mode']}</mode>' : ''}'
                '${values.containsKey('time') ? '<time>${values['time']}</time>' : ''}'
                '</set>',
          },
        );
    return ProviderScope(
      overrides: [
        specCodecProvider.overrideWithValue(codec),
        soapControlClientProvider
            .overrideWithValue(SoapControlClient(httpClient: http)),
      ],
      child: const MaterialApp(home: SizedBox()),
    );
  }

  Future<void> pump(WidgetTester tester, MockClient http) async {
    posts = [];
    await tester.pumpWidget(screen(http));
    // Navigate inside the ProviderScope so the screen sees the overrides.
    final context = tester.element(find.byType(SizedBox));
    unawaited(Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => NetworkDeviceScreen(
            device: _cookerDevice,
            controls:
                const NetworkControls(specYaml: 'yaml', entities: _entities)),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('loads state and renders one card per entity', (tester) async {
    await pump(tester, cooker(mode: 51, time: 240));

    // The description's own name, not the SSDP one.
    expect(find.text('Kitchen Crock-Pot'), findsOneWidget);
    // The switch reads on (mode 51 != 0), the select highlights low, the
    // sensor shows its number with the unit.
    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.value, isTrue);
    final low =
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'low'));
    expect(low.selected, isTrue);
    expect(find.text('15 min'), findsOneWidget);
  });

  testWidgets('changing the mode reads the cook time back first',
      (tester) async {
    await pump(tester, cooker(mode: 52, time: 240));

    await tester.tap(find.widgetWithText(ChoiceChip, 'warm'));
    await tester.pumpAndSettle();

    // The command carried BOTH the picked mode and the time the device
    // reported — the documented Crock-Pot rule. A send without the time
    // would have cleared the timer to the spec default of 0.
    final call = codec.renderNetworkCommandCalls.single;
    expect(call.commandName, 'set_cook_mode');
    expect(call.values, {'mode': '50', 'time': '240'});

    // And the device's reply, not the tap, is what the UI now shows.
    final warm =
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'warm'));
    expect(warm.selected, isTrue);
  });

  testWidgets('an unknown mode reads as unrecognized, never as off',
      (tester) async {
    await pump(tester, cooker(mode: 99, time: 0));

    expect(find.textContaining('Unrecognized state (99)'), findsOneWidget);
    final off =
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'off'));
    expect(off.selected, isFalse);
  });

  testWidgets('turning off sends without a read-back', (tester) async {
    await pump(tester, cooker(mode: 51, time: 240));

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    final call = codec.renderNetworkCommandCalls.single;
    expect(call.commandName, 'crockpot_turn_off');
    // Off is the one write with nothing to read first — the spec defaults
    // both arguments, so the screen sends no values at all.
    expect(call.values, isEmpty);
    final toggle = tester.widget<Switch>(find.byType(Switch));
    expect(toggle.value, isFalse);
  });

  testWidgets('an unreachable device degrades to an error, not a crash',
      (tester) async {
    await pump(tester, MockClient((request) async => http.Response('no', 500)));

    expect(find.byType(Switch), findsNothing);
    expect(find.textContaining('Could not reach'), findsOneWidget);
  });

  // ── The other transport: a remote of stateless plain-HTTP buttons ────────
  //
  // Roku-shaped: every entity is a `button` whose press renders to
  // POST /keypress/<Key>. No setup.xml, no state polling — the screen must
  // work without ever fetching a description, and a 403 is a settings
  // problem, not a network one.
  group('plain-HTTP remote', () {
    final rokuDevice = NetworkDevice(
      host: '10.0.0.9',
      name: '',
      port: 8060,
      ssdpTargets: const ['roku:ecp'],
      sources: const {NetworkDiscoverySource.ssdp},
      discoveredAt: DateTime.utc(2026),
    );

    const remoteEntities = [
      NetworkEntityDto(
        isInstanced: false,
        name: 'Power On',
        platform: 'button',
        icon: 'mdi:power',
        stateCommand: '',
        options: [],
        actions: [
          NetworkActionDto(
            credentials: [],
            instanceParams: [],
            role: 'press',
            commandName: 'press_power_on',
            transport: 'http',
            userParams: [],
            readBack: [],
          ),
        ],
      ),
      NetworkEntityDto(
        isInstanced: false,
        name: 'Home',
        platform: 'button',
        icon: 'mdi:home',
        stateCommand: '',
        options: [],
        actions: [
          NetworkActionDto(
            credentials: [],
            instanceParams: [],
            role: 'press',
            commandName: 'press_home',
            transport: 'http',
            userParams: [],
            readBack: [],
          ),
        ],
      ),
    ];

    /// Requests the virtual Roku received, and its canned answer.
    Future<void> pumpRemote(
      WidgetTester tester, {
      required List<http.Request> received,
      int statusCode = 200,
      List<NetworkEntityDto> entities = remoteEntities,
      Ecp2ControlService? ecp2,
    }) async {
      codec = FakeSpecCodec(
        networkEntities: (_) => entities,
        networkHttpRequest: (name, _) => HttpRequestDto(
          method: 'POST',
          path: switch (name) {
            'press_power_on' => '/keypress/PowerOn',
            'press_home' => '/keypress/Home',
            _ => '/keypress/$name',
          },
          body: '',
        ),
      );
      final roku = MockClient((request) async {
        received.add(request);
        return http.Response('', statusCode);
      });
      // The SOAP client MUST go unused: a Roku serves no setup.xml, and a
      // screen that asks for one turns the remote into an error screen.
      final soap = MockClient((request) async {
        fail('the description was fetched for a device that needs none: '
            '${request.url}');
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(codec),
          soapControlClientProvider
              .overrideWithValue(SoapControlClient(httpClient: soap)),
          httpControlClientProvider
              .overrideWithValue(HttpControlClient(httpClient: roku)),
          ecp2ControlServiceProvider.overrideWithValue(ecp2 ?? noEcp2()),
        ],
        child: const MaterialApp(home: SizedBox()),
      ));
      final context = tester.element(find.byType(SizedBox));
      unawaited(Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkDeviceScreen(
              device: rokuDevice,
              controls: NetworkControls(specYaml: 'yaml', entities: entities)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('renders the remote without fetching any description',
        (tester) async {
      final received = <http.Request>[];
      await pumpRemote(tester, received: received);

      // One Remote card carrying every button, ready with no I/O at all.
      expect(find.text('Remote'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Power On'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Home'), findsOneWidget);
      expect(received, isEmpty);
      expect(find.textContaining('Could not reach'), findsNothing);
    });

    testWidgets('pressing a button POSTs the rendered keypress',
        (tester) async {
      final received = <http.Request>[];
      await pumpRemote(tester, received: received);

      await tester.tap(find.widgetWithText(FilledButton, 'Power On'));
      await tester.pumpAndSettle();

      final call = codec.renderNetworkHttpCommandCalls.single;
      expect(call.commandName, 'press_power_on');
      expect(call.values, isEmpty);

      final request = received.single;
      expect(request.method, 'POST');
      expect(request.url.toString(), 'http://10.0.0.9:8060/keypress/PowerOn');
      expect(request.body, isEmpty);
      // Nothing about a keypress warrants a state poll afterwards.
      expect(received, hasLength(1));
    });

    testWidgets('a 403 explains the device-side setting', (tester) async {
      final received = <http.Request>[];
      await pumpRemote(tester, received: received, statusCode: 403);

      await tester.tap(find.widgetWithText(FilledButton, 'Home'));
      await tester.pumpAndSettle();

      // The wording is the ControlRefusedException's: a settings problem on
      // the device, not a network failure and not the generic fallback.
      expect(find.textContaining('control by mobile apps'), findsOneWidget);
      expect(find.textContaining('did not accept'), findsNothing);

      // And the standing note, which says what still worked — a user whose
      // TV ignores every button is otherwise left wondering whether the app
      // found the right device at all.
      expect(find.text('The device is refusing commands'), findsOneWidget);
      expect(find.textContaining('answered discovery'), findsOneWidget);
    });

    NetworkEntityDto button(String name, [String? icon]) => NetworkEntityDto(
          name: name,
          platform: 'button',
          icon: icon,
          isInstanced: false,
          stateCommand: '',
          options: [],
          actions: [
            NetworkActionDto(
              role: 'press',
              commandName: 'press_${name.toLowerCase().replaceAll(' ', '_')}',
              transport: 'http',
              userParams: [],
              readBack: [],
              credentials: [],
              instanceParams: [],
            ),
          ],
        );

    testWidgets('lays the full key set out like a remote', (tester) async {
      // The whole Roku entity list from the spec, placed by name: D-pad with
      // OK in the middle, rockers for volume and channel, inputs in a wrap.
      final fullRemote = [
        button('Power On', 'mdi:power'),
        button('Power Off', 'mdi:power-off'),
        button('Back', 'mdi:arrow-u-left-top'),
        button('Home', 'mdi:home'),
        button('Up', 'mdi:chevron-up'),
        button('Left', 'mdi:chevron-left'),
        button('OK'),
        button('Right', 'mdi:chevron-right'),
        button('Down', 'mdi:chevron-down'),
        button('Replay', 'mdi:replay'),
        button('Options', 'mdi:asterisk'),
        button('Rewind', 'mdi:rewind'),
        button('Play/Pause', 'mdi:play-pause'),
        button('Fast Forward', 'mdi:fast-forward'),
        button('Volume Down', 'mdi:volume-minus'),
        button('Mute', 'mdi:volume-mute'),
        button('Volume Up', 'mdi:volume-plus'),
        button('Channel Up', 'mdi:chevron-double-up'),
        button('Channel Down', 'mdi:chevron-double-down'),
        button('Search', 'mdi:magnify'),
        button('Find Remote', 'mdi:remote'),
        button('HDMI 1', 'mdi:hdmi-port'),
        button('HDMI 2', 'mdi:hdmi-port'),
        button('AV', 'mdi:video-input-component'),
        button('Antenna', 'mdi:antenna'),
      ];
      await pumpRemote(tester, received: [], entities: fullRemote);

      // The D-pad's keys are icon buttons; OK is the labelled centre.
      Finder iconKey(String tooltip) => find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == tooltip);
      for (final key in ['Up', 'Down', 'Left', 'Right']) {
        expect(iconKey(key), findsOneWidget,
            reason: '$key should be an icon key on the D-pad');
      }
      expect(find.widgetWithText(FilledButton, 'OK'), findsOneWidget);

      // The rockers: volume and channel as icon keys, not labelled chips.
      for (final key in ['Volume Up', 'Volume Down', 'Mute']) {
        expect(iconKey(key), findsOneWidget);
      }

      // Inputs get their own section; nothing landed in the leftover wrap.
      expect(find.text('Inputs'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'HDMI 1'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Antenna'), findsOneWidget);

      // Up sits directly above OK, Down directly below — the pad's shape.
      final upPos = tester.getCenter(iconKey('Up'));
      final okPos = tester.getCenter(find.widgetWithText(FilledButton, 'OK'));
      final downPos = tester.getCenter(iconKey('Down'));
      expect(upPos.dx, closeTo(okPos.dx, 1));
      expect(downPos.dx, closeTo(okPos.dx, 1));
      expect(upPos.dy, lessThan(okPos.dy));
      expect(okPos.dy, lessThan(downPos.dy));
    });

    testWidgets('renders the channel picker below the button pad',
        (tester) async {
      // A spec-optioned picker (no device fetch needed) next to one remote
      // button: the pad must sit above the picker, so the remote keeps its
      // place whether or not the channel list has loaded yet.
      const picker = NetworkEntityDto(
        isInstanced: false,
        name: 'Channel',
        platform: 'select',
        stateCommand: '',
        options: [
          NetworkOptionDto(raw: '12', label: 'Netflix'),
          NetworkOptionDto(raw: '837', label: 'YouTube'),
        ],
        actions: [
          NetworkActionDto(
            credentials: [],
            instanceParams: [],
            role: 'select_option',
            commandName: 'launch_app',
            transport: 'http',
            userParams: ['app_id'],
            readBack: [],
          ),
        ],
      );
      await pumpRemote(tester,
          received: [], entities: [button('Home', 'mdi:home'), picker]);

      expect(find.widgetWithText(FilledButton, 'Home'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Netflix'), findsOneWidget);

      final padPos =
          tester.getCenter(find.widgetWithText(FilledButton, 'Home'));
      final pickerPos =
          tester.getCenter(find.widgetWithText(ChoiceChip, 'Netflix'));
      expect(pickerPos.dy, greaterThan(padPos.dy),
          reason: 'the channel picker is the foot of the remote, '
              'below the button pad');
    });
  });

  // ── The channel launcher: options that live on the device ───────────────
  group('device-sourced channel list', () {
    final rokuDevice = NetworkDevice(
      host: '10.0.0.9',
      name: '',
      port: 8060,
      ssdpTargets: const ['roku:ecp'],
      sources: const {NetworkDiscoverySource.ssdp},
      discoveredAt: DateTime.utc(2026),
    );

    const channelEntity = NetworkEntityDto(
      isInstanced: false,
      name: 'Channel',
      platform: 'select',
      stateCommand: '',
      options: [],
      optionsSource: QuerySourceDto(
        method: 'GET',
        path: '/query/apps',
        item: 'app',
        valueAttribute: 'id',
      ),
      stateSource: QuerySourceDto(
        method: 'GET',
        path: '/query/active-app',
        item: 'app',
        valueAttribute: 'id',
      ),
      actions: [
        NetworkActionDto(
          credentials: [],
          instanceParams: [],
          role: 'select_option',
          commandName: 'launch_app',
          transport: 'http',
          userParams: ['app_id'],
          readBack: [],
        ),
      ],
    );

    const apps = '''
<apps>
  <app id="12">Netflix</app>
  <app id="837">YouTube</app>
</apps>
''';

    /// A virtual Roku: serves both query lists, records launches, and moves
    /// its foreground channel when one arrives — like the device does.
    /// [appsStatus]/[appsBody] let a test make the device refuse the list.
    Future<List<http.Request>> pumpChannels(
      WidgetTester tester, {
      String activeApp = '<active-app><app id="837">YouTube</app></active-app>',
      int appsStatus = 200,
      String appsBody = apps,
      Ecp2ControlService? ecp2,
    }) async {
      final received = <http.Request>[];
      var current = activeApp;
      codec = FakeSpecCodec(
        networkEntities: (_) => [channelEntity],
        networkHttpRequest: (name, values) => HttpRequestDto(
            method: 'POST', path: '/launch/${values['app_id']}', body: ''),
      );
      final roku = MockClient((request) async {
        received.add(request);
        if (request.url.path == '/query/apps') {
          return http.Response(appsBody, appsStatus);
        }
        if (request.url.path == '/query/active-app') {
          return http.Response(current, 200);
        }
        final launched = request.url.path.split('/').last;
        current = '<active-app><app id="$launched">Now</app></active-app>';
        return http.Response('', 200);
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(codec),
          soapControlClientProvider.overrideWithValue(SoapControlClient(
              httpClient: MockClient((request) async =>
                  fail('no description exists for this device')))),
          httpControlClientProvider
              .overrideWithValue(HttpControlClient(httpClient: roku)),
          ecp2ControlServiceProvider.overrideWithValue(ecp2 ?? noEcp2()),
        ],
        child: const MaterialApp(home: SizedBox()),
      ));
      final context = tester.element(find.byType(SizedBox));
      unawaited(Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkDeviceScreen(
              device: rokuDevice,
              controls: const NetworkControls(
                  specYaml: 'yaml', entities: [channelEntity])),
        ),
      ));
      await tester.pumpAndSettle();
      return received;
    }

    testWidgets('lists the channels the device says it has', (tester) async {
      final received = await pumpChannels(tester);

      expect(find.widgetWithText(ChoiceChip, 'Netflix'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'YouTube'), findsOneWidget);
      // The foreground channel is the selected one — read from the device,
      // not guessed.
      final youtube =
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'YouTube'));
      expect(youtube.selected, isTrue);
      final netflix =
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Netflix'));
      expect(netflix.selected, isFalse);
      expect(received.map((r) => r.url.path),
          containsAll(<String>['/query/apps', '/query/active-app']));
    });

    testWidgets('tapping a channel launches it and re-reads what is current',
        (tester) async {
      final received = await pumpChannels(tester);
      received.clear();

      await tester.tap(find.widgetWithText(ChoiceChip, 'Netflix'));
      await tester.pumpAndSettle();

      // The launch carried the id the list gave it...
      final call = codec.renderNetworkHttpCommandCalls.single;
      expect(call.commandName, 'launch_app');
      expect(call.values, {'app_id': '12'});
      expect(received.first.url.path, '/launch/12');
      // ...and the selection now follows the device, which is why the state
      // source is re-read rather than assumed from the tap.
      final netflix =
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Netflix'));
      expect(netflix.selected, isTrue);
    });

    testWidgets('a refused list says so, instead of reading as no channels',
        (tester) async {
      // Limited mode answers /query/apps with 400 and this body — the fleet's
      // other spelling of 403. The list exists; the device will not share it.
      await pumpChannels(tester,
          appsStatus: 400,
          appsBody: 'ECP command not allowed in Limited mode.');

      expect(find.widgetWithText(ChoiceChip, 'Netflix'), findsNothing);
      expect(
          find.textContaining('refusing to share this list'), findsOneWidget);
      expect(find.text('The device is refusing commands'), findsOneWidget);
      expect(find.text('The device listed nothing here.'), findsNothing);
    });

    testWidgets('an unanswered list says the device did not answer',
        (tester) async {
      // Distinct from refused and from empty: the query failed outright
      // (asleep TV, stale address), and "listed nothing" would be a lie.
      await pumpChannels(tester, appsStatus: 500, appsBody: 'gone');

      expect(find.widgetWithText(ChoiceChip, 'Netflix'), findsNothing);
      expect(find.textContaining('did not answer'), findsOneWidget);
      expect(find.text('The device listed nothing here.'), findsNothing);
      expect(find.text('The device is refusing commands'), findsNothing);
    });

    testWidgets('the home screen reads as no channel selected', (tester) async {
      // Roku's home screen answers with an <app> carrying no id at all.
      await pumpChannels(tester,
          activeApp: '<active-app><app>Roku</app></active-app>');

      for (final label in ['Netflix', 'YouTube']) {
        final chip =
            tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));
        expect(chip.selected, isFalse,
            reason: '$label must not read as current on the home screen');
      }
    });
  });

  // ── The on-screen keyboard: shown only when a field is focused ───────────
  group('keyboard usability gate', () {
    final rokuDevice = NetworkDevice(
      host: '10.0.0.9',
      name: '',
      port: 8060,
      ssdpTargets: const ['roku:ecp'],
      sources: const {NetworkDiscoverySource.ssdp},
      discoveredAt: DateTime.utc(2026),
    );

    const keyboardEntity = NetworkEntityDto(
      isInstanced: false,
      name: 'Keyboard',
      platform: 'text',
      stateCommand: '',
      options: [],
      actions: [
        NetworkActionDto(
          credentials: [],
          instanceParams: [],
          role: 'submit',
          commandName: 'type_char',
          transport: 'http',
          userParams: ['char'],
          readBack: [],
        ),
        NetworkActionDto(
          credentials: [],
          instanceParams: [],
          role: 'press',
          commandName: 'press_backspace',
          transport: 'http',
          userParams: [],
          readBack: [],
        ),
      ],
    );

    /// Mount the keyboard-only Roku screen against a virtual Limited-mode TV
    /// whose ECP2 session reports [textEditId] as the focused field ('none'
    /// for nothing focused). [ecp2] null runs with no ECP2 at all, so the
    /// signal can never be read.
    Future<void> pumpKeyboard(
      WidgetTester tester, {
      String textEditId = 'none',
      bool withEcp2 = true,
    }) async {
      codec = FakeSpecCodec(networkEntities: (_) => [keyboardEntity]);
      final ecp2 = withEcp2
          ? ecp2On(AutoEcp2Socket(queryPayloads: {
              'query-textedit-state':
                  '{"textedit-state":{"textedit-id":"$textEditId"}}',
            }))
          : noEcp2();
      await tester.pumpWidget(ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(codec),
          soapControlClientProvider.overrideWithValue(SoapControlClient(
              httpClient: MockClient((request) async =>
                  fail('a keyboard remote fetches no description')))),
          httpControlClientProvider.overrideWithValue(HttpControlClient(
              httpClient: MockClient(
                  (request) async => fail('nothing types during a render')))),
          ecp2ControlServiceProvider.overrideWithValue(ecp2),
        ],
        child: MaterialApp(
          home: NetworkDeviceScreen(
              device: rokuDevice,
              controls: const NetworkControls(
                  specYaml: 'yaml', entities: [keyboardEntity])),
        ),
      ));
      // Let the load drop the spinner and the ECP2 textedit poll resolve — a
      // handful of microtask turns, not a settle (the poll timer never idles).
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
    }

    testWidgets('hides the keyboard when no field is focused', (tester) async {
      await pumpKeyboard(tester, textEditId: 'none');

      expect(find.byType(TextField), findsNothing,
          reason: 'a keystroke with nothing focused has nowhere to land');
      // The remote itself loaded — it is the keyboard specifically that waits.
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await tester.pumpWidget(const SizedBox()); // dispose: cancel the poll.
    });

    testWidgets('shows the keyboard when a field is focused', (tester) async {
      await pumpKeyboard(tester, textEditId: 'search-1');

      expect(find.byType(TextField), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('a live textedit notice flips the keyboard on without a poll',
        (tester) async {
      // The device volunteers focus changes; the card must react to the notice,
      // not wait out the 3s backstop poll.
      final socket = AutoEcp2Socket(queryPayloads: {
        'query-textedit-state': '{"textedit-state":{"textedit-id":"none"}}',
      });
      codec = FakeSpecCodec(networkEntities: (_) => [keyboardEntity]);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(codec),
          soapControlClientProvider.overrideWithValue(SoapControlClient(
              httpClient: MockClient((r) async => fail('no description')))),
          httpControlClientProvider.overrideWithValue(HttpControlClient(
              httpClient: MockClient((r) async => fail('nothing types')))),
          ecp2ControlServiceProvider.overrideWithValue(ecp2On(socket)),
        ],
        child: MaterialApp(
          home: NetworkDeviceScreen(
              device: rokuDevice,
              controls: const NetworkControls(
                  specYaml: 'yaml', entities: [keyboardEntity])),
        ),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump();
      }
      expect(find.byType(TextField), findsNothing,
          reason: 'the poll read "none"');

      socket.receive({
        'notify': 'textedit',
        'textedit-state': {'textedit-id': 'search-9'},
      });
      await tester.pump();
      await tester.pump();
      expect(find.byType(TextField), findsOneWidget,
          reason: 'the notice flips it on live');

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('shows the keyboard when the signal cannot be read',
        (tester) async {
      // No ECP2 session means no textedit-state to read; the keyboard shows
      // rather than hide a control the user might have been able to use.
      await pumpKeyboard(tester, withEcp2: false);

      expect(find.byType(TextField), findsOneWidget);

      await tester.pumpWidget(const SizedBox());
    });

    testWidgets(
        'a focused keyboard sits above the channel picker; an uncertain one '
        'sits below it', (tester) async {
      const channelEntity = NetworkEntityDto(
        isInstanced: false,
        name: 'Channel',
        platform: 'select',
        stateCommand: '',
        options: [],
        optionsSource: QuerySourceDto(
            method: 'GET',
            path: '/query/apps',
            item: 'app',
            valueAttribute: 'id'),
        actions: [],
      );

      Future<void> pumpRemote(
          {required bool withEcp2, String textEditId = 'none'}) async {
        codec = FakeSpecCodec(
            networkEntities: (_) => [channelEntity, keyboardEntity]);
        final ecp2 = withEcp2
            ? ecp2On(AutoEcp2Socket(queryPayloads: {
                'query-textedit-state':
                    '{"textedit-state":{"textedit-id":"$textEditId"}}',
              }))
            : noEcp2();
        final roku = MockClient((request) async =>
            request.url.path == '/query/apps'
                ? http.Response('<apps><app id="12">Netflix</app></apps>', 200)
                : http.Response('', 200));
        await tester.pumpWidget(ProviderScope(
          overrides: [
            specCodecProvider.overrideWithValue(codec),
            soapControlClientProvider.overrideWithValue(SoapControlClient(
                httpClient:
                    MockClient((r) async => fail('a remote fetches no xml')))),
            httpControlClientProvider
                .overrideWithValue(HttpControlClient(httpClient: roku)),
            ecp2ControlServiceProvider.overrideWithValue(ecp2),
          ],
          child: MaterialApp(
            home: NetworkDeviceScreen(
                device: rokuDevice,
                controls: const NetworkControls(
                    specYaml: 'yaml',
                    entities: [channelEntity, keyboardEntity])),
          ),
        ));
        for (var i = 0; i < 8; i++) {
          await tester.pump();
        }
      }

      // A focused field: the keyboard rides above the channel picker.
      await pumpRemote(withEcp2: true, textEditId: 'search-1');
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.getTopLeft(find.text('Keyboard')).dy,
          lessThan(tester.getTopLeft(find.text('Channel')).dy));
      await tester.pumpWidget(const SizedBox());

      // Unknown (no signed session): it drops to the foot, below the channels.
      await pumpRemote(withEcp2: false);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.getTopLeft(find.text('Keyboard')).dy,
          greaterThan(tester.getTopLeft(find.text('Channel')).dy));
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ── The TV keyboard: one keystroke per character ─────────────────────────
  group('text entry', () {
    final rokuDevice = NetworkDevice(
      host: '10.0.0.9',
      name: '',
      port: 8060,
      ssdpTargets: const ['roku:ecp'],
      sources: const {NetworkDiscoverySource.ssdp},
      discoveredAt: DateTime.utc(2026),
    );

    const keyboardEntity = NetworkEntityDto(
      name: 'Keyboard',
      platform: 'text',
      icon: 'mdi:keyboard',
      isInstanced: false,
      stateCommand: '',
      options: [],
      actions: [
        NetworkActionDto(
          role: 'submit',
          commandName: 'type_char',
          transport: 'http',
          userParams: ['char'],
          readBack: [],
          credentials: [],
          instanceParams: [],
        ),
        NetworkActionDto(
          role: 'press',
          commandName: 'press_backspace',
          transport: 'http',
          userParams: [],
          readBack: [],
          credentials: [],
          instanceParams: [],
        ),
      ],
    );

    Future<List<http.Request>> pumpKeyboard(WidgetTester tester,
        {Ecp2ControlService? ecp2}) async {
      final received = <http.Request>[];
      codec = FakeSpecCodec(
        networkEntities: (_) => [keyboardEntity],
        networkHttpRequest: (name, values) => HttpRequestDto(
          method: 'POST',
          path: name == 'type_char'
              ? '/keypress/Lit_${values['char']}'
              : '/keypress/Backspace',
          body: '',
        ),
      );
      final roku = MockClient((request) async {
        received.add(request);
        return http.Response('', 200);
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(codec),
          soapControlClientProvider.overrideWithValue(SoapControlClient(
              httpClient: MockClient((request) async =>
                  fail('no description exists for this device')))),
          httpControlClientProvider
              .overrideWithValue(HttpControlClient(httpClient: roku)),
          ecp2ControlServiceProvider.overrideWithValue(ecp2 ?? noEcp2()),
        ],
        child: const MaterialApp(home: SizedBox()),
      ));
      final context = tester.element(find.byType(SizedBox));
      unawaited(Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkDeviceScreen(
              device: rokuDevice,
              controls: const NetworkControls(
                  specYaml: 'yaml', entities: [keyboardEntity])),
        ),
      ));
      await tester.pumpAndSettle();
      return received;
    }

    testWidgets('typing sends one keypress per character, in order',
        (tester) async {
      final received = await pumpKeyboard(tester);

      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pumpAndSettle();

      expect(received.map((r) => r.url.path),
          ['/keypress/Lit_a', '/keypress/Lit_b']);
    });

    testWidgets('deleting sends backspace per removed character',
        (tester) async {
      final received = await pumpKeyboard(tester);
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pumpAndSettle();
      received.clear();

      await tester.enterText(find.byType(TextField), 'a');
      await tester.pumpAndSettle();

      expect(received.map((r) => r.url.path), ['/keypress/Backspace']);
    });

    testWidgets('an edit in the middle retypes only the difference',
        (tester) async {
      final received = await pumpKeyboard(tester);
      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pumpAndSettle();
      received.clear();

      await tester.enterText(find.byType(TextField), 'abx');
      await tester.pumpAndSettle();

      expect(received.map((r) => r.url.path),
          ['/keypress/Backspace', '/keypress/Lit_x']);
    });

    testWidgets('the backspace key deletes on the device and in the field',
        (tester) async {
      final received = await pumpKeyboard(tester);
      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pumpAndSettle();
      received.clear();

      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pumpAndSettle();

      expect(received.map((r) => r.url.path), ['/keypress/Backspace']);
      expect(tester.widget<TextField>(find.byType(TextField)).controller?.text,
          'a');
    });
  });

  // ── The ECP2 session is the primary path for every Roku ─────────────────
  //
  // A Roku is driven over the app's authenticated ECP2 session for
  // everything — the remote, the channel list and the keyboard — the same
  // path the official Roku app uses. Plain ECP is only a fallback for when the
  // session is unavailable (that path is the plain-HTTP remote group), so here
  // the plain client is wired to fail if it is ever touched. These tests run
  // the whole surface against a scripted socket playing the device.
  group('ECP2 session (primary Roku path)', () {
    final rokuDevice = NetworkDevice(
      host: '10.0.0.9',
      name: '',
      port: 8060,
      ssdpTargets: const ['roku:ecp'],
      sources: const {NetworkDiscoverySource.ssdp},
      discoveredAt: DateTime.utc(2026),
    );

    const channelEntity = NetworkEntityDto(
      name: 'Channel',
      platform: 'select',
      isInstanced: false,
      stateCommand: '',
      options: [],
      optionsSource: QuerySourceDto(
        method: 'GET',
        path: '/query/apps',
        item: 'app',
        valueAttribute: 'id',
      ),
      stateSource: QuerySourceDto(
        method: 'GET',
        path: '/query/active-app',
        item: 'app',
        valueAttribute: 'id',
      ),
      actions: [
        NetworkActionDto(
          role: 'select_option',
          commandName: 'launch_app',
          transport: 'http',
          userParams: ['app_id'],
          readBack: [],
          credentials: [],
          instanceParams: [],
        ),
      ],
    );

    const homeButton = NetworkEntityDto(
      name: 'Home',
      platform: 'button',
      icon: 'mdi:home',
      isInstanced: false,
      stateCommand: '',
      options: [],
      actions: [
        NetworkActionDto(
          role: 'press',
          commandName: 'press_home',
          transport: 'http',
          userParams: [],
          readBack: [],
          credentials: [],
          instanceParams: [],
        ),
      ],
    );

    const keyboardEntity = NetworkEntityDto(
      name: 'Keyboard',
      platform: 'text',
      icon: 'mdi:keyboard',
      isInstanced: false,
      stateCommand: '',
      options: [],
      actions: [
        NetworkActionDto(
          role: 'submit',
          commandName: 'type_char',
          transport: 'http',
          userParams: ['char'],
          readBack: [],
          credentials: [],
          instanceParams: [],
        ),
      ],
    );

    /// A virtual Roku driven entirely over the ECP2 session on [socket]. The
    /// plain-ECP client fails if it is ever called, so a passing test proves
    /// the session carried the whole surface, not the plain path.
    Future<AutoEcp2Socket> pumpRoku(
      WidgetTester tester, {
      required List<NetworkEntityDto> entities,
      required Map<String, String> queryPayloads,
      required HttpRequestDto Function(String, Map<String, String>) render,
    }) async {
      final socket = AutoEcp2Socket(queryPayloads: queryPayloads);
      codec = FakeSpecCodec(
        networkEntities: (_) => entities,
        networkHttpRequest: render,
      );
      final plain = MockClient((request) async => fail(
          'plain ECP was used while the ECP2 session was available: '
          '${request.url}'));
      await tester.pumpWidget(ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(codec),
          soapControlClientProvider.overrideWithValue(SoapControlClient(
              httpClient: MockClient((request) async =>
                  fail('no description exists for this device')))),
          httpControlClientProvider
              .overrideWithValue(HttpControlClient(httpClient: plain)),
          ecp2ControlServiceProvider.overrideWithValue(ecp2On(socket)),
        ],
        child: const MaterialApp(home: SizedBox()),
      ));
      final context = tester.element(find.byType(SizedBox));
      unawaited(Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkDeviceScreen(
              device: rokuDevice,
              controls: NetworkControls(specYaml: 'yaml', entities: entities)),
        ),
      ));
      await tester.pumpAndSettle();
      return socket;
    }

    testWidgets('the channel list loads over the session', (tester) async {
      await pumpRoku(
        tester,
        entities: const [channelEntity],
        queryPayloads: const {
          'query-apps': '<apps>'
              '<app id="12">Netflix</app>'
              '<app id="837">YouTube</app>'
              '</apps>',
          'query-active-app':
              '<active-app><app id="837">YouTube</app></active-app>',
        },
        render: (name, values) => HttpRequestDto(
            method: 'POST', path: '/launch/${values['app_id']}', body: ''),
      );

      expect(find.widgetWithText(ChoiceChip, 'Netflix'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'YouTube'), findsOneWidget);
      final youtube =
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'YouTube'));
      expect(youtube.selected, isTrue);
      // Control works, so no gate note and no "list refused" note.
      expect(find.text('The device is refusing commands'), findsNothing);
      expect(find.textContaining('refusing to share this list'), findsNothing);
    });

    testWidgets('a keypress goes through the session', (tester) async {
      final socket = await pumpRoku(
        tester,
        entities: const [homeButton],
        queryPayloads: const {},
        render: (name, values) => const HttpRequestDto(
            method: 'POST', path: '/keypress/Home', body: ''),
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Home'));
      await tester.pumpAndSettle();

      expect(socket.sent, contains(containsPair('request', 'key-press')));
      final keypress =
          socket.sent.firstWhere((frame) => frame['request'] == 'key-press');
      expect(keypress['param-key'], 'Home');
      expect(find.text('The device is refusing commands'), findsNothing);
    });

    testWidgets('typing goes over the session, one key-press per character',
        (tester) async {
      final socket = await pumpRoku(
        tester,
        entities: const [keyboardEntity],
        queryPayloads: const {},
        render: (name, values) => HttpRequestDto(
            method: 'POST', path: '/keypress/Lit_${values['char']}', body: ''),
      );

      await tester.enterText(find.byType(TextField), 'ab');
      await tester.pumpAndSettle();

      final keys = [
        for (final frame in socket.sent)
          if (frame['request'] == 'key-press') frame['param-key'],
      ];
      expect(keys, ['Lit_a', 'Lit_b']);
    });
  });

  // ── The third transport: a Kasa smart plug over TCP-JSON ─────────────────
  //
  // Switch-shaped like the Crock-Pot, but over a raw socket: no setup.xml and
  // no UPnP control URLs. The screen polls get_sysinfo, reflects the reported
  // relay state, and after a toggle sends set_relay_state and re-polls, so the
  // switch shows the plug's true state either way.
  group('Kasa smart plug', () {
    final kasaDevice = NetworkDevice(
      host: '10.0.0.7',
      name: 'Desk Lamp',
      port: 9999,
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime.utc(2026),
    );

    const kasaEntities = [
      NetworkEntityDto(
        name: 'Outlet',
        platform: 'switch',
        deviceClass: 'outlet',
        stateCommand: 'get_sysinfo',
        valueField: 'relay_state',
        options: [],
        isInstanced: false,
        actions: [
          NetworkActionDto(
            role: 'turn_on',
            commandName: 'relay_on',
            transport: 'tcp-json',
            userParams: [],
            readBack: [],
            credentials: [],
            instanceParams: [],
          ),
          NetworkActionDto(
            role: 'turn_off',
            commandName: 'relay_off',
            transport: 'tcp-json',
            userParams: [],
            readBack: [],
            credentials: [],
            instanceParams: [],
          ),
        ],
      ),
    ];

    late int relayState;
    late FakeSpecCodec kasaCodec;

    // The HS110's energy meter: four pure readings polled by get_emeter,
    // their value fields the dotted paths into the reply root.
    const emeterEntities = [
      NetworkEntityDto(
        name: 'Voltage',
        platform: 'sensor',
        deviceClass: 'voltage',
        unit: 'V',
        stateCommand: 'get_emeter',
        valueField: 'emeter.get_realtime.voltage',
        transport: 'tcp-json',
        options: [],
        isInstanced: false,
        actions: [],
      ),
      NetworkEntityDto(
        name: 'Power',
        platform: 'sensor',
        deviceClass: 'power',
        unit: 'W',
        stateCommand: 'get_emeter',
        valueField: 'emeter.get_realtime.power',
        transport: 'tcp-json',
        options: [],
        isInstanced: false,
        actions: [],
      ),
    ];

    // A stand-in plug: it holds a relay state, answers get_sysinfo with it, and
    // flips it on set_relay_state — so the screen's poll-after-send loop runs
    // for real over the (faithful-cipher) fake codec. With [emeter] it also
    // answers get_realtime, the way an HS110 does.
    Future<void> pumpPlug(
      WidgetTester tester, {
      int initial = 0,
      bool emeter = false,
      bool bulb = false,
    }) async {
      relayState = initial;
      final entities = [...kasaEntities, if (emeter) ...emeterEntities];
      kasaCodec = FakeSpecCodec(
        networkEntities: (_) => entities,
        networkKasaRequest: (name, _) => KasaRequestDto(
          json: switch (name) {
            'relay_on' => '{"system":{"set_relay_state":{"state":1}}}',
            'relay_off' => '{"system":{"set_relay_state":{"state":0}}}',
            'get_emeter' => '{"emeter":{"get_realtime":null}}',
            _ => '{"system":{"get_sysinfo":null}}',
          },
        ),
        networkReading: (entity, returned) {
          if (entity == 'Outlet') {
            final on = (int.tryParse(returned['relay_state'] ?? '0') ?? 0) != 0;
            return NetworkReadingDto(
                kind: NetworkReadingKind.onOff, isOn: on, raw: on ? '1' : '0');
          }
          // The sensors: the dotted path the flattener keys the reply by.
          final field = switch (entity) {
            'Voltage' => 'emeter.get_realtime.voltage',
            'Power' => 'emeter.get_realtime.power',
            _ => entity,
          };
          final raw = returned[field];
          if (raw == null) return null;
          return NetworkReadingDto(
              kind: NetworkReadingKind.number,
              number: double.parse(raw),
              raw: raw);
        },
      );

      Future<Uint8List> exchange(
          String host, int port, List<int> request, Duration timeout) async {
        final json = await kasaCodec.kasaDecodeFrame(frame: request);
        final String reply;
        if (json.contains('set_relay_state')) {
          relayState = json.contains('"state":1') ? 1 : 0;
          reply = '{"system":{"set_relay_state":{"err_code":0}}}';
        } else if (json.contains('get_realtime')) {
          reply = '{"emeter":{"get_realtime":{"voltage":120.4,"current":0.5,'
              '"power":60.2,"total":12.34,"err_code":0}}}';
        } else {
          reply = bulb
              ? '{"system":{"get_sysinfo":{"mic_type":"IOT.SMARTBULB",'
                  '"light_state":{"on_off":1,"brightness":75},"alias":"Reading Lamp"}}}'
              : '{"system":{"get_sysinfo":{"relay_state":$relayState,'
                  '"alias":"Desk Lamp"}}}';
        }
        return Uint8List.fromList(await kasaCodec.kasaEncodeFrame(json: reply));
      }

      await tester.pumpWidget(ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(kasaCodec),
          // A plug serves no setup.xml — reaching for one is a bug.
          soapControlClientProvider.overrideWithValue(SoapControlClient(
              httpClient: MockClient((r) async =>
                  fail('fetched a description for a Kasa plug: ${r.url}')))),
          kasaControlClientProvider.overrideWithValue(
              KasaControlClient(kasaCodec, exchange: exchange)),
        ],
        child: const MaterialApp(home: SizedBox()),
      ));
      final context = tester.element(find.byType(SizedBox));
      unawaited(Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkDeviceScreen(
              device: kasaDevice,
              controls: NetworkControls(specYaml: 'yaml', entities: entities)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('polls get_sysinfo and reflects the relay state',
        (tester) async {
      await pumpPlug(tester, initial: 1);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.textContaining('Could not reach'), findsNothing);
    });

    testWidgets('the emeter sensors poll get_emeter alongside the switch',
        (tester) async {
      await pumpPlug(tester, initial: 1, emeter: true);

      // The switch still reads the sysinfo poll; the sensors read the emeter
      // one — two state commands over the same socket, decoded from the two
      // reply shapes.
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.text('120.4 V'), findsOneWidget);
      expect(find.text('60.2 W'), findsOneWidget);
      expect(find.textContaining('Could not reach'), findsNothing);
    });

    testWidgets('toggling sends set_relay_state and re-polls the new state',
        (tester) async {
      await pumpPlug(tester, initial: 0);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      // The on command rendered, and the switch now reads on because the
      // post-send poll saw the flipped relay.
      expect(
        kasaCodec.renderNetworkKasaCommandCalls.map((c) => c.commandName),
        contains('relay_on'),
      );
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
    });

    testWidgets('a Kasa light gets real on/off and brightness controls',
        (tester) async {
      // A KL430 answers the plug protocol but reports light_state, not
      // relay_state. Drive it as a light: an on/off switch reflecting
      // light_state.on_off and a brightness slider, over the lightingservice.
      await pumpPlug(tester, bulb: true);

      // On/off reflects light_state.on_off (on), plus a brightness slider at 75.
      expect(tester.widget<Switch>(find.byType(Switch)).value, isTrue);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('75%'), findsOneWidget);
      // Named by the bulb's alias, not the generic "Outlet".
      expect(find.text('Reading Lamp'), findsOneWidget);

      // Toggling sends light_off (the lightingservice), not set_relay_state.
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(
        kasaCodec.renderNetworkKasaCommandCalls.map((c) => c.commandName),
        contains('light_off'),
      );
      expect(find.textContaining('Could not reach'), findsNothing);
    });
  });

  // ── A Kasa power strip: outlets are instanced children over the socket ────
  //
  // A HS300 reports a `children` array; each outlet is its own switch, named by
  // its alias, toggled by scoping the write to the outlet's id via
  // context.child_ids. The plain "Outlet" switch is hidden on a strip.
  group('Kasa power strip', () {
    final stripDevice = NetworkDevice(
      host: '10.0.0.8',
      name: 'Rack Strip',
      port: 9999,
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime.utc(2026),
    );

    const stripEntities = [
      // The plain single-outlet switch the shared spec also declares — hidden
      // on a strip, which has no top-level relay_state to read.
      NetworkEntityDto(
        name: 'Outlet',
        platform: 'switch',
        deviceClass: 'outlet',
        stateCommand: 'get_sysinfo',
        valueField: 'relay_state',
        options: [],
        isInstanced: false,
        actions: [
          NetworkActionDto(
              role: 'turn_on',
              commandName: 'relay_on',
              transport: 'tcp-json',
              userParams: [],
              readBack: [],
              credentials: [],
              instanceParams: []),
          NetworkActionDto(
              role: 'turn_off',
              commandName: 'relay_off',
              transport: 'tcp-json',
              userParams: [],
              readBack: [],
              credentials: [],
              instanceParams: []),
        ],
      ),
      // The instanced multi-outlet switch: each child a switch, its id threaded
      // into the child-scoped command through the instance param.
      NetworkEntityDto(
        name: 'Outlets',
        platform: 'switch',
        deviceClass: 'outlet',
        stateCommand: 'get_sysinfo',
        options: [],
        isInstanced: true,
        actions: [
          NetworkActionDto(
              role: 'turn_on',
              commandName: 'relay_on_child',
              transport: 'tcp-json',
              userParams: [],
              readBack: [],
              credentials: [],
              instanceParams: [NetworkSourceParamDto(param: 'child_id', name: 'id')]),
          NetworkActionDto(
              role: 'turn_off',
              commandName: 'relay_off_child',
              transport: 'tcp-json',
              userParams: [],
              readBack: [],
              credentials: [],
              instanceParams: [NetworkSourceParamDto(param: 'child_id', name: 'id')]),
        ],
      ),
    ];

    const children = [
      NetworkInstanceDto(id: '8006AAA00', label: 'RackFans'),
      NetworkInstanceDto(id: '8006AAA01', label: 'Pleaky1'),
      NetworkInstanceDto(id: '8006AAA02', label: 'Spare'),
    ];

    late Map<String, bool> childOn;
    late FakeSpecCodec stripCodec;

    Future<void> pumpStrip(WidgetTester tester) async {
      childOn = {'8006AAA00': true, '8006AAA01': false, '8006AAA02': true};
      stripCodec = FakeSpecCodec(
        networkEntities: (_) => stripEntities,
        instances: children,
        instanceReadings: (id) => [
          NetworkRoleReadingDto(
            role: 'is_on',
            reading: NetworkReadingDto(
                kind: NetworkReadingKind.onOff,
                isOn: childOn[id] ?? false,
                raw: (childOn[id] ?? false) ? '1' : '0'),
          ),
        ],
        // The plain "Outlet" reads nothing on a strip.
        networkReading: (entity, returned) => null,
        // Echo command + child so the exchange can flip the addressed outlet.
        networkKasaRequest: (name, values) => KasaRequestDto(
            json: '{"cmd":"$name","child":"${values['child_id'] ?? ''}"}'),
      );

      Future<Uint8List> exchange(
          String host, int port, List<int> request, Duration timeout) async {
        final json = await stripCodec.kasaDecodeFrame(frame: request);
        final child = RegExp(r'"child":"([^"]*)"').firstMatch(json)?.group(1);
        if (child != null && child.isNotEmpty) {
          if (json.contains('relay_on_child')) childOn[child] = true;
          if (json.contains('relay_off_child')) childOn[child] = false;
        }
        // Every poll answers get_sysinfo; the fake codec enumerates the
        // children from its configured list, so the body's exact shape is moot.
        const reply = '{"system":{"get_sysinfo":{"alias":"Rack Strip"}}}';
        return Uint8List.fromList(await stripCodec.kasaEncodeFrame(json: reply));
      }

      await tester.pumpWidget(ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(stripCodec),
          soapControlClientProvider.overrideWithValue(SoapControlClient(
              httpClient: MockClient((r) async =>
                  fail('fetched a description for a Kasa strip: ${r.url}')))),
          kasaControlClientProvider.overrideWithValue(
              KasaControlClient(stripCodec, exchange: exchange)),
        ],
        child: const MaterialApp(home: SizedBox()),
      ));
      final context = tester.element(find.byType(SizedBox));
      unawaited(Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkDeviceScreen(
              device: stripDevice,
              controls:
                  NetworkControls(specYaml: 'yaml', entities: stripEntities)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    Switch outletSwitch(WidgetTester tester, String label) =>
        tester.widget<Switch>(find.descendant(
            of: find.widgetWithText(Card, label),
            matching: find.byType(Switch)));

    testWidgets('renders one switch per outlet by alias, hiding the plain one',
        (tester) async {
      await pumpStrip(tester);

      expect(find.text('RackFans'), findsOneWidget);
      expect(find.text('Pleaky1'), findsOneWidget);
      expect(find.text('Spare'), findsOneWidget);
      // Three outlets, and no fourth plain "Outlet" switch beside them.
      expect(find.byType(Switch), findsNWidgets(3));
      expect(find.text('Outlet'), findsNothing);
      // Each reflects its child's reported state.
      expect(outletSwitch(tester, 'RackFans').value, isTrue);
      expect(outletSwitch(tester, 'Pleaky1').value, isFalse);
      expect(outletSwitch(tester, 'Spare').value, isTrue);
    });

    testWidgets('toggling an outlet scopes the write to its child id',
        (tester) async {
      await pumpStrip(tester);

      // Pleaky1 is off; turn it on.
      await tester.tap(find.descendant(
          of: find.widgetWithText(Card, 'Pleaky1'),
          matching: find.byType(Switch)));
      await tester.pumpAndSettle();

      // The child-scoped command rendered, carrying Pleaky1's id — not the
      // whole-device relay_on.
      expect(
        stripCodec.renderNetworkKasaCommandCalls,
        contains(predicate<({String commandName, Map<String, String> values})>(
            (c) =>
                c.commandName == 'relay_on_child' &&
                c.values['child_id'] == '8006AAA01')),
      );
      // The post-send poll shows Pleaky1 on now, its siblings untouched.
      expect(outletSwitch(tester, 'Pleaky1').value, isTrue);
      expect(outletSwitch(tester, 'RackFans').value, isTrue);
      expect(outletSwitch(tester, 'Spare').value, isTrue);
    });
  });

  // ── HTTP state polling: read-only telemetry (Enphase Envoy) ──────────────
  //
  // The Envoy's whole surface is three sensors whose state command is a
  // plain-HTTP GET declared in the spec's `commands` block. No setup.xml, no
  // actions — and on firmware 7+ a JWT gate that refuses the poll with
  // 401/403, which must read as the device's gate, not as a broken screen.
  group('HTTP telemetry (Enphase Envoy)', () {
    final envoyDevice = NetworkDevice(
      host: '10.0.0.11',
      name: 'Envoy',
      port: 80,
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime.utc(2026),
    );

    NetworkEntityDto sensor(String name, String field, String unit) =>
        NetworkEntityDto(
          name: name,
          platform: 'sensor',
          unit: unit,
          stateCommand: 'get_production_v1',
          valueField: field,
          // What the codec fills from the state command's own declaration —
          // the signal the screen routes the poll on.
          transport: 'http',
          options: const [],
          isInstanced: false,
          actions: const [],
        );

    final envoyEntities = [
      sensor('Solar Production', 'wattsNow', 'W'),
      sensor("Today's Energy", 'wattHoursToday', 'Wh'),
      sensor('Lifetime Energy', 'wattHoursLifetime', 'Wh'),
    ];

    const productionJson = '{"wattsNow":2532,"wattHoursToday":18320,'
        '"wattHoursSevenDays":120440,"wattHoursLifetime":10324050}';

    /// A stand-in gateway: answers the production GET with [body]/[status]
    /// and records what it was asked. No setup.xml exists to fetch.
    Future<List<http.Request>> pumpEnvoy(
      WidgetTester tester, {
      int status = 200,
      String body = productionJson,
    }) async {
      final received = <http.Request>[];
      codec = FakeSpecCodec(
        networkEntities: (_) => envoyEntities,
        networkHttpRequest: (name, _) => const HttpRequestDto(
            method: 'GET', path: '/api/v1/production', body: ''),
        networkReading: (entity, returned) {
          final field = switch (entity) {
            'Solar Production' => 'wattsNow',
            "Today's Energy" => 'wattHoursToday',
            _ => 'wattHoursLifetime',
          };
          final raw = returned[field];
          if (raw == null) return null;
          return NetworkReadingDto(
              kind: NetworkReadingKind.number,
              number: double.parse(raw),
              raw: raw);
        },
      );
      final envoy = MockClient((request) async {
        received.add(request);
        return http.Response(body, status);
      });
      await tester.pumpWidget(ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(codec),
          // The gateway serves no UPnP description — asking is a bug.
          soapControlClientProvider.overrideWithValue(SoapControlClient(
              httpClient: MockClient((r) async =>
                  fail('fetched a description for an Envoy: ${r.url}')))),
          httpControlClientProvider
              .overrideWithValue(HttpControlClient(httpClient: envoy)),
          ecp2ControlServiceProvider.overrideWithValue(noEcp2()),
        ],
        child: const MaterialApp(home: SizedBox()),
      ));
      final context = tester.element(find.byType(SizedBox));
      unawaited(Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkDeviceScreen(
              device: envoyDevice,
              controls:
                  NetworkControls(specYaml: 'yaml', entities: envoyEntities)),
        ),
      ));
      await tester.pumpAndSettle();
      return received;
    }

    testWidgets('polls production over HTTP and renders the sensors',
        (tester) async {
      final received = await pumpEnvoy(tester);

      // Exactly one GET, the one the spec declares — and no description.
      // (Dart's Uri drops the default port when it stringifies, so no :80.)
      expect(received, hasLength(1));
      expect(received.single.method, 'GET');
      expect(
          received.single.url.toString(), 'http://10.0.0.11/api/v1/production');

      expect(find.text('2532 W'), findsOneWidget);
      expect(find.text('18320 Wh'), findsOneWidget);
      expect(find.text('10324050 Wh'), findsOneWidget);
      expect(find.textContaining('Could not reach'), findsNothing);
    });

    testWidgets('a 403 (JWT-gated firmware) shows the gate note, not an error',
        (tester) async {
      await pumpEnvoy(tester, status: 403);

      // The refusal is a device-side policy: the standing note names it, the
      // readings stay honestly unknown, and the screen is not an error page.
      expect(find.text('The device is refusing commands'), findsOneWidget);
      expect(find.textContaining('answered discovery'), findsOneWidget);
      expect(find.text('Unknown'), findsNWidgets(3));
      expect(find.textContaining('Could not reach'), findsNothing);
    });
  });

  // ── The fourth transport: a Rabbit Air purifier over encrypted UDP ──────
  //
  // Switch/select/number/sensor-shaped like the others, but every exchange is
  // an AES-128-CBC datagram under the per-device user key: the screen asks for
  // the key when none is stored, syncs the device clock once per session, and
  // polls get_state for everything.
  group('Rabbit Air purifier', () {
    const rabbitKey = '0123456789abcdeffedcba9876543210';

    final rabbitDevice = NetworkDevice(
      host: '10.0.0.12',
      name: 'Bedroom Purifier',
      // The mDNS hostname IS the Thing ID — the identity the key is stored
      // under.
      hostname: 'abcdef1234_000000000000000000.local',
      port: 9009,
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime.utc(2026),
    );

    NetworkActionDto udpAction(String role, String command,
            [List<String> params = const []]) =>
        NetworkActionDto(
            role: role,
            commandName: command,
            transport: 'udp',
            userParams: params,
            readBack: const [],
            credentials: const [],
            instanceParams: const []);

    // The spec's control surface, mirrored: power/mode/speed as controls,
    // quality/filter-life/rssi as readings, ionizer/lock as switches.
    late final rabbitEntities = [
      NetworkEntityDto(
        name: 'Power',
        platform: 'switch',
        stateCommand: 'get_state',
        valueField: 'power',
        options: const [],
        isInstanced: false,
        actions: [
          udpAction('turn_on', 'turn_on'),
          udpAction('turn_off', 'turn_off')
        ],
      ),
      NetworkEntityDto(
        name: 'Mode',
        platform: 'select',
        stateCommand: 'get_state',
        valueField: 'mode',
        options: const [
          NetworkOptionDto(raw: '0', label: 'Auto'),
          NetworkOptionDto(raw: '1', label: 'Pollen'),
          NetworkOptionDto(raw: '2', label: 'Manual'),
        ],
        isInstanced: false,
        actions: [
          udpAction('select_option', 'set_mode', ['mode'])
        ],
      ),
      NetworkEntityDto(
        name: 'Fan Speed',
        platform: 'number',
        stateCommand: 'get_state',
        valueField: 'speed',
        setpointMin: 1,
        setpointMax: 5,
        setpointStep: 1,
        options: const [],
        isInstanced: false,
        actions: [
          udpAction('set_value', 'set_speed', ['speed'])
        ],
      ),
      const NetworkEntityDto(
        name: 'Air Quality',
        platform: 'sensor',
        stateCommand: 'get_state',
        valueField: 'quality',
        transport: 'udp',
        options: [
          NetworkOptionDto(raw: '0', label: 'Lowest'),
          NetworkOptionDto(raw: '1', label: 'Low'),
          NetworkOptionDto(raw: '2', label: 'Medium'),
          NetworkOptionDto(raw: '3', label: 'High'),
          NetworkOptionDto(raw: '4', label: 'Highest'),
        ],
        isInstanced: false,
        actions: [],
      ),
      const NetworkEntityDto(
        name: 'Filter Life',
        platform: 'sensor',
        unit: 'min',
        stateCommand: 'get_state',
        valueField: 'filter_life',
        transport: 'udp',
        options: [],
        isInstanced: false,
        actions: [],
      ),
      const NetworkEntityDto(
        name: 'Wi-Fi RSSI',
        platform: 'sensor',
        unit: 'dBm',
        stateCommand: 'get_state',
        valueField: 'rssi',
        transport: 'udp',
        options: [],
        isInstanced: false,
        actions: [],
      ),
      NetworkEntityDto(
        name: 'Ionizer',
        platform: 'switch',
        stateCommand: 'get_state',
        valueField: 'ionizer',
        options: const [],
        isInstanced: false,
        actions: [
          udpAction('turn_on', 'ionizer_on'),
          udpAction('turn_off', 'ionizer_off'),
        ],
      ),
      NetworkEntityDto(
        name: 'Child Lock',
        platform: 'switch',
        stateCommand: 'get_state',
        valueField: 'lock',
        options: const [],
        isInstanced: false,
        actions: [
          udpAction('turn_on', 'child_lock_on'),
          udpAction('turn_off', 'child_lock_off'),
        ],
      ),
    ];

    late Map<String, Object?> purifierState;
    late int timeSyncs;
    late FakeSpecCodec rabbitCodec;

    /// A stand-in purifier: holds state, answers the time sync with its
    /// clock, answers get_state with the lot, applies cmd-4 writes — all
    /// encrypted under [rabbitKey], over the fake codec's faithful cipher.
    Future<void> pumpPurifier(WidgetTester tester,
        {bool withKey = true}) async {
      purifierState = {
        'power': false,
        'mode': 2,
        'speed': 3,
        'quality': 2,
        'ionizer': false,
        'lock': false,
        'filter_life': 4320,
        'rssi': -55,
        'model': 1,
      };
      timeSyncs = 0;
      rabbitCodec = FakeSpecCodec(
        networkEntities: (_) => rabbitEntities,
        // Render the way the real renderer does: body fields + runtime id/ts,
        // data last.
        networkRabbitAirRequest: (name, values, requestId, deviceTs) {
          final data = switch (name) {
            'turn_on' => ',"data":{"power":true}',
            'turn_off' => ',"data":{"power":false}',
            'set_mode' => ',"data":{"mode":${values['mode']}}',
            'set_speed' => ',"data":{"mode":2,"speed":${values['speed']}}',
            'ionizer_on' => ',"data":{"ionizer":true}',
            'ionizer_off' => ',"data":{"ionizer":false}',
            'child_lock_on' => ',"data":{"lock":true}',
            'child_lock_off' => ',"data":{"lock":false}',
            _ => '',
          };
          return RabbitAirRequestDto(
              json:
                  '{"id":$requestId,"cmd":${name == 'time_sync' ? 9 : 4},"ts":$deviceTs$data}',
              requestId: requestId);
        },
        networkReading: (entity, returned) {
          const boolFields = {
            'Power': 'power',
            'Ionizer': 'ionizer',
            'Child Lock': 'lock',
          };
          const optionFields = {'Mode': 'mode', 'Air Quality': 'quality'};
          final entity_ = rabbitEntities.firstWhere((e) => e.name == entity);
          final boolField = boolFields[entity];
          if (boolField != null) {
            final raw = returned[boolField];
            if (raw == null) return null;
            final on = raw == 'true';
            return NetworkReadingDto(
                kind: NetworkReadingKind.onOff, isOn: on, raw: on ? '1' : '0');
          }
          final optionField = optionFields[entity];
          if (optionField != null) {
            final raw = returned[optionField];
            if (raw == null) return null;
            String? label;
            for (final option in entity_.options) {
              if (option.raw == raw) label = option.label;
            }
            if (label == null) {
              return NetworkReadingDto(
                  kind: NetworkReadingKind.unknownOption, raw: raw);
            }
            return NetworkReadingDto(
                kind: NetworkReadingKind.option, label: label, raw: raw);
          }
          final field = switch (entity) {
            'Fan Speed' => 'speed',
            'Filter Life' => 'filter_life',
            'Wi-Fi RSSI' => 'rssi',
            _ => entity,
          };
          final raw = returned[field];
          if (raw == null) return null;
          return NetworkReadingDto(
              kind: NetworkReadingKind.number,
              number: double.parse(raw),
              raw: raw);
        },
      );

      Future<List<Uint8List>> exchange(
          String host, int port, Uint8List datagram, Duration timeout) async {
        final plaintext = await rabbitCodec.rabbitAirDecryptDatagram(
            userKey: rabbitKey, datagram: datagram);
        final decoded = jsonDecode(plaintext) as Map<String, Object?>;
        final id = decoded['id'];
        if (decoded['cmd'] == 9) {
          timeSyncs++;
          final ts = DateTime.now().millisecondsSinceEpoch ~/ 1000;
          return [
            Uint8List.fromList(await rabbitCodec.rabbitAirEncryptDatagram(
                userKey: rabbitKey, plaintext: '{"id":$id,"data":{"ts":$ts}}'))
          ];
        }
        final data = decoded['data'];
        if (data is Map) purifierState.addAll(data.cast());
        final reply = jsonEncode({'id': id, 'data': purifierState});
        return [
          Uint8List.fromList(await rabbitCodec.rabbitAirEncryptDatagram(
              userKey: rabbitKey, plaintext: reply))
        ];
      }

      final store = InMemorySettingsStore();
      if (withKey) {
        await RabbitAirKeyStore(store)
            .saveUserKey(rabbitDevice.hostname!, rabbitKey);
      }
      await tester.pumpWidget(ProviderScope(
        overrides: [
          specCodecProvider.overrideWithValue(rabbitCodec),
          settingsStoreProvider.overrideWithValue(store),
          // A purifier serves no setup.xml — reaching for one is a bug.
          soapControlClientProvider.overrideWithValue(SoapControlClient(
              httpClient: MockClient((r) async =>
                  fail('fetched a description for a purifier: ${r.url}')))),
          rabbitAirControlClientProvider.overrideWithValue(
              RabbitAirControlClient(rabbitCodec, exchange: exchange)),
        ],
        child: const MaterialApp(home: SizedBox()),
      ));
      final context = tester.element(find.byType(SizedBox));
      unawaited(Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkDeviceScreen(
              device: rabbitDevice,
              controls:
                  NetworkControls(specYaml: 'yaml', entities: rabbitEntities)),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'asks for the user key when none is stored, then drives the '
        'device once it is', (tester) async {
      await pumpPurifier(tester, withKey: false);

      // No key: the entry card is the surface, and nothing was sent.
      expect(find.text('This purifier needs its user key'), findsOneWidget);
      expect(timeSyncs, 0);
      expect(find.byType(Switch), findsNothing);

      await tester.tap(find.text('Enter user key'));
      await tester.pumpAndSettle();
      expect(find.text('Rabbit Air user key'), findsOneWidget);

      // A malformed key is refused in the dialog, not stored.
      await tester.enterText(find.byType(TextField), 'not-a-key');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('32 hex characters'), findsWidgets);

      await tester.enterText(find.byType(TextField), rabbitKey);
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // The key landed, the clock synced, and the first poll rendered.
      expect(find.text('This purifier needs its user key'), findsNothing);
      expect(timeSyncs, 1);
      expect(find.text('4320 min'), findsOneWidget);
      expect(find.text('-55 dBm'), findsOneWidget);
    });

    testWidgets('with a stored key, syncs once, polls get_state and renders',
        (tester) async {
      await pumpPurifier(tester);

      expect(timeSyncs, 1);
      expect(find.textContaining('Could not reach'), findsNothing);
      // The switch reflects the reported power, the select its option, the
      // number its speed, and the sensors their readings.
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isFalse);
      expect(find.text('Medium'), findsOneWidget); // Air Quality, labelled
      expect(find.text('4320 min'), findsOneWidget);
      expect(find.text('-55 dBm'), findsOneWidget);
      expect(find.text('3'), findsWidgets); // Fan Speed
      final manualChip =
          tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Manual'));
      expect(manualChip.selected, isTrue);
    });

    testWidgets('toggling power sends the encrypted write and re-polls',
        (tester) async {
      await pumpPurifier(tester);

      await tester.tap(find.byType(Switch).first);
      await tester.pumpAndSettle();

      expect(
        rabbitCodec.renderNetworkRabbitAirCommandCalls
            .map((c) => c.commandName),
        contains('turn_on'),
      );
      expect(purifierState['power'], isTrue);
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
    });

    testWidgets('the mode select sends set_mode with the picked option',
        (tester) async {
      await pumpPurifier(tester);

      // The select card sits below the switches and sensors — scroll it into
      // view before tapping, or the tap misses the fold.
      final autoChip = find.widgetWithText(ChoiceChip, 'Auto');
      await tester.ensureVisible(autoChip);
      await tester.pumpAndSettle();
      await tester.tap(autoChip);
      await tester.pumpAndSettle();

      final call = rabbitCodec.renderNetworkRabbitAirCommandCalls
          .firstWhere((c) => c.commandName == 'set_mode');
      expect(call.values, {'mode': '0'});
      expect(purifierState['mode'], 0);
    });
  });
}

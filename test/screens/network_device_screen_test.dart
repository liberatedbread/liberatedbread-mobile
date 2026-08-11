// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The network control screen, end to end against a fake codec and canned
// HTTP: load state, render one card per entity, and — the part that must
// never regress — send a mode change WITH the cook time read back from the
// device first, so changing the mode does not clear the timer.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/network_device_screen.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/soap_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

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
    name: 'Slow Cooker',
    platform: 'switch',
    stateCommand: 'GetCrockpotState',
    valueField: 'mode',
    options: [],
    actions: [
      NetworkActionDto(
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
        role: 'turn_off',
        transport: 'soap',
        commandName: 'crockpot_turn_off',
        userParams: [],
        readBack: [],
      ),
    ],
  ),
  NetworkEntityDto(
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
        name: 'Power On',
        platform: 'button',
        icon: 'mdi:power',
        stateCommand: '',
        options: [],
        actions: [
          NetworkActionDto(
            role: 'press',
            commandName: 'press_power_on',
            transport: 'http',
            userParams: [],
            readBack: [],
          ),
        ],
      ),
      NetworkEntityDto(
        name: 'Home',
        platform: 'button',
        icon: 'mdi:home',
        stateCommand: '',
        options: [],
        actions: [
          NetworkActionDto(
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
    }) async {
      codec = FakeSpecCodec(
        networkEntities: (_) => remoteEntities,
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
        ],
        child: const MaterialApp(home: SizedBox()),
      ));
      final context = tester.element(find.byType(SizedBox));
      unawaited(Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          builder: (_) => NetworkDeviceScreen(
              device: rokuDevice,
              controls: const NetworkControls(
                  specYaml: 'yaml', entities: remoteEntities)),
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
    });
  });
}

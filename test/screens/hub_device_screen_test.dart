// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The hub screen end to end against fakes: unpaired shows the link-button
// story, paired enumerates children from ONE state GET, a toggle carries the
// credential and the child id, every write is followed by a re-read, and
// error type 1 flips the screen back to pairing with its reason stated.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/hub_control_provider.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/settings_store_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/hub_device_screen.dart';
import 'package:liberated_bread_mobile/services/hub_credential_store.dart';
import 'package:liberated_bread_mobile/services/hub_http_client.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/hub_child_light_card.dart';

import '../fakes/fake_spec_codec.dart';
import '../fakes/in_memory_settings_store.dart';

const _bridgeId = '001788FFFE61FCB0';

const _credential = NetworkSourceParamDto(param: 'username', name: 'username');
const _instance = NetworkSourceParamDto(param: 'id', name: 'id');

const _lightEntity = NetworkEntityDto(
  isInstanced: true,
  name: 'Hue Light',
  platform: 'light',
  transport: 'http',
  stateCommand: 'Lights',
  options: [],
  actions: [
    NetworkActionDto(
      role: 'turn_on',
      transport: 'http',
      commandName: 'light_turn_on',
      userParams: [],
      readBack: [],
      credentials: [_credential],
      instanceParams: [_instance],
    ),
    NetworkActionDto(
      role: 'turn_off',
      transport: 'http',
      commandName: 'light_turn_off',
      userParams: [],
      readBack: [],
      credentials: [_credential],
      instanceParams: [_instance],
    ),
    NetworkActionDto(
      role: 'set_brightness',
      transport: 'http',
      commandName: 'light_set_brightness',
      userParams: ['bri'],
      readBack: [],
      credentials: [_credential],
      instanceParams: [_instance],
      min: 1,
      max: 254,
    ),
  ],
);

NetworkDevice _device() => NetworkDevice(
      host: '10.69.200.190',
      name: 'Philips Hue - FCB0',
      txt: const {'bridgeid': _bridgeId, 'modelid': 'BSB002'},
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime(2026),
    );

NetworkReadingDto _onOff(bool on) => NetworkReadingDto(
    kind: NetworkReadingKind.onOff,
    isOn: on,
    label: null,
    number: null,
    raw: on ? '1' : '0');

NetworkReadingDto _number(double n) => NetworkReadingDto(
    kind: NetworkReadingKind.number,
    isOn: null,
    label: null,
    number: n,
    raw: '$n');

/// Answers every send with a canned body and records the requests, in order.
class _StubHubClient extends HubHttpClient {
  final List<HttpRequestDto> sent = [];
  Object? sendError;

  /// When true, [sendError] is thrown on the GET state read too, not only on
  /// writes — how the initial-load auth-failure path is exercised.
  bool errorOnGet = false;

  _StubHubClient(HubCredentialStore store) : super(credentials: store);

  @override
  Future<String> send(
    String host,
    String bridgeId,
    HttpRequestDto request,
  ) async {
    sent.add(request);
    final error = sendError;
    if (error != null && (errorOnGet || request.method != 'GET')) {
      sendError = null;
      return Future<String>.error(error);
    }
    return '{"canned":true}';
  }
}

void main() {
  late InMemorySettingsStore settings;
  late HubCredentialStore store;
  late _StubHubClient client;
  late FakeSpecCodec codec;

  setUp(() {
    settings = InMemorySettingsStore();
    store = HubCredentialStore(settings);
    client = _StubHubClient(store);
    codec = FakeSpecCodec(
      networkEntities: (_) => const [_lightEntity],
      networkHttpRequest: (name, values) => HttpRequestDto(
        method: name == 'Lights' ? 'GET' : 'PUT',
        path: '/rendered/$name',
        body: name == 'Lights' ? '' : '{"rendered":"$name"}',
      ),
      instances: const [
        NetworkInstanceDto(id: '1', label: 'Kitchen counter'),
        NetworkInstanceDto(id: '2', label: 'Hallway'),
      ],
      instanceReadings: (id) => id == '1'
          ? [
              NetworkRoleReadingDto(role: 'is_on', reading: _onOff(true)),
              NetworkRoleReadingDto(role: 'brightness', reading: _number(254)),
            ]
          : [
              NetworkRoleReadingDto(role: 'is_on', reading: _onOff(false)),
              NetworkRoleReadingDto(role: 'brightness', reading: _number(77)),
            ],
    );
  });

  Widget wrap() => ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(settings),
          specCodecProvider.overrideWithValue(codec),
          hubHttpClientProvider.overrideWithValue(client),
        ],
        child: MaterialApp(
          home: HubDeviceScreen(
            device: _device(),
            controls: const NetworkControls(
              specYaml: 'yaml',
              entities: [_lightEntity],
            ),
          ),
        ),
      );

  testWidgets('unpaired shows the link-button story, not empty controls',
      (tester) async {
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Not paired yet'), findsOneWidget);
    expect(find.text('Pair with bridge'), findsOneWidget);
    expect(find.byType(HubChildLightCard), findsNothing);
    expect(client.sent, isEmpty,
        reason: 'no credential, no requests — the unpaired state must not '
            'improvise sends the bridge answers with error 1');
  });

  testWidgets('paired enumerates every light from one state GET',
      (tester) async {
    await store.saveCredentials(
        _bridgeId, const HubCredentials(username: 'testuser'));

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.byType(HubChildLightCard), findsNWidgets(2));
    expect(find.text('Kitchen counter'), findsOneWidget);
    expect(find.text('Hallway'), findsOneWidget);
    expect(
      client.sent.where((r) => r.method == 'GET'),
      hasLength(1),
      reason: 'enumeration and every child\'s state ride the one GET the '
          'spec binds — per-child polling is how a client gets throttled',
    );

    final switches = tester.widgetList<Switch>(find.byType(Switch)).toList();
    expect(switches.map((s) => s.value), [true, false]);
  });

  testWidgets('a toggle carries the credential and child id, then re-reads',
      (tester) async {
    await store.saveCredentials(
        _bridgeId, const HubCredentials(username: 'testuser'));
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    // Hallway is off; its switch asks for on.
    await tester.tap(find.byType(Switch).last);
    await tester.pumpAndSettle();

    final call = codec.renderNetworkHttpCommandCalls.single;
    expect(call.commandName, 'light_turn_on');
    expect(call.values, {'username': 'testuser', 'id': '2'});

    // PUT then a fresh GET: the reply was an acknowledgement, not state.
    final methods = client.sent.map((r) => r.method).toList();
    expect(methods, ['GET', 'PUT', 'GET']);
  });

  testWidgets('a brightness commit sends the rounded value', (tester) async {
    await store.saveCredentials(
        _bridgeId, const HubCredentials(username: 'testuser'));
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Slider).first, const Offset(-60, 0));
    await tester.pumpAndSettle();

    final call = codec.renderNetworkHttpCommandCalls.single;
    expect(call.commandName, 'light_set_brightness');
    expect(call.values['username'], 'testuser');
    expect(call.values['id'], '1');
    expect(int.tryParse(call.values['bri'] ?? ''), isNotNull,
        reason: 'the slider commits a whole number in the device range');
  });

  testWidgets('error type 1 flips back to pairing and says why',
      (tester) async {
    await store.saveCredentials(
        _bridgeId, const HubCredentials(username: 'stale'));
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();
    expect(find.byType(HubChildLightCard), findsNWidgets(2));

    client.sendError = HubAuthException('unauthorized user');
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    expect(find.text('Pair with bridge'), findsOneWidget);
    expect(find.textContaining('no longer recognizes'), findsOneWidget);
  });

  testWidgets(
      'error type 1 on the initial load flips to pairing, not a '
      'dead "try scanning again"', (tester) async {
    // A bridge reset since pairing: the very first state GET answers error 1,
    // so _load (not just _send) must recover. Without the on-HubAuthException
    // clause the screen sat paired-but-empty behind a scan-again banner a
    // re-scan could never fix.
    await store.saveCredentials(
        _bridgeId, const HubCredentials(username: 'stale'));
    client
      ..errorOnGet = true
      ..sendError = HubAuthException('unauthorized user');

    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    expect(find.text('Pair with bridge'), findsOneWidget);
    expect(find.textContaining('no longer recognizes'), findsOneWidget);
    expect(find.byType(HubChildLightCard), findsNothing);
    // The misleading transport banner must not be what the user sees.
    expect(find.textContaining('try scanning again'), findsNothing);
  });

  testWidgets('forgetting the bridge clears the pairing after confirmation',
      (tester) async {
    await store.saveCredentials(
        _bridgeId, const HubCredentials(username: 'testuser'));
    await tester.pumpWidget(wrap());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget this bridge'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Forget'));
    await tester.pumpAndSettle();

    expect(await store.credentials(_bridgeId), isNull);
    expect(find.text('Pair with bridge'), findsOneWidget);
  });
}

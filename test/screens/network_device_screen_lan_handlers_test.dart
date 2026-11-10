// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The screen's half of the two handlers that hide behind a transport another
// vendor already uses: a Yeelight polls and sends down its own socket, a
// write-only bridge loads with nothing to poll, and neither goes looking for a
// UPnP description or reaches Kasa's cipher.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart'
    show sharedPreferencesProvider;
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/network_device_screen.dart';
import 'package:liberated_bread_mobile/services/ecp2_control_service.dart';
import 'package:liberated_bread_mobile/services/http_control_service.dart';
import 'package:liberated_bread_mobile/services/limitlessled_control_service.dart';
import 'package:liberated_bread_mobile/services/popled_udp_control_service.dart';
import 'package:liberated_bread_mobile/services/soap_control_service.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/services/yeelight_control_service.dart';
import 'package:liberated_bread_mobile/widgets/led_image_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_spec_codec.dart';

class _FakeYeelight extends YeelightControlClient {
  _FakeYeelight(super.codec, {this.failure});
  final Object? failure;
  final sent = <String>[];

  @override
  Future<YeelightReplyDto> send(
    String host,
    int port,
    YeelightRequestDto request,
  ) async {
    final failed = failure;
    if (failed != null) throw failed;
    sent.add(request.json);
    return const YeelightReplyDto(
      answersRequest: true,
      fields: {'power': 'on', 'bright': '42'},
    );
  }
}

class _FakeBridge extends LimitlessledControlClient {
  _FakeBridge({this.failure});
  final Object? failure;
  final sent = <int>[];

  @override
  Future<void> send(
    String host,
    int port,
    List<LimitlessledFrameDto> frames,
  ) async {
    final failed = failure;
    if (failed != null) throw failed;
    sent.add(port);
  }
}

class _FakePanel extends PopledUdpClient {
  _FakePanel(super.codec);
  final sent = <({int port, List<int> body})>[];

  @override
  Future<PopledUdpReplyDto> send(String host, int port, List<int> body) async {
    sent.add((port: port, body: body));
    return const PopledUdpReplyDto(
      seq: 1,
      ackStatus: 0,
      answer: false,
      fields: {},
    );
  }

  @override
  Future<({int width, int height})?> panelSize(String host, int port) async =>
      null;
}

NetworkActionDto _action(String role, String transport) => NetworkActionDto(
  role: role,
  commandName: role,
  transport: transport,
  userParams: const [],
  readBack: const [],
  credentials: const [],
  instanceParams: const [],
);

NetworkEntityDto _light(String transport, {String stateCommand = ''}) =>
    NetworkEntityDto(
      name: 'Lamp',
      platform: 'light',
      stateCommand: stateCommand,
      transport: transport,
      options: const [],
      isInstanced: false,
      actions: [_action('turn_on', transport), _action('turn_off', transport)],
    );

Future<void> _open(
  WidgetTester tester,
  FakeSpecCodec codec,
  List<NetworkEntityDto> entities, {
  YeelightControlClient? yeelight,
  LimitlessledControlClient? bridge,
  PopledUdpClient? panel,
  NetworkCapabilitiesDto? capabilities,
}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        // The picture editor a Wi-Fi panel draws remembers its size.
        sharedPreferencesProvider.overrideWithValue(prefs),
        specCodecProvider.overrideWithValue(codec),
        soapControlClientProvider.overrideWithValue(
          SoapControlClient(
            httpClient: MockClient((r) async => fail('no SOAP: ${r.url}')),
          ),
        ),
        httpControlClientProvider.overrideWithValue(
          HttpControlClient(
            httpClient: MockClient((r) async => fail('no HTTP: ${r.url}')),
          ),
        ),
        ecp2ControlServiceProvider.overrideWithValue(
          Ecp2ControlService(
            connector: (host, port) async =>
                throw const Ecp2Exception('no ECP2 in this test'),
          ),
        ),
        if (yeelight != null)
          yeelightControlClientProvider.overrideWithValue(yeelight),
        if (bridge != null)
          limitlessledControlClientProvider.overrideWithValue(bridge),
        if (panel != null)
          popledUdpClientFactoryProvider.overrideWithValue(() => panel),
      ],
      child: const MaterialApp(home: SizedBox()),
    ),
  );
  final context = tester.element(find.byType(SizedBox));
  unawaited(
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => NetworkDeviceScreen(
          device: NetworkDevice(
            host: '10.0.0.15',
            name: 'Lamp',
            sources: const {NetworkDiscoverySource.lanProbe},
            discoveredAt: DateTime.utc(2026),
          ),
          controls: NetworkControls(
            specYaml: 'yaml',
            entities: entities,
            capabilities: capabilities,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Leave the screen, so its four-second poll timer stops.
Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 5));
}

void main() {
  testWidgets('a send the phone could not make is not shown as sent', (
    tester,
  ) async {
    final codec = FakeSpecCodec(networkEntities: (_) => [_light(kBridge)]);
    await _open(
      tester,
      codec,
      [_light(kBridge)],
      bridge: _FakeBridge(
        failure: const LimitlessledControlException('Local Network is off.'),
      ),
    );

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(find.text('Local Network is off.'), findsOneWidget);
    expect(find.text('On (sent)'), findsNothing);

    await _close(tester);
  });

  testWidgets('a Yeelight polls over its own socket and reads the mapping', (
    tester,
  ) async {
    final codec = FakeSpecCodec(
      networkEntities: (_) => [_light(kYeelight, stateCommand: 'get_prop')],
      networkRoleReadings: (name, returned) => [
        NetworkRoleReadingDto(
          role: 'is_on',
          reading: NetworkReadingDto(
            kind: NetworkReadingKind.onOff,
            isOn: returned['power'] == 'on',
            raw: returned['power'] ?? '',
          ),
        ),
      ],
    );
    final yeelight = _FakeYeelight(codec);
    await _open(tester, codec, [
      _light(kYeelight, stateCommand: 'get_prop'),
    ], yeelight: yeelight);

    expect(yeelight.sent, isNotEmpty, reason: 'the load polled');
    expect(yeelight.sent.first, contains('get_prop'));
    expect(find.text('On'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('a Yeelight switch sends down that socket', (tester) async {
    final codec = FakeSpecCodec(
      networkEntities: (_) => [_light(kYeelight, stateCommand: 'get_prop')],
    );
    final yeelight = _FakeYeelight(codec);
    await _open(tester, codec, [
      _light(kYeelight, stateCommand: 'get_prop'),
    ], yeelight: yeelight);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(
      codec.renderNetworkYeelightCommandCalls.single.commandName,
      'turn_on',
    );

    await _close(tester);
  });

  testWidgets('an unreachable Yeelight says why and offers the setup notes', (
    tester,
  ) async {
    final codec =
        FakeSpecCodec(
            networkEntities: (_) => [
              _light(kYeelight, stateCommand: 'get_prop'),
            ],
          )
          ..setupInstructionsFor = (_) => const SetupInstructionsDto(
            notes: 'Turn on LAN Control in the vendor app.',
            methods: [],
          );
    await _open(
      tester,
      codec,
      [_light(kYeelight, stateCommand: 'get_prop')],
      yeelight: _FakeYeelight(
        codec,
        failure: const YeelightControlException(
          'LAN Control is off, probably.',
        ),
      ),
    );

    expect(find.text('LAN Control is off, probably.'), findsOneWidget);
    expect(find.text('How to connect'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('a write-only bridge loads with nothing to poll, and sends', (
    tester,
  ) async {
    final codec = FakeSpecCodec(networkEntities: (_) => [_light(kBridge)]);
    final bridge = _FakeBridge();
    await _open(tester, codec, [_light(kBridge)], bridge: bridge);

    expect(find.byType(Switch), findsOneWidget);
    expect(find.text('How to connect'), findsNothing);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(
      codec.renderNetworkLimitlessledCommandCalls.single.commandName,
      'turn_on',
    );
    expect(bridge.sent.single, 8899);
    expect(find.text('On (sent)'), findsOneWidget);

    await _close(tester);
  });

  testWidgets('a Wi-Fi panel draws its picture editor, its setup notes, and '
      'sends its light over its own UDP client', (tester) async {
    final codec =
        FakeSpecCodec(
            spec: _panelSpec(),
            networkEntities: (_) => [_light(kPanel)],
          )
          ..setupInstructionsFor = (_) => const SetupInstructionsDto(
            notes: 'Join the YS hotspot (password 12345678).',
            methods: [],
          );
    final panel = _FakePanel(codec);
    await _open(
      tester,
      codec,
      [_light(kPanel)],
      bridge: _FakeBridge(failure: StateError('not a bridge')),
      panel: panel,
      capabilities: const NetworkCapabilitiesDto(
        defaultPort: 9090,
        tlsSelfSigned: false,
        advertisedPortUnreliable: false,
        protocolHandler: kPanel,
        mqttClientIdGenerated: false,
      ),
    );

    expect(find.byType(LedImageWidget), findsOneWidget);
    expect(find.text('How to connect'), findsOneWidget);

    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();

    expect(codec.renderNetworkPopledCommandCalls.single.commandName, 'turn_on');
    expect(panel.sent.single.port, 9090);
    // The panel acknowledged the frame, so the switch keeps what was sent.
    expect(find.text('On'), findsOneWidget);

    await _close(tester);
  });
}

const kPanel = 'popled_json';

/// led-space.yaml as far as the screen needs it: a picture surface.
DeviceSpecDto _panelSpec() => DeviceSpecDto(
  protocolHandler: kPanel,
  nameMatchers: const [],
  platformFallbackTypes: const [],
  txtMatchGroups: const [],
  hiddenEntityNames: const [],
  deviceName: 'LED space',
  manufacturer: 'LOY SPACE',
  manufacturerStatus: 'active',
  protocol: 'wifi',
  category: 'display',
  localNamePrefixes: const [],
  localNames: const [],
  serviceUuids: const [],
  companyIds: Uint16List(0),
  macPrefixes: const [],
  mdnsServiceTypes: const [],
  ssdpSearchTargets: const [],
  lanProtocols: const [kPanel],
  defaultPort: 9090,
  entities: const [],
  services: const [],
  imageUpload: const ImageUploadDto(
    handler: kPanel,
    encodable: true,
    maxWidth: 64,
    maxHeight: 64,
    resolutionDeviceReported: true,
    animation: true,
    animatedUpload: true,
  ),
);

const kYeelight = 'yeelight_lan';
const kBridge = 'limitlessled_legacy_8899';

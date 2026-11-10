// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The AirPort status screen: a status shown on request, the restart and the
// writes listed and refused, and no control on it that could change the
// base station.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/acp_status_screen.dart';
import 'package:liberated_bread_mobile/services/acp_status_client.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/apple_acp.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_spec_codec.dart';

const _surface = ReadOnlySurfaceDto(
  handler: 'apple_acp',
  defaultPort: 5009,
  commands: [
    ReadOnlyCommandDto(name: 'get_status', sent: true),
    ReadOnlyCommandDto(
      name: 'reboot',
      sent: false,
      refusal: 'Not sent by this app.',
    ),
  ],
);

class _Fake extends AcpStatusClient {
  _Fake() : super(host: 'unused', port: 1);
  Object? error;
  final passwords = <String>[];

  @override
  Future<AcpStatusDto> read({required String password}) async {
    passwords.add(password);
    if (error != null) throw error!;
    return const AcpStatusDto(
      name: 'Example Base',
      firmware: '7.9.1',
      productId: 120,
      productName: 'AirPort Extreme 802.11ac',
      uptimeSeconds: 90000,
      wifiName: 'Example Net',
      unavailable: [],
    );
  }
}

void main() {
  Future<(String, int)?> pump(WidgetTester tester, _Fake client) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    (String, int)? built;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          specCodecProvider.overrideWithValue(
            FakeSpecCodec(readOnlySurfaceResult: _surface),
          ),
          acpClientFactoryProvider.overrideWithValue((host, port) {
            built = (host, port);
            return client;
          }),
        ],
        child: MaterialApp(
          home: AcpStatusScreen(
            device: NetworkDevice(
              host: '192.168.1.1',
              name: 'Base',
              sources: const {NetworkDiscoverySource.mdns},
              discoveredAt: DateTime(2026),
            ),
            controls: const NetworkControls(
              specYaml: 'acp',
              entities: [],
              acpStatus: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return built;
  }

  testWidgets('reads the status on request and shows it', (tester) async {
    final client = _Fake();
    await pump(tester, client);
    expect(client.passwords, isEmpty, reason: 'nothing is read unasked');

    await tester.enterText(
      find.widgetWithText(TextField, 'Base station password'),
      'pw',
    );
    await tester.tap(find.text('Read status'));
    await tester.pump();
    await tester.pump();

    expect(client.passwords, ['pw']);
    expect(find.text('Example Base'), findsOneWidget);
    expect(find.text('AirPort Extreme 802.11ac'), findsOneWidget);
    expect(find.text('Firmware 7.9.1'), findsOneWidget);
    expect(find.text('Up 1 d 1 h'), findsOneWidget);
    expect(find.text('Wi-Fi network: Example Net'), findsOneWidget);
  });

  testWidgets('a refusal is shown in words', (tester) async {
    final client = _Fake()
      ..error = const AcpException('The base station refused that password.');
    await pump(tester, client);
    await tester.enterText(
      find.widgetWithText(TextField, 'Base station password'),
      'wrong',
    );
    await tester.tap(find.text('Read status'));
    await tester.pump();
    await tester.pump();
    expect(
      find.text('The base station refused that password.'),
      findsOneWidget,
    );
  });

  testWidgets('offers nothing that writes or restarts', (tester) async {
    await pump(tester, _Fake());
    expect(find.textContaining('Restart'), findsNothing);
    expect(find.byType(Switch), findsNothing);
    // The one button is the read.
    expect(find.byType(FilledButton), findsOneWidget);
    await tester.tap(find.text('Commands in the device spec'));
    await tester.pumpAndSettle();
    expect(find.text('reboot'), findsOneWidget, reason: 'listed, refused');
    expect(find.text('Not sent by this app.'), findsOneWidget);
  });
}

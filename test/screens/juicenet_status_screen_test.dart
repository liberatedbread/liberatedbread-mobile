// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The JuiceBox screen: listen on request, show what is heard, say so when the
// charger is encrypted, and offer nothing that sets a current.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/juicenet_status_screen.dart';
import 'package:liberated_bread_mobile/services/juicenet_listener.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/juicenet.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_spec_codec.dart';

const _surface = ReadOnlySurfaceDto(
  handler: 'juicenet_udp',
  commands: [
    ReadOnlyCommandDto(
      name: 'set_online_current',
      sent: false,
      refusal: 'Not sent by this app.',
    ),
  ],
);

class _FakeListener extends JuiceNetListener {
  _FakeListener() : super(port: 8042);
  // ignore: close_sinks — closed by dispose(), which the screen calls.
  final controller = StreamController<JuiceNetHeard>.broadcast();
  var started = false;

  @override
  Stream<JuiceNetHeard> get heard => controller.stream;

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> dispose() => controller.close();
}

JuiceNetFrameDto _frame(JuiceNetFrameKind kind, {String? note}) =>
    JuiceNetFrameDto(
      kind: kind,
      unitId: '0910000000000000000000004242',
      version: 'v09u',
      statusCode: 2,
      statusText: kind == JuiceNetFrameKind.status ? 'Charging' : null,
      currentAmps: kind == JuiceNetFrameKind.status ? 16.1 : null,
      voltage: kind == JuiceNetFrameKind.status ? 240.0 : null,
      powerWatts: kind == JuiceNetFrameKind.status ? 3864.0 : null,
      note: note,
    );

void main() {
  (int, String?)? built;

  Future<void> pump(WidgetTester tester, _FakeListener fake) async {
    built = null;
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          specCodecProvider.overrideWithValue(
            FakeSpecCodec(readOnlySurfaceResult: _surface),
          ),
          juiceNetListenerFactoryProvider.overrideWithValue((port, host) {
            built = (port, host);
            return fake;
          }),
        ],
        child: MaterialApp(
          home: JuiceNetStatusScreen(
            device: NetworkDevice(
              host: '192.168.1.77',
              name: 'JuiceBox',
              sources: const {NetworkDiscoverySource.lanProbe},
              discoveredAt: DateTime(2026),
            ),
            controls: const NetworkControls(
              specYaml: 'juicenet',
              entities: [],
              juiceNetStatus: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  testWidgets('listens on request and shows what it hears', (tester) async {
    final fake = _FakeListener();
    await pump(tester, fake);
    expect(fake.started, isFalse, reason: 'nothing binds unasked');

    await tester.tap(find.text('Listen'));
    await tester.pump();
    expect(fake.started, isTrue);
    expect(find.textContaining('Waiting for the charger'), findsOneWidget);

    fake.controller.add(
      JuiceNetHeard(
        InternetAddress('192.168.1.77'),
        _frame(JuiceNetFrameKind.status),
        DateTime(2026),
      ),
    );
    await tester.pump();
    expect(find.text('Charging'), findsOneWidget);
    expect(find.text('Charging current: 16.1 A'), findsOneWidget);
    expect(find.text('Charging power: 3864 W'), findsOneWidget);
  });

  testWidgets('an encrypted charger is refused in words', (tester) async {
    final fake = _FakeListener();
    await pump(tester, fake);
    await tester.tap(find.text('Listen'));
    await tester.pump();
    fake.controller.add(
      JuiceNetHeard(
        InternetAddress('192.168.1.77'),
        _frame(
          JuiceNetFrameKind.encrypted,
          note:
              'This charger is sending the encrypted protocol, which cannot '
              'be decoded.',
        ),
        DateTime(2026),
      ),
    );
    await tester.pump();
    expect(find.textContaining('cannot be decoded'), findsOneWidget);
    expect(find.textContaining('Charging current'), findsNothing);
  });

  testWidgets('the listener is told the charger\'s address, and the screen '
      'offers nothing that sets a current', (tester) async {
    final fake = _FakeListener();
    await pump(tester, fake);
    await tester.tap(find.text('Listen'));
    await tester.pump();
    expect(built, (8042, '192.168.1.77'));
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(Switch), findsNothing);
    // The one text field is the port.
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('Limit', findRichText: true), findsNothing);
  });
}

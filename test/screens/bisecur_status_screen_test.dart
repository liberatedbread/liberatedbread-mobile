// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The BiSecur door screen: positions shown, the impulse listed and refused,
// and no control on it that could move a door.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/bisecur_status_screen.dart';
import 'package:liberated_bread_mobile/services/bisecur_client.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/src/rust/protocol/bisecur.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_spec_codec.dart';

const _surface = ReadOnlySurfaceDto(
  handler: 'bisecur_mcp',
  commands: [
    ReadOnlyCommandDto(name: 'get_transition', sent: true),
    ReadOnlyCommandDto(
      name: 'send_impulse',
      sent: false,
      refusal: 'Read-only in this app: an impulse moves a motorised door.',
    ),
  ],
);

const _port = BiSecurPortDto(id: 0, typeCode: 1, typeName: 'Impulse');

const _transition = BiSecurTransitionDto(
  positionPercent: 92,
  targetPercent: 0,
  fault: false,
  autoClose: false,
  fullyOpen: false,
  fullyClosed: false,
  lightBarrier: true,
  statusError: false,
  driving: true,
  drivingTowardsClosed: true,
  halfOpen: false,
  forecast: false,
  learned: true,
  notReferenced: false,
);

class _Fake implements BiSecurClient {
  Object? error;
  List<BiSecurPortReading> readings = const [
    BiSecurPortReading(
      groupName: 'Garage',
      port: _port,
      transition: _transition,
    ),
  ];
  final calls = <(String, String)>[];

  @override
  Future<List<BiSecurPortReading>> read({
    required String user,
    required String password,
  }) async {
    calls.add((user, password));
    if (error != null) throw error!;
    return readings;
  }
}

void main() {
  NetworkDevice device({
    Map<String, String> txt = const {'mac': '54:10:EC:00:00:01'},
  }) => NetworkDevice(
    host: '192.168.1.50',
    name: 'Gateway',
    sources: const {NetworkDiscoverySource.lanProbe},
    discoveredAt: DateTime(2026),
    txt: txt,
  );

  Future<(String, int, String)?> pump(
    WidgetTester tester,
    _Fake client, {
    NetworkDevice? gateway,
  }) async {
    tester.view.physicalSize = const Size(800, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    (String, int, String)? built;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          specCodecProvider.overrideWithValue(
            FakeSpecCodec(readOnlySurfaceResult: _surface),
          ),
          biSecurClientFactoryProvider.overrideWithValue((host, port, mac) {
            built = (host, port, mac);
            return client;
          }),
        ],
        child: MaterialApp(
          home: BiSecurStatusScreen(
            device: gateway ?? device(),
            controls: const NetworkControls(
              specYaml: 'bisecur',
              entities: [],
              biSecurStatus: true,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return built;
  }

  Future<void> readDoors(WidgetTester tester) async {
    await tester.enterText(
      find.widgetWithText(TextField, 'Gateway user'),
      'me',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Password'),
      'secret',
    );
    await tester.tap(find.text('Read door positions'));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('reads only when asked, and shows the door', (tester) async {
    final client = _Fake();
    await pump(tester, client);
    expect(client.calls, isEmpty, reason: 'no read until the user asks');

    await readDoors(tester);
    expect(client.calls, [('me', 'secret')]);
    expect(find.text('Garage'), findsOneWidget);
    expect(find.text('92% open'), findsOneWidget);
    expect(find.text('Moving towards closed'), findsOneWidget);
    expect(find.text('Port 0 · Impulse'), findsOneWidget);
  });

  testWidgets('offers nothing that could move a door', (tester) async {
    await pump(tester, _Fake());
    await readDoors(tester);
    expect(find.byType(Switch), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(
      find.textContaining(RegExp('open door|close door', caseSensitive: false)),
      findsNothing,
    );
    // One button on the whole screen, and it reads.
    expect(find.byType(FilledButton), findsOneWidget);
    expect(find.text('Read door positions'), findsOneWidget);
    expect(find.byType(ElevatedButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('the impulse is listed and refused', (tester) async {
    await pump(tester, _Fake());
    await tester.tap(find.text('Commands in the device spec'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100));
    expect(find.text('send_impulse'), findsOneWidget);
    expect(find.textContaining('moves a motorised door'), findsOneWidget);
  });

  testWidgets('says the login is unencrypted and the password is not kept', (
    tester,
  ) async {
    await pump(tester, _Fake());
    expect(find.textContaining('no encryption'), findsOneWidget);
    expect(find.textContaining('does not store'), findsOneWidget);
    final password = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Password'),
    );
    expect(password.obscureText, isTrue);
  });

  testWidgets('a port with no position shows why', (tester) async {
    final client = _Fake()
      ..readings = const [
        BiSecurPortReading(
          groupName: 'Gate',
          port: _port,
          note: 'The gateway gave no position for this port.',
        ),
      ];
    await pump(tester, client);
    await readDoors(tester);
    expect(find.textContaining('no position'), findsOneWidget);
    expect(find.textContaining('% open'), findsNothing);
  });

  testWidgets('a failed read says why', (tester) async {
    final client = _Fake()
      ..error = const BiSecurException(
        'The gateway refused that user name and password.',
      );
    await pump(tester, client);
    await readDoors(tester);
    expect(find.textContaining('refused that user'), findsOneWidget);
  });

  testWidgets('needs a user name before it connects', (tester) async {
    final client = _Fake();
    await pump(tester, client);
    await tester.tap(find.text('Read door positions'));
    await tester.pump();
    expect(find.text('Enter a gateway user name first.'), findsOneWidget);
    expect(client.calls, isEmpty);
  });

  testWidgets('with no MAC from discovery it says so and offers no login', (
    tester,
  ) async {
    await pump(tester, _Fake(), gateway: device(txt: const {}));
    expect(find.textContaining('no hardware address'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Read door positions'), findsNothing);
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// F-018: the explicitly-padded ListView ignored MediaQuery.padding, so in
// landscape (declared for iPhone) the cards sat under the notch / Dynamic
// Island while the app bar above them was inset correctly.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart';
import 'package:liberated_bread_mobile/screens/roomba_transport_screen.dart';
import 'package:liberated_bread_mobile/services/roomba_credential_store.dart';

import '../fakes/fake_ha_api_client.dart';
import '../fakes/in_memory_settings_store.dart';

const _credentials = RoombaCredentials(
  blid: 'ABC123',
  password: ':1:9:secret',
  name: 'Dusty',
);

Widget _screen({RoombaCredentials? credentials}) => ProviderScope(
  overrides: [
    settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
    haApiClientProvider.overrideWithValue(FakeHaApiClient()),
    urlOpenerProvider.overrideWithValue((url) async => true),
  ],
  child: MaterialApp(home: RoombaTransportScreen(credentials: credentials)),
);

void main() {
  testWidgets('the body is inset from the notch side in landscape', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(667, 375);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(InMemorySettingsStore()),
          haApiClientProvider.overrideWithValue(FakeHaApiClient()),
          urlOpenerProvider.overrideWithValue((url) async => true),
        ],
        child: MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: const EdgeInsets.only(left: 59)),
              child: const RoombaTransportScreen(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('How to reach this robot'), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.byType(ListView)).dx, closeTo(59, 1));
  });

  // R-093: the direct and rest980 sections are drawn only when the screen is
  // given credentials, and until the saved-devices tile could open it that
  // way, the one caller passed none — so both sections, and the settings the
  // rest980 client's own error text points at, were unreachable.
  testWidgets('with a robot\'s credentials, all three transports are offered', (
    tester,
  ) async {
    // Tall enough that the lazy ListView builds all three cards at once.
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_screen(credentials: _credentials));
    await tester.pumpAndSettle();

    expect(find.text('Straight at the robot'), findsOneWidget);
    expect(find.text('A rest980 server'), findsOneWidget);
    expect(find.text('Use this server'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('without credentials only Home Assistant is offered', (
    tester,
  ) async {
    // Adding a robot from Home Assistant's list: the other two paths need a
    // local password this app does not hold.
    await tester.pumpWidget(_screen());
    await tester.pumpAndSettle();

    expect(find.text('Straight at the robot'), findsNothing);
    expect(find.text('A rest980 server'), findsNothing);
  });

  testWidgets('choosing the direct path clears any stored routing', (
    tester,
  ) async {
    // The robot serves one client at a time, so picking a path means
    // releasing the others: whatever was pointed at Home Assistant or a
    // rest980 server has to stop being the answer for this robot.
    tester.view.physicalSize = const Size(500, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    final store = InMemorySettingsStore();
    final credentialStore = RoombaCredentialStore(store);
    const routed = RoombaCredentials(
      blid: 'ABC123',
      password: ':1:9:secret',
      name: 'Dusty',
      rest980BaseUrl: 'http://pi.local:3000',
    );
    await credentialStore.save(routed);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsStoreProvider.overrideWithValue(store),
          haApiClientProvider.overrideWithValue(FakeHaApiClient()),
          urlOpenerProvider.overrideWithValue((url) async => true),
        ],
        child: const MaterialApp(
          home: RoombaTransportScreen(credentials: routed),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Use the direct connection'));
    await tester.pumpAndSettle();

    final saved = await credentialStore.credentials('ABC123');
    expect(saved?.rest980BaseUrl, isNull);
    expect(saved?.haEntityId, isNull);
  });
}

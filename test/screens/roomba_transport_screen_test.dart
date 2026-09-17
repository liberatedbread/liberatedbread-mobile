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

import '../fakes/fake_ha_api_client.dart';
import '../fakes/in_memory_settings_store.dart';

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
}

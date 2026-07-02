// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/core/constants.dart';
import 'package:opengreeniot_mobile/models/ha_config.dart';
import 'package:opengreeniot_mobile/providers/ha_provider.dart';
import 'package:opengreeniot_mobile/screens/ha_settings_screen.dart';
import 'package:opengreeniot_mobile/services/ha_api_client.dart';

import '../fakes/fake_ha_api_client.dart';
import '../fakes/in_memory_settings_store.dart';

const _registeredConfig = HaConfig(
  baseUrl: 'http://192.168.1.5:8123',
  token: 'tok',
  deviceId: 'dev1',
  webhookId: 'wh-0123456789abcdef',
);

Widget _wrap({
  required InMemorySettingsStore store,
  required FakeHaApiClient api,
  List<Uri>? openedUrls,
}) {
  return ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(store),
      haApiClientProvider.overrideWithValue(api),
      urlOpenerProvider.overrideWithValue((url) async {
        openedUrls?.add(url);
        return true;
      }),
    ],
    child: const MaterialApp(home: HaSettingsScreen()),
  );
}

InMemorySettingsStore _registeredStore() => InMemorySettingsStore({
      HaConfigNotifier.configKey: jsonEncode(_registeredConfig.toJson()),
      HaConfigNotifier.deviceIdKey: 'dev1',
    });

void main() {
  testWidgets('shows the setup form when unconfigured', (tester) async {
    await tester.pumpWidget(
        _wrap(store: InMemorySettingsStore(), api: FakeHaApiClient()));
    await tester.pumpAndSettle();

    expect(find.text('Home Assistant URL'), findsOneWidget);
    expect(find.text('Long-lived access token'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('LAN URL shows the Tailscale suggestion live', (tester) async {
    await tester.pumpWidget(
        _wrap(store: InMemorySettingsStore(), api: FakeHaApiClient()));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField).first, 'http://192.168.1.5:8123');
    await tester.pump();

    expect(
        find.textContaining('only works on your home network'), findsOneWidget);
  });

  testWidgets('tailnet URL shows the Tailscale-detected card', (tester) async {
    await tester.pumpWidget(
        _wrap(store: InMemorySettingsStore(), api: FakeHaApiClient()));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField).first, 'https://ha.tail1234.ts.net');
    await tester.pump();

    expect(find.text('Tailscale detected'), findsOneWidget);
  });

  testWidgets('learn-more opens the Tailscale HA guide', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(_wrap(
      store: InMemorySettingsStore(),
      api: FakeHaApiClient(),
      openedUrls: opened,
    ));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField).first, 'http://192.168.1.5:8123');
    await tester.pump();
    await tester.tap(find.text('Set up Tailscale'));

    expect(opened, [Uri.parse(AppConstants.tailscaleHaKbUrl)]);
  });

  testWidgets('connect registers, persists, and shows the connected view',
      (tester) async {
    final store = InMemorySettingsStore();
    final api = FakeHaApiClient();
    await tester.pumpWidget(_wrap(store: store, api: api));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(TextField).first, 'http://192.168.1.5:8123/');
    await tester.enterText(find.byType(TextField).last, 'secret-token');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
    // Registration carried the app identity and normalized URL.
    final registration = api.registeredDevices.single;
    expect(registration['app_id'], AppConstants.haAppId);
    expect(registration['base_url'], 'http://192.168.1.5:8123');
    // Config persisted with the webhook id.
    final saved = HaConfig.fromJson(
        jsonDecode(store.values[HaConfigNotifier.configKey]!)
            as Map<String, dynamic>);
    expect(saved.webhookId, api.webhookId);
    expect(saved.baseUrl, 'http://192.168.1.5:8123');
    // A stable device id was generated and stored separately.
    expect(store.values[HaConfigNotifier.deviceIdKey], isNotNull);
  });

  testWidgets('shows a friendly message when the token is rejected',
      (tester) async {
    final api = FakeHaApiClient()
      ..registerDeviceError = const HaAuthException();
    await tester.pumpWidget(_wrap(store: InMemorySettingsStore(), api: api));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'http://ha:8123');
    await tester.enterText(find.byType(TextField).last, 'bad');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.textContaining('rejected the access token'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
  });

  testWidgets('suggests Tailscale when the server is unreachable',
      (tester) async {
    final api = FakeHaApiClient()
      ..registerDeviceError = const HaNetworkException('no route');
    await tester.pumpWidget(_wrap(store: InMemorySettingsStore(), api: api));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'http://ha:8123');
    await tester.enterText(find.byType(TextField).last, 'tok');
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Tailscale tip'), findsOneWidget);
  });

  testWidgets('requires both fields before connecting', (tester) async {
    final api = FakeHaApiClient();
    await tester.pumpWidget(_wrap(store: InMemorySettingsStore(), api: api));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Connect'));
    await tester.pump();

    expect(find.textContaining('Enter both'), findsOneWidget);
    expect(api.registeredDevices, isEmpty);
  });

  testWidgets('registered view shows status and forwarding toggle',
      (tester) async {
    await tester
        .pumpWidget(_wrap(store: _registeredStore(), api: FakeHaApiClient()));
    await tester.pumpAndSettle();

    expect(find.text('Connected'), findsOneWidget);
    expect(find.text('http://192.168.1.5:8123'), findsOneWidget);
    // Webhook id is masked, not shown in full.
    expect(find.textContaining('wh-01234...'), findsOneWidget);
    expect(find.textContaining(_registeredConfig.webhookId!), findsNothing);
    // LAN URL still gets the Tailscale nudge.
    expect(
        find.textContaining('only works on your home network'), findsOneWidget);

    final toggle = tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(toggle.value, isTrue);
  });

  testWidgets('toggling forwarding persists the flag', (tester) async {
    final store = _registeredStore();
    await tester.pumpWidget(_wrap(store: store, api: FakeHaApiClient()));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();

    final saved = HaConfig.fromJson(
        jsonDecode(store.values[HaConfigNotifier.configKey]!)
            as Map<String, dynamic>);
    expect(saved.enabled, isFalse);
  });

  testWidgets('disconnect clears the config after confirmation',
      (tester) async {
    final store = _registeredStore();
    await tester.pumpWidget(_wrap(store: store, api: FakeHaApiClient()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Disconnect'));
    await tester.pumpAndSettle();
    expect(find.textContaining('not deleted'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Disconnect'));
    await tester.pumpAndSettle();

    expect(find.text('Home Assistant URL'), findsOneWidget);
    expect(store.values.containsKey(HaConfigNotifier.configKey), isFalse);
    // Device id survives so a re-registration reuses the same HA entry.
    expect(store.values[HaConfigNotifier.deviceIdKey], 'dev1');
  });
}

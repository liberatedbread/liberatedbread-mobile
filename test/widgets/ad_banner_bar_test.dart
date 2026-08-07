// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/ad_banner.dart';
import 'package:liberated_bread_mobile/providers/ad_banner_provider.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/services/ad_banner_service.dart';
import 'package:liberated_bread_mobile/widgets/ad_banner_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

late SharedPreferences _prefs;

/// The bar mounted the way the scan screen mounts it. The service override
/// fails fast, pinning the bundled fallback so widget assertions are stable.
Widget _wrap({required List<Uri> opened}) => ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(_prefs),
        adBannerServiceProvider.overrideWithValue(
          AdBannerService(client: MockClient((_) async => http.Response('', 500))),
        ),
        urlOpenerProvider.overrideWithValue((url) async {
          opened.add(url);
          return true;
        }),
      ],
      child: const MaterialApp(
        home: Scaffold(bottomNavigationBar: AdBannerBar()),
      ),
    );

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('renders the banner with an AD tag on the first frame',
      (tester) async {
    await tester.pumpWidget(_wrap(opened: []));

    // No pumps beyond the first frame: the fallback must already be there.
    expect(find.text('AD'), findsOneWidget);
    expect(find.text(AdBanner.fallback.message), findsOneWidget);
    expect(find.text(AdBanner.fallback.cta), findsOneWidget);
    await tester.pumpAndSettle();
  });

  testWidgets('a tap opens the shop URL externally', (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(_wrap(opened: opened));

    await tester.tap(find.text(AdBanner.fallback.message));
    await tester.pumpAndSettle();

    expect(opened, [AdBanner.fallback.url]);
  });

  testWidgets('the close button dismisses without opening anything',
      (tester) async {
    final opened = <Uri>[];
    await tester.pumpWidget(_wrap(opened: opened));

    await tester.tap(find.byTooltip('Dismiss ad'));
    await tester.pumpAndSettle();

    expect(find.text('AD'), findsNothing);
    expect(find.text(AdBanner.fallback.message), findsNothing);
    expect(opened, isEmpty);
    expect(_prefs.getString(AdBannerNotifier.dismissedKey),
        AdBanner.fallback.id);
  });

  testWidgets('renders nothing when the promotion was already dismissed',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {AdBannerNotifier.dismissedKey: AdBanner.fallback.id});
    _prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(_wrap(opened: []));

    expect(find.text('AD'), findsNothing);
    await tester.pumpAndSettle();
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The catalogue and the number registries are lazy providers, and until the
// terms gate started them nothing asked for either until the first BLE scan
// result did — so a 200-spec parse and 1.7 MB of registry TSVs landed in the
// middle of the radar sweep. This pins the kick: the app asks for both before
// any screen that needs them exists.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/providers/device_description_provider.dart';
import 'package:liberated_bread_mobile/providers/device_spec_match_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/terms_screen.dart';
import 'package:liberated_bread_mobile/services/number_registry.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../fakes/fake_spec_codec.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the terms gate starts the catalogue and registry loads', (
    tester,
  ) async {
    // Terms NOT accepted, so the only thing on screen is the gate — which
    // watches neither provider. Anything that asks for them is the warm-up.
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();

    var catalogueAsked = 0;
    var registryAsked = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          specCodecProvider.overrideWithValue(FakeSpecCodec()),
          specCatalogueProvider.overrideWith((ref) async {
            catalogueAsked++;
            return FallbackSpecCatalogue.fromParsed(
              ref.watch(specCodecProvider),
              const [],
            );
          }),
          numberRegistryProvider.overrideWith((ref) async {
            registryAsked++;
            return NumberRegistry.empty;
          }),
        ],
        child: const LiberatedBreadApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byType(TermsScreen), findsOneWidget);
    expect(catalogueAsked, 1, reason: 'the catalogue load was not kicked');
    expect(registryAsked, 1, reason: 'the registry load was not kicked');
  });

  testWidgets('a failing warm-up does not take the app down', (tester) async {
    SharedPreferences.setMockInitialValues({
      AppConstants.termsAcceptedKey: AppConstants.termsVersion,
    });
    final prefs = await SharedPreferences.getInstance();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          specCodecProvider.overrideWithValue(FakeSpecCodec()),
          // Both fail, as they would with a native library that did not load.
          // The warm-up drops the result, errors included; the screens that
          // actually need these values are the ones that report.
          specCatalogueProvider.overrideWith(
            (ref) async => throw StateError('no catalogue'),
          ),
          numberRegistryProvider.overrideWith(
            (ref) async => throw StateError('no registries'),
          ),
        ],
        child: const LiberatedBreadApp(),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));

    expect(tester.takeException(), isNull);
  });
}

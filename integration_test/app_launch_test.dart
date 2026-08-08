// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Boots the app through its REAL entrypoint — lib/main.dart's main() — and
// waits for the first screen.
//
// WHAT THIS COVERS THAT NOTHING ELSE DID
//
// Every other test in this repo, unit and integration alike, constructs
// `LiberatedBreadApp` itself inside a ProviderScope with the providers it wants
// overridden. That is the right shape for testing a screen, and it means
// main() was executed by NOTHING: it did not appear in coverage/lcov.info at
// all, because no test ever imported it, and "absent from the report" is a
// weaker signal than "0%" — there is nothing to notice.
//
// main() is not a formality. Before runApp it:
//
//   * awaits RustLib.init(), catching failure and continuing on the Dart-side
//     mock (see native_core_test.dart, which is the suite that makes a failure
//     here loud instead of silent);
//   * awaits SharedPreferences.getInstance() and injects it into the
//     ProviderScope, because the saved-device list is read synchronously
//     during build and widgets must never await preferences mid-frame;
//   * builds the one real, un-overridden ProviderScope the shipped app uses.
//
// So the failure modes it owns are ordering and wiring ones: a provider that
// is only overridden in tests and unbound in production, an await moved after
// runApp, an initialisation that throws where nothing catches it. Every one of
// those produces an app that dies or hangs on launch for a real user while the
// entire test suite stays green — which is precisely the gap the shipped
// entrypoint should not have.
//
// This is also the pattern package:integration_test documents
// (`app.main(); await tester.pumpAndSettle();`) and the repo simply did not
// have it.
//
// COST: none worth measuring. It joins the single build/install/launch cycle
// the device jobs already pay for through ci_all_test.dart, and on Linux it is
// one more ~2s invocation in a loop that already runs.
//
// ORDER: last, with native_core_test.dart, and for the same reason — main()
// initialises RustLib, which is process-wide, and doing that ahead of the flow
// suites would switch MockBleService from its Dart fallback table to the real
// codec underneath them and change what they are testing.
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/main.dart' as app;
import 'package:liberated_bread_mobile/screens/scan_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the shipped entrypoint boots to the scan screen',
      (tester) async {
    // No ProviderScope, no overrides, no pumpWidget. main() calls runApp
    // itself, and building the widget tree its own way is the entire point —
    // anything constructed here would be testing this file instead of the app.
    await app.main();

    // pumpAndSettle rather than pump: main() has already awaited its own
    // async setup, but the first frame still resolves the theme, the saved
    // device list and the ad-banner config fetch.
    await tester.pumpAndSettle();

    // Reaching a rendered ScanScreen means the whole chain held: RustLib.init
    // returned or was caught, SharedPreferences resolved and was injected
    // (ScanScreen's History section reads savedDevicesProvider during its
    // first build and throws if the override is missing), and the real
    // ProviderScope satisfied every provider the tree asks for.
    expect(find.byType(LiberatedBreadApp), findsOneWidget);
    expect(find.byType(ScanScreen), findsOneWidget);
    expect(find.text(AppConstants.appName), findsOneWidget);
  });
}

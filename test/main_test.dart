// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The app's entrypoint, which nothing executed.
//
// It was not merely uncovered — it was INVISIBLE. `flutter test --coverage`
// instruments only the libraries a test actually imports, so a file no test
// reaches is absent from lcov entirely rather than reported as zero. It is
// therefore missing from the denominator too: main.dart contributed nothing to
// the percentage, and no `project` status could ever notice it. That is the
// failure mode scripts/ci-coverage-audit.sh now refuses, and this file is what
// stops main.dart being its first offender.
//
// What lives here is small and load-bearing. `main()` resolves SharedPreferences
// BEFORE `runApp` so the saved-device list is readable synchronously during
// build (widgets never await preferences mid-frame), and it initialises the
// Rust core inside a try/catch whose stated contract is that the app keeps
// working when the native library cannot be loaded. Both are exactly the sort
// of claim that quietly stops being true.
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/core/log.dart';
import 'package:liberated_bread_mobile/main.dart' as entrypoint;
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/screens/home_shell.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fakes/emulated_ble.dart';

void main() {
  // `main()` does not override bleServiceProvider, so the tree it builds
  // constructs the REAL service — which is the point, since that is what ships.
  // The emulated adapter stands in at the flutter_blue_plus platform interface,
  // the same seam test/app_real_ble_path_test.dart uses, so no platform channel
  // is reached and nothing here depends on a radio.
  late EmulatedBleAdapter ble;
  late List<LogRecord> logs;

  setUpAll(() {
    ble = EmulatedBleAdapter.install();
  });

  setUp(() async {
    await ble.reset();
    SharedPreferences.setMockInitialValues({});
    logs = Log.captureRecords();
  });

  tearDown(Log.reset);

  testWidgets('main() boots the app all the way to the home shell',
      (tester) async {
    await entrypoint.main();
    await tester.pump();

    expect(find.byType(LiberatedBreadApp), findsOneWidget);
    expect(find.byType(HomeShell), findsOneWidget,
        reason: 'runApp mounted the real widget tree, not just a MaterialApp');
  });

  testWidgets('the SharedPreferences instance is resolved before runApp',
      (tester) async {
    // The reason main() awaits it rather than letting a provider do so: the
    // saved-device list reads preferences DURING build. Overriding the provider
    // with an unresolved value throws "sharedPreferencesProvider has not been
    // overridden" at the first widget that reads it, which is a crash on
    // launch — so this asserts the override is in place and usable
    // synchronously, from inside the mounted tree.
    SharedPreferences.setMockInitialValues({'saved_devices': '[]'});

    await entrypoint.main();
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(HomeShell)),
    );
    expect(
      container.read(sharedPreferencesProvider).getString('saved_devices'),
      '[]',
      reason: 'the resolved instance, not a placeholder, reaches the tree',
    );
  });

  testWidgets('a failed RustLib.init is logged and does not stop the app',
      (tester) async {
    // The documented contract: "the app keeps working — MockBleService falls
    // back to a Dart implementation". Provoked here by initialising twice,
    // since flutter_rust_bridge refuses a second init in one isolate. That is
    // a real shape of the failure and the only one reachable in a host test:
    // the alternative (no native library on disk) is not something a test can
    // arrange for a process that may already have loaded one.
    await entrypoint.main();
    await tester.pump();

    logs.clear();
    await entrypoint.main();
    await tester.pump();

    expect(find.byType(HomeShell), findsOneWidget,
        reason: 'the app still builds when the native core is unavailable');
    final failures = logs.where(
      (r) => r.category == 'app' && r.level == LogLevel.error,
    );
    expect(failures, isNotEmpty,
        reason: 'and it is LOUD about it — on desktop this is the first thing '
            'to check when spec parsing does nothing');
    expect(failures.first.message, contains('RustLib.init failed'));
  });
}

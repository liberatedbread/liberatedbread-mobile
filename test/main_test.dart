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
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/app.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/core/log.dart';
import 'package:liberated_bread_mobile/main.dart' as entrypoint;
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/screens/home_shell.dart';
import 'package:liberated_bread_mobile/services/secure_settings_store.dart';
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
  late List<String> secureStorageCalls;

  setUpAll(() {
    ble = EmulatedBleAdapter.install();
  });

  setUp(() async {
    await ble.reset();
    // Seed the disclaimer as accepted so main() boots straight to the home
    // shell; the first-launch gate is covered by app_test.dart. The install
    // marker is seeded too, so the fresh-install keychain wipe is a no-op
    // here — its own behaviour is covered by
    // secure_settings_store_test.dart.
    SharedPreferences.setMockInitialValues({
      AppConstants.termsAcceptedKey: AppConstants.termsVersion,
      SecureSettingsStore.freshInstallMarkerKey: true,
    });
    // main() now touches the keychain on startup, and this test boots the
    // real main(), so it has to stand in for that plugin exactly as it does
    // for SharedPreferences above. Without a handler the channel does not
    // fail — it never answers, and a Timer-based timeout cannot rescue it
    // because widget-test timers only advance when the test pumps. The
    // symptom is the whole suite hanging for ten minutes on this one test.
    secureStorageCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      (call) async {
        secureStorageCalls.add(call.method);
        return call.method == 'readAll' ? <String, String>{} : null;
      },
    );
    logs = Log.captureRecords();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
      null,
    );
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
    SharedPreferences.setMockInitialValues({
      'saved_devices': '[]',
      AppConstants.termsAcceptedKey: AppConstants.termsVersion,
    });

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

  group('the fresh-install keychain wipe is wired correctly', () {
    // These boot the REAL main(), which is the only place the marker key and
    // the fresh-install predicate are joined up. secure_settings_store_test
    // proves the predicate; nothing proved the wiring, and a mistyped marker
    // key there would wipe the keychain on every single launch while every
    // unit test stayed green.

    testWidgets('an install that has accepted the terms is never wiped',
        (tester) async {
      // The upgrade case, and the one that caused real data loss: the marker
      // did not exist before the build that introduced it, so it is absent
      // for every existing install on that build's first launch. Preferences
      // survive an in-place update, so absence of the marker alone must not
      // mean "fresh".
      SharedPreferences.setMockInitialValues(
          {AppConstants.termsAcceptedKey: AppConstants.termsVersion});
      await entrypoint.main();
      await tester.pump();

      expect(
        secureStorageCalls,
        isNot(contains('deleteAll')),
        reason: 'main() wiped the keychain on an install that had already '
            'accepted the terms. That is an app update, not a fresh install, '
            'and the wipe destroys the HA token, Hue credentials, Roomba '
            'password and every TLS pin with no way back.',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(SecureSettingsStore.freshInstallMarkerKey), isTrue,
          reason: 'The marker must still be adopted, or this decision is '
              're-made from scratch on every launch.');
    });

    testWidgets('a genuinely fresh install is wiped exactly once',
        (tester) async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      await entrypoint.main();
      await tester.pump();
      expect(secureStorageCalls.where((c) => c == 'deleteAll'), hasLength(1),
          reason: 'Empty preferences with a non-empty keychain is exactly the '
              'reinstall case: iOS keeps keychain items when the app is '
              'deleted, so they would otherwise be silently inherited.');

      // Second boot, same preferences the first one left behind.
      secureStorageCalls.clear();
      await entrypoint.main();
      await tester.pump();
      expect(secureStorageCalls, isNot(contains('deleteAll')),
          reason: 'The marker written by the first boot must stop it '
              'happening again, or every launch deletes what the user just '
              'entered.');
    });
  });
}

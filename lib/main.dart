// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'core/log.dart';
import 'providers/saved_device_provider.dart';
import 'services/secure_settings_store.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Uncaught errors into the diagnostics log buffer. Without these two hooks
  // a framework error or an unhandled async error went to the console only,
  // which on a phone is nowhere — the Diagnostics screen (the one place a
  // user can copy a report from) never saw them.
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    Log.app.error(
      'uncaught Flutter error',
      error: details.exception,
      stackTrace: details.stack,
    );
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    Log.app.error('uncaught error', error: error, stackTrace: stack);
    return true;
  };
  // Initialize the Rust core. The native library is built and bundled per
  // platform by the rust_builder (cargokit) plugin. If it still can't be loaded
  // (e.g. a host unit-test run without the host library on the library path),
  // the app keeps working — MockBleService falls back to a Dart implementation
  // that matches the Rust mock output.
  try {
    await RustLib.init();
    Log.app.info('RustLib.init succeeded; native core is available');
  } catch (e, st) {
    // Loud on purpose: on desktop this is the first thing to check when spec
    // parsing/matching does nothing — the app still runs, on the Dart mock.
    Log.app.error(
      'RustLib.init failed; falling back to the Dart-side mock',
      error: e,
      stackTrace: st,
    );
  }
  // Resolved once here so the saved-device list is readable synchronously
  // during build; widgets never await preferences mid-frame.
  final prefs = await SharedPreferences.getInstance();

  // The keychain outlives the app on iOS: deleting the app removes
  // SharedPreferences but leaves every secret behind, so a reinstall showed
  // the first-run Terms gate on top of a store that still held the user's
  // Home Assistant token, Hue credentials, Roomba password and TLS pins.
  // Clear it the first time a given install runs.
  //
  // "Fresh" is NOT just the absence of
  // SecureSettingsStore.freshInstallMarkerKey. The marker was added after the
  // app had users, so on the first launch of the build that introduced it the
  // key is absent for every existing install — and prefs survive an in-place
  // update on every platform. Reading absence as "fresh install" therefore
  // wiped every credential of every existing user, once, on upgrade.
  // SecureSettingsStore.isFreshInstall also requires that the terms gate has
  // never been accepted here, which no real update can satisfy.
  //
  // Runs before the gate, so nothing has read a stale credential yet, and
  // best-effort: a keychain that will not clear must not stop the app
  // launching.
  final wiped = await SecureSettingsStore().reconcileInstall(prefs);
  if (wiped) {
    Log.app.info('fresh install: cleared credentials left by a previous one');
  }

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const LiberatedBreadApp(),
    ),
  );
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app.dart';
import 'providers/saved_device_provider.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize the Rust core. The native library is built and bundled per
  // platform by the rust_builder (cargokit) plugin. If it still can't be loaded
  // (e.g. a host unit-test run without the host library on the library path),
  // the app keeps working — MockBleService falls back to a Dart implementation
  // that matches the Rust mock output.
  try {
    await RustLib.init();
    debugPrint('RustLib.init succeeded');
  } catch (e, st) {
    debugPrint('RustLib.init failed ($e); falling back to Dart-side mock. $st');
  }
  // Resolved once here so the saved-device list is readable synchronously
  // during build; widgets never await preferences mid-frame.
  final prefs = await SharedPreferences.getInstance();

  runApp(
    ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: const LiberatedBreadApp(),
    ),
  );
}

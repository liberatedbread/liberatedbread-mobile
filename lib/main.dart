// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
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
  runApp(const ProviderScope(child: LiberatedBreadApp()));
}

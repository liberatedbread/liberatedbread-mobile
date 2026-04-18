// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize the Rust core. If the native library isn't bundled (e.g. on
  // platforms where cargokit wiring is still TODO), the app still runs —
  // MockBleService has a Dart fallback that matches the Rust mock output.
  try {
    await RustLib.init();
  } catch (e, st) {
    debugPrint('RustLib.init failed ($e); falling back to Dart-side mock. $st');
  }
  runApp(const ProviderScope(child: OpenGreenIoTApp()));
}

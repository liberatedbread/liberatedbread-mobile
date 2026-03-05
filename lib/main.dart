// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
// TODO: Uncomment after running `flutter_rust_bridge_codegen generate`
// import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // TODO: Uncomment after running `flutter_rust_bridge_codegen generate`
  // await RustLib.init();
  runApp(const ProviderScope(child: OpenGreenIoTApp()));
}

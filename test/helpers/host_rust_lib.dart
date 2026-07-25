// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Loads the host-target Rust library for the tests that exercise the real
// flutter_rust_bridge path.
//
// `flutter test` runs on the host Dart VM, where nothing bundles the native
// library the way an iOS/Android/desktop build does. Pointing dlopen at the
// cargo output with `DYLD_FALLBACK_LIBRARY_PATH` does not work either: the
// Flutter SDK's `dart` binary uses the macOS hardened runtime, and the loader
// strips `DYLD_*` from such processes — which is why these tests had been
// silently skipping even when `scripts/test.sh` set that variable.
//
// So open the artifact by path. `cargo build` writes it under `rust/target/`,
// and `flutter test` runs with the package root as its working directory, so a
// relative path resolves. Falls back to skipping (returns false) when no build
// is present, which keeps a bare `flutter test` on a fresh checkout working.
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:opengreeniot_mobile/src/rust/frb_generated.dart' show RustLib;

/// Library filename cargo produces for this crate on the current platform.
String get _libFileName {
  if (Platform.isMacOS) return 'libopengreeniot_core.dylib';
  if (Platform.isWindows) return 'opengreeniot_core.dll';
  return 'libopengreeniot_core.so';
}

/// Paths tried in order. An explicit override wins so CI can point at an
/// artifact built somewhere else.
List<String> _candidatePaths() {
  final override = Platform.environment['OPENGREENIOT_RUST_LIB'];
  return [
    if (override != null && override.isNotEmpty) override,
    'rust/target/debug/$_libFileName',
    'rust/target/release/$_libFileName',
  ];
}

/// Initialize [RustLib] against a host build of the Rust core.
///
/// Returns true when the native library loaded and the FFI is usable, false
/// when no host build could be found — callers skip in that case rather than
/// failing, since not every environment has run `cargo build`.
Future<bool> initHostRustLib() async {
  for (final path in _candidatePaths()) {
    if (!File(path).existsSync()) continue;
    try {
      await RustLib.init(externalLibrary: ExternalLibrary.open(path));
      return true;
    } catch (_) {
      // Try the next candidate; a stale or wrong-arch artifact should not stop
      // a good one further down the list from being used.
    }
  }
  // Last resort: whatever the default loader can find (a platform build, or a
  // library already on the system search path).
  try {
    await RustLib.init();
    return true;
  } catch (_) {
    return false;
  }
}

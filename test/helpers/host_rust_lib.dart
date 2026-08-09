// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Loads the host-target Rust library for the tests that exercise the real
// flutter_rust_bridge path, rebuilding it first when it is missing or stale.
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
// relative path resolves.
//
// WHY THIS BUILDS THE CRATE ITSELF
//
// Every failure mode here is silent by construction. These suites call
// `markTestSkipped` when the library will not load, because a fresh clone that
// has never run cargo should not look like a broken app — but that means an
// ABSENT library and a STALE one both report green:
//
//   * Absent: `flutter test` on a checkout where nobody ran `cargo build` runs
//     the Dart tests and quietly drops every test that would have crossed the
//     FFI boundary. Nothing in the output says the suite got smaller.
//   * Stale: worse, because it does not even skip. Edit `rust/src/`, run
//     `flutter test` (or hit "run" in an IDE, which is what most of these runs
//     actually are), and the tests load the .so from BEFORE the edit. They pass.
//     They are testing code that no longer exists.
//
// `scripts/test.sh` and CI both build the crate before running the suite, so
// neither hits this — but they are not where a change is iterated on. Making
// the helper do it means the rebuild follows the tests instead of following the
// one entry point that remembers, and the check costs nothing when it is not
// needed: cargo settles a warm target directory in well under a tenth of a
// second, and the staleness test below means cargo is usually not run at all.
//
// Opt out with LIBERATED_BREAD_NO_RUST_BUILD=1 (or by pointing
// LIBERATED_BREAD_RUST_LIB at an artifact you built yourself, which is treated
// as "the caller owns this file"). Both then fall back to the original
// behaviour: load what is there, skip when there is nothing.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart'
    show ExternalLibrary;
import 'package:liberated_bread_mobile/src/rust/frb_generated.dart'
    show RustLib;

/// Library filename cargo produces for this crate on the current platform.
String get _libFileName {
  if (Platform.isMacOS) return 'libliberated_bread_core.dylib';
  if (Platform.isWindows) return 'liberated_bread_core.dll';
  return 'libliberated_bread_core.so';
}

/// Paths tried in order. An explicit override wins so CI can point at an
/// artifact built somewhere else.
List<String> _candidatePaths() {
  final override = Platform.environment['LIBERATED_BREAD_RUST_LIB'];
  return [
    if (override != null && override.isNotEmpty) override,
    'rust/target/debug/$_libFileName',
    'rust/target/release/$_libFileName',
  ];
}

/// Whether an environment variable is set to something that means "yes".
bool _envFlag(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) return false;
  return value != '0' && value.toLowerCase() != 'false';
}

/// Sources [lib] was built from, read out of cargo's own dep-info file.
///
/// Cargo writes `<artifact>.d` next to every artifact it links: a make-style
/// `target: dep dep dep` listing of every file that went into it. Using it
/// rather than globbing `rust/src/**` is the difference between guessing the
/// inputs and knowing them — the crate `include_str!`s a registry out of
/// `vendor/protocol-specs/`, and no glob of the crate directory would ever have
/// noticed that file changing.
///
/// Returns an empty list when the file is absent or unreadable, which callers
/// read as "assume stale" — the cost of being wrong is one no-op cargo run.
List<String> _dependenciesOf(File lib) {
  // `libfoo.so` -> `libfoo.d`, `foo.dll` -> `foo.d`.
  final path = lib.path;
  final dot = path.lastIndexOf('.');
  if (dot <= path.lastIndexOf(Platform.pathSeparator)) return const [];
  final depFile = File('${path.substring(0, dot)}.d');
  if (!depFile.existsSync()) return const [];
  return parseCargoDepInfo(depFile.readAsStringSync());
}

/// Every path on the right-hand side of a make-style dep-info listing.
///
/// Public, and tested by `test/helpers/host_rust_lib_test.dart`, because the
/// escaping rules are the sort of thing that looks obvious and is not: a
/// checkout under a directory with a space in its name writes `\ ` into these
/// paths, and reading that as two paths would make every input look absent and
/// the library look permanently fresh — a rebuild that silently stops
/// happening, which is precisely what this file exists to prevent.
List<String> parseCargoDepInfo(String contents) {
  final deps = <String>[];
  for (final line in const LineSplitter().convert(contents)) {
    // Anything without a rule separator (cargo also emits `# env-dep:...`
    // comments and phony `dep:` entries) contributes nothing. On Windows the
    // target itself starts `C:\...`, so the separator is the first colon that
    // is NOT the one after a drive letter.
    var colon = line.indexOf(':');
    if (colon == 1 && line.length > 2) colon = line.indexOf(':', 2);
    if (colon < 0) continue;
    final rhs = line.substring(colon + 1).trim();
    if (rhs.isEmpty) continue;
    // Make escapes a space inside a path as `\ `; split on the unescaped ones.
    final buffer = StringBuffer();
    for (var i = 0; i < rhs.length; i++) {
      final ch = rhs[i];
      if (ch == r'\' && i + 1 < rhs.length && rhs[i + 1] == ' ') {
        buffer.write(' ');
        i++;
      } else if (ch == ' ') {
        if (buffer.isNotEmpty) deps.add(buffer.toString());
        buffer.clear();
      } else {
        buffer.write(ch);
      }
    }
    if (buffer.isNotEmpty) deps.add(buffer.toString());
  }
  return deps;
}

/// True when [lib] is older than something it was built from.
///
/// The manifest and the lockfile are checked alongside cargo's dep-info list
/// because they are not in it: a dependency bump changes what gets linked
/// without touching a single file under `rust/src/`.
bool _isStale(File lib) {
  final deps = _dependenciesOf(lib);
  // An empty dep-info list means cargo has not recorded what this was built
  // from, so nothing here can say it is current.
  if (deps.isEmpty) return true;

  final built = lib.lastModifiedSync();
  for (final input in [...deps, 'rust/Cargo.toml', 'rust/Cargo.lock']) {
    final file = File(input);
    if (!file.existsSync()) continue;
    if (file.lastModifiedSync().isAfter(built)) return true;
  }
  return false;
}

/// Runs `cargo build` for the host target, at most once per test process.
///
/// Nothing here fails the test on a bad outcome: a machine with no Rust
/// toolchain is a supported way to run the Dart suite, and the load below still
/// reports honestly (by skipping) when there is no library to open. What this
/// removes is the case where a library IS opened and is the wrong one.
bool _buildAttempted = false;

void _ensureHostBuild() {
  if (_buildAttempted) return;
  _buildAttempted = true;

  final override = Platform.environment['LIBERATED_BREAD_RUST_LIB'];
  if (override != null && override.isNotEmpty) return;
  if (_envFlag('LIBERATED_BREAD_NO_RUST_BUILD')) return;

  // Only ever the debug profile: it is what `rust/target/debug` holds and what
  // every other entry point builds. A checkout that has only a release build
  // is left alone rather than being handed a second, slower one it did not ask
  // for — `_candidatePaths` still finds it.
  final debug = File('rust/target/debug/$_libFileName');
  final release = File('rust/target/release/$_libFileName');
  if (!debug.existsSync() && release.existsSync()) return;

  if (debug.existsSync() && !_isStale(debug)) return;

  final reason = debug.existsSync()
      ? 'is older than the sources it was built from'
      : 'has not been built yet';
  stdout.writeln('[host_rust_lib] ${debug.path} $reason; running cargo build. '
      'Set LIBERATED_BREAD_NO_RUST_BUILD=1 to skip this.');

  final ProcessResult result;
  try {
    // Serialised by cargo's own lock on the target directory, which matters
    // because `flutter test` runs test files as concurrent processes and more
    // than one of them can reach this at the same moment. The losers block,
    // then find the build already done and return in milliseconds.
    result = Process.runSync('cargo', ['build'], workingDirectory: 'rust');
  } on ProcessException catch (e) {
    stdout.writeln(
        '[host_rust_lib] cargo is not available ($e); the FFI-backed '
        'tests in this file will skip. Install it with ./scripts/setup.sh.');
    return;
  }
  if (result.exitCode != 0) {
    stdout.writeln('[host_rust_lib] cargo build failed (exit '
        '${result.exitCode}); the FFI-backed tests in this file will skip or '
        'run against a stale library.\n${result.stdout}\n${result.stderr}');
  }
}

/// Initialize [RustLib] against a host build of the Rust core.
///
/// Returns true when the native library loaded and the FFI is usable, false
/// when no host build could be found — callers skip in that case rather than
/// failing, since not every environment has a Rust toolchain.
Future<bool> initHostRustLib() async {
  _ensureHostBuild();
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

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Pins the dep-info reader that decides whether the host Rust library needs
// rebuilding before the FFI-backed suites run.
//
// This is a test for a test helper, which needs justifying. `host_rust_lib.dart`
// is the only thing standing between "I edited rust/src and re-ran the tests"
// and "the tests loaded yesterday's .so and passed", and it decides that by
// reading cargo's `<artifact>.d` file. If the reader returns nothing — because
// the format moved, or because a path with a space in it split into two
// non-existent files — then no input ever looks newer than the artifact, the
// rebuild silently stops happening, and the suites go back to testing code that
// is no longer there. That failure has no symptom: every test still passes.
//
// So the escaping rules get assertions of their own, against a real fixture
// (the one cargo wrote for this crate, when it is present) and against the
// awkward cases a real checkout can produce.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'host_rust_lib.dart';

void main() {
  group('parseCargoDepInfo', () {
    test('reads every dependency off a rule line', () {
      final deps = parseCargoDepInfo(
        '/w/rust/target/debug/libcore.so: /w/rust/src/lib.rs /w/rust/src/api.rs\n',
      );
      expect(deps, ['/w/rust/src/lib.rs', '/w/rust/src/api.rs']);
    });

    test('keeps a path containing an escaped space in one piece', () {
      // A checkout under "~/My Projects/…" is the ordinary way to hit this, and
      // splitting it would make both halves look like files that do not exist —
      // so nothing would ever appear newer than the artifact.
      final deps = parseCargoDepInfo(
        r'/w/target/debug/libcore.so: /w/My\ Projects/a.rs /w/b.rs',
      );
      expect(deps, [r'/w/My Projects/a.rs', '/w/b.rs']);
    });

    test('ignores lines with no rule separator and empty right-hand sides', () {
      final deps = parseCargoDepInfo(
        '/w/libcore.so: /w/src/lib.rs\n'
        '\n'
        'not a rule line\n'
        '/w/libcore.d:\n',
      );
      expect(deps, ['/w/src/lib.rs']);
    });

    test('takes the rule colon, not a Windows drive letter', () {
      final deps = parseCargoDepInfo(
        r'C:\w\target\debug\core.dll: C:\w\rust\src\lib.rs',
      );
      expect(deps, [r'C:\w\rust\src\lib.rs']);
    });

    test('sees the vendored registry the crate include_str!s', () {
      // The reason this reads cargo's dep-info instead of globbing rust/src:
      // rust/src/api/device_api.rs embeds a TSV out of vendor/, and no glob of
      // the crate directory would notice that file changing.
      final depFile = File(
        'rust/target/debug/libliberated_bread_core.d',
      );
      if (!depFile.existsSync()) {
        markTestSkipped(
          'No host build present (${depFile.path}); run '
          './scripts/ensure-rust-lib.sh to produce the fixture this asserts on.',
        );
        return;
      }
      final deps = parseCargoDepInfo(depFile.readAsStringSync());
      expect(deps, isNotEmpty,
          reason: 'An empty dep list makes the library look permanently fresh, '
              'so it would never be rebuilt before the FFI suites run.');
      expect(
        deps.any((d) => d.endsWith('.rs')),
        isTrue,
        reason: 'The crate sources must be among the recorded inputs.',
      );
      expect(
        deps.any((d) => d.contains('protocol-specs')),
        isTrue,
        reason: 'device_api.rs include_str!s a registry from '
            'vendor/protocol-specs; if cargo has stopped recording it, editing '
            'that file no longer triggers a rebuild.',
      );
    });
  });
}

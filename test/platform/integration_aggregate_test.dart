// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Audits integration_test/ci_all_test.dart against the suites on disk.
//
// The iOS and Android jobs run that ONE file rather than the integration_test/
// directory, because on a device every file passed to `flutter test` is its own
// kernel-compile → native build → install → launch cycle. That makes the import
// list load-bearing in two opposite directions, neither of which anything else
// checks:
//
//   * A mock-safe suite left OUT never runs on any device. It still runs in the
//     linux-desktop per-file loop, so CI stays green and the coverage hole is
//     invisible.
//   * An e2e suite pulled IN runs on the emulator and the 10x-billed simulator.
//     It needs scripts/e2e_shot_server.py reachable on 127.0.0.1, which on an
//     emulator is the emulator itself, so it hangs to its timeout.
//
// This lived in ci.yml as `grep -qF "'$base'" ci_all_test.dart`, which is the
// prose-is-indistinguishable-from-configuration trap that the workflow header
// documents biting this repo twice: a filename mentioned in a comment satisfied
// the grep while the file was never imported. Everything here reads
// comment-stripped source, so prose cannot satisfy any assertion below.
// stripCommentsKeepingStrings, not stripDartCommentsAndStringContents: the
// values being read — import paths — live INSIDE string literals, so blanking
// what is between the quotes would erase them.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const String _aggregate = 'integration_test/ci_all_test.dart';
const String _dir = 'integration_test';

/// Matches a file-level `@Tags([...])` carrying `e2e`, tolerantly.
///
/// Deliberately looser than the `grep -qE "@Tags\(\[.*'e2e'.*\]\)"` it replaces,
/// which accepted exactly one spelling. `dart format` wraps a two-entry
/// annotation across lines, and `@Tags(const <String>['e2e'])` is equally
/// valid — both slipped past the old single-line, single-quote pattern, and a
/// miss was not harmless: it made CI demand that an e2e file be imported into
/// the aggregate, i.e. instruct the developer to break the device jobs.
final RegExp _e2eTag = RegExp(
  r'@Tags\s*\(\s*(?:const\s*)?(?:<[^>]*>\s*)?\[[^\]]*[' "'" r'"]e2e[' "'" r'"]',
  dotAll: true,
);

/// `import '<file>' as <prefix>;` — anchored, so a mention in prose or a
/// commented-out import cannot pass for a real one.
RegExp _importOf(String basename) => RegExp(
    "^import\\s+['\"]${RegExp.escape(basename)}['\"]\\s+as\\s+(\\w+)\\s*;",
    multiLine: true);

void main() {
  late String aggregate;
  late List<String> suites;

  setUpAll(() {
    aggregate = stripCommentsKeepingStrings(
      readRepoFile(
        _aggregate,
        consequence: 'It is the only entrypoint the iOS and Android jobs run, '
            'so without it those jobs execute no integration tests at all.',
      ),
    );
    suites = Directory('${repoRoot.path}/$_dir')
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('_test.dart') && n != 'ci_all_test.dart')
        .toList()
      ..sort();
    expect(suites, isNotEmpty,
        reason: 'Found no *_test.dart under $_dir/. Either the directory moved '
            'or this audit is silently checking nothing.');
  });

  bool isE2e(String basename) => _e2eTag.hasMatch(
        stripCommentsKeepingStrings(
          readRepoFile('$_dir/$basename',
              consequence: 'It was listed in $_dir/ a moment ago.'),
        ),
      );

  test('every mock-safe suite is imported AND run by the aggregate', () {
    for (final name in suites) {
      if (isE2e(name)) continue;
      final match = _importOf(name).firstMatch(aggregate);
      expect(
        match,
        isNotNull,
        reason: '$_dir/$name is not imported by $_aggregate, so the iOS '
            'simulator and Android emulator jobs will never run it — while the '
            'linux-desktop job still will, which is what makes the gap silent. '
            "Add `import '$name' as <prefix>;` and call its main() in a "
            'group().',
      );
      final prefix = match!.group(1)!;
      expect(
        RegExp('\\b$prefix\\s*\\.\\s*main\\b').hasMatch(aggregate),
        isTrue,
        reason: '$_aggregate imports $name as `$prefix` but never calls '
            '`$prefix.main`. An import alone registers no tests, so the suite '
            'is silently skipped on every device.',
      );
    }
  });

  test('no e2e-tagged suite is imported by the aggregate', () {
    for (final name in suites) {
      if (!isE2e(name)) continue;
      expect(
        _importOf(name).hasMatch(aggregate),
        isFalse,
        reason: '$_dir/$name is tagged e2e but is imported by $_aggregate. '
            'A FILE-level @Tags annotation is read from the entrypoint file '
            'only, so --exclude-tags cannot filter it out of an import — the '
            'suite would actually run on the emulator and the simulator, where '
            'the host-side scripts/e2e_shot_server.py it needs is unreachable. '
            'e2e suites stay out of CI by not being imported here.',
      );
    }
  });
}

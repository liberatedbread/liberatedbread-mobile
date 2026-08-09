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
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

const String _aggregate = 'integration_test/ci_all_test.dart';
const String _dir = 'integration_test';

/// Tags that mean "this suite cannot run on a device", each with the reason a
/// failure message should give.
///
/// A file-level `@Tags` annotation is read from the ENTRYPOINT file only, so
/// `--exclude-tags` cannot filter a tagged suite out of an import. Anything
/// listed here therefore stays out of the aggregate entirely — being imported
/// is what would make it run.
const Map<String, String> _hostOnlyTags = {
  'e2e': 'it needs scripts/e2e_shot_server.py reachable on 127.0.0.1, which on '
      'an emulator is the emulator itself',
  'bluez': 'it needs the virtual BlueZ stack scripts/linux-virtual-ble.sh '
      'starts, which exists only on the Linux desktop target',
};

/// Matches a file-level `@Tags([...])` carrying [tag], tolerantly.
///
/// Deliberately looser than the `grep -qE "@Tags\(\[.*'e2e'.*\]\)"` it replaces,
/// which accepted exactly one spelling. `dart format` wraps a two-entry
/// annotation across lines, and `@Tags(const <String>['e2e'])` is equally
/// valid — both slipped past the old single-line, single-quote pattern, and a
/// miss was not harmless: it made CI demand that a host-only file be imported
/// into the aggregate, i.e. instruct the developer to break the device jobs.
RegExp _fileTag(String tag) => RegExp(
      '@Tags\\s*\\(\\s*(?:const\\s*)?(?:<[^>]*>\\s*)?'
      '\\[[^\\]]*[\'"]${RegExp.escape(tag)}[\'"]',
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

  /// The host-only tag [basename] carries, or null when it is device-safe.
  String? hostOnlyTagOf(String basename) {
    final source = stripCommentsKeepingStrings(
      readRepoFile('$_dir/$basename',
          consequence: 'It was listed in $_dir/ a moment ago.'),
    );
    for (final tag in _hostOnlyTags.keys) {
      if (_fileTag(tag).hasMatch(source)) return tag;
    }
    return null;
  }

  test('every mock-safe suite is imported AND run by the aggregate', () {
    for (final name in suites) {
      if (hostOnlyTagOf(name) != null) continue;
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

  // The aggregate runs every suite in ONE process, so anything process-wide
  // that a suite switches on stays switched on for the suites after it. There
  // is exactly one such thing here, and it is load-bearing: RustLib. Once the
  // bridge is up, MockBleService stops using its Dart fallback table and
  // starts calling the real spec codec.
  //
  // Reproduced, not imagined. With app_launch_test.dart in its alphabetical
  // position — first — mock_flow_test.dart fails on the device jobs with:
  //
  //   Expected: exactly one matching candidate
  //     Actual: Found 0 widgets with text "Battery Service"
  //
  // because the real codec parses the bulb spec and the device screen renders
  // spec-driven controls instead of the raw GATT service list that suite
  // asserts on. The failure names a widget, points at the wrong suite, and
  // says nothing about ordering — so it is worth an assertion that does.
  //
  // Which suites those are is DERIVED, not listed: a hardcoded list is one
  // more thing to forget when adding a suite. A suite brings the bridge up if
  // it calls RustLib.init itself, or if it imports the app's entrypoint, whose
  // main() does.
  test('suites that bring up RustLib run after the ones that do not', () {
    final bringsUpRust = <String>[];
    final leavesRustAlone = <String>[];

    for (final name in suites) {
      if (hostOnlyTagOf(name) != null) continue;
      final source = stripCommentsKeepingStrings(
        readRepoFile('$_dir/$name',
            consequence: 'It was listed in $_dir/ a moment ago.'),
      );
      final initsDirectly = RegExp(r'RustLib\s*\.\s*init').hasMatch(source);
      final bootsTheApp = RegExp(
        r'''import\s+['"]package:liberated_bread_mobile/main\.dart['"]''',
      ).hasMatch(source);
      (initsDirectly || bootsTheApp ? bringsUpRust : leavesRustAlone).add(name);
    }

    // Both halves must be non-empty or this proves nothing: no rust suites
    // means the detection above has drifted from reality (there are two
    // today), and no plain suites means there is no ordering left to get
    // wrong.
    expect(bringsUpRust, isNotEmpty,
        reason: 'No suite under $_dir/ looks like it initializes RustLib, so '
            'this ordering check is asserting nothing. Either the suites that '
            'did were removed, or they now bring the bridge up by some route '
            'the two patterns here do not recognise — teach it the new one.');
    expect(leavesRustAlone, isNotEmpty,
        reason: 'Every suite under $_dir/ now brings RustLib up, so nothing is '
            'left running against MockBleService\'s Dart fallback table. That '
            'path ships too; something should still cover it.');

    /// Index of the `group(...)` call that runs [basename], via the prefix it
    /// was imported under. The import line itself also contains that prefix,
    /// so match `<prefix>.main` rather than the bare name.
    int groupPositionOf(String basename) {
      final match = _importOf(basename).firstMatch(aggregate);
      expect(match, isNotNull,
          reason: '$basename is not imported by $_aggregate — the first test '
              'in this file explains why that matters.');
      final prefix = match!.group(1)!;
      final position =
          aggregate.indexOf(RegExp('\\b$prefix\\s*\\.\\s*main\\b'));
      expect(position, greaterThanOrEqualTo(0),
          reason: '$_aggregate imports $basename as `$prefix` but never calls '
              '`$prefix.main`.');
      return position;
    }

    final lastPlain = leavesRustAlone.map(groupPositionOf).reduce(max);
    final firstRust = bringsUpRust.map(groupPositionOf).reduce(min);

    expect(
      firstRust,
      greaterThan(lastPlain),
      reason: 'In $_aggregate, ${bringsUpRust.join(', ')} bring RustLib up and '
          'must be grouped AFTER ${leavesRustAlone.join(', ')}. RustLib is '
          'process-wide and the aggregate is one process, so initializing it '
          'first switches MockBleService from its Dart fallback table to the '
          'real spec codec underneath the suites above — which is a device-job '
          'failure that blames the wrong suite. The linux-desktop job cannot '
          'catch this: it runs each file in its own process.',
    );
  });

  test('no host-only suite is imported by the aggregate', () {
    for (final name in suites) {
      final tag = hostOnlyTagOf(name);
      if (tag == null) continue;
      expect(
        _importOf(name).hasMatch(aggregate),
        isFalse,
        reason: '$_dir/$name is tagged $tag but is imported by $_aggregate. '
            'A FILE-level @Tags annotation is read from the entrypoint file '
            'only, so --exclude-tags cannot filter it out of an import — the '
            'suite would actually run on the emulator and the simulator, where '
            '${_hostOnlyTags[tag]}. Host-only suites stay out of the device '
            'jobs by not being imported here.',
      );
    }
  });
}

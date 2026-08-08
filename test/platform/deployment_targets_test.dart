// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Audits the minimum-OS / SDK floors each platform declares, and asserts the
// several files that declare each one still agree.
//
// Every platform here states its floor in more than one place — an Xcode
// project AND a podspec AND (on iOS) a plist, a Gradle module AND the SDK
// package CI installs. Nothing cross-checks them, and disagreement does not
// announce itself:
//
//   * A podspec floor BELOW the app's means CocoaPods compiles that pod against
//     the older SDK, so availability checking silently stops applying to it.
//     The pod builds green and an API newer than its floor crashes on a device
//     the app still claims to support.
//   * A Gradle module floor below the app's describes an API range nothing
//     builds or tests: the manifest merger takes the highest minSdk anyway, so
//     the lower number is a promise that is never kept and never checked.
//   * A compileSdk below what the app uses is what made every Android CI build
//     stop and download an extra SDK platform mid-build — rust_builder asked
//     for 33 while the app and the runner image were on 36. Nothing failed;
//     each build just paid for it, invisibly, for months.
//
// This suite is deliberately about AGREEMENT rather than exact values: the
// floors move when the pinned Flutter moves, and a test that hardcodes them
// would have to be edited in lockstep, which is the same coupling it is trying
// to protect. The `_floor*` constants below are therefore MINIMUMS (assert
// `>=`), so raising a floor needs no edit here and only lowering one past what
// the pinned Flutter supports is rejected.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'platform_config_reader.dart';

// What Flutter 3.44.8 scaffolds for a new app, read from the pinned SDK's own
// templates (packages/flutter_tools/templates/): ios.tmpl declares
// IPHONEOS_DEPLOYMENT_TARGET 13.0, macos.tmpl declares
// MACOSX_DEPLOYMENT_TARGET 10.15. Going below these means building against a
// platform the pinned toolchain no longer targets.
const String _floorIos = '13.0';
const String _floorMacos = '10.15';

const String _iosPbxproj = 'ios/Runner.xcodeproj/project.pbxproj';
const String _iosFrameworkPlist = 'ios/Flutter/AppFrameworkInfo.plist';
const String _iosPodfile = 'ios/Podfile';
const String _iosPodspec = 'rust_builder/ios/liberated_bread_core.podspec';
const String _macosPbxproj = 'macos/Runner.xcodeproj/project.pbxproj';
const String _macosPodspec = 'rust_builder/macos/liberated_bread_core.podspec';
const String _appGradle = 'android/app/build.gradle';
const String _rustGradle = 'rust_builder/android/build.gradle';
const String _ciWorkflow = '.github/workflows/ci.yml';

/// Compare dotted numeric versions ("10.15" vs "10.9") segment by segment.
///
/// A plain string compare gets this exactly backwards for the case that
/// matters — "10.9" sorts after "10.15" — which would make the floor assertions
/// below pass on a downgrade.
int _compareVersions(String a, String b) {
  // tryParse, not parse: a hand-edit leaving `13.` or `10..15` in a pbxproj is
  // still captured by the `([0-9.]+)` patterns below, and an unhandled
  // FormatException out of a comparator tells the reader nothing about which
  // of six files is malformed. Treating a junk segment as 0 lets the floor
  // assertion fail with its own message instead.
  final left = a.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  final right = b.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  for (var i = 0;
      i < (left.length > right.length ? left.length : right.length);
      i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}

/// The values `scripts/ci-versions.sh` resolves, by running it.
///
/// Deliberately NOT a second parser. An earlier version of this file
/// re-implemented that script's `env:`-block grammar in Dart, and the two
/// disagreed before either had shipped — the shell reader preserves a `#`
/// inside a quoted value, the Dart one truncated at the first `#` anywhere.
/// A guard that agrees with its own copy of the grammar instead of the real
/// one reports green precisely when the real one has started reading something
/// else, which is the failure it exists to catch.
///
/// `ci_versions_print` already emits `KEY=value` per line — the contract
/// ios-adhoc.yml consumes — so this asserts against exactly what dev
/// environments provision from. Memoised: the script forks an awk per key, and
/// nothing it reads changes mid-run.
Map<String, String>? _ciVarsCache;

Map<String, String> _ciVars() {
  if (_ciVarsCache != null) return _ciVarsCache!;
  final ProcessResult result;
  try {
    result = Process.runSync(
      'bash',
      ['scripts/ci-versions.sh'],
      workingDirectory: repoRoot.path,
    );
  } on ProcessException catch (e) {
    // Windows without a POSIX shell. Skipping beats failing: the script is what
    // CI and both setup scripts run, so there is nothing meaningful to assert
    // against here, and every other group in this file still runs.
    markTestSkipped('Could not run scripts/ci-versions.sh ($e).');
    return _ciVarsCache = const {};
  }
  if (result.exitCode != 0) {
    fail('scripts/ci-versions.sh exited ${result.exitCode}. Dev environments '
        'provision from it, so a failure here means setup.sh and the session '
        'hook are reading nothing.\nstderr: ${result.stderr}');
  }
  return _ciVarsCache = {
    for (final line in const LineSplitter().convert(result.stdout as String))
      if (line.contains('=')) ...{
        line.substring(0, line.indexOf('=')): line.substring(
          line.indexOf('=') + 1,
        ),
      },
  };
}

/// One resolved `CI_*` value, failing when the script did not produce it.
String _ciVar(String key) {
  final vars = _ciVars();
  if (vars.isEmpty) return ''; // Skipped above.
  final value = vars[key];
  if (value == null || value.isEmpty) {
    fail('scripts/ci-versions.sh did not print $key. Every pinned version '
        "belongs in ci.yml's top-level env: block, which is the only place "
        'that script reads — a value declared anywhere else is invisible to '
        'the setup scripts that provision dev environments from it.');
  }
  return value;
}

/// Every capture of [pattern] in [path], failing when there are none.
///
/// "No matches" must be a failure, not an empty pass: a renamed build setting
/// or a reformatted podspec would otherwise silently turn this whole suite into
/// a no-op while still reporting green.
List<String> _allMatches(
  String path,
  RegExp pattern, {
  required String consequence,
}) {
  var contents = readRepoFile(path, consequence: consequence);
  // Gradle AND YAML both carry long comments naming the very settings being
  // asserted, so prose would otherwise read as a second declaration. Quoted
  // values are kept either way, because one assertion has to see inside a
  // `classpath '...'` literal.
  if (path.endsWith('.gradle')) {
    contents = stripCommentsKeepingStrings(contents);
  } else if (path.endsWith('.yml')) {
    contents = stripHashComments(contents);
  }
  final values = [
    for (final m in pattern.allMatches(contents)) m.group(1)!,
  ];
  if (values.isEmpty) {
    fail('Found no `${pattern.pattern}` in $path. $consequence');
  }
  return values;
}

/// The one value [pattern] captures in [path], failing readably when there are
/// several.
///
/// `.single` throws `Bad state: Too many elements`, which discards the reasoned
/// message these assertions are built around and points at no file. A second
/// match is a legitimate thing to hit — an Android product flavour with its own
/// `minSdkVersion`, or the emulator matrix gaining a second API level — and the
/// reader deserves to be told which file and which values.
String _onlyMatch(
  String path,
  RegExp pattern, {
  required String consequence,
}) {
  final values = _allMatches(path, pattern, consequence: consequence);
  if (values.length > 1) {
    fail('Expected one `${pattern.pattern}` in $path but found '
        '${values.length}: ${values.join(", ")}. $consequence This audit '
        'compares a single declaration; if more than one is now legitimate, '
        'the assertion needs to say which one governs rather than assuming '
        'there is only one.');
  }
  return values.single;
}

void main() {
  group('iOS deployment target agrees everywhere it is declared', () {
    late Map<String, List<String>> declarations;

    setUpAll(() {
      declarations = {
        _iosPbxproj: _allMatches(
          _iosPbxproj,
          RegExp(r'IPHONEOS_DEPLOYMENT_TARGET = ([0-9.]+);'),
          consequence: 'It sets the deployment target for every build '
              'configuration; without it the app has no declared iOS floor.',
        ),
        _iosFrameworkPlist: _allMatches(
          _iosFrameworkPlist,
          RegExp(r'<key>MinimumOSVersion</key>\s*<string>([0-9.]+)</string>'),
          consequence: 'It declares the embedded App.framework minimum, which '
              'the App Store validates against the binary.',
        ),
        // The Podfile line ships commented out, matching Flutter's template —
        // the platform comes from the Runner target instead. It is still
        // asserted, because a stale version in a commented line is precisely
        // what someone copies the day they uncomment it.
        //
        // `#?` — the leading hash is OPTIONAL. Requiring it would turn
        // uncommenting the line, which the Podfile's own comment explains how
        // to do, into a "declaration is missing" failure at the exact moment
        // the declaration became real and started overriding the target.
        _iosPodfile: _allMatches(
          _iosPodfile,
          RegExp(r"^\s*#?\s*platform\s*:ios,\s*'([0-9.]+)'", multiLine: true),
          consequence: 'The platform line (commented or not) is the documented '
              'way to pin the pod platform and must not name a stale version.',
        ),
        _iosPodspec: _allMatches(
          _iosPodspec,
          RegExp(r"s\.platform\s*=\s*:ios,\s*'([0-9.]+)'"),
          consequence: 'It is the floor CocoaPods compiles the Rust core pod '
              'against, and the pod links the FFI entry points the app needs.',
        ),
      };
    });

    test('every declaration names the same version', () {
      final distinct = {for (final v in declarations.values) ...v};
      expect(
        distinct,
        hasLength(1),
        reason: 'The iOS deployment target is declared in several files and '
            'they disagree: ${_describe(declarations)}. A podspec floor below '
            "the app's silently exempts that pod from availability checking, "
            'so code using a newer API compiles and then crashes on a device '
            'the app still claims to support. Set them all to the same value.',
      );
    });

    test('is at or above what the pinned Flutter scaffolds', () {
      for (final entry in declarations.entries) {
        for (final value in entry.value) {
          expect(
            _compareVersions(value, _floorIos) >= 0,
            isTrue,
            reason: '${entry.key} declares iOS $value, below the $_floorIos '
                'that Flutter 3.44.8 scaffolds (its ios.tmpl template). '
                'Building against a platform the pinned toolchain no longer '
                'targets is unsupported, not merely conservative.',
          );
        }
      }
    });
  });

  group('macOS deployment target agrees everywhere it is declared', () {
    late Map<String, List<String>> declarations;

    setUpAll(() {
      declarations = {
        _macosPbxproj: _allMatches(
          _macosPbxproj,
          RegExp(r'MACOSX_DEPLOYMENT_TARGET = ([0-9.]+);'),
          consequence: 'It sets the deployment target for every build '
              'configuration of the macOS app.',
        ),
        _macosPodspec: _allMatches(
          _macosPodspec,
          RegExp(r"s\.platform\s*=\s*:osx,\s*'([0-9.]+)'"),
          consequence: 'It is the floor CocoaPods compiles the Rust core pod '
              'against on macOS.',
        ),
      };
    });

    test('every declaration names the same version', () {
      final distinct = {for (final v in declarations.values) ...v};
      expect(
        distinct,
        hasLength(1),
        reason: 'The macOS deployment target is declared in several files and '
            'they disagree: ${_describe(declarations)}.',
      );
    });

    test('is at or above what the pinned Flutter scaffolds', () {
      for (final entry in declarations.entries) {
        for (final value in entry.value) {
          expect(
            _compareVersions(value, _floorMacos) >= 0,
            isTrue,
            reason: '${entry.key} declares macOS $value, below the '
                '$_floorMacos that Flutter 3.44.8 scaffolds (its macos.tmpl '
                'template).',
          );
        }
      }
    });
  });

  group('Android SDK levels agree across the modules and CI', () {
    // Both DSL spellings: the app uses `minSdkVersion = 24` (Kotlin-ish
    // assignment, after the Flutter migrator's newDsl opt-out) while the
    // cargokit-derived module uses Groovy's bare `minSdkVersion 24`.
    RegExp gradleValue(String key) => RegExp('$key\\s*=?\\s*(\\d+)');

    test('rust_builder minSdk matches the app it links into', () {
      final app = _onlyMatch(
        _appGradle,
        gradleValue('minSdkVersion'),
        consequence: 'It declares the oldest Android the app installs on.',
      );
      final rust = _onlyMatch(
        _rustGradle,
        gradleValue('minSdkVersion'),
        consequence: 'It declares the floor the Rust FFI module is built for.',
      );
      expect(
        rust,
        app,
        reason: 'rust_builder declares minSdk $rust while the app declares '
            '$app. The manifest merger takes the highest, so a lower value '
            'here is an API range that is never built and never tested — it '
            'reads as support the module does not actually have.',
      );
    });

    test('rust_builder compileSdk matches the SDK platform CI installs', () {
      final rust = _onlyMatch(
        _rustGradle,
        gradleValue('compileSdkVersion'),
        consequence: 'It selects the SDK the Rust FFI module compiles against.',
      );
      final installed = _ciVar('CI_ANDROID_API');
      expect(
        rust,
        installed,
        reason: 'rust_builder compiles against SDK $rust but CI installs '
            '$installed. When they differ, Gradle stops partway through every '
            'Android build to download the missing platform — the build stays '
            'green and simply costs more, which is why this went unnoticed. '
            "The app tracks `flutter.compileSdkVersion`, so ci.yml's "
            'ANDROID_API is the number to keep aligned with it.',
      );
    });

    // The single place ci.yml repeats a pinned value instead of interpolating
    // it, because GitHub does not expose the `env` context to `strategy:`. That
    // makes it the only pair that can silently drift, so it is the one pair
    // worth asserting: scripts/ci-versions.sh reads the env key, while the job
    // that actually boots the emulator reads the matrix.
    // The warm-up build's --target-platform must name the same ABI the AVD
    // boots, in Flutter's vocabulary rather than the SDK's. They cannot be one
    // key, so they are two keys with this assertion between them: if they
    // drift, the warm-up populates caches the emulator's build cannot use and
    // the real build happens inside package:test_core's hardcoded 12-minute
    // load window — the `loading ...` timeout the warm-up step exists to
    // prevent, reappearing with nothing pointing at the cause.
    test('the warm-up target platform matches the emulator arch', () {
      const abiToTargetPlatform = {
        'x86_64': 'android-x64',
        'x86': 'android-x86',
        'arm64-v8a': 'android-arm64',
        'armeabi-v7a': 'android-arm',
      };
      final arch = _ciVar('CI_EMULATOR_ARCH');
      final warmup = _onlyMatch(
        _ciWorkflow,
        RegExp(r"ANDROID_WARMUP_TARGET_PLATFORM:\s*'([a-z0-9-]+)'"),
        consequence: 'It is the ABI the emulator job warms its caches for.',
      );
      expect(
        abiToTargetPlatform[arch],
        isNotNull,
        reason: 'No --target-platform mapping is known for emulator arch '
            '$arch. Add it here alongside the ANDROID_WARMUP_TARGET_PLATFORM '
            'change, or the two silently stop describing the same ABI.',
      );
      expect(
        warmup,
        abiToTargetPlatform[arch],
        reason: 'The emulator boots $arch but the warm-up build targets '
            '$warmup. The warm-up exists to build the app OUTSIDE the test '
            'loading phase; aimed at the wrong ABI it warms nothing the '
            'emulator can use.',
      );
    });

    test('the emulator matrix agrees with ANDROID_EMULATOR_API', () {
      final declared = _ciVar('CI_EMULATOR_API');
      final matrix = _onlyMatch(
        _ciWorkflow,
        RegExp(r'api-level:\s*\[\s*(\d+)\s*\]'),
        consequence: 'It is the API level the emulator job boots.',
      );
      expect(
        matrix,
        declared,
        reason: 'ci.yml boots an API $matrix emulator but declares '
            'ANDROID_EMULATOR_API: $declared. scripts/ci-versions.sh reads the '
            'env key, so setup.sh and the Claude Code session hook would '
            'create an API $declared AVD for a job that runs on API $matrix — '
            'dev environments quietly testing a different Android than CI.',
      );
    });

    test('rust_builder does not pin its own Android Gradle Plugin', () {
      final gradle = stripCommentsKeepingStrings(readRepoFile(
        _rustGradle,
        consequence: 'It is the Gradle module that builds the Rust core for '
            'Android.',
      ));
      expect(
        RegExp(r'classpath\s+[' "'" r'"]com\.android\.tools\.build:gradle')
            .hasMatch(gradle),
        isFalse,
        reason: 'rust_builder declares its own AGP on the buildscript '
            'classpath. The cargokit template shipped 7.3.0 there, which never '
            'took effect — android/settings.gradle resolves AGP first and a '
            'parent-first classloader means the already-loaded class wins — so '
            'it only made Gradle fetch a second, ancient AGP while presenting '
            'a version number that looked authoritative. Let the module '
            'inherit the one version from android/settings.gradle.',
      );
    });
  });
}

String _describe(Map<String, List<String>> declarations) => declarations.entries
    .map((e) => '${e.key} -> ${e.value.toSet().join(", ")}')
    .join('; ');

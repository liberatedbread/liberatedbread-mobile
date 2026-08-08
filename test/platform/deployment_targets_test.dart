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
  final left = a.split('.').map(int.parse).toList();
  final right = b.split('.').map(int.parse).toList();
  for (var i = 0;
      i < (left.length > right.length ? left.length : right.length);
      i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l.compareTo(r);
  }
  return 0;
}

/// A key's value from ci.yml's TOP-LEVEL `env:` mapping.
///
/// Scoped the same way `scripts/ci-versions.sh`'s `_ci_env` is, and for the
/// same reason: that block is the single declaration site for every pinned
/// version, and reading only it is what stops a number mentioned in a comment
/// from being read as configuration. A job-level `env:` is indented, so it is
/// never picked up. Keep the two readers in step — if one starts accepting a
/// shape the other rejects, this test stops guarding what CI actually does.
String _ciEnv(String key) {
  final contents = readRepoFile(
    _ciWorkflow,
    consequence: 'It is the toolchain source of truth that '
        'scripts/ci-versions.sh reads and dev environments provision from.',
  );
  var inBlock = false;
  for (final raw in const LineSplitter().convert(contents)) {
    if (!inBlock) {
      if (raw == 'env:' || RegExp(r'^env:\s*$').hasMatch(raw)) inBlock = true;
      continue;
    }
    if (raw.trim().isEmpty || raw.trimLeft().startsWith('#')) continue;
    if (!raw.startsWith(' ')) break; // Column-0 line ends the block.
    final m = RegExp('^  ${RegExp.escape(key)}:\\s*(.*)\$').firstMatch(raw);
    if (m == null) continue;
    var value = m.group(1)!;
    final hash = value.indexOf('#');
    if (hash >= 0) value = value.substring(0, hash);
    value = value.trim();
    if (value.length >= 2 &&
        (value.startsWith("'") && value.endsWith("'") ||
            value.startsWith('"') && value.endsWith('"'))) {
      value = value.substring(1, value.length - 1);
    }
    if (value.isNotEmpty) return value;
  }
  fail(
    '$key is not declared in the top-level env: block of $_ciWorkflow. Every '
    'pinned version belongs there — scripts/ci-versions.sh reads only that '
    'block, so a value declared anywhere else is invisible to the setup '
    'scripts that provision dev environments from it.',
  );
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
  // Gradle files here document the very settings being asserted, so prose
  // would otherwise read as a second declaration. Strings are kept — one
  // assertion below has to see inside a `classpath '...'` literal.
  if (path.endsWith('.gradle')) contents = stripGradleComments(contents);
  final values = [
    for (final m in pattern.allMatches(contents)) m.group(1)!,
  ];
  if (values.isEmpty) {
    fail('Found no `${pattern.pattern}` in $path. $consequence');
  }
  return values;
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
        // The Podfile line is commented out, matching Flutter's template — the
        // platform comes from the Runner target instead. It is still asserted:
        // a stale version in a commented line is precisely what someone copies
        // the day they uncomment it.
        _iosPodfile: _allMatches(
          _iosPodfile,
          RegExp(r"#\s*platform\s*:ios,\s*'([0-9.]+)'"),
          consequence: 'The commented platform line is the documented way to '
              'pin the pod platform and must not name a stale version.',
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
      final app = _allMatches(
        _appGradle,
        gradleValue('minSdkVersion'),
        consequence: 'It declares the oldest Android the app installs on.',
      ).single;
      final rust = _allMatches(
        _rustGradle,
        gradleValue('minSdkVersion'),
        consequence: 'It declares the floor the Rust FFI module is built for.',
      ).single;
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
      final rust = _allMatches(
        _rustGradle,
        gradleValue('compileSdkVersion'),
        consequence: 'It selects the SDK the Rust FFI module compiles against.',
      ).single;
      final installed = _ciEnv('ANDROID_API');
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
    test('the emulator matrix agrees with ANDROID_EMULATOR_API', () {
      final declared = _ciEnv('ANDROID_EMULATOR_API');
      final matrix = _allMatches(
        _ciWorkflow,
        RegExp(r'api-level:\s*\[\s*(\d+)\s*\]'),
        consequence: 'It is the API level the emulator job boots.',
      ).single;
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
      final gradle = stripGradleComments(readRepoFile(
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

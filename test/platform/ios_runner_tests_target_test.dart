// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The RunnerTests XCTest target is how scripts/run-ios-device-tests.sh gets
// the Dart integration suites onto a physical iPhone without Xcode.app
// (`xcodebuild test`). Its source has to stay the integration_test host,
// the project has to keep pointing at that file, and the target has to sign
// with the app's team — a regression in any of the three is a device run
// that fails a long way from the file that caused it.
@Tags(['platform'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final pbxproj = File(
    'ios/Runner.xcodeproj/project.pbxproj',
  ).readAsStringSync();
  final host = File('ios/RunnerTests/RunnerTests.m');

  test(
    'RunnerTests.m hosts the Dart integration suites for xcodebuild test',
    () {
      expect(host.existsSync(), isTrue, reason: '${host.path} is missing');
      final source = host.readAsStringSync();
      expect(source, contains('@import integration_test;'));
      expect(source, contains('INTEGRATION_TEST_IOS_RUNNER(RunnerTests)'));
      expect(
        File('ios/RunnerTests/RunnerTests.swift').existsSync(),
        isFalse,
        reason: 'the Swift stub would be a second RunnerTests class',
      );
    },
  );

  test('the project compiles RunnerTests.m into the RunnerTests target', () {
    expect(pbxproj, contains('RunnerTests.m in Sources'));
    expect(
      pbxproj,
      contains('lastKnownFileType = sourcecode.c.objc; path = RunnerTests.m;'),
    );
    expect(pbxproj, isNot(contains('RunnerTests.swift')));
  });

  test('RunnerTests signs with the same team as Runner', () {
    final teams = RegExp(
      r'DEVELOPMENT_TEAM = ([A-Z0-9]+);',
    ).allMatches(pbxproj).map((m) => m.group(1)).toSet();
    expect(teams, hasLength(1), reason: 'one team across every configuration');
    // Runner has Debug/Profile/Release, RunnerTests the same three.
    expect(
      RegExp(r'DEVELOPMENT_TEAM = ').allMatches(pbxproj).length,
      6,
      reason: 'both targets name the team on all three configurations',
    );
  });

  test('the runner script defaults to the xcodebuild lane', () {
    final script = File('scripts/run-ios-device-tests.sh').readAsStringSync();
    expect(script, contains(r'LAUNCHER="${LB_IOS_LAUNCHER:-xcodebuild}"'));
    expect(script, contains('-only-testing:RunnerTests'));
    expect(script, contains('flutter build ios --config-only --debug -t'));
    expect(script, contains('Unlock .* to Continue'));
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The XCTest host for the Dart integration suites, so a physical iPhone can
// run them through `xcodebuild test` — no Xcode.app, no AppleScript, no
// Automation permission prompt. scripts/run-ios-device-tests.sh uses this
// lane by default; `flutter test -d <udid>` (its --launcher flutter lane)
// needs Xcode.app to attach a debugger on iOS 17+ and hangs forever in a
// shell that has not been granted control of Xcode.
//
// The macro asks the Dart side (IntegrationTestWidgetsFlutterBinding) for
// its results once the suite finishes and mints one XCTest method per Dart
// test, so `Test Case '-[RunnerTests testXxx]' passed` lines and the
// .xcresult bundle name each Dart test individually. Which Dart file runs is
// FLUTTER_TARGET in ios/Flutter/Generated.xcconfig, written by
// `flutter build ios --config-only -t integration_test/<suite>.dart`.
@import XCTest;
@import integration_test;

INTEGRATION_TEST_IOS_RUNNER(RunnerTests)

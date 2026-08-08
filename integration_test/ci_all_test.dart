// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Single entrypoint bundling every mock-safe integration test, for the CI
// device jobs (iOS simulator, Android emulator).
//
// Why this file exists: `flutter test integration_test` on a device treats
// EACH file as its own Dart entrypoint, so every file pays a full
// kernel-compile → Xcode/Gradle build → install → launch cycle. Measured on
// the macOS runner (10x-billed minutes), each cycle is ~2 minutes even with
// every cache warm — the second file cost more wall clock than actually
// running both files' tests. Importing the suites here and running only this
// file collapses N cycles into one.
//
// The cost is process isolation between suites, which is deliberately NOT
// lost everywhere: the linux-desktop CI job still runs each file in its own
// invocation (its per-file loop exists to dodge a flutter_tools VM-service
// bug anyway), so state leakage between files is still caught on the cheapest
// runner. Suites imported here must stay self-contained — build their own
// ProviderScope, reset any persistence they read (mock_flow_test.dart calls
// SharedPreferences.setMockInitialValues) — and run in the same alphabetical
// order the per-file jobs used, so both paths see the same sequence.
//
// Adding a new integration test file? Import it and add a group below — CI's
// `flutter` job fails if a mock-safe *_test.dart is missing from this file.
// Do NOT import e2e-tagged files (e2e_walkthrough_test.dart): file-level
// @Tags annotations are read from the entrypoint file only, so a tag in an
// imported file cannot be excluded with --exclude-tags — its tests would
// simply run. Exclusion from CI is by omission here.
import 'package:flutter_test/flutter_test.dart';

import 'error_flow_test.dart' as error_flow;
import 'mock_flow_test.dart' as mock_flow;

void main() {
  group('error_flow_test.dart', error_flow.main);
  group('mock_flow_test.dart', mock_flow.main);
}

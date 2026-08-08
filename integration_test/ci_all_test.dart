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
import 'package:integration_test/integration_test.dart';

import 'error_flow_test.dart' as error_flow;
import 'mock_flow_test.dart' as mock_flow;
import 'native_core_test.dart' as native_core;

void main() {
  // MUST come before the group() calls, and is not redundant with the
  // ensureInitialized() each imported suite already makes.
  //
  // IntegrationTestWidgetsFlutterBinding's CONSTRUCTOR registers a tearDownAll
  // (integration_test.dart: it completes _allTestsPassed and invokes the
  // native `allTestsFinished` channel method). package:test scopes a
  // tearDownAll to whatever group is being declared when it is registered — so
  // with initialization left to the imported suites, the binding is built
  // inside the FIRST group and its end-of-run hook fires between the two
  // suites instead of after both. The second suite then runs against an
  // already-finalised binding whose _allTestsPassed is complete, so its
  // failures cannot flip the verdict.
  //
  // Under `flutter test` (what CI uses) that is currently masked: flutter_tools
  // sets INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false and collects
  // results itself. It is NOT masked under flutter drive / integration_test_driver
  // / native instrumentation, which read exactly those results — so an
  // aggregate is the one shape where this ordering matters, and this file is
  // now the only device entrypoint.
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  group('error_flow_test.dart', error_flow.main);
  group('mock_flow_test.dart', mock_flow.main);
  // Last, and not only because the alphabet puts it there. It calls
  // RustLib.init(), which is process-wide: once the bridge is up
  // MockBleService stops using its Dart fallback table and starts calling the
  // real codec, so running this suite earlier would quietly change what the
  // two above are testing. See the header of native_core_test.dart.
  group('native_core_test.dart', native_core.main);
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Runs once before every test under test/. Flutter picks this file up by name;
// there is no import anywhere and there should not be one.
//
// Its whole job is to stop the app's own logging from being test output. A full
// `flutter test` run emitted 1,076 log lines interleaved with the progress
// lines — 274 `INFO [ble]`, 68 `DEBUG [ads]` and so on — so finding which test
// failed meant grepping past the app narrating itself. None of it is about the
// test that is running; a widget test builds a screen, the screen scans, the
// scan logs.
//
// Discarded rather than raised past: a test asserting on a WARNING is a real
// pattern here (`roomba_logging_test`, `adopt_service_test`), and a threshold
// that hid warnings would make those tests pass while testing nothing. The
// sink is what output goes to INSTEAD of the console, so every level still
// flows and simply lands nowhere. Tests that want the records call
// `Log.captureRecords()`, which replaces this for their duration —
// `Log.reset()` restores it afterwards via `Log.defaultSink`, which is the
// hook this file exists to set.
//
// To watch the logs while debugging one test, run with LB_TEST_LOGS set:
//
//     LB_TEST_LOGS=1 flutter test test/screens/scan_screen_test.dart
//
// which leaves the sink alone and lets everything reach the console as it
// always did.

import 'dart:async';
import 'dart:io';

import 'package:liberated_bread_mobile/core/log.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  if (Platform.environment['LB_TEST_LOGS'] == null) {
    // Named, not a literal, so `Log.reset()` in any test's tearDown restores
    // THIS rather than the console — otherwise one reset would turn the noise
    // back on for every test that ran after it.
    Log.defaultSink = _discard;
    Log.sink = _discard;
  }
  // The ring buffer is the app's diagnostics feature and costs a list append
  // per record; a test run has no reader for it and 1,076 records to keep.
  // Tests that exercise the buffer install their own.
  Log.buffer = null;
  await testMain();
}

void _discard(LogRecord record) {}

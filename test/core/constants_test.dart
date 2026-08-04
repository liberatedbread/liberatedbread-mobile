// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/constants.dart';

void main() {
  test('app constants have sane values', () {
    expect(AppConstants.appName, 'Liberated Bread');
    expect(AppConstants.appTagline, isNotEmpty);
    expect(AppConstants.defaultScanDuration, greaterThan(0));
    expect(AppConstants.nearbyRssiThreshold, -70);
  });

  test('appVersion matches the pubspec.yaml version', () {
    // appVersion is sent to Home Assistant as app_version; a drift from the
    // released version makes support logs lie. flutter test runs from the
    // package root, so pubspec.yaml resolves relatively.
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final match =
        RegExp(r'^version:\s*(\S+)', multiLine: true).firstMatch(pubspec);
    expect(match, isNotNull, reason: 'pubspec.yaml must declare a version');
    // The '+buildNumber' suffix is not part of the human-facing version.
    final version = match!.group(1)!.split('+').first;
    expect(AppConstants.appVersion, version);
  });
}

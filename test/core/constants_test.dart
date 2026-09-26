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

  test('appVersion is the release stamp, and admits when there is none', () {
    // A test build is not stamped, so it must not pass for a release.
    expect(AppConstants.appVersion, 'dev build');
    // scripts/release.sh stamps releases. If the define it passes and the one
    // constants.dart reads ever drift apart, every store build reports
    // "dev build" and its bug reports lose their commit. flutter test runs from
    // the package root, so both paths resolve relatively.
    for (final file in ['lib/core/constants.dart', 'scripts/release.sh']) {
      expect(
        File(file).readAsStringSync(),
        contains('LIBERATED_BREAD_BUILD'),
        reason: '$file must use the LIBERATED_BREAD_BUILD define',
      );
    }
  });
}

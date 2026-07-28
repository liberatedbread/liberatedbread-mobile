// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/constants.dart';

void main() {
  test('app constants have sane values', () {
    expect(AppConstants.appName, 'Liberated Bread');
    expect(AppConstants.appTagline, isNotEmpty);
    expect(AppConstants.defaultScanDuration, greaterThan(0));
    expect(AppConstants.nearbyRssiThreshold, -70);
  });
}

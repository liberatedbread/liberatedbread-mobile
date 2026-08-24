// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// `AppConstants.appVersion` is a second copy of pubspec's `version:`, and a
// second copy of a fact drifts. This is the cheapest thing that stops it:
// no runtime dependency (package_info_plus would be one for a single
// string), just a test that reads the file the build already reads.
//
// The version is not decoration — it goes out as `app_version` in the Home
// Assistant registration, which is where a stale one is least visible and
// most annoying to diagnose.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/constants.dart';

void main() {
  test('AppConstants.appVersion matches pubspec', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final declared = RegExp(r'^version:\s*(\S+)\s*$', multiLine: true)
        .firstMatch(pubspec)
        ?.group(1);
    expect(declared, isNotNull, reason: 'pubspec.yaml must declare a version');

    // pubspec carries the build number too (`0.1.0+1`); the constant is the
    // semantic half, which is what a server wants to hear.
    final semantic = declared!.split('+').first;
    expect(
      AppConstants.appVersion,
      semantic,
      reason: 'lib/core/constants.dart duplicates pubspec.yaml\'s version — '
          'bump both, or the Home Assistant registration reports a version '
          'this build is not',
    );
  });
}

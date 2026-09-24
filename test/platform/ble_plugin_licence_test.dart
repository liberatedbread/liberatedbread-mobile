// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// flutter_blue_plus 2.x is not open source. From 2.0 the project moved to a
// "FlutterBluePlus License" that restricts redistribution and adds build-time
// telemetry; 1.36.8 (with platform packages 7.0.x) is the last BSD-3 release
// and is therefore the ceiling for this app, which ships under Apache-2.0.
//
// That is a licence boundary, not a preference, and `pub upgrade --major`
// would cross it silently — so the pin is asserted here rather than left to a
// comment in pubspec.yaml.
@Tags(['platform'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The BSD-3 clause every one of these packages' LICENSE files carries. A 2.x
/// package's licence has no such sentence.
const _bsdMarker = 'Redistribution and use in source and binary forms';

void main() {
  final pubspec = File('pubspec.yaml').readAsStringSync();
  final lock = File('pubspec.lock').readAsStringSync();

  /// The version a pubspec.yaml line pins, e.g. `flutter_blue_plus: 1.36.8`.
  String pinned(String package) {
    final match = RegExp(
      '^  $package:\\s*(\\S+)\\s*\$',
      multiLine: true,
    ).firstMatch(pubspec);
    expect(match, isNotNull, reason: '$package is not pinned in pubspec.yaml');
    return match!.group(1)!;
  }

  String lockedVersion(String package) {
    final match = RegExp(
      '^  $package:\\n(?:.*\\n)*?    version: "([^"]+)"',
      multiLine: true,
    ).firstMatch(lock);
    expect(match, isNotNull, reason: '$package is not in pubspec.lock');
    return match!.group(1)!;
  }

  test('flutter_blue_plus is pinned exactly, at the last BSD-3 release', () {
    // Exact, not a caret range: `^1.36.8` would let a resolve walk into 2.x.
    expect(
      pinned('flutter_blue_plus'),
      '1.36.8',
      reason:
          'flutter_blue_plus 2.x is the commercial licence; 1.36.8 is the '
          'last BSD-3 release',
    );
    expect(lockedVersion('flutter_blue_plus'), '1.36.8');
  });

  test('the federated packages moved with it, and stayed BSD-3', () {
    // The interface package is what test/fakes/emulated_ble.dart implements,
    // so a mismatch with the plugin is a compile error rather than a warning.
    expect(pinned('flutter_blue_plus_platform_interface'), '7.0.0');
    expect(pinned('flutter_blue_plus_linux'), '7.0.3');
    for (final package in const [
      'flutter_blue_plus',
      'flutter_blue_plus_platform_interface',
      'flutter_blue_plus_darwin',
      'flutter_blue_plus_linux',
      'flutter_blue_plus_android',
    ]) {
      final version = lockedVersion(package);
      expect(
        version,
        isNot(startsWith('2.')),
        reason: '$package $version is past the BSD-3 line',
      );
      final licence = File('${_pubCache()}/$package-$version/LICENSE');
      if (!licence.existsSync()) continue; // not fetched on this host
      expect(
        licence.readAsStringSync(),
        contains(_bsdMarker),
        reason: '$package $version no longer carries the BSD-3 grant',
      );
    }
  });
}

/// Where pub unpacks hosted packages, honouring PUB_CACHE.
String _pubCache() {
  final override = Platform.environment['PUB_CACHE'];
  final root = override ?? '${Platform.environment['HOME']}/.pub-cache';
  return '$root/hosted/pub.dev';
}

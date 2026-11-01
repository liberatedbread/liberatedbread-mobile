// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _plugin =
    'packages/flutter_blue_plus_darwin/darwin/flutter_blue_plus_darwin/'
    'Sources/flutter_blue_plus_darwin/FlutterBluePlusPlugin.m';

void main() {
  final source = File(_plugin).readAsStringSync();

  test('setOptions ignores NSNull instead of messaging it as a bool', () {
    for (final variable in ['powerAlert', 'restoreState']) {
      expect(
        source,
        contains(
          'if ($variable != nil && '
          '![$variable isKindOfClass:[NSNull class]])',
        ),
      );
    }
    expect(
      source,
      isNot(contains('self.showPowerAlert = args[@"show_power_alert"];')),
    );
    expect(
      source,
      isNot(contains('self.restoreState = args[@"restore_state"];')),
    );
  });

  test('a nil or unsupported descriptor value becomes NSNull, not a crash', () {
    expect(
      source,
      contains('@"value":                  data ? data : [NSNull null],'),
    );
  });

  test('the override resolves to the local BSD-licensed source', () {
    final lock = File('pubspec.lock').readAsStringSync();
    expect(lock, contains('source: path'));
    expect(lock, contains('path: "packages/flutter_blue_plus_darwin"'));
    expect(
      File('packages/flutter_blue_plus_darwin/LICENSE').readAsStringSync(),
      contains('Redistribution and use in source and binary forms'),
    );
  });
}

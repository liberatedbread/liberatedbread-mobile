// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/core/theme.dart';

void main() {
  test('light theme uses Material 3 and a light color scheme', () {
    final theme = OpenGreenIoTTheme.light;
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.brightness, Brightness.light);
  });

  test('dark theme uses Material 3 and a dark color scheme', () {
    final theme = OpenGreenIoTTheme.dark;
    expect(theme.useMaterial3, isTrue);
    expect(theme.colorScheme.brightness, Brightness.dark);
  });
}

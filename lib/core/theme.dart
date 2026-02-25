// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

class OpenGreenIoTTheme {
  OpenGreenIoTTheme._();
  static final ThemeData light = ThemeData(
    useMaterial3: true,
    colorSchemeSeed: const Color(0xFF2D6A4F),
    brightness: Brightness.light,
  );
  static final ThemeData dark = ThemeData(
    useMaterial3: true,
    colorSchemeSeed: const Color(0xFF40916C),
    brightness: Brightness.dark,
  );
}

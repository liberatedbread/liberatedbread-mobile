// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'core/theme.dart';
import 'screens/scan_screen.dart';

class OpenGreenIoTApp extends StatelessWidget {
  const OpenGreenIoTApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'OpenGreenIoT',
      theme: OpenGreenIoTTheme.light,
      darkTheme: OpenGreenIoTTheme.dark,
      home: const ScanScreen(),
    );
  }
}

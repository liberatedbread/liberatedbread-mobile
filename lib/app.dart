// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'core/theme.dart';
import 'screens/home_shell.dart';

class LiberatedBreadApp extends StatelessWidget {
  const LiberatedBreadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liberated Bread',
      theme: LiberatedBreadTheme.light,
      darkTheme: LiberatedBreadTheme.dark,
      home: const HomeShell(),
    );
  }
}

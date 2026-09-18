// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'core/constants.dart';
import 'core/theme.dart';
import 'providers/saved_device_provider.dart';
import 'providers/startup_warmup.dart';
import 'screens/home_shell.dart';
import 'screens/terms_screen.dart';

class LiberatedBreadApp extends StatelessWidget {
  const LiberatedBreadApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Liberated Bread',
      theme: LiberatedBreadTheme.light,
      darkTheme: LiberatedBreadTheme.dark,
      // First launch shows the disclaimer gate; once accepted (for the current
      // terms version) the app opens straight onto the home shell.
      home: const _TermsGate(),
    );
  }
}

/// Gates the app behind the first-launch disclaimer. Reads the accepted-terms
/// version from SharedPreferences (resolved eagerly before runApp, so the read
/// is synchronous) and shows [TermsScreen] until the user accepts the current
/// [AppConstants.termsVersion], then swaps in [HomeShell].
class _TermsGate extends ConsumerStatefulWidget {
  const _TermsGate();

  @override
  ConsumerState<_TermsGate> createState() => _TermsGateState();
}

class _TermsGateState extends ConsumerState<_TermsGate> {
  late bool _accepted;

  @override
  void initState() {
    super.initState();
    final prefs = ref.read(sharedPreferencesProvider);
    _accepted =
        (prefs.getInt(AppConstants.termsAcceptedKey) ?? 0) >=
        AppConstants.termsVersion;
    // The first screen the app has is the first chance to start the catalogue
    // and registry loads. Without this they began when the first scan result
    // arrived, which is the worst moment for them.
    warmStartupCaches(ref);
  }

  Future<void> _accept() async {
    final prefs = ref.read(sharedPreferencesProvider);
    await prefs.setInt(
      AppConstants.termsAcceptedKey,
      AppConstants.termsVersion,
    );
    if (mounted) setState(() => _accepted = true);
  }

  @override
  Widget build(BuildContext context) =>
      _accepted ? const HomeShell() : TermsScreen(onAccept: _accept);
}

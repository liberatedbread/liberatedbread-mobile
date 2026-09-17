// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The one place the privacy policy, the disclaimer and the open-source
// licences can be reached AFTER first launch.
//
// They used to live only on the Terms gate, which is shown once and never
// again (lib/app.dart swaps it out permanently once accepted). App Review
// Guideline 5.1.1(i) wants the privacy policy "easily accessible" inside the
// app, and a user who wants to re-read what they agreed to should not have
// to reinstall to find it.
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/web_link.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            AppConstants.appName,
            style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Independent and unofficial. Liberated Bread talks to your devices '
            'directly, over Bluetooth and your own Wi-Fi network, and is not '
            'affiliated with any device maker.',
            style: text.bodyMedium?.copyWith(
              color: scheme.onSurfaceVariant,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 24),
          ListTile(
            leading: const Icon(Icons.privacy_tip_outlined),
            title: const Text('Privacy policy'),
            subtitle: const Text(AppConstants.privacyUrl),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => openWebLink(context, AppConstants.privacyUrl),
          ),
          ListTile(
            leading: const Icon(Icons.gavel_outlined),
            title: const Text('Disclaimer and terms'),
            subtitle: const Text(AppConstants.disclaimerUrl),
            trailing: const Icon(Icons.open_in_new, size: 18),
            onTap: () => openWebLink(context, AppConstants.disclaimerUrl),
          ),
          ListTile(
            leading: const Icon(Icons.description_outlined),
            title: const Text('Open-source licences'),
            subtitle: const Text('The packages this app is built from'),
            onTap: () => showLicensePage(
              context: context,
              applicationName: AppConstants.appName,
            ),
          ),
        ],
      ),
    );
  }
}

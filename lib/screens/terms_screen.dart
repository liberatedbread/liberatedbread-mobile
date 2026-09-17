// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../core/constants.dart';
import '../core/web_link.dart';

/// The first-launch gate: the user must accept the disclaimer before the app
/// opens. Shown once (until [AppConstants.termsVersion] is bumped), it states
/// plainly that this is an independent, unofficial project and links the full
/// disclaimer and privacy policy.
///
/// Presentation-only — it does not persist anything. The caller ([app.dart]'s
/// gate) records acceptance and swaps in the home screen via [onAccept].
class TermsScreen extends StatelessWidget {
  final VoidCallback onAccept;

  const TermsScreen({super.key, required this.onAccept});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
          children: [
            Icon(Icons.bakery_dining_outlined, size: 44, color: scheme.primary),
            const SizedBox(height: 12),
            Text(
              'Welcome to ${AppConstants.appName}',
              style: text.headlineSmall,
            ),
            const SizedBox(height: 4),
            Text(
              AppConstants.appTagline,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),

            // Independence / unofficial notice. Deliberately not worded as
            // "experimental" or "beta" — Guideline 2.2 rejects demos and
            // betas, and reviewers act on that wording on the first screen
            // they see. The disclaimer content is unchanged; only the framing.
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: scheme.tertiary.withValues(alpha: .12),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: scheme.tertiary.withValues(alpha: .5),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.science_outlined,
                        size: 20,
                        color: scheme.tertiary,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        'Independent and unofficial',
                        style: text.titleSmall?.copyWith(
                          color: scheme.tertiary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'This app talks to consumer devices over Bluetooth and '
                    'your local network. It is an independent, open-source '
                    'project — not affiliated with, endorsed by, or supported '
                    'by any device manufacturer. Device support is contributed '
                    'and may be incomplete or wrong, and it is provided as-is, '
                    'without warranty. You use it at your own risk.',
                    style: text.bodyMedium,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Some devices it can control — IPL hair-removal handsets, '
                    'treadmills, heaters and the like — can cause injury or '
                    'damage if used improperly. Always follow the '
                    "manufacturer's own instructions and safety guidance.",
                    style: text.bodyMedium,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Text(
              'By continuing you agree to the disclaimer / terms of use and '
              'acknowledge the privacy policy.',
              style: text.bodyMedium,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 8,
                children: [
                  OutlinedButton.icon(
                    onPressed: () => _open(context, AppConstants.disclaimerUrl),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Disclaimer & terms'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _open(context, AppConstants.privacyUrl),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Privacy policy'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: onAccept,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 6),
                child: Text('I understand and agree'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // These links are constants, but they go through the same guard every
  // external link does, so there is exactly one way a URL leaves the app.
  Future<void> _open(BuildContext context, String url) =>
      openWebLink(context, url);
}

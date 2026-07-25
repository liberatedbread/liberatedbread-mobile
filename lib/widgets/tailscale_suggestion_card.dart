// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../core/ha_url.dart';

/// Contextual remote-access advice for the entered Home Assistant URL.
///
/// LAN-only addresses get a nudge toward Tailscale (free, no port
/// forwarding, stable `https://...ts.net` MagicDNS URL), tailnet addresses
/// get a confirmation, and public plain-HTTP gets a security warning.
/// Renders nothing for public HTTPS or unparseable input.
class TailscaleSuggestionCard extends StatelessWidget {
  final HaUrlKind kind;
  final VoidCallback? onLearnMore;

  const TailscaleSuggestionCard({
    super.key,
    required this.kind,
    this.onLearnMore,
  });

  @override
  Widget build(BuildContext context) {
    // Derive colors from the active ColorScheme so the card stays legible in
    // both light and dark themes (see lib/core/theme.dart). Each *Container /
    // on*Container pair is a guaranteed-contrast fill/foreground duo.
    final scheme = Theme.of(context).colorScheme;
    switch (kind) {
      case HaUrlKind.privateLan:
      case HaUrlKind.mdnsLocal:
        return _card(
          background: scheme.secondaryContainer,
          foreground: scheme.onSecondaryContainer,
          icon: Icons.home_outlined,
          title: 'This address only works on your home network',
          body: 'For secure remote access, try Tailscale: it\'s free for '
              'personal use and gives Home Assistant a magic '
              'https://...ts.net address that works anywhere - no port '
              'forwarding.',
          showLearnMore: true,
        );
      case HaUrlKind.tailscale:
        return _card(
          background: scheme.tertiaryContainer,
          foreground: scheme.onTertiaryContainer,
          icon: Icons.vpn_lock,
          title: 'Tailscale detected',
          body: 'Secure remote access ready - this address works from '
              'anywhere on your tailnet.',
          showLearnMore: false,
        );
      case HaUrlKind.publicHttp:
        return _card(
          background: scheme.errorContainer,
          foreground: scheme.onErrorContainer,
          icon: Icons.warning_amber_outlined,
          title: 'Unencrypted connection',
          body: 'Plain HTTP over the internet lets others intercept your '
              'access token. Use HTTPS, or Tailscale for an encrypted '
              'tunnel without certificates.',
          showLearnMore: true,
        );
      case HaUrlKind.publicHttps:
      case HaUrlKind.invalid:
        return const SizedBox.shrink();
    }
  }

  Widget _card({
    required Color background,
    required Color foreground,
    required IconData icon,
    required String title,
    required String body,
    required bool showLearnMore,
  }) {
    return Card(
      color: background,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: foreground, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: foreground,
                      )),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(body, style: TextStyle(fontSize: 13, color: foreground)),
            if (showLearnMore && onLearnMore != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  style: TextButton.styleFrom(foregroundColor: foreground),
                  onPressed: onLearnMore,
                  child: const Text('Set up Tailscale'),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

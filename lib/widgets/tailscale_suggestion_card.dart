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
    switch (kind) {
      case HaUrlKind.privateLan:
      case HaUrlKind.mdnsLocal:
        return _card(
          color: Colors.amber.shade50,
          icon: Icons.home_outlined,
          iconColor: Colors.amber.shade800,
          title: 'This address only works on your home network',
          body: 'For secure remote access, try Tailscale: it\'s free for '
              'personal use and gives Home Assistant a magic '
              'https://...ts.net address that works anywhere - no port '
              'forwarding.',
          showLearnMore: true,
        );
      case HaUrlKind.tailscale:
        return _card(
          color: Colors.green.shade50,
          icon: Icons.vpn_lock,
          iconColor: Colors.green.shade700,
          title: 'Tailscale detected',
          body: 'Secure remote access ready - this address works from '
              'anywhere on your tailnet.',
          showLearnMore: false,
        );
      case HaUrlKind.publicHttp:
        return _card(
          color: Colors.orange.shade50,
          icon: Icons.warning_amber_outlined,
          iconColor: Colors.orange.shade800,
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
    required Color color,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String body,
    required bool showLearnMore,
  }) {
    return Card(
      color: color,
      margin: const EdgeInsets.symmetric(vertical: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: iconColor, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(title,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(body, style: const TextStyle(fontSize: 13)),
            if (showLearnMore && onLearnMore != null)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
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

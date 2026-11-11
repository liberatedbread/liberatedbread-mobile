// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// The entry point to the Bluetooth pairing guide, at the foot of the Nearby
/// tab — the counterpart of the Wi-Fi tab's `AdoptDeviceCard`.
///
/// At the foot rather than the head because the order of the tab is the order
/// of the questions: the scan answers "what is here", and someone who scrolls
/// past everything it found without seeing their device is the person asking
/// "how do I make it show up". It has no live state of its own — unlike the
/// Wi-Fi card, there is no setup network for the OS to notice.
class PairNewDeviceCard extends StatelessWidget {
  final VoidCallback onTap;

  const PairNewDeviceCard({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.surfaceContainerHighest,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.bluetooth_searching, color: scheme.secondary),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Pairing a new device',
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'How to put each device in pairing mode so the scan '
                      'can find it',
                      style: text.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

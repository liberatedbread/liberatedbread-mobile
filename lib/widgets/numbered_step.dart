// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

/// One numbered instruction — a filled circle with the number, the text
/// beside it. Shared by the Wi-Fi adopt screen and the Bluetooth pairing
/// guide so the two "how to set this up" pages read as one family.
class NumberedStep extends StatelessWidget {
  final int number;
  final String text;

  const NumberedStep({super.key, required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final theme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CircleAvatar(
            radius: 14,
            backgroundColor: scheme.secondaryContainer,
            child: Text(
              '$number',
              style: theme.labelLarge?.copyWith(
                color: scheme.onSecondaryContainer,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: theme.bodyMedium?.copyWith(height: 1.5)),
          ),
        ],
      ),
    );
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The acknowledgement that stands between a stored setting and a wider radio.

import 'package:flutter/material.dart';

import '../core/frequency.dart';
import '../models/radio_profile.dart';

/// Ask the operator to acknowledge what widening a radio's transmit range
/// means, and return true only if they did.
///
/// Configuring a wider transmit range is a standard feature of every serious
/// programming tool. Transmitting outside your own authorization is not, and
/// that responsibility sits with the operator alone -- so the app says so
/// once, plainly, in the operator's own words rather than burying it in a
/// settings subtitle nobody reads.
///
/// Returns false for a cancel, a back gesture, or a profile that has no
/// documented software path at all.
Future<bool> showTxUnlockDialog(
  BuildContext context,
  RadioProfile profile,
) async {
  if (!profile.txUnlock.supported) return false;

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => _TxUnlockDialog(profile: profile),
  );
  return confirmed ?? false;
}

class _TxUnlockDialog extends StatefulWidget {
  final RadioProfile profile;

  const _TxUnlockDialog({required this.profile});

  @override
  State<_TxUnlockDialog> createState() => _TxUnlockDialogState();
}

class _TxUnlockDialogState extends State<_TxUnlockDialog> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unlock = widget.profile.txUnlock;

    return AlertDialog(
      title: const Text('Widen the transmit range?'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This changes the frequency limits stored in your '
              '${widget.profile.displayName}, the same way CHIRP and the '
              "manufacturer's own software can.",
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 12),
            Text(
              'It would be able to transmit on:',
              style: theme.textTheme.labelLarge,
            ),
            const SizedBox(height: 4),
            for (final range in unlock.expandedTxRanges)
              Padding(
                padding: const EdgeInsets.only(left: 8, top: 2),
                child: Text(
                  '${formatHzAsMegahertz(range.lowHz)} – '
                  '${formatHzAsMegahertz(range.highHz)} MHz',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            const SizedBox(height: 12),
            Text(
              'Those ranges include spectrum allocated to public safety, '
              'commercial and government users. Transmitting there without '
              'authorization is unlawful and can interfere with emergency '
              'communications.',
              style: theme.textTheme.bodyMedium,
            ),
            if (!unlock.verified) ...[
              const SizedBox(height: 12),
              Text(
                'This radio\'s limits have not been confirmed on hardware '
                'yet. The app reads the existing limits back before and '
                'after, and always keeps a full backup you can restore.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _acknowledged,
              onChanged: (value) =>
                  setState(() => _acknowledged = value ?? false),
              title: const Text(
                'I am solely responsible for transmitting only within my '
                'licence or other lawful authority — such as MARS or CAP '
                'membership.',
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          // Nothing to press until the box is ticked: the acknowledgement is
          // the point, and a dialog whose confirm button works regardless is
          // a dialog nobody read.
          onPressed: _acknowledged
              ? () => Navigator.of(context).pop(true)
              : null,
          child: const Text('Enable'),
        ),
      ],
    );
  }
}

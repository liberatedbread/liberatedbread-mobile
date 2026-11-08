// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../services/spec_codec.dart';

/// The notice every read-only handler's screen carries: this app reads this
/// device and sends nothing that changes it, the readings have not been
/// checked on real hardware here, and what the spec warns about.
class ReadOnlyNotice extends StatelessWidget {
  final SafetyAdvisoryDto? advisory;

  const ReadOnlyNotice({super.key, this.advisory});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final summary = advisory?.summary.trim();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.visibility_outlined, color: scheme.secondary),
              const SizedBox(width: 10),
              Expanded(child: Text('Read-only', style: text.titleMedium)),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'This app only reads this device. It cannot change a setting or '
            'switch anything on it. The decoding comes from the published '
            'protocol notes and has not been checked against hardware by this '
            'project.',
            style: text.bodySmall,
          ),
          if (summary != null && summary.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(summary, style: text.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// Every command the spec declares, with what this app does about it.
///
/// Listing them is the point: the spec really does describe these, and a
/// reader who knows that should find a plain refusal here and not wonder
/// where the buttons went. There is nothing to press, on purpose.
class ReadOnlyCommandsCard extends StatelessWidget {
  final List<ReadOnlyCommandDto> commands;

  const ReadOnlyCommandsCard({super.key, required this.commands});

  @override
  Widget build(BuildContext context) {
    if (commands.isEmpty) return const SizedBox.shrink();
    final refused = commands.where((c) => !c.sent).length;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        title: const Text('Commands in the device spec'),
        subtitle: Text(
          '$refused of ${commands.length} are refused by this app',
        ),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final command in commands)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    command.sent ? Icons.download_outlined : Icons.block,
                    size: 18,
                    color: command.sent ? scheme.secondary : scheme.error,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(command.name, style: text.titleSmall),
                        Text(
                          command.sent
                              ? 'Sent by this app, to read.'
                              : command.refusal ?? 'Refused by this app.',
                          style: text.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

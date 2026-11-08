// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/mono_text.dart';
import '../../core/web_link.dart';

const _researchUrl =
    'https://inventor7777.github.io/blog/2026/10/22/debug-access-on-brother/';

Future<void> showBrotherDebugSheet(
  BuildContext context, {
  required String host,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  builder: (_) => _BrotherDebugSheet(host: host),
);

class _BrotherDebugSheet extends StatelessWidget {
  final String host;

  const _BrotherDebugSheet({required this.host});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Brother debug console', style: text.titleLarge),
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'Advanced and model-specific. The public research was verified '
                'on an MFC-L8900CDW, not on this printer. Nothing here is sent '
                'automatically.',
                style: text.bodyMedium?.copyWith(
                  color: scheme.onErrorContainer,
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              '1. In the printer’s admin page, enable Telnet (usually under '
              'Network or Advanced Settings; the exact menu varies by '
              'firmware).\n\n'
              '2. Connect with the command below. Enter the printer admin '
              'password at the # prompt, and leave Enter username blank.',
              style: text.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 12),
            _CommandRow(command: 'telnet $host'),
            const SizedBox(height: 16),
            Text(
              'On the MFC-L8900CDW, the researcher reports that this command '
              'enters debug user mode at the Local> prompt:',
              style: text.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 12),
            const _CommandRow(command: 'SET USER 640184.571119'),
            const SizedBox(height: 12),
            Text(
              'DEBUG SHOW HEAP was verified there as a read-only diagnostic. '
              'The other debug, SET, CLEAR, INITIALIZE, ZERO and WATCH '
              'operations can change configuration, counters or memory. Do '
              'not run them unless you understand their effect.',
              style: text.bodyMedium?.copyWith(height: 1.4),
            ),
            const SizedBox(height: 12),
            Text(
              'The same article says this family uses T-Kernel, not Linux. '
              'Its findings are a lead for investigation, not evidence that '
              'this model accepts the same command.',
              style: text.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => unawaited(openWebLink(context, _researchUrl)),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Read the MFC-L8900CDW research'),
            ),
          ],
        ),
      ),
    );
  }
}

class _CommandRow extends StatelessWidget {
  final String command;

  const _CommandRow({required this.command});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Row(
      children: [
        Expanded(
          child: SelectableText(
            command,
            style: Theme.of(context).textTheme.bodySmall?.monospaced,
          ),
        ),
        IconButton(
          tooltip: 'Copy command',
          icon: const Icon(Icons.copy),
          onPressed: () =>
              unawaited(Clipboard.setData(ClipboardData(text: command))),
        ),
      ],
    ),
  );
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';

import '../services/spec_codec.dart';

/// The card a device shows when its spec names a value the app has to be
/// given before anything on the screen will work.
///
/// The generic form of the Rabbit Air panel's user-key prompt, which is where
/// the shape comes from: name the missing thing, say where a person finds it,
/// take it, store it. What makes this one generic is that every word of it
/// comes from the spec — the credential's name and the sentence describing it
/// are the spec author's, so a device added to the catalogue tomorrow gets a
/// working prompt with no UI written for it.
///
/// Only credentials the spec says must be ASKED for reach here. One a pairing
/// flow issues is that flow's to obtain — prompting for it teaches people to
/// paste secrets a button press was about to hand over — and one no command
/// consumes is a question no answer improves. `mustBeAskedFor` is that rule,
/// resolved in Rust beside the spec that states it.
class DeviceCredentialsCard extends StatelessWidget {
  /// What is still missing, in the spec's own order.
  final List<NetworkCredentialDto> missing;

  /// Store one value under its spec-declared name. Returning re-reads the
  /// screen's state, so the caller owns the reload.
  final Future<void> Function(String name, String value) onSave;

  const DeviceCredentialsCard({
    super.key,
    required this.missing,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    if (missing.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key_outlined, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    missing.length == 1
                        ? 'This device needs one more thing'
                        : 'This device needs ${missing.length} more things',
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              // Said once, at the top: the per-credential rows below carry the
              // spec's own description, which is the part that differs.
              'Its controls stay unavailable until then — a command sent '
              'without these has nowhere to go.',
              style: theme.textTheme.bodySmall,
            ),
            for (final credential in missing) ...[
              const SizedBox(height: 12),
              _CredentialRow(
                credential: credential,
                onSave: (value) => onSave(credential.name, value),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CredentialRow extends StatelessWidget {
  final NetworkCredentialDto credential;
  final Future<void> Function(String value) onSave;

  const _CredentialRow({required this.credential, required this.onSave});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final description = credential.description;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(credential.name, style: theme.textTheme.titleSmall),
        if (description != null && description.isNotEmpty)
          Text(description.trim(), style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.icon(
            onPressed: () => unawaited(_prompt(context)),
            icon: const Icon(Icons.edit_outlined),
            label: Text('Enter ${credential.name}'),
          ),
        ),
      ],
    );
  }

  Future<void> _prompt(BuildContext context) async {
    final controller = TextEditingController();
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(credential.name),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (credential.description?.isNotEmpty ?? false) ...[
              Text(credential.description!.trim()),
              const SizedBox(height: 12),
            ],
            TextField(
              controller: controller,
              autofocus: true,
              autocorrect: false,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
              ),
              onSubmitted: (value) {
                final trimmed = value.trim();
                if (trimmed.isNotEmpty) Navigator.of(context).pop(trimmed);
              },
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              // An empty value is not a credential: stored, it would render a
              // path with a blank segment and reach the device as a request
              // for somebody else's resource. Refused by doing nothing, the
              // way the field being untouched does.
              if (value.isEmpty) return;
              Navigator.of(context).pop(value);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // Deliberately not disposed: the pop animation still builds the TextField
    // for a few frames, and a focused field schedules a caret frame that would
    // touch a disposed controller. Dialog-scoped, collected with the tree.
    if (entered == null) return;
    await onSave(entered);
  }
}

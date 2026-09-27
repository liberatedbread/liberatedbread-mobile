// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Asking before something that cannot be taken back.

import 'package:flutter/material.dart';

/// Ask before an action that changes something for good, and answer true
/// only for its confirm button — never for Cancel, a back gesture or a tap
/// outside the dialog.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
}) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// Ask before anything that opens a lock, answering true only for Unlock.
///
/// One helper for every card that can actuate a lock — the bolt switch and a
/// lock's momentary buttons — so the wording and the Cancel default cannot
/// drift. A lock whose spec modelled unlocking as a `button` used to fire on
/// one tap under a generic 'Press', while the switch beside it asked first.
Future<bool> confirmUnlock(BuildContext context, String entityName) =>
    confirmAction(
      context,
      title: 'Unlock $entityName?',
      message: 'This opens the lock for anyone at the door.',
      confirmLabel: 'Unlock',
    );

/// Ask before a lock's momentary action that is not known to open it — a
/// button press or a role nobody draws — answering true only for the
/// action's own label.
///
/// Every such action on a lock still asks (see `BleEntityActionCard.isLock`:
/// what a button does is not guessed from its name). But [confirmUnlock]'s
/// 'Unlock X? This opens the lock…' told the user a 'Lock' or 'Beep' button
/// would open the door, and titled BioKey's own 'Unlock' button 'Unlock
/// Unlock?'. This names what will be sent and keeps the warning conditional.
Future<bool> confirmLockAction(BuildContext context, String actionLabel) =>
    confirmAction(
      context,
      title: 'Send "$actionLabel" to this lock?',
      message:
          'The spec does not say whether this opens the lock. If it does, '
          'it opens it for anyone at the door.',
      confirmLabel: actionLabel,
    );

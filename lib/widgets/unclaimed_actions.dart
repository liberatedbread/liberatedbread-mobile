// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';

import '../core/value_format.dart';

/// The actions a curated card resolved but did not draw.
///
/// WHY THIS EXISTS
///
/// The resolver and the cards keep two separate lists of role names. Rust
/// decides which roles an entity supports from the shared `PLATFORM_ROLES`
/// table; each card then asks for the handful it knows how to present —
/// `_action('turn_on')`, `_action('set_brightness')` — and anything else the
/// resolver produced is simply never looked up. It does not appear, and it is
/// not counted in the hidden-controls note either, because that note reports
/// entities that resolved NOTHING and this entity resolved plenty.
///
/// So a role could be added to the table, bound by a spec, resolved by Rust,
/// and still be invisible, with no failure anywhere. `toggle` and `set_effect`
/// both spent a release in exactly that state: a television whose only power
/// channel is a toggle drew a card with a title, a state line, and no control.
///
/// This closes the loop from the other end. A card draws what it knows how to
/// draw and hands the rest here; every resolved action reaches the screen one
/// way or another, and adding a role to the table can no longer produce a
/// silent nothing.
///
/// WHAT IT DRAWS, AND WHAT IT DECLINES TO
///
/// A FIXED action — no user parameter — is a button, labelled from its role.
/// That is the whole control: pressing it sends the command, which is exactly
/// what the spec said the role does. `toggle`, `press`, `open_cover` and every
/// fixed role a future table gains work here without another line of code.
///
/// A VALUED action needs a control shaped to its value — a slider wants
/// bounds, a picker wants the option table — and guessing that shape is how a
/// dead control gets drawn. Those are NAMED instead, in the same muted line the
/// panels already use for what they cannot show. Being told "Set fan mode is
/// not shown yet" is worse than a working picker and much better than silence.
class UnclaimedActions extends StatelessWidget {
  /// Every action the entity resolved, as (role, has a value to supply).
  final List<({String role, bool takesValue})> actions;

  /// Roles the calling card already drew. Case-sensitive role names, the
  /// same vocabulary `PLATFORM_ROLES` emits.
  final Set<String> claimed;

  /// Send a fixed action. Called with the role, because that is what both
  /// stacks' senders key on.
  final Future<void> Function(String role) onSend;

  /// The role currently in flight, so its button shows the wait and the
  /// others disable — the same convention the curated cards use.
  final String? sendingRole;

  /// Whether the whole row should be inert (a SOAP write is in flight, the
  /// device is unpaired).
  final bool enabled;

  const UnclaimedActions({
    super.key,
    required this.actions,
    required this.claimed,
    required this.onSend,
    this.sendingRole,
    this.enabled = true,
  });

  /// A role's button label. `set_fan_mode` reads "Set fan mode", through the
  /// same humaniser every other spec identifier goes through, so a role and a
  /// command by the same name never appear under two spellings.
  static String labelFor(String role) => humanizeName(role);

  @override
  Widget build(BuildContext context) {
    final unclaimed = actions
        .where((a) => !claimed.contains(a.role))
        .toList(growable: false);
    if (unclaimed.isEmpty) return const SizedBox.shrink();

    final fixed = unclaimed.where((a) => !a.takesValue).toList();
    final valued = unclaimed.where((a) => a.takesValue).toList();
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (fixed.isNotEmpty)
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final action in fixed)
                OutlinedButton(
                  key: ValueKey('unclaimed-action:${action.role}'),
                  style: OutlinedButton.styleFrom(
                    minimumSize: const Size(0, 44),
                  ),
                  onPressed: enabled && sendingRole == null
                      ? () => onSend(action.role)
                      : null,
                  child: sendingRole == action.role
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : Text(labelFor(action.role)),
                ),
            ],
          ),
        if (valued.isNotEmpty)
          Padding(
            padding: EdgeInsets.only(top: fixed.isEmpty ? 0 : 10),
            child: Text(
              valued.length == 1
                  ? '${labelFor(valued.single.role)} is in this device’s spec '
                        'but has no control here yet.'
                  : '${valued.map((a) => labelFor(a.role)).join(', ')} are in '
                        'this device’s spec but have no controls here yet.',
              key: const ValueKey('unclaimed-valued-note'),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
      ],
    );
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The Radio tab: pick a radio, keep channel plans, go find channels.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/channel_plan.dart';
import '../models/radio_profile.dart';
import '../providers/channel_plan_provider.dart';
import '../providers/radio_profile_provider.dart';
import '../widgets/tx_unlock_dialog.dart';
import 'channel_plan_screen.dart';
import 'radio_source_settings_screen.dart';
import 'radio_suggestion_screen.dart';

class RadioScreen extends ConsumerWidget {
  const RadioScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileState = ref.watch(selectedRadioProfileProvider);
    final plans = ref.watch(channelPlansProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Radio'),
        actions: [
          IconButton(
            tooltip: 'Repeater sources',
            icon: const Icon(Icons.travel_explore_outlined),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const RadioSourceSettingsScreen(),
              ),
            ),
          ),
        ],
      ),
      body: profileState.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(friendlyErrorText(
              error,
              fallback: 'Could not load your radio settings.',
              context: 'radio screen',
            )),
          ),
        ),
        data: (profile) => ListView(
          children: [
            _RadioPicker(profile: profile),
            if (profile.txUnlock.supported) _TxUnlockTile(profile: profile),
            const Divider(height: 24),
            _SuggestTile(profile: profile),
            const Divider(height: 24),
            _PlansHeader(profile: profile),
            if (plans.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 24),
                child: Text(
                  'No channel plans yet. Suggest channels near you, or start '
                  'an empty plan and add channels by hand.',
                ),
              ),
            for (final plan in plans) _PlanTile(plan: plan, profile: profile),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}

class _RadioPicker extends ConsumerWidget {
  final RadioProfile profile;

  const _RadioPicker({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.radio_outlined),
      title: const Text('Radio'),
      subtitle: Text(profile.displayName),
      trailing: const Icon(Icons.arrow_drop_down),
      onTap: () => _pick(context, ref),
    );
  }

  Future<void> _pick(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(selectedRadioProfileProvider.notifier);
    final chosen = await showModalBottomSheet<RadioProfile>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final candidate in radioProfiles)
              ListTile(
                leading: Icon(candidate == profile
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked),
                title: Text(candidate.displayName),
                subtitle: Text(_capabilityLine(candidate)),
                onTap: () => Navigator.of(context).pop(candidate),
              ),
          ],
        ),
      ),
    );
    if (chosen != null) await notifier.select(chosen);
  }

  /// Says what this build can actually do with the radio, rather than letting
  /// someone find out by trying.
  static String _capabilityLine(RadioProfile profile) =>
      switch (profile.programmerSupport) {
        ProgrammerSupport.verified =>
          '${profile.channelCapacity} channels · programs over Bluetooth',
        ProgrammerSupport.unverified =>
          '${profile.channelCapacity} channels · Bluetooth programming '
              'unconfirmed on this model',
        ProgrammerSupport.none =>
          '${profile.channelCapacity} channels · export to CHIRP',
      };
}

class _TxUnlockTile extends ConsumerWidget {
  final RadioProfile profile;

  const _TxUnlockTile({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(txUnlockEnabledProvider);
    return SwitchListTile(
      secondary: const Icon(Icons.lock_open_outlined),
      title: const Text('Widen transmit range'),
      subtitle: Text(
        enabled
            ? 'On for this radio. Suggestions in the expanded range are '
                'marked, and plans built with it are flagged.'
            : 'Off. Suggestions are limited to what this radio transmits on '
                'as it left the factory.',
      ),
      value: enabled,
      onChanged: (value) => _set(context, ref, value),
    );
  }

  Future<void> _set(BuildContext context, WidgetRef ref, bool value) async {
    final notifier = ref.read(txUnlockProvider.notifier);
    if (!value) {
      await notifier.setEnabled(profile, false);
      return;
    }
    // Turning it ON always asks, every time, rather than remembering that
    // somebody once agreed: the acknowledgement is about this radio and
    // these ranges.
    final acknowledged = await showTxUnlockDialog(context, profile);
    if (acknowledged) await notifier.setEnabled(profile, true);
  }
}

class _SuggestTile extends StatelessWidget {
  final RadioProfile profile;

  const _SuggestTile({required this.profile});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.my_location_outlined),
      title: const Text('Suggest channels near me'),
      subtitle: const Text(
        'Repeaters, GMRS and the standard channels for where you are.',
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RadioSuggestionScreen(profile: profile),
        ),
      ),
    );
  }
}

class _PlansHeader extends ConsumerWidget {
  final RadioProfile profile;

  const _PlansHeader({required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        children: [
          Expanded(
            child: Text('Channel plans',
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.bold)),
          ),
          TextButton.icon(
            onPressed: () => _newPlan(context, ref),
            icon: const Icon(Icons.add),
            label: const Text('New'),
          ),
        ],
      ),
    );
  }

  Future<void> _newPlan(BuildContext context, WidgetRef ref) async {
    final notifier = ref.read(channelPlansProvider.notifier);
    final navigator = Navigator.of(context);
    final name = await _promptForName(context, initial: 'New plan');
    if (name == null) return;
    final plan = await notifier.create(
      name: name,
      radioProfileId: profile.id,
    );
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => ChannelPlanScreen(planId: plan.id),
    ));
  }
}

class _PlanTile extends ConsumerWidget {
  final ChannelPlan plan;
  final RadioProfile profile;

  const _PlanTile({required this.plan, required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final planProfile = radioProfileById(plan.radioProfileId);
    final forAnotherRadio = planProfile != null && planProfile.id != profile.id;

    return ListTile(
      leading: const Icon(Icons.list_alt_outlined),
      title: Text(plan.name),
      subtitle: Text([
        '${plan.length} '
            '${plan.length == 1 ? 'channel' : 'channels'}',
        if (forAnotherRadio) 'for ${planProfile.displayName}',
        if (plan.builtWithTxUnlock) 'widened transmit range',
      ].join(' · ')),
      trailing: PopupMenuButton<String>(
        onSelected: (action) => _act(context, ref, action),
        itemBuilder: (context) => const [
          PopupMenuItem(value: 'rename', child: Text('Rename')),
          PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ChannelPlanScreen(planId: plan.id),
        ),
      ),
    );
  }

  Future<void> _act(BuildContext context, WidgetRef ref, String action) async {
    final notifier = ref.read(channelPlansProvider.notifier);
    if (action == 'rename') {
      final name = await _promptForName(context, initial: plan.name);
      if (name != null) await notifier.rename(plan.id, name);
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${plan.name}"?'),
        content: const Text('The plan is removed from this device. Nothing '
            'on a radio changes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed == true) await notifier.remove(plan.id);
  }
}

/// Ask for a plan name. Returns null when cancelled or left blank.
Future<String?> _promptForName(
  BuildContext context, {
  required String initial,
}) async {
  final name = await showDialog<String>(
    context: context,
    builder: (context) => _NamePromptDialog(initial: initial),
  );
  return (name == null || name.isEmpty) ? null : name;
}

/// The dialog owns its controller.
///
/// Disposing one at the call site the moment `showDialog` returns looks tidy
/// and is a use-after-dispose: the route's exit animation is still running,
/// and the TextField it left behind rebuilds against a controller that has
/// already gone.
class _NamePromptDialog extends StatefulWidget {
  final String initial;

  const _NamePromptDialog({required this.initial});

  @override
  State<_NamePromptDialog> createState() => _NamePromptDialogState();
}

class _NamePromptDialogState extends State<_NamePromptDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initial);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Plan name'),
        content: TextField(
          controller: _controller,
          autofocus: true,
          decoration: const InputDecoration(border: OutlineInputBorder()),
          onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      );
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// One radio: which one, and everything the app can do with it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/channel_plan.dart';
import '../models/radio_band_limits.dart';
import '../models/radio_profile.dart';
import '../models/radio_target.dart';
import '../providers/channel_plan_provider.dart';
import '../providers/radio_profile_provider.dart';
import '../providers/radio_programmer_provider.dart';
import '../providers/saved_radio_provider.dart';
import '../services/codeplug_backup_store.dart';
import '../services/radio_programmer.dart';
import '../widgets/tx_unlock_dialog.dart';
import 'channel_plan_screen.dart';
import 'radio_program_screen.dart';

/// A radio, opened from the Nearby list, Saved devices or the USB tab.
///
/// The Radio tab is where plans are made; this is where a particular radio
/// is dealt with: checking it answers, putting a plan on it, reading what is
/// on it, putting a backup back — and, for a radio that stores its own
/// transmit limits, widening them and putting them back.
class RadioDeviceScreen extends ConsumerStatefulWidget {
  final RadioTarget target;

  /// The model to open on — a saved record's, or what the advertised name
  /// suggests. Used only if it programs over [target]'s transport.
  final RadioProfile? initialProfile;

  const RadioDeviceScreen({
    super.key,
    required this.target,
    this.initialProfile,
  });

  @override
  ConsumerState<RadioDeviceScreen> createState() => _RadioDeviceScreenState();
}

class _RadioDeviceScreenState extends ConsumerState<RadioDeviceScreen> {
  RadioProfile? _profile;

  /// Set while a session is running; nothing else may start one.
  RadioProgressEvent? _progress;
  String? _error;
  String? _outcome;

  /// A plan the last read produced, offered as a shortcut.
  String? _readPlanId;

  bool get _busy => _progress != null;

  RadioTarget get _target => widget.target;

  @override
  void initState() {
    super.initState();
    _profile = _pickInitialProfile();
  }

  /// The first of: what the caller suggested, what this radio was last used
  /// as, and the Radio tab's radio — that can actually be programmed over
  /// this link. Falls back to the first model that can.
  RadioProfile? _pickInitialProfile() {
    final candidates = profilesProgrammableOver(_target.transport);
    final saved = ref.read(savedRadiosProvider.notifier).savedRadioFor(_target);
    final preferences = [
      widget.initialProfile,
      radioProfileById(saved?.radioProfileId),
      ref.read(selectedRadioProfileProvider).valueOrNull,
    ];
    for (final profile in preferences) {
      if (profile != null && candidates.contains(profile)) return profile;
    }
    return candidates.firstOrNull;
  }

  @override
  Widget build(BuildContext context) {
    final saved = ref
        .watch(savedRadiosProvider)
        .any((r) => r.transport == _target.transport && r.id == _target.id);
    final profile = _profile;

    // Leaving mid-session would not stop it — the session finishes behind
    // the popped route — but it would hide a write that is still going, and
    // the one thing worse than a radio cut off mid-write is one somebody
    // unplugs because the screen said nothing was happening.
    return PopScope(
      canPop: !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Wait for the radio to finish — leaving now would '
              'hide a session that is still running.',
            ),
          ),
        );
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(_target.displayName),
          actions: [
            if (saved)
              IconButton(
                tooltip: 'Forget this radio',
                icon: const Icon(Icons.delete_outline),
                onPressed: _busy ? null : _forget,
              ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            _Header(target: _target, saved: saved),
            if (_error case final String error)
              ListTile(
                leading: Icon(
                  Icons.error_outline,
                  color: Theme.of(context).colorScheme.error,
                ),
                title: Text(error),
              ),
            if (_outcome case final String outcome)
              ListTile(
                leading: const Icon(Icons.check_circle_outline),
                title: Text(outcome),
                trailing: _readPlanId == null
                    ? null
                    : TextButton(
                        onPressed: _openReadPlan,
                        child: const Text('Open plan'),
                      ),
              ),
            if (_progress case final RadioProgressEvent event)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(event.message),
                    const SizedBox(height: 8),
                    LinearProgressIndicator(value: event.progress),
                  ],
                ),
              ),
            const Divider(height: 24),
            if (profile == null)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'This build cannot program a radio '
                  '${_target.transport.overPhrase} yet. Channel '
                  'plans can still be exported for CHIRP from the Radio tab.',
                ),
              )
            else
              ..._actions(profile),
          ],
        ),
      ),
    );
  }

  List<Widget> _actions(RadioProfile profile) {
    final tabProfile = ref.watch(selectedRadioProfileProvider).valueOrNull;
    return [
      ListTile(
        leading: const Icon(Icons.radio_outlined),
        title: const Text('Radio model'),
        subtitle: Text(profile.displayName),
        trailing: const Icon(Icons.arrow_drop_down),
        enabled: !_busy,
        onTap: _pickModel,
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: Text(
          _target.transport == RadioTransport.usb
              ? 'Pick the model printed on the radio. Checking it answers '
                    'shows the firmware it reports.'
              : 'Pick the model printed on the radio. It cannot be asked: '
                    'these radios answer to one programming request between '
                    'them.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
      if (tabProfile != null && tabProfile != profile)
        ListTile(
          leading: const Icon(Icons.push_pin_outlined),
          title: const Text('Use for suggestions and new plans'),
          subtitle: Text('The Radio tab is set to ${tabProfile.displayName}.'),
          enabled: !_busy,
          onTap: () =>
              ref.read(selectedRadioProfileProvider.notifier).select(profile),
        ),
      if (profile.programmerSupport == ProgrammerSupport.unverified)
        const ListTile(
          leading: Icon(Icons.info_outline),
          title: Text('Not yet confirmed on this model'),
          subtitle: Text(
            'Programming this model has not been checked on a '
            'real radio. Every write keeps a backup first — that is the '
            'thing to rely on.',
          ),
        ),
      const Divider(height: 24),
      ListTile(
        leading: const Icon(Icons.wifi_tethering_outlined),
        title: const Text('Check it answers'),
        subtitle: const Text(
          'Connects and asks the radio to start a '
          'programming session. Nothing on it changes.',
        ),
        enabled: !_busy,
        onTap: () => _identify(profile),
      ),
      ListTile(
        leading: const Icon(Icons.upload_outlined),
        title: const Text('Write a channel plan'),
        subtitle: const Text(
          'Backs the radio up first, then replaces its '
          'memory channels with a plan.',
        ),
        enabled: !_busy,
        onTap: () => _writePlan(profile),
      ),
      ListTile(
        leading: const Icon(Icons.download_outlined),
        title: const Text('Read its channels into a new plan'),
        subtitle: const Text(
          'Nothing on the radio changes. The copy it '
          'reads is kept as a backup too.',
        ),
        enabled: !_busy,
        onTap: () => _readIntoPlan(profile),
      ),
      ListTile(
        leading: const Icon(Icons.restore_outlined),
        title: const Text('Restore a backup'),
        subtitle: Text(
          'Puts back a copy saved from a '
          '${profile.displayName}.',
        ),
        enabled: !_busy,
        onTap: () => _restore(profile),
      ),
      ..._transmitLimits(profile),
    ];
  }

  /// What can be done with the transmit limits [profile] stores, where it
  /// stores any and this link can set them.
  List<Widget> _transmitLimits(RadioProfile profile) {
    // The profile first: a radio with no limits to set never needs its
    // programmer built just to be asked.
    final widened = RadioBandLimits.widenedFor(profile);
    if (widened == null) return const [];
    final programmer = ref.watch(
      radioProgrammerForTransportProvider(_target.transport),
    );
    if (programmer is! BandLimitProgrammer || !programmer.supports(profile)) {
      return const [];
    }
    final original = ref
        .watch(originalBandLimitsProvider)
        .valueOrNull?[profile.id];
    return [
      const Divider(height: 24),
      ListTile(
        leading: const Icon(Icons.lock_open_outlined),
        title: const Text('Widen its transmit limits'),
        subtitle: Text(
          [
            'To ${widened.label}. Backs the radio up first.',
            if (!profile.txUnlock.verified)
              'Not yet confirmed on a real radio: the backup is what to rely '
                  'on.',
          ].join(' '),
        ),
        enabled: !_busy,
        onTap: () => _widen(profile, widened),
      ),
      if (original != null)
        ListTile(
          leading: const Icon(Icons.lock_outline),
          title: const Text('Put back its original transmit limits'),
          subtitle: Text(
            '${original.limits.label}: what a '
            '${profile.displayName} held before this app first widened '
            'one, read ${_when(original.readAt)}.',
          ),
          enabled: !_busy,
          onTap: () => _putBack(profile, original),
        ),
    ];
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _pickModel() async {
    final savedRadios = ref.read(savedRadiosProvider.notifier);
    final candidates = profilesProgrammableOver(_target.transport);
    final chosen = await showModalBottomSheet<RadioProfile>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final candidate in candidates)
              ListTile(
                leading: Icon(
                  candidate == _profile
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                ),
                title: Text(candidate.displayName),
                onTap: () => Navigator.of(context).pop(candidate),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _profile = chosen);
    // Remembered only for a radio already saved. Choosing a model is not
    // talking to the radio, and saving is for radios that have answered.
    if (savedRadios.contains(_target)) {
      await savedRadios.touch(
        target: _target,
        seenAt: savedRadios.savedRadioFor(_target)!.lastSeen,
        radioProfileId: chosen.id,
      );
    }
  }

  Future<void> _identify(RadioProfile profile) => _session(
    profile,
    start: 'Asking the radio to answer…',
    body: (programmer) async {
      final identity = await programmer.identify(
        deviceId: _target.id,
        profile: profile,
      );
      return identity.summary;
    },
  );

  Future<void> _writePlan(RadioProfile profile) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final plans = ref.read(channelPlansProvider);
    if (plans.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'No channel plans yet. Make one on the Radio tab, or '
            'read this radio\'s channels into one.',
          ),
        ),
      );
      return;
    }
    final plan = await showModalBottomSheet<ChannelPlan>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final plan in plans)
              ListTile(
                leading: const Icon(Icons.list_alt_outlined),
                title: Text(plan.name),
                subtitle: Text(
                  [
                    '${plan.length} '
                        '${plan.length == 1 ? 'channel' : 'channels'}',
                    if (plan.radioProfileId != profile.id)
                      'made for '
                          '${radioProfileById(plan.radioProfileId)?.displayName ?? 'another radio'}',
                  ].join(' · '),
                ),
                onTap: () => Navigator.of(context).pop(plan),
              ),
          ],
        ),
      ),
    );
    if (plan == null) return;
    await navigator.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            RadioProgramScreen(plan: plan, profile: profile, target: _target),
      ),
    );
  }

  Future<void> _readIntoPlan(RadioProfile profile) {
    final backups = ref.read(codeplugBackupStoreProvider);
    final plans = ref.read(channelPlansProvider.notifier);
    final decoder = ref.read(codeplugDecoderProvider);
    return _session(
      profile,
      start: 'Reading the radio…',
      body: (programmer) async {
        final codeplug = await _read(programmer, profile);
        await backups.save(codeplug);
        final decoded = await decoder.decode(codeplug, profile);
        final plan = await plans.create(
          name: 'From ${_target.displayName}',
          radioProfileId: profile.id,
        );
        await plans.replaceChannels(
          plan.id,
          decoded.channels,
          profile: profile,
        );
        _readPlanId = plan.id;
        final n = decoded.channels.length;
        return [
          '$n ${n == 1 ? 'channel' : 'channels'} read into "${plan.name}".',
          if (decoded.hadGaps)
            'The radio had empty slots between channels. A plan numbers '
                'its channels from 1, so those gaps were closed up — writing '
                'this plan back would move the channels after them.',
        ].join(' ');
      },
    );
  }

  Future<void> _restore(RadioProfile profile) async {
    final backups = ref.read(codeplugBackupStoreProvider);
    final messenger = ScaffoldMessenger.of(context);
    final List<CodeplugBackup> mine;
    try {
      mine = [
        for (final backup in await backups.list())
          if (backup.modelId == profile.id) backup,
      ];
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            friendlyErrorText(
              error,
              fallback: 'Could not read the saved backups.',
              context: 'radio backup list',
            ),
          ),
        ),
      );
      return;
    }
    if (!mounted) return;
    if (mine.isEmpty) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            'No backups of a ${profile.displayName} on this device '
            'yet. One is saved every time the app reads or writes a radio.',
          ),
        ),
      );
      return;
    }
    final chosen = await showModalBottomSheet<CodeplugBackup>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final backup in mine)
              ListTile(
                leading: const Icon(Icons.history),
                title: Text(_when(backup.takenAt)),
                subtitle: Text(backup.displayName),
                onTap: () => Navigator.of(context).pop(backup),
              ),
          ],
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    if (!await _confirmRestore(chosen)) return;

    await _session(
      profile,
      start: 'Starting…',
      body: (programmer) async {
        // The chosen copy is loaded before anything is saved: saving prunes
        // each model's backups to the newest few, and the one being restored
        // may be the oldest.
        final codeplug = await backups.load(chosen);
        // Then the radio is read and saved before it is overwritten, exactly
        // as before a plan is written: whatever is on it now may be newer
        // than the backup, and a restore is a write like any other.
        final current = await _read(programmer, profile);
        await backups.save(current);
        await programmer
            .restoreCodeplug(
              deviceId: _target.id,
              profile: profile,
              codeplug: codeplug,
            )
            .forEach(_onProgress);
        return 'Backup from ${_when(chosen.takenAt)} restored. What was on '
            'the radio before was saved as a backup first.';
      },
    );
  }

  Future<void> _widen(RadioProfile profile, RadioBandLimits widened) async {
    // Asked every time, as the Radio tab's switch asks: the acknowledgement
    // is about this radio and these ranges, not something agreed to once.
    if (!await showTxUnlockDialog(context, profile) || !mounted) return;
    final backups = ref.read(codeplugBackupStoreProvider);
    final originals = ref.read(originalBandLimitsProvider.notifier);
    final unlock = ref.read(txUnlockProvider.notifier);
    await _session(
      profile,
      start: 'Reading the radio…',
      body: (programmer) async {
        final limits = programmer as BandLimitProgrammer;
        final base = await _read(programmer, profile);
        await backups.save(base);
        final before = await limits.bandLimitsIn(base, profile);
        if (before == widened) {
          await unlock.setEnabled(profile, true);
          return 'Its transmit limits are already ${widened.label}. '
              'Nothing was written.';
        }
        // Kept before the write, so one that fails part way still leaves
        // the way back.
        await originals.recordIfAbsent(
          profile,
          OriginalBandLimits(limits: before, readAt: base.readAt),
        );
        await limits
            .writeBandLimits(
              deviceId: _target.id,
              profile: profile,
              base: base,
              limits: widened,
            )
            .forEach(_onProgress);
        // It transmits there now, so suggestions for it may say so.
        await unlock.setEnabled(profile, true);
        return 'Widened to ${widened.label}, and read back. It had '
            '${before.label}. Suggestions for a ${profile.displayName} now '
            'include the wider range.';
      },
    );
  }

  Future<void> _putBack(
    RadioProfile profile,
    OriginalBandLimits original,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Put back its transmit limits?'),
        content: Text(
          '${_target.displayName} will be set to ${original.limits.label}: '
          'what a ${profile.displayName} held before this app first widened '
          'one.\n\nThe radio is read and backed up first.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Put back'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final backups = ref.read(codeplugBackupStoreProvider);
    final unlock = ref.read(txUnlockProvider.notifier);
    await _session(
      profile,
      start: 'Reading the radio…',
      body: (programmer) async {
        final limits = programmer as BandLimitProgrammer;
        final base = await _read(programmer, profile);
        await backups.save(base);
        final before = await limits.bandLimitsIn(base, profile);
        if (before != original.limits) {
          await limits
              .writeBandLimits(
                deviceId: _target.id,
                profile: profile,
                base: base,
                limits: original.limits,
              )
              .forEach(_onProgress);
        }
        await unlock.setEnabled(profile, false);
        return before == original.limits
            ? 'Its transmit limits are already ${original.limits.label}. '
                  'Nothing was written.'
            : 'Put back to ${original.limits.label}, and read back. '
                  'Suggestions for a ${profile.displayName} keep to its '
                  'factory range again.';
      },
    );
  }

  Future<void> _forget() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    await ref.read(savedRadiosProvider.notifier).remove(_target);
    messenger.showSnackBar(
      SnackBar(content: Text('Removed ${_target.displayName}')),
    );
    navigator.pop();
  }

  void _openReadPlan() {
    final id = _readPlanId;
    if (id == null) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => ChannelPlanScreen(planId: id)),
    );
  }

  // -------------------------------------------------------------------------
  // Session plumbing
  // -------------------------------------------------------------------------

  /// Run one session against the radio, owning the busy state, the error
  /// text and the save-on-answer.
  ///
  /// [body] returns the line to show when it succeeds. Any session that
  /// completes counts as the radio having answered, which is what saves it:
  /// the same save-on-connect rule the other device lists use.
  Future<void> _session(
    RadioProfile profile, {
    required String start,
    required Future<String> Function(RadioProgrammer programmer) body,
  }) async {
    final programmer = ref.read(
      radioProgrammerForTransportProvider(_target.transport),
    );
    final savedRadios = ref.read(savedRadiosProvider.notifier);
    final messenger = ScaffoldMessenger.of(context);

    if (!programmer.supports(profile)) {
      setState(() => _error = const RadioUnsupportedException().message);
      return;
    }
    setState(() {
      _error = null;
      _outcome = null;
      _readPlanId = null;
      _progress = RadioProgressEvent(
        stage: RadioProgressStage.connecting,
        message: start,
      );
    });
    try {
      final outcome = await body(programmer);
      await savedRadios.touch(
        target: _target,
        seenAt: DateTime.now(),
        radioProfileId: profile.id,
      );
      if (!mounted) return;
      setState(() {
        _progress = null;
        _outcome = outcome;
      });
    } catch (error) {
      if (!mounted) return;
      final text = friendlyErrorText(
        error,
        fallback: 'The radio did not finish.',
        context: 'radio session',
      );
      setState(() {
        _progress = null;
        _readPlanId = null;
        _error = text;
      });
      messenger.showSnackBar(SnackBar(content: Text(text)));
    }
  }

  /// A full read, reporting progress, returning the image.
  Future<RadioCodeplug> _read(
    RadioProgrammer programmer,
    RadioProfile profile,
  ) async {
    RadioCodeplug? result;
    await programmer
        .readCodeplug(
          deviceId: _target.id,
          profile: profile,
          onResult: (codeplug) => result = codeplug,
        )
        .forEach(_onProgress);
    final codeplug = result;
    if (codeplug == null) throw const RadioProtocolException();
    return codeplug;
  }

  void _onProgress(RadioProgressEvent event) {
    if (mounted) setState(() => _progress = event);
  }

  Future<bool> _confirmRestore(CodeplugBackup backup) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Restore to ${_target.displayName}?'),
        content: Text(
          'Everything on the radio is replaced with the copy saved '
          '${_when(backup.takenAt)}: channels, settings, all of it.\n\n'
          'What is on the radio now is read and saved first, so this can be '
          'undone the same way.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    return confirmed ?? false;
  }

  static String _when(DateTime at) {
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} '
        '${two(local.hour)}:${two(local.minute)}';
  }
}

class _Header extends StatelessWidget {
  final RadioTarget target;
  final bool saved;

  const _Header({required this.target, required this.saved});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListTile(
      contentPadding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      leading: const Icon(Icons.settings_input_antenna, size: 32),
      title: Text(target.displayName, style: text.titleMedium),
      subtitle: Text(
        [
          target.transport.label,
          if (target.id != target.displayName) target.id,
          if (saved) 'saved',
        ].join(' · '),
      ),
    );
  }
}

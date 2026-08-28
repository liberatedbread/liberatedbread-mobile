// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// A plan, slot by slot: reorder, edit, delete, export.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../core/error_text.dart';
import '../core/frequency.dart';
import '../models/channel_plan.dart';
import '../models/radio_channel.dart';
import '../models/radio_profile.dart';
import '../providers/channel_plan_provider.dart';
import '../providers/radio_profile_provider.dart';
import '../services/plan_export_service.dart';

/// Provides the exporter. Overridden in tests with a temp directory.
final planExportServiceProvider = Provider<PlanExportService>((ref) {
  throw UnimplementedError(
    'planExportServiceProvider must be overridden — see main().',
  );
});

/// Shares an exported file. Injected so widget tests never reach the
/// share_plus platform channel, the same way [urlOpenerProvider] is.
final fileShareProvider =
    Provider<Future<void> Function(ExportedFile)>((ref) => (exported) async {
          await SharePlus.instance.share(
            ShareParams(
              files: [XFile(exported.file.path)],
              fileNameOverrides: [exported.displayName],
            ),
          );
        });

class ChannelPlanScreen extends ConsumerStatefulWidget {
  final String planId;

  const ChannelPlanScreen({super.key, required this.planId});

  @override
  ConsumerState<ChannelPlanScreen> createState() => _ChannelPlanScreenState();
}

class _ChannelPlanScreenState extends ConsumerState<ChannelPlanScreen> {
  /// Slots ticked in multi-select mode. Empty means the mode is off.
  final Set<int> _selected = {};
  bool _selecting = false;

  @override
  Widget build(BuildContext context) {
    final plans = ref.watch(channelPlansProvider);
    final plan = plans.where((p) => p.id == widget.planId).firstOrNull;
    if (plan == null) {
      // Deleted from under us — nothing to show and nothing to say.
      return Scaffold(
        appBar: AppBar(title: const Text('Plan')),
        body: const Center(child: Text('This plan no longer exists.')),
      );
    }

    final profile = radioProfileById(plan.radioProfileId) ??
        ref.watch(selectedRadioProfileProvider).value ??
        defaultRadioProfile;

    return Scaffold(
      appBar: AppBar(
        title: Text(_selecting ? '${_selected.length} selected' : plan.name),
        leading: _selecting
            ? IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => setState(() {
                  _selecting = false;
                  _selected.clear();
                }),
              )
            : null,
        actions: [
          if (_selecting)
            IconButton(
              tooltip: 'Delete selected',
              icon: const Icon(Icons.delete_outline),
              onPressed: _selected.isEmpty ? null : () => _deleteSelected(plan),
            )
          else ...[
            IconButton(
              tooltip: 'Select channels',
              icon: const Icon(Icons.checklist),
              onPressed:
                  plan.isEmpty ? null : () => setState(() => _selecting = true),
            ),
            IconButton(
              tooltip: 'Export as CHIRP CSV',
              icon: const Icon(Icons.ios_share),
              onPressed: plan.isEmpty ? null : () => _export(plan),
            ),
          ],
        ],
      ),
      body: Column(
        children: [
          if (plan.builtWithTxUnlock) const _UnlockBanner(),
          _CapacityBar(plan: plan, profile: profile),
          Expanded(
            child: plan.isEmpty
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(24),
                      child: Text(
                        'No channels yet. Use "Suggest channels near me" on '
                        'the Radio tab to fill this in.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ReorderableListView.builder(
                    itemCount: plan.channels.length,
                    onReorderItem: (from, to) => ref
                        .read(channelPlansProvider.notifier)
                        .reorder(plan.id, from, to),
                    itemBuilder: (context, index) => _channelTile(
                      plan,
                      profile,
                      index,
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _channelTile(ChannelPlan plan, RadioProfile profile, int index) {
    final channel = plan.channels[index];
    return ListTile(
      key: ValueKey('slot-$index-${channel.name}-${channel.rxFreqHz}'),
      leading: _selecting
          ? Checkbox(
              value: _selected.contains(index),
              onChanged: (value) => setState(() {
                if (value ?? false) {
                  _selected.add(index);
                } else {
                  _selected.remove(index);
                }
              }),
            )
          : CircleAvatar(
              radius: 14,
              child: Text('${index + 1}', style: const TextStyle(fontSize: 12)),
            ),
      title: Text(channel.name.isEmpty ? '(unnamed)' : channel.name),
      subtitle: Text(_summary(channel)),
      trailing: _selecting
          ? null
          : ReorderableDragStartListener(
              index: index,
              child: const Icon(Icons.drag_handle),
            ),
      onTap: _selecting
          ? () => setState(() {
                if (!_selected.remove(index)) _selected.add(index);
              })
          : () => _edit(plan, profile, index),
    );
  }

  static String _summary(RadioChannel channel) {
    final parts = <String>[
      '${formatHzAsMegahertz(channel.rxFreqHz)} MHz',
      if (channel.rxOnly)
        'receive only'
      else if (!channel.isSimplex)
        '${channel.offsetHz > 0 ? '+' : '−'}'
            '${formatHzAsMegahertz(channel.offsetHz.abs())}'
      else
        'simplex',
      if (!channel.txTone.isNone) 'tone ${channel.txTone.label}',
      channel.mode.chirpName,
      if (channel.power == PowerLevel.low) 'low power',
    ];
    return parts.join(' · ');
  }

  Future<void> _deleteSelected(ChannelPlan plan) async {
    final indices = {..._selected};
    await ref.read(channelPlansProvider.notifier).removeMany(plan.id, indices);
    if (!mounted) return;
    setState(() {
      _selected.clear();
      _selecting = false;
    });
  }

  Future<void> _edit(ChannelPlan plan, RadioProfile profile, int index) async {
    final edited = await showModalBottomSheet<RadioChannel>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _ChannelEditSheet(
        channel: plan.channels[index],
        profile: profile,
      ),
    );
    if (edited == null || !mounted) return;
    await ref
        .read(channelPlansProvider.notifier)
        .updateChannel(plan.id, index, edited, profile: profile);
  }

  Future<void> _export(ChannelPlan plan) async {
    final messenger = ScaffoldMessenger.of(context);
    final exporter = ref.read(planExportServiceProvider);
    final share = ref.read(fileShareProvider);

    try {
      final exported = await exporter.exportChirpCsv(plan);
      // Android and iOS have a share sheet; the desktop does not, so there
      // the path plus a copy action is the whole affordance.
      if (Platform.isAndroid || Platform.isIOS) {
        await share(exported);
        return;
      }
      await Clipboard.setData(ClipboardData(text: exported.file.path));
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text('Saved to ${exported.file.path} (path copied)'),
      ));
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(SnackBar(
        content: Text(friendlyErrorText(
          error,
          fallback: 'Could not export this plan.',
          context: 'chirp csv export',
        )),
      ));
    }
  }
}

class _UnlockBanner extends StatelessWidget {
  const _UnlockBanner();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      color: scheme.tertiaryContainer,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.lock_open_outlined,
              size: 20, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Built with the transmit range widened. Some channels here need '
              'that setting on, and your own licence to use.',
              style: TextStyle(color: scheme.onTertiaryContainer),
            ),
          ),
        ],
      ),
    );
  }
}

class _CapacityBar extends StatelessWidget {
  final ChannelPlan plan;
  final RadioProfile profile;

  const _CapacityBar({required this.plan, required this.profile});

  @override
  Widget build(BuildContext context) {
    final fraction =
        (plan.length / profile.channelCapacity).clamp(0.0, 1.0).toDouble();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${plan.length} of ${profile.channelCapacity} channels · '
              '${profile.displayName}'),
          const SizedBox(height: 6),
          LinearProgressIndicator(value: fraction),
        ],
      ),
    );
  }
}

/// Edit one channel. Frequencies are typed in MHz and parsed exactly.
class _ChannelEditSheet extends StatefulWidget {
  final RadioChannel channel;
  final RadioProfile profile;

  const _ChannelEditSheet({required this.channel, required this.profile});

  @override
  State<_ChannelEditSheet> createState() => _ChannelEditSheetState();
}

class _ChannelEditSheetState extends State<_ChannelEditSheet> {
  late final TextEditingController _name;
  late final TextEditingController _rx;
  late final TextEditingController _tx;
  late ChannelMode _mode;
  late PowerLevel _power;
  late bool _rxOnly;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.channel.name);
    _rx = TextEditingController(
        text: formatHzAsMegahertz(widget.channel.rxFreqHz));
    _tx = TextEditingController(
        text: formatHzAsMegahertz(widget.channel.txFreqHz));
    _mode = widget.channel.mode;
    _power = widget.channel.power;
    _rxOnly = widget.channel.rxOnly;
  }

  @override
  void dispose() {
    _name.dispose();
    _rx.dispose();
    _tx.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: _name,
                maxLength: widget.profile.nameLength,
                decoration: InputDecoration(
                  labelText: 'Name',
                  border: const OutlineInputBorder(),
                  helperText: '${widget.profile.displayName} shows '
                      '${widget.profile.nameLength} characters',
                ),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _rx,
                decoration: const InputDecoration(
                  labelText: 'Receive (MHz)',
                  border: OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _tx,
                enabled: !_rxOnly,
                decoration: const InputDecoration(
                  labelText: 'Transmit (MHz)',
                  border: OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Receive only'),
                value: _rxOnly,
                onChanged: (value) => setState(() => _rxOnly = value),
              ),
              Row(
                children: [
                  const Text('Mode'),
                  const SizedBox(width: 12),
                  SegmentedButton<ChannelMode>(
                    segments: const [
                      ButtonSegment(value: ChannelMode.fm, label: Text('FM')),
                      ButtonSegment(value: ChannelMode.nfm, label: Text('NFM')),
                    ],
                    selected: {_mode},
                    onSelectionChanged: (values) =>
                        setState(() => _mode = values.first),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  const Text('Power'),
                  const SizedBox(width: 12),
                  SegmentedButton<PowerLevel>(
                    segments: const [
                      ButtonSegment(
                          value: PowerLevel.high, label: Text('High')),
                      ButtonSegment(value: PowerLevel.low, label: Text('Low')),
                    ],
                    selected: {_power},
                    onSelectionChanged: (values) =>
                        setState(() => _power = values.first),
                  ),
                ],
              ),
              if (!widget.channel.txTone.isNone ||
                  !widget.channel.rxTone.isNone)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    'Tones: transmit '
                    '${widget.channel.txTone.isNone ? 'none' : widget.channel.txTone.label}'
                    ', receive '
                    '${widget.channel.rxTone.isNone ? 'none' : widget.channel.rxTone.label}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (_error case final String error)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(error,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(onPressed: _save, child: const Text('Save')),
                ],
              ),
            ],
          ),
        ),
      );

  void _save() {
    final rx = parseMegahertzToHz(_rx.text);
    if (rx == null || rx <= 0) {
      setState(() => _error = 'Receive frequency should look like 146.940.');
      return;
    }
    final tx = _rxOnly ? rx : parseMegahertzToHz(_tx.text);
    if (tx == null || tx <= 0) {
      setState(() => _error = 'Transmit frequency should look like 146.340.');
      return;
    }
    Navigator.of(context).pop(widget.channel.copyWith(
      name: _name.text,
      rxFreqHz: rx,
      txFreqHz: tx,
      rxOnly: _rxOnly,
      mode: _mode,
      power: _power,
      // A receive-only channel carries no transmit tone: there is nothing to
      // send it on.
      txTone: _rxOnly ? ToneSetting.none : widget.channel.txTone,
    ));
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_category.dart';
import '../core/group_actions.dart';
import '../core/stop_signal.dart';
import '../providers/device_group_provider.dart';
import '../services/device_group_store.dart';
import '../services/group_runner.dart';
import '../services/saved_device_store.dart';
import '../widgets/device_list_tile.dart';
import 'group_edit_screen.dart';
import 'groups_screen.dart' show GroupTile;

/// One group, its members, and the operations that act on all of them.
///
/// Opened in one of two modes: an automatic by-kind group ([category] set) or
/// a user group ([groupId] set). Both watch their source, so a device gaining
/// a category or a group being edited updates this screen in place.
class GroupDetailScreen extends ConsumerStatefulWidget {
  final DeviceCategory? category;
  final String? groupId;

  const GroupDetailScreen({super.key, this.category, this.groupId})
      : assert((category == null) != (groupId == null),
            'exactly one of category/groupId identifies the group');

  @override
  ConsumerState<GroupDetailScreen> createState() => _GroupDetailScreenState();
}

class _GroupDetailScreenState extends ConsumerState<GroupDetailScreen> {
  /// Latest runner event per member, cleared when a new run starts. Rows
  /// without an entry show their pre-run summary instead.
  final Map<String, GroupRunEvent> _latest = {};
  StreamSubscription<GroupRunEvent>? _runSub;
  StopSignal _stop = StopSignal();
  bool _running = false;

  @override
  void dispose() {
    // Leaving the screen cancels the run: the stop flag skips members not yet
    // started, and cancelling the subscription makes the runner's finally
    // disconnect whichever device was mid-flight.
    _stop.stop();
    unawaited(_runSub?.cancel());
    super.dispose();
  }

  Future<void> _run(
    List<GroupMember> members,
    GroupOp op, {
    double? brightnessPercent,
  }) async {
    // Rows derive "queued" from `_running` plus the absence of an event —
    // not from pre-seeded entries — so a member list that changes mid-run
    // still renders honestly instead of carrying stale placeholders.
    setState(() {
      _running = true;
      _latest.clear();
    });
    _stop = StopSignal();
    _runSub = ref
        .read(groupRunnerProvider)
        .run(op, members, brightnessPercent: brightnessPercent, stop: _stop)
        .listen(
          (event) => setState(() => _latest[event.deviceId] = event),
          onDone: () => setState(() => _running = false),
          // The runner reports per-device failures as events; a stream error
          // would be a bug, but it must still release the buttons.
          onError: (Object _) => setState(() => _running = false),
        );
  }

  Future<void> _pickBrightness(List<GroupMember> members) async {
    var percent = 100.0;
    final apply = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set brightness'),
        content: StatefulBuilder(
          builder: (context, setDialogState) => Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Slider(
                value: percent,
                min: 0,
                max: 100,
                divisions: 20,
                label: '${percent.round()}%',
                onChanged: (value) => setDialogState(() => percent = value),
              ),
              Text('${percent.round()}% — re-scaled to each device\'s own '
                  'brightness range'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Apply'),
          ),
        ],
      ),
    );
    if (apply == true && mounted) {
      await _run(members, GroupOp.setBrightness, brightnessPercent: percent);
    }
  }

  @override
  Widget build(BuildContext context) {
    final resolved = _resolveGroup();
    if (resolved == null) {
      // The group was deleted under us (edit screen's delete pops back here).
      return const Scaffold(body: SizedBox.shrink());
    }
    final scheme = Theme.of(context).colorScheme;
    final membersAsync = ref
        .watch(groupMembersProvider(GroupMembersRequest(resolved.deviceIds)));
    final members = membersAsync.valueOrNull ?? const <GroupMember>[];

    final group = resolved.group;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(resolved.title),
        actions: [
          if (group != null)
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: 'Edit group',
              onPressed: _running
                  ? null
                  : () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => GroupEditScreen(group: group),
                        ),
                      ),
            ),
        ],
      ),
      body: SafeArea(
        // While the auto-group buckets (or the member resolution) are still
        // in flight, an empty list means "still looking", never "your
        // devices may have been forgotten".
        child: members.isEmpty
            ? _EmptyMembers(waiting: membersAsync.isLoading || resolved.pending)
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: [
                  _OpButtons(
                    members: members,
                    running: _running,
                    onRun: (op) => _run(members, op),
                    onBrightness: () => _pickBrightness(members),
                    onCancel: () => _stop.stop(),
                  ),
                  const SizedBox(height: 20),
                  SectionHeader(label: 'Devices', count: members.length),
                  const SizedBox(height: 12),
                  for (final member in members) ...[
                    _MemberRow(
                      member: member,
                      event: _latest[member.id],
                      queued: _running && !_latest.containsKey(member.id),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
      ),
    );
  }

  /// What this screen is showing: title and member ids, plus the underlying
  /// [DeviceGroup] when in user-group mode (the edit button's target, looked
  /// up once here rather than a second time in its onPressed), and whether
  /// the source is still resolving. Null only when a user group was deleted
  /// under us.
  ({
    String title,
    List<String> deviceIds,
    DeviceGroup? group,
    bool pending,
  })? _resolveGroup() {
    final category = widget.category;
    if (category != null) {
      final auto = ref.watch(autoGroupsProvider);
      final bucket = auto.valueOrNull?.groups
          .where((g) => g.category == category)
          .firstOrNull;
      return (
        title: category.pluralLabel,
        deviceIds: [
          for (final d in bucket?.devices ?? const <SavedDevice>[]) d.id
        ],
        group: null,
        // An errored guess pass also reads as pending: a spinner over a
        // false "members may have been forgotten" — the next rebuild retries.
        pending: !auto.hasValue,
      );
    }
    final group = ref
        .watch(deviceGroupsProvider)
        .where((g) => g.id == widget.groupId)
        .firstOrNull;
    if (group == null) return null;
    return (
      title: group.name,
      deviceIds: group.deviceIds,
      group: group,
      pending: false,
    );
  }
}

/// The operation buttons, enabled by what the members' specs can actually do.
class _OpButtons extends StatelessWidget {
  final List<GroupMember> members;
  final bool running;
  final void Function(GroupOp op) onRun;
  final VoidCallback onBrightness;
  final VoidCallback onCancel;

  const _OpButtons({
    required this.members,
    required this.running,
    required this.onRun,
    required this.onBrightness,
    required this.onCancel,
  });

  int _supportCount(GroupOp op) =>
      members.where((m) => m.specOps.contains(op)).length;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final anySpecUnknown = members.any((m) => m.spec == null);

    Widget opButton(GroupOp op, {VoidCallback? custom}) {
      // An op that works spec-less (battery, via the SIG service) is always
      // worth attempting. The rest need at least one member whose spec
      // resolves the verb — or a member with no spec yet, whose row already
      // promises "will match on connect": the runner resolves it there and
      // reports an honest per-device skip if the match never comes.
      final supported = _supportCount(op);
      final enabled = op.worksWithoutSpec || supported > 0 || anySpecUnknown;
      final count = op.worksWithoutSpec
          ? null
          : supported == members.length
              ? null
              : '$supported of ${members.length}';
      return Tooltip(
        message: switch ((enabled, count)) {
          (false, _) => 'No device in this group supports this',
          (true, null) => '',
          (true, final c) => 'Supported by $c devices',
        },
        child: FilledButton.tonalIcon(
          onPressed: !enabled || running ? null : custom ?? () => onRun(op),
          style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
          icon: Icon(op.icon, size: 20),
          label: Text(count == null ? op.label : '${op.label} · $count'),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            opButton(GroupOp.turnOn),
            opButton(GroupOp.turnOff),
            opButton(GroupOp.setBrightness, custom: onBrightness),
            opButton(GroupOp.readBattery),
            opButton(GroupOp.readSensors),
            if (running)
              OutlinedButton.icon(
                onPressed: onCancel,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(0, 48),
                  foregroundColor: scheme.error,
                ),
                icon: const Icon(Icons.stop_circle_outlined, size: 20),
                label: const Text('Cancel'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Devices are handled one at a time; each connects, acts, and '
          'disconnects before the next.',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// One member row: what this device can do before a run, live status during
/// one, and the outcome (or readings) after it.
class _MemberRow extends StatelessWidget {
  final GroupMember member;
  final GroupRunEvent? event;

  /// True while a run is underway and this member has no event yet.
  final bool queued;

  const _MemberRow({required this.member, this.event, this.queued = false});

  String _preRunSummary() {
    if (member.spec == null) return 'Kind unknown — will match on connect';
    final ops = member.specOps;
    if (ops.isEmpty) return 'No group operations in its spec';
    return [for (final op in GroupOp.values.where(ops.contains)) op.label]
        .join(' · ');
  }

  @override
  Widget build(BuildContext context) {
    final current = event;
    final status =
        current?.status ?? (queued ? GroupDeviceStatus.queued : null);
    final category = DeviceCategory.parse(member.spec?.category);

    // Failure reasons live in the subtitle text and the glyph carries the
    // color, so the row reads calmly in every state.
    final subtitle = switch (status) {
      null || GroupDeviceStatus.queued => _preRunSummary(),
      GroupDeviceStatus.connecting => 'Connecting…',
      GroupDeviceStatus.discovering => 'Looking at its services…',
      GroupDeviceStatus.running => 'Working…',
      GroupDeviceStatus.ok => current!.readings.isEmpty
          ? (current.detail ?? 'Done')
          : [for (final r in current.readings) '${r.label}: ${r.value}']
              .join(' · '),
      GroupDeviceStatus.skipped => 'Skipped — ${current!.detail}',
      GroupDeviceStatus.failed => current!.detail ?? 'Failed',
    };

    return GroupTile(
      icon: category?.icon ?? unknownDeviceIcon,
      title: member.name.isNotEmpty ? member.name : 'Unknown device',
      subtitle: subtitle,
      onTap: null,
      trailing: _StatusGlyph(status: status),
    );
  }
}

class _StatusGlyph extends StatelessWidget {
  final GroupDeviceStatus? status;

  const _StatusGlyph({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return switch (status) {
      null => const SizedBox(width: 24),
      GroupDeviceStatus.queued =>
        Icon(Icons.schedule, size: 20, color: scheme.onSurfaceVariant),
      GroupDeviceStatus.connecting ||
      GroupDeviceStatus.discovering ||
      GroupDeviceStatus.running =>
        const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2.4),
        ),
      GroupDeviceStatus.ok =>
        Icon(Icons.check_circle, size: 22, color: scheme.secondary),
      GroupDeviceStatus.skipped =>
        Icon(Icons.block, size: 20, color: scheme.onSurfaceVariant),
      GroupDeviceStatus.failed =>
        Icon(Icons.error_outline, size: 22, color: scheme.error),
    };
  }
}

class _EmptyMembers extends StatelessWidget {
  final bool waiting;

  const _EmptyMembers({required this.waiting});

  @override
  Widget build(BuildContext context) {
    if (waiting) return const Center(child: CircularProgressIndicator());
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Text(
          'No devices in this group. Its members may have been forgotten '
          'from the Saved tab.',
          textAlign: TextAlign.center,
          style: text.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
        ),
      ),
    );
  }
}

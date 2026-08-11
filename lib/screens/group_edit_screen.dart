// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_category.dart';
import '../providers/device_group_provider.dart';
import '../providers/saved_device_provider.dart';
import '../services/device_group_store.dart';
import '../services/saved_device_store.dart';
import '../widgets/device_list_tile.dart';

/// Create a group, or rename/re-member/delete an existing one.
class GroupEditScreen extends ConsumerStatefulWidget {
  /// Null to create a new group.
  final DeviceGroup? group;

  const GroupEditScreen({super.key, this.group});

  @override
  ConsumerState<GroupEditScreen> createState() => _GroupEditScreenState();
}

class _GroupEditScreenState extends ConsumerState<GroupEditScreen> {
  late final TextEditingController _name;
  late final Set<String> _selected;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.group?.name ?? '');
    _selected = {...widget.group?.deviceIds ?? const []};
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _selected.isEmpty || _saving) return;
    setState(() => _saving = true);
    final navigator = Navigator.of(context);
    final notifier = ref.read(deviceGroupsProvider.notifier);
    final existing = widget.group;
    // Membership keeps the saved-devices order (recency), not tap order —
    // the run executes in list order and recency is at least a meaningful one.
    final ordered = [
      for (final device in ref.read(savedDevicesProvider))
        if (_selected.contains(device.id)) device.id,
    ];
    if (existing == null) {
      await notifier.create(name: name, deviceIds: ordered);
    } else {
      await notifier.update(existing.copyWith(name: name, deviceIds: ordered));
    }
    navigator.pop();
  }

  Future<void> _delete() async {
    final group = widget.group;
    if (group == null) return;
    final navigator = Navigator.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete "${group.name}"?'),
        content:
            const Text('The devices stay saved — only the group goes away.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(deviceGroupsProvider.notifier).remove(group.id);
    // Pop past the (now dangling) detail screen when editing, straight back
    // to the groups list.
    navigator.popUntil((route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // Anything saved can join a group except the categories grouping
    // excludes on principle (protocol references, OBD dongles). A device
    // with no known kind is offered: battery reads work without a spec.
    final candidates = [
      for (final device in ref.watch(savedDevicesProvider))
        if (!kNonGroupableCategories
            .contains(DeviceCategory.parse(device.category)))
          device,
    ];
    final canSave = _name.text.trim().isNotEmpty && _selected.isNotEmpty;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(widget.group == null ? 'New group' : 'Edit group'),
        actions: [
          if (widget.group != null)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'Delete group',
              onPressed: _saving ? null : _delete,
            ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            TextField(
              controller: _name,
              onChanged: (_) => setState(() {}),
              textCapitalization: TextCapitalization.sentences,
              decoration: const InputDecoration(
                labelText: 'Group name',
                hintText: 'Living room, Bike, Greenhouse…',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 20),
            SectionHeader(label: 'Devices', count: _selected.length),
            const SizedBox(height: 8),
            if (candidates.isEmpty)
              Text(
                'No saved devices to add. Connect to a device from the '
                'Nearby tab first.',
                style:
                    text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            for (final device in candidates) ...[
              _PickRow(
                device: device,
                selected: _selected.contains(device.id),
                onChanged: (selected) => setState(() {
                  selected
                      ? _selected.add(device.id)
                      : _selected.remove(device.id);
                }),
              ),
              const SizedBox(height: 10),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: canSave && !_saving ? _save : null,
              style: FilledButton.styleFrom(minimumSize: const Size(0, 48)),
              icon: const Icon(Icons.check),
              label: Text(widget.group == null ? 'Create group' : 'Save'),
            ),
          ],
        ),
      ),
    );
  }
}

/// A member-picker row: the shared card chrome with a checkbox, deliberately
/// its own widget rather than a grown [DeviceListTile] — the shared tile
/// serves three device lists that have no notion of selection.
class _PickRow extends StatelessWidget {
  final SavedDevice device;
  final bool selected;
  final ValueChanged<bool> onChanged;

  const _PickRow({
    required this.device,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final category = DeviceCategory.parse(device.category);

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => onChanged(!selected),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? scheme.secondary : scheme.outlineVariant,
            ),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                onChanged: (value) => onChanged(value ?? false),
              ),
              Icon(
                category?.icon ?? Icons.bluetooth,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      device.name.isNotEmpty ? device.name : 'Unknown device',
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      category?.label ?? 'Kind not known yet',
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
      ),
    );
  }
}

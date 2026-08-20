// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_category.dart';
import '../providers/device_group_provider.dart';
import '../providers/saved_device_provider.dart';
import '../providers/saved_network_device_provider.dart';
import '../services/device_group_store.dart';
import '../services/saved_device_store.dart';
import '../services/saved_network_device_store.dart';
import '../widgets/device_list_tile.dart';
import 'group_detail_screen.dart';
import 'group_edit_screen.dart';

/// The Groups tab: the saved devices bucketed by kind, plus the user's own
/// named groups, each opening a screen that acts on all members at once.
class GroupsScreen extends ConsumerWidget {
  const GroupsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final saved = ref.watch(savedDevicesProvider);
    final savedNetwork = ref.watch(savedNetworkDevicesProvider);
    final auto = ref.watch(autoGroupsProvider);
    final custom = ref.watch(deviceGroupsProvider);
    final savedById = {for (final device in saved) device.id: device};
    final savedNetworkById = {
      for (final device in savedNetwork) device.id: device
    };

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Groups')),
      floatingActionButton: saved.isEmpty && savedNetwork.isEmpty
          ? null
          : FloatingActionButton.extended(
              heroTag: 'groups-create-fab',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                    builder: (_) => const GroupEditScreen()),
              ),
              icon: const Icon(Icons.add),
              label: const Text('New group'),
            ),
      body: SafeArea(
        child: saved.isEmpty && savedNetwork.isEmpty
            ? const _EmptyState()
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 96),
                children: [
                  ..._byTypeSection(context, auto),
                  ..._myGroupsSection(
                      context, custom, savedById, savedNetworkById),
                  ..._unidentifiedSection(context, auto),
                ],
              ),
      ),
    );
  }

  List<Widget> _byTypeSection(
      BuildContext context, AsyncValue<AutoGroups> auto) {
    final groups = auto.valueOrNull?.groups ?? const <AutoGroup>[];
    if (groups.isEmpty) return const [];
    return [
      SectionHeader(label: 'By type', count: groups.length),
      const SizedBox(height: 12),
      for (final group in groups) ...[
        GroupTile(
          icon: group.category.icon,
          title: group.category.pluralLabel,
          subtitle: group.memberCount == 1
              ? '1 device'
              : '${group.memberCount} devices',
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute<void>(
              builder: (_) => GroupDetailScreen(category: group.category),
            ),
          ),
        ),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _myGroupsSection(
      BuildContext context,
      List<DeviceGroup> custom,
      Map<String, SavedDevice> savedById,
      Map<String, SavedNetworkDevice> savedNetworkById) {
    if (custom.isEmpty) return const [];
    return [
      SectionHeader(label: 'My groups', count: custom.length),
      const SizedBox(height: 12),
      for (final group in custom) ...[
        Builder(builder: (context) {
          // The count reflects what a run would actually touch — the same
          // filter groupMembersProvider applies: forgotten devices leave a
          // group silently, and so does a member whose recorded kind turned
          // out to be non-groupable. Network members resolve through their
          // own store and namespace.
          final liveMembers = group.deviceIds.where((id) {
            if (isNetworkMemberId(id)) {
              final device = savedNetworkById[networkDeviceIdOf(id)];
              return device != null && isGroupable(device.category);
            }
            final device = savedById[id];
            return device != null && isGroupable(device.category);
          }).length;
          return GroupTile(
            icon: Icons.workspaces_outlined,
            title: group.name,
            subtitle: liveMembers == 1 ? '1 device' : '$liveMembers devices',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => GroupDetailScreen(groupId: group.id),
              ),
            ),
          );
        }),
        const SizedBox(height: 10),
      ],
      const SizedBox(height: 12),
    ];
  }

  List<Widget> _unidentifiedSection(
      BuildContext context, AsyncValue<AutoGroups> auto) {
    final unidentified = auto.valueOrNull?.unidentified ?? const [];
    if (unidentified.isEmpty) return const [];
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return [
      SectionHeader(label: 'Not identified yet', count: unidentified.length),
      const SizedBox(height: 8),
      Text(
        'These saved devices have no known kind. Connect to one from the '
        'Saved tab and it will join its group here.',
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 12),
      for (final device in unidentified) ...[
        GroupTile(
          icon: unknownDeviceIcon,
          title: device.name.isNotEmpty ? device.name : 'Unknown device',
          subtitle: device.id,
          onTap: null,
        ),
        const SizedBox(height: 10),
      ],
    ];
  }
}

/// One group row: the shared device-card chrome (surface, radius, icon
/// square) without [DeviceListTile]'s device-specific slots — a group has no
/// signal, staleness, or forget affordance, and grafting those holes onto the
/// shared tile would complicate three other lists for one screen's benefit.
class GroupTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  const GroupTile({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final tint = onTap != null ? scheme.onSurface : scheme.onSurfaceVariant;

    return Material(
      color: scheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: scheme.outlineVariant),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
          child: Row(
            children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Icon(icon, color: tint, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700, color: tint),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (trailing != null)
                trailing!
              else if (onTap != null)
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.workspaces_outlined,
                size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'No groups yet',
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Groups are built from your saved devices. Connect to a device '
              'from the Nearby tab first — every kind of device you save '
              'gets a group here automatically, and you can make your own.',
              textAlign: TextAlign.center,
              style: text.bodyMedium
                  ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

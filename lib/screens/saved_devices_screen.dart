// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/iot_device.dart';
import '../providers/ble_provider.dart';
import '../providers/device_description_provider.dart';
import '../providers/device_group_provider.dart';
import '../providers/saved_device_provider.dart';
import '../services/number_registry.dart';
import '../services/saved_device_store.dart';
import '../widgets/device_list_tile.dart';
import 'device_screen.dart';

/// The devices the user has already paired with.
///
/// Previously a "History" section pinned to the bottom of the scan screen,
/// where it was below however many strangers' earbuds the last scan turned up.
/// A device you have already set up is the one you come back to, so it gets a
/// destination of its own rather than a footer.
class SavedDevicesScreen extends ConsumerWidget {
  const SavedDevicesScreen({super.key});

  /// Reconnect to a saved device.
  ///
  /// A saved record carries no live RSSI — it's a pointer, not a sighting — so
  /// the reconstructed device is marked connectable and lets the device screen
  /// surface the real outcome if it's out of range.
  ///
  /// Stops the scan first, for the same reason [ScanScreen] does before it
  /// connects: connecting while a scan is running is flaky on both platforms.
  /// It matters more here, not less — the shell holds the scan tab in an
  /// [IndexedStack], so a scan the user started and then walked away from is
  /// still running natively while they tap a saved device on another tab.
  /// Errors are swallowed because a scan that was never started, or has already
  /// stopped, must not block a reconnect.
  Future<void> _reconnect(
      BuildContext context, WidgetRef ref, SavedDevice saved) async {
    final navigator = Navigator.of(context);
    await ref.read(bleServiceProvider).stopScan().catchError((Object _) {});
    await navigator.push(
      MaterialPageRoute(
        builder: (_) => DeviceScreen(
          device: IoTDevice(
            id: saved.id,
            name: saved.name,
            rssi: 0,
            isConnectable: true,
            discoveredAt: DateTime.now(),
          ),
        ),
      ),
    );
  }

  Future<void> _forget(
      BuildContext context, WidgetRef ref, SavedDevice saved) async {
    // Everything context- or ref-derived is resolved before the first await:
    // both lookups throw once this screen is disposed, and a forget should
    // finish even if the user navigates away mid-write.
    final messenger = ScaffoldMessenger.of(context);
    final savedDevices = ref.read(savedDevicesProvider.notifier);
    final groups = ref.read(deviceGroupsProvider.notifier);
    await forgetDevice(
      savedDevices: savedDevices,
      groups: groups,
      deviceId: saved.id,
    );
    messenger.showSnackBar(SnackBar(content: Text('Removed ${saved.name}')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedDevicesProvider);
    final registry = ref.watch(numberRegistryProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Saved devices')),
      body: SafeArea(
        child: saved.isEmpty
            ? const _EmptyState()
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: [
                  SectionHeader(label: 'Paired', count: saved.length),
                  const SizedBox(height: 12),
                  for (final device in saved) ...[
                    DeviceListTile(
                      title: device.name.isNotEmpty
                          ? device.name
                          : 'Unknown device',
                      subtitle: 'Paired',
                      detail: relativeTime(device.lastSeen),
                      icon: Icons.memory,
                      // The address is all a saved record keeps, so run it
                      // through the registry the same way a scan result is —
                      // a paired device you cannot place by name is exactly as
                      // confusing here as it is in the scan list.
                      description: _savedDescription(registry, device),
                      onTap: () => _reconnect(context, ref, device),
                      onForget: () => _forget(context, ref, device),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
      ),
    );
  }

  /// A saved id is a MAC on Android/Linux and a CoreBluetooth UUID on Apple
  /// platforms; [NumberRegistry.vendorForMac] validates and returns null for
  /// the latter, so the id goes straight through.
  String _savedDescription(
      AsyncValue<NumberRegistry> registry, SavedDevice device) {
    final vendor = registry.valueOrNull?.vendorForMac(device.id);
    return [device.id, if (vendor != null) vendor].join(' · ');
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
            Icon(Icons.memory, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'No saved devices yet',
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Connect to a device from the Nearby tab and it will show up '
              'here, ready to reconnect without scanning again.',
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

/// "Just now", "3h ago", or a date once it stops being a useful relative time.
String relativeTime(DateTime when) {
  final diff = DateTime.now().difference(when);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inHours < 1) return '${diff.inMinutes}m ago';
  if (diff.inDays < 1) return '${diff.inHours}h ago';
  if (diff.inDays < 7) return '${diff.inDays}d ago';
  return '${when.year}-${when.month.toString().padLeft(2, '0')}-'
      '${when.day.toString().padLeft(2, '0')}';
}

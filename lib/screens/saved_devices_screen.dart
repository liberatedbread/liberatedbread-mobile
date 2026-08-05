// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/iot_device.dart';
import '../providers/device_description_provider.dart';
import '../providers/saved_device_provider.dart';
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
  Future<void> _reconnect(BuildContext context, SavedDevice saved) =>
      Navigator.push(
        context,
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

  Future<void> _forget(
      BuildContext context, WidgetRef ref, SavedDevice saved) async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(savedDevicesProvider.notifier).remove(saved.id);
    messenger.showSnackBar(SnackBar(content: Text('Removed ${saved.name}')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedDevicesProvider);
    final registry = ref.watch(numberRegistryProvider);
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Saved devices')),
      body: SafeArea(
        child: saved.isEmpty
            ? _EmptyState(scheme: scheme, text: text)
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
                      onTap: () => _reconnect(context, device),
                      onForget: () => _forget(context, ref, device),
                    ),
                    const SizedBox(height: 10),
                  ],
                ],
              ),
      ),
    );
  }

  String? _savedDescription(AsyncValue<dynamic> registry, SavedDevice device) {
    final vendor = registry.maybeWhen(
      data: (r) => r.vendorForMac(_macOf(device.id)) as String?,
      orElse: () => null,
    );
    return [device.id, if (vendor != null) vendor].join(' · ');
  }

  /// A saved id is a MAC on Android/Linux and a CoreBluetooth UUID on Apple
  /// platforms; only the former can be looked up.
  static String? _macOf(String id) => id.split(':').length == 6 ? id : null;
}

class _EmptyState extends StatelessWidget {
  final ColorScheme scheme;
  final TextTheme text;

  const _EmptyState({required this.scheme, required this.text});

  @override
  Widget build(BuildContext context) {
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

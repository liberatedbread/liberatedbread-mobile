// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/device_category.dart';
import '../core/error_text.dart';
import '../models/iot_device.dart';
import '../models/radio_profile.dart';
import '../models/radio_target.dart';
import '../providers/ble_provider.dart';
import '../providers/device_description_provider.dart';
import '../providers/device_group_provider.dart';
import '../providers/network_control_provider.dart';
import '../providers/roomba_provider.dart';
import '../providers/panel_resolution_cache_provider.dart';
import '../providers/saved_designs_provider.dart';
import '../providers/saved_device_provider.dart';
import '../providers/saved_network_device_provider.dart';
import '../providers/saved_radio_provider.dart';
import '../providers/spec_choice_provider.dart';
import '../services/number_registry.dart';
import '../services/saved_device_store.dart';
import '../services/roomba_control_service.dart' show roombaProtocolHandler;
import '../services/roomba_credential_store.dart';
import '../services/saved_network_device_store.dart';
import '../services/saved_radio_store.dart';
import '../widgets/device_list_tile.dart';
import 'device_screen.dart';
import 'network_controls_launcher.dart';
import 'radio_device_screen.dart';
import 'roomba_transport_screen.dart';

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
    BuildContext context,
    WidgetRef ref,
    SavedDevice saved,
  ) async {
    final navigator = Navigator.of(context);
    await ref.read(bleServiceProvider).stopScan().catchError((Object _) {});
    await navigator.push(
      MaterialPageRoute<void>(
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

  /// Ask before forgetting. The close icon sits on the trailing edge of a
  /// row whose whole surface is the reconnect tap target, so a thumb aimed
  /// at the row lands on it easily — and what it does has no undo: a Wi-Fi
  /// device's stored password, certificate pin and group memberships go with
  /// the record, and getting them back means the device's own pairing dance
  /// (a Roomba's Home button, a Hue bridge's link button). Every other
  /// destructive flow in the app confirms first; this one was the exception.
  ///
  /// Returns false when the dialog was dismissed or cancelled.
  Future<bool> _confirmForget(
    BuildContext context,
    String name,
    String consequence,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Forget $name?'),
        content: Text(consequence),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  Future<void> _forget(
    BuildContext context,
    WidgetRef ref,
    SavedDevice saved,
  ) async {
    final confirmed = await _confirmForget(
      context,
      saved.name.isNotEmpty ? saved.name : 'Unknown device',
      'It comes off this list and out of any groups it is in. Connect to it '
      'again from the Nearby tab to bring it back.',
    );
    // The dialog is modal, so the screen is normally still here — but the
    // dialog resolves null on a route pop too, and a context that is gone
    // has no messenger to look up.
    if (!confirmed || !context.mounted) return;
    // Everything context- or ref-derived is resolved before the next await:
    // both lookups throw once this screen is disposed, and a forget should
    // finish even if the user navigates away mid-write.
    final messenger = ScaffoldMessenger.of(context);
    final savedDevices = ref.read(savedDevicesProvider.notifier);
    final groups = ref.read(deviceGroupsProvider.notifier);
    await forgetDevice(
      savedDevices: savedDevices,
      groups: groups,
      deviceId: saved.id,
      // A Rabbit Air set up over BLE files its key under the BLE scope.
      rabbitAir: ref.read(rabbitAirKeyStoreProvider),
      // The per-device preferences keyed by this id. A re-saved device gets
      // the same id back, so without these a removal left the old spec
      // choice, LED designs and panel size to reappear under it.
      specChoices: ref.read(specChoiceStoreProvider),
      savedDesigns: ref.read(savedDesignsStoreProvider),
      panelResolutions: ref.read(panelResolutionCacheProvider),
    );
    messenger.showSnackBar(SnackBar(content: Text('Removed ${saved.name}')));
  }

  /// Open a saved network device's control screen at its cached address.
  ///
  /// The controls re-resolve from the recorded spec identity; the cached
  /// host/ports are the last sighting, so a device whose lease moved fails
  /// with the screen's own "could not reach — try scanning again" rather
  /// than anything new.
  ///
  /// Goes through the same launcher the scan list uses, so a saved robot whose
  /// password is not on this handset reaches the adoption wizard instead of a
  /// control screen that can only report errors.
  Future<void> _openNetwork(
    BuildContext context,
    WidgetRef ref,
    SavedNetworkDevice saved,
    NetworkControls controls,
  ) => openNetworkControls(
    context: context,
    ref: ref,
    device: saved.toNetworkDevice(),
    controls: controls,
    category: saved.category,
    specKey: saved.specKey,
  );

  Future<void> _forgetNetwork(
    BuildContext context,
    WidgetRef ref,
    SavedNetworkDevice saved,
  ) async {
    final confirmed = await _confirmForget(
      context,
      saved.name.isNotEmpty ? saved.name : 'Unknown device',
      'This also removes its stored password and certificate from this '
      'phone and takes it out of any groups it is in. Getting it back means '
      'pairing with the device again.',
    );
    if (!confirmed || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final savedDevices = ref.read(savedNetworkDevicesProvider.notifier);
    final groups = ref.read(deviceGroupsProvider.notifier);
    await forgetNetworkDevice(
      savedDevices: savedDevices,
      groups: groups,
      deviceId: saved.id,
      // Forgetting the device forgets its certificate too. A refused
      // certificate says "re-pair it if the device was reset", and this is
      // the only thing that is.
      trust: ref.read(tlsTrustProvider),
      // …and whatever its spec said it needed, for the same reason.
      credentials: ref.read(deviceCredentialStoreProvider),
      deviceMac: saved.toNetworkDevice().advertisedMac,
      // The two secrets that are not "spec credentials": a Roomba's local
      // password is filed under its blid, a Rabbit Air's key under the
      // hostname it was provisioned as. Neither store had a caller here, so
      // "forget" left both behind while telling the user it had not.
      roomba: ref.read(roombaCredentialStoreProvider),
      rabbitAir: ref.read(rabbitAirKeyStoreProvider),
      blid: saved.txt['blid'],
      hostname: saved.hostname,
      host: saved.host,
      // What the record says its pins were actually keyed by at write time.
      recordedIdentity: saved.credentialIdentity,
      // …and every identity it was ever keyed under (host changes re-key it),
      // so a pin/credential left under an old host key is cleared too.
      recordedIdentities: saved.credentialIdentities,
    );
    messenger.showSnackBar(SnackBar(content: Text('Removed ${saved.name}')));
  }

  /// Reopen a saved radio's screen.
  ///
  /// A Bluetooth radio stops the scan first, for the same reason
  /// [_reconnect] does. A cable radio has no scan to stop.
  Future<void> _openRadio(
      BuildContext context, WidgetRef ref, SavedRadio radio) async {
    final navigator = Navigator.of(context);
    if (radio.transport == RadioTransport.ble) {
      await ref.read(bleServiceProvider).stopScan().catchError((Object _) {});
    }
    await navigator.push(MaterialPageRoute<void>(
      builder: (_) => RadioDeviceScreen(
        target: radio.target,
        initialProfile: radioProfileById(radio.radioProfileId),
      ),
    ));
  }

  Future<void> _forgetRadio(
      BuildContext context, WidgetRef ref, SavedRadio radio) async {
    final messenger = ScaffoldMessenger.of(context);
    await ref.read(savedRadiosProvider.notifier).remove(radio.target);
    messenger.showSnackBar(
        SnackBar(content: Text('Removed ${radio.target.displayName}')));
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final saved = ref.watch(savedDevicesProvider);
    final savedNetwork = ref.watch(savedNetworkDevicesProvider);
    final savedRadios = ref.watch(savedRadiosProvider);
    final registry = ref.watch(numberRegistryProvider);
    final scheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Saved devices')),
      body: SafeArea(
        child: saved.isEmpty && savedNetwork.isEmpty && savedRadios.isEmpty
            ? const _EmptyState()
            : ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: [
                  if (saved.isNotEmpty) ...[
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
                        // a paired device you cannot place by name is exactly
                        // as confusing here as it is in the scan list.
                        description: _savedDescription(registry, device),
                        onTap: () => _reconnect(context, ref, device),
                        onForget: () => _forget(context, ref, device),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                  if (savedNetwork.isNotEmpty) ...[
                    SectionHeader(label: 'Wi-Fi', count: savedNetwork.length),
                    const SizedBox(height: 12),
                    for (final device in savedNetwork) ...[
                      _NetworkSavedTile(
                        device: device,
                        onOpen: (controls) =>
                            _openNetwork(context, ref, device, controls),
                        onForget: () => _forgetNetwork(context, ref, device),
                      ),
                      const SizedBox(height: 10),
                    ],
                  ],
                  if (savedRadios.isNotEmpty) ...[
                    SectionHeader(label: 'Radios', count: savedRadios.length),
                    const SizedBox(height: 12),
                    for (final radio in savedRadios) ...[
                      DeviceListTile(
                        title: radio.target.displayName,
                        subtitle: radioProfileById(radio.radioProfileId)
                                ?.displayName ??
                            'Radio',
                        detail: relativeTime(radio.lastSeen),
                        icon: Icons.settings_input_antenna,
                        description: '${radio.transport.label} · ${radio.id}',
                        onTap: () => _openRadio(context, ref, radio),
                        onForget: () => _forgetRadio(context, ref, radio),
                      ),
                      const SizedBox(height: 10),
                    ],
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
    AsyncValue<NumberRegistry> registry,
    SavedDevice device,
  ) {
    final vendor = registry.valueOrNull?.vendorForMac(device.id);
    return [device.id, ?vendor].join(' · ');
  }
}

/// One saved Wi-Fi device row. A ConsumerWidget of its own because the
/// controls re-resolve per row (the same family the Wi-Fi scan tile
/// watches), and a row whose spec no longer resolves must render disabled
/// rather than take the whole list down.
class _NetworkSavedTile extends ConsumerWidget {
  final SavedNetworkDevice device;
  final void Function(NetworkControls controls) onOpen;
  final VoidCallback onForget;

  const _NetworkSavedTile({
    required this.device,
    required this.onOpen,
    required this.onForget,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final specKey = device.specKey;
    final parts = specKey?.split('|');
    final controls = parts != null && parts.length == 2
        ? ref
              .watch(
                networkControlsProvider(
                  NetworkControlRequest(
                    deviceName: parts[0],
                    manufacturer: parts[1],
                    ssdpTargets: device.ssdpTargets,
                  ),
                ),
              )
              .valueOrNull
        : null;
    final category = DeviceCategory.parse(device.category);
    // A robot serves ONE local client at a time, and a new connection evicts
    // the last, so which thing holds that slot — this app, a rest980 server,
    // or Home Assistant — is a real setting. RoombaTransportScreen is where
    // it is answered, and until now nothing in the app could reach it with a
    // robot's credentials, so the choice could be made once at adoption and
    // never revised. This is that entry point.
    final blid = device.txt['blid'];
    final isRoomba =
        blid != null &&
        blid.isNotEmpty &&
        controls?.capabilities?.protocolHandler == roombaProtocolHandler;
    return DeviceListTile(
      title: device.name.isNotEmpty ? device.name : 'Unknown device',
      subtitle: category?.label ?? 'Wi-Fi',
      detail: relativeTime(device.lastSeen),
      icon: category?.icon ?? Icons.router_outlined,
      description: device.host,
      onTap: controls == null ? null : () => onOpen(controls),
      onConfigure: isRoomba ? () => _chooseTransport(context, ref, blid) : null,
      configureTooltip: isRoomba ? 'How to reach this robot' : null,
      onForget: onForget,
    );
  }

  /// Opens the transport chooser for a saved robot.
  ///
  /// The screen needs the stored credentials: without them it can only offer
  /// Home Assistant, because the direct and rest980 paths need the robot's
  /// local password, and that is the state the one existing caller (the
  /// adoption flow) leaves it in.
  Future<void> _chooseTransport(
    BuildContext context,
    WidgetRef ref,
    String blid,
  ) async {
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    RoombaCredentials? stored;
    try {
      stored = await ref.read(roombaCredentialStoreProvider).credentials(blid);
    } catch (error) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            friendlyErrorText(
              error,
              fallback: "Could not read this robot's stored password.",
              context: 'roomba transport chooser',
            ),
          ),
        ),
      );
      return;
    }
    if (!context.mounted) return;
    if (stored == null) {
      // Adopted through Home Assistant, or the password was cleared: the
      // robot is still drivable, just not directly, and saying so beats a
      // screen with two sections that cannot work.
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            'This robot has no stored password on this phone, so it can only '
            'be reached through Home Assistant.',
          ),
        ),
      );
      return;
    }
    await navigator.push<void>(
      MaterialPageRoute(
        builder: (_) => RoombaTransportScreen(credentials: stored),
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
            Icon(Icons.memory, size: 48, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(
              'No saved devices yet',
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              'Connect to a device or a radio from the Nearby tab and it '
              'will show up here, ready to reconnect without scanning again.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: scheme.onSurfaceVariant,
                height: 1.5,
              ),
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

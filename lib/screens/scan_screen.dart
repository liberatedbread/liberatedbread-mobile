// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/constants.dart';
import '../core/error_text.dart';
import '../models/iot_device.dart';
import '../providers/ble_provider.dart';
import '../providers/saved_device_provider.dart';
import '../services/ble_service.dart';
import '../services/device_manager.dart';
import '../services/saved_device_store.dart';
import '../widgets/radar_scanner.dart';
import 'device_screen.dart';
import 'ha_settings_screen.dart';
import 'spec_pack_settings_screen.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final DeviceManager _deviceManager = DeviceManager();
  bool _isScanning = false;
  // True once at least one scan has completed (successfully or with an error).
  // Distinguishes the "never scanned" prompt from the "scanned, found nothing"
  // dead-end.
  bool _hasScanned = false;
  String? _error;
  // Set when scanning failed because BLE permissions were denied; drives a
  // permission-specific state with an open-settings recovery path.
  bool _permissionDenied = false;
  late final BleService _bleService;
  // Owned scan subscription so a device tap (or dispose) can cancel the active
  // scan instead of leaving it running behind the pushed route.
  StreamSubscription<IoTDevice>? _scanSub;

  @override
  void initState() {
    super.initState();
    _bleService = ref.read(bleServiceProvider);
  }

  Future<void> _startScan() async {
    // Tear down any in-flight scan before starting a new one. Cancel is
    // fire-and-forget: it synchronously stops delivery, and awaiting the
    // teardown future can stall inside the widget-test fake zone.
    unawaited(_scanSub?.cancel());
    _scanSub = null;

    setState(() {
      _isScanning = true;
      _error = null;
      _permissionDenied = false;
      _deviceManager.clear();
    });

    _scanSub = _bleService.scan().listen(
      (device) {
        if (!mounted) return;
        setState(() {
          _deviceManager.addOrUpdate(device);
        });
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _isScanning = false;
          _hasScanned = true;
          if (e is BlePermissionDeniedException) {
            _permissionDenied = true;
            _error = null;
          } else {
            _error = friendlyErrorText(
              e,
              context: 'BLE scan',
              fallback: 'Scanning failed. Check that Bluetooth is on, then '
                  'try again.',
            );
          }
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() {
          _isScanning = false;
          _hasScanned = true;
        });
      },
      cancelOnError: true,
    );
  }

  /// Stop the active scan, then navigate to the device screen (which owns the
  /// connect). Stopping first keeps the native scan from running behind the
  /// pushed route, which otherwise makes connections flaky.
  Future<void> _connect(IoTDevice device) async {
    unawaited(_scanSub?.cancel());
    _scanSub = null;
    await _bleService.stopScan().catchError((Object _) {});
    if (!mounted) return;
    setState(() => _isScanning = false);
    await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => DeviceScreen(device: device)),
    );
  }

  /// Reconnect to a device the user already paired with.
  ///
  /// A saved record carries no live RSSI — it's a pointer, not a sighting — so
  /// the reconstructed device is marked connectable and lets the device screen
  /// surface the real outcome if it's out of range.
  Future<void> _reconnect(SavedDevice saved) => _connect(
        IoTDevice(
          id: saved.id,
          name: saved.name,
          rssi: 0,
          isConnectable: true,
          discoveredAt: DateTime.now(),
        ),
      );

  Future<void> _forget(SavedDevice saved) async {
    await ref.read(savedDevicesProvider.notifier).remove(saved.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Removed ${saved.name}')),
    );
  }

  @override
  void dispose() {
    // Fire-and-forget: unawaited() does not swallow errors, so attach a
    // catchError to keep a throw during teardown from surfacing as an
    // unhandled async error.
    unawaited(_scanSub?.cancel());
    unawaited(_bleService.stopScan().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: const Text(AppConstants.appName),
        actions: [
          IconButton(
            icon: const Icon(Icons.extension_outlined),
            tooltip: 'Device Spec Packs',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SpecPackSettingsScreen()),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Home Assistant',
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const HaSettingsScreen()),
            ),
          ),
          if (isMockMode) const _MockBadge(),
        ],
      ),
      body: SafeArea(child: _buildBody()),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? null : _startScan,
        icon: _isScanning
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  // Match the FAB's themed foreground; a hardcoded white here
                  // fails contrast against the bread-orange fill.
                  color: Theme.of(context)
                      .floatingActionButtonTheme
                      .foregroundColor,
                ),
              )
            : const Icon(Icons.search),
        label: Text(_isScanning ? 'Scanning...' : 'Scan'),
      ),
    );
  }

  /// Headline under the radar. Doubles as the scan status readout, so the
  /// screen never needs a separate progress caption.
  String get _headline {
    if (_permissionDenied) return 'Bluetooth permission needed';
    if (_error != null) return 'Scan failed';
    if (_isScanning) return 'Searching for devices...';
    if (_deviceManager.count > 0) {
      final n = _deviceManager.count;
      return '$n device${n == 1 ? '' : 's'} found';
    }
    if (_hasScanned) return 'No devices found';
    return 'Scan for BLE Devices';
  }

  String get _subhead {
    if (_permissionDenied) {
      return 'Grant Bluetooth (and, on Android, nearby-devices/location) '
          'access so the app can scan for devices.';
    }
    if (_error != null) return _error!;
    if (_isScanning) return 'Make sure your device is powered on and nearby.';
    if (_deviceManager.count > 0) return 'Tap a device to connect.';
    if (_hasScanned) {
      return 'Move closer or check the device is powered on, then scan again.';
    }
    return AppConstants.appTagline;
  }

  Widget _buildBody() {
    final saved = ref.watch(savedDevicesProvider);
    final found = _deviceManager.devices;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ListView(
      // Bottom inset clears the extended FAB so the last row is never parked
      // underneath it.
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 120),
      children: [
        const SizedBox(height: 16),
        Center(child: RadarScanner(scanning: _isScanning)),
        const SizedBox(height: 32),
        Text(
          _headline,
          textAlign: TextAlign.center,
          style: text.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: -0.4,
          ),
        ),
        const SizedBox(height: 10),
        Center(
          child: ConstrainedBox(
            // Constrained measure keeps guidance text at a readable line length
            // instead of running edge to edge.
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              _subhead,
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: _error != null ? scheme.error : scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ),
        if (_permissionDenied) ...[
          const SizedBox(height: 24),
          Center(
            child: ElevatedButton(
              // Fire-and-forget like the other teardown calls in this file: a
              // failure to open the settings app must not become an unhandled
              // async error.
              onPressed: () =>
                  unawaited(openAppSettings().catchError((Object _) => false)),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.settings),
                  SizedBox(width: 8),
                  Text('Open settings'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 4),
          Center(
            child: TextButton(
              onPressed: _isScanning ? null : _startScan,
              style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
              child: const Text('Retry'),
            ),
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 24),
          Center(
            child: ElevatedButton(
              onPressed: _isScanning ? null : _startScan,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh),
                  SizedBox(width: 8),
                  Text('Retry'),
                ],
              ),
            ),
          ),
        ],
        // A completed empty scan gets its own call to action rather than
        // relying on the user finding the FAB again.
        if (_hasScanned &&
            !_isScanning &&
            found.isEmpty &&
            _error == null &&
            !_permissionDenied) ...[
          const SizedBox(height: 24),
          Center(
            child: ElevatedButton(
              onPressed: _startScan,
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.refresh),
                  SizedBox(width: 8),
                  Text('Scan again'),
                ],
              ),
            ),
          ),
        ],
        if (found.isNotEmpty) ...[
          const SizedBox(height: 36),
          _SectionHeader(label: 'Found', count: found.length),
          const SizedBox(height: 12),
          for (final device in found) ...[
            _DeviceCard(
              title: device.displayName,
              subtitle: device.isConnectable
                  ? _signalLabel(device.rssi)
                  : 'Not connectable',
              detail: '${device.rssi} dBm',
              rssi: device.rssi,
              enabled: device.isConnectable,
              onTap: device.isConnectable ? () => _connect(device) : null,
            ),
            const SizedBox(height: 10),
          ],
        ],
        if (saved.isNotEmpty) ...[
          const SizedBox(height: 28),
          _SectionHeader(label: 'History', count: saved.length),
          const SizedBox(height: 12),
          for (final device in saved) ...[
            _DeviceCard(
              title: device.name,
              subtitle: 'Paired',
              detail: _relativeTime(device.lastSeen),
              icon: Icons.memory,
              onTap: () => _reconnect(device),
              onForget: () => _forget(device),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ],
    );
  }

  static String _signalLabel(int rssi) {
    if (rssi >= -60) return 'Strong signal';
    if (rssi >= -75) return 'Good signal';
    return 'Weak signal';
  }

  static String _relativeTime(DateTime when) {
    final diff = DateTime.now().difference(when);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${when.year}-${when.month.toString().padLeft(2, '0')}-'
        '${when.day.toString().padLeft(2, '0')}';
  }
}

/// Section label with a count pill, e.g. "Found · 2".
class _SectionHeader extends StatelessWidget {
  final String label;
  final int count;

  const _SectionHeader({required this.label, required this.count});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Row(
      children: [
        Text(
          label,
          style: text.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
          ),
        ),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '$count',
            style: text.labelSmall?.copyWith(
              color: scheme.onSurfaceVariant,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

/// A device row — used for both live scan results and saved history entries.
///
/// One component for both keeps the two lists visually consistent; the only
/// difference is the trailing detail (signal vs. last-seen) and whether a
/// forget action is offered.
class _DeviceCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final String detail;
  final int? rssi;
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;
  final VoidCallback? onForget;

  const _DeviceCard({
    required this.title,
    required this.subtitle,
    required this.detail,
    this.rssi,
    this.icon = Icons.bluetooth,
    this.enabled = true,
    this.onTap,
    this.onForget,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    // Unconnectable devices stay visible but recede, so the list still reflects
    // what's on air without inviting a tap that would do nothing.
    final tint = enabled ? scheme.onSurface : scheme.onSurfaceVariant;

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
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: tint,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        if (rssi != null) ...[
                          _SignalBars(rssi: rssi!, color: scheme.secondary),
                          const SizedBox(width: 8),
                        ],
                        Flexible(
                          child: Text(
                            subtitle,
                            style: text.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          '  ·  $detail',
                          style: text.bodySmall?.copyWith(
                            color:
                                scheme.onSurfaceVariant.withValues(alpha: 0.7),
                            // Tabular figures stop the row jittering as values
                            // update.
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (onForget != null)
                IconButton(
                  icon: const Icon(Icons.close),
                  iconSize: 18,
                  tooltip: 'Forget $title',
                  onPressed: onForget,
                )
              else if (onTap != null)
                Icon(Icons.chevron_right, color: scheme.onSurfaceVariant),
            ],
          ),
        ),
      ),
    );
  }
}

/// Four-step signal meter.
///
/// Signal strength is conveyed by bar count as well as colour, so it still
/// reads without colour perception.
class _SignalBars extends StatelessWidget {
  final int rssi;
  final Color color;

  const _SignalBars({required this.rssi, required this.color});

  int get _filled {
    if (rssi >= -60) return 4;
    if (rssi >= -70) return 3;
    if (rssi >= -80) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: List.generate(4, (i) {
        final on = i < _filled;
        return Container(
          width: 3,
          height: 5.0 + (i * 3),
          margin: const EdgeInsets.only(right: 2),
          decoration: BoxDecoration(
            color: on ? color : color.withValues(alpha: 0.22),
            borderRadius: BorderRadius.circular(2),
          ),
        );
      }),
    );
  }
}

class _MockBadge extends StatelessWidget {
  const _MockBadge();

  @override
  Widget build(BuildContext context) {
    final fg = Theme.of(context).appBarTheme.foregroundColor;
    return Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: fg?.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: fg?.withValues(alpha: 0.4) ?? fg!),
          ),
          child: Text(
            'MOCK',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.8,
                ),
          ),
        ),
      ),
    );
  }
}

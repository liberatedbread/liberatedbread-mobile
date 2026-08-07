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
import '../providers/device_description_provider.dart';
import '../providers/scan_match_provider.dart';
import '../services/ble_service.dart';
import '../services/device_manager.dart';
import '../widgets/ad_banner_bar.dart';
import '../widgets/device_list_tile.dart';
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
      // House-ad bar. Renders zero-height until the provider has a banner, and
      // the provider never blocks: bundled/cached content first, network later.
      bottomNavigationBar: const AdBannerBar(),
      floatingActionButton: FloatingActionButton.extended(
        // Explicit because HomeShell keeps this screen and the Wi-Fi one alive
        // together in an IndexedStack, so both FABs are in the tree at once and
        // the default tag would collide. A Hero tag collision is not a layout
        // nit: it throws out of the hero controller the moment any route is
        // pushed, which is every tap on a device.
        heroTag: 'scan-fab',
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

  /// One row in either found-devices group.
  Widget _deviceCard(RankedDevice entry, DeviceDescription description) {
    final device = entry.device;
    return DeviceListTile(
      title: deviceTitle(device, description),
      subtitle:
          device.isConnectable ? _signalLabel(device.rssi) : 'Not connectable',
      detail: '${device.rssi} dBm',
      rssi: device.rssi,
      badge: entry.guess?.label,
      badgeIsClaim: entry.isLikelySupported,
      // Only worth saying for a device the catalogue could not place. Once a
      // spec has matched, the badge already names the product, and "Ember
      // Technologies · Battery Service" underneath it is noise.
      description:
          entry.guess == null ? deviceSubtitle(device, description) : null,
      enabled: device.isConnectable,
      onTap: device.isConnectable ? () => _connect(device) : null,
    );
  }

  Widget _buildBody() {
    final registry = ref.watch(numberRegistryProvider);
    final found = _deviceManager.devices;
    // Each device gets its own matching future, keyed on its identity rather
    // than its id — an rssi tick reuses the cached result instead of asking
    // again. A guess that has not resolved yet reads as "no guess", so a row
    // appears immediately and gains its badge a frame later rather than the
    // whole list waiting on the catalogue.
    final ranked = rankScannedDevices(
      found,
      (device) =>
          ref.watch(scanGuessProvider(ScanIdentity.of(device))).valueOrNull,
    );
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
            child: ActionPillButton(
              // Fire-and-forget like the other teardown calls in this file: a
              // failure to open the settings app must not become an unhandled
              // async error.
              onPressed: () =>
                  unawaited(openAppSettings().catchError((Object _) => false)),
              icon: Icons.settings,
              label: 'Open settings',
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
            child: ActionPillButton(
              onPressed: _isScanning ? null : _startScan,
              icon: Icons.refresh,
              label: 'Retry',
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
            child: ActionPillButton(
              onPressed: _startScan,
              icon: Icons.refresh,
              label: 'Scan again',
            ),
          ),
        ],
        if (found.isNotEmpty) ...[
          if (ranked.likelySupported.isNotEmpty) ...[
            const SizedBox(height: 36),
            SectionHeader(
              label: 'Likely supported',
              count: ranked.likelySupported.length,
            ),
            const SizedBox(height: 12),
            for (final entry in ranked.likelySupported) ...[
              _deviceCard(entry, describeWith(registry, entry.device)),
              const SizedBox(height: 10),
            ],
          ],
          if (ranked.other.isNotEmpty) ...[
            const SizedBox(height: 36),
            SectionHeader(
              // Only worth distinguishing from the group above when there IS
              // a group above; otherwise this is simply everything found.
              label: ranked.likelySupported.isEmpty ? 'Found' : 'Other devices',
              count: ranked.other.length,
            ),
            const SizedBox(height: 12),
            for (final entry in ranked.other) ...[
              _deviceCard(entry, describeWith(registry, entry.device)),
              const SizedBox(height: 10),
            ],
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

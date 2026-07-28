// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import '../core/constants.dart';
import '../models/iot_device.dart';
import '../providers/ble_provider.dart';
import '../services/ble_service.dart';
import '../services/device_manager.dart';
import 'device_screen.dart';
import 'ha_settings_screen.dart';
import 'spec_pack_settings_screen.dart';
import '../core/error_text.dart';

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
  // permission-specific empty state with an open-settings recovery path.
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
    return Scaffold(
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
          if (isMockMode)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Chip(label: Text('MOCK')),
            ),
        ],
      ),
      body: _buildBody(),
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

  Widget _buildBody() {
    if (_permissionDenied) {
      return _EmptyState(
        icon: Icons.bluetooth_disabled,
        iconColor: Colors.red,
        title: 'Bluetooth permission needed',
        message:
            'Grant Bluetooth (and, on Android, nearby-devices/location) access '
            'so the app can scan for devices.',
        primaryLabel: 'Open settings',
        primaryIcon: Icons.settings,
        onPrimary: () => openAppSettings(),
        secondaryLabel: 'Retry',
        onSecondary: _isScanning ? null : _startScan,
      );
    }

    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(_error!,
                  style: const TextStyle(color: Colors.red),
                  textAlign: TextAlign.center),
              const SizedBox(height: 24),
              ElevatedButton.icon(
                onPressed: _isScanning ? null : _startScan,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_deviceManager.count == 0) {
      // Distinguish "scanned, found nothing" from the initial "never scanned"
      // prompt so a completed empty scan isn't a silent dead-end.
      if (_hasScanned && !_isScanning) {
        return _EmptyState(
          icon: Icons.search_off,
          title: 'No devices found',
          message: 'Move closer or check the device is powered on, then scan '
              'again.',
          primaryLabel: 'Scan again',
          onPrimary: _startScan,
        );
      }

      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bluetooth_searching, size: 64),
            SizedBox(height: 16),
            Text('Scan for BLE Devices', style: TextStyle(fontSize: 18)),
            SizedBox(height: 8),
            Text(AppConstants.appTagline,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    final devices = _deviceManager.devices;
    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        return ListTile(
          leading: Icon(
            device.isConnectable ? Icons.bluetooth : Icons.bluetooth_disabled,
            color: device.isNearby ? Colors.blue : Colors.grey,
          ),
          title: Text(device.displayName),
          subtitle: Text('RSSI: ${device.rssi} dBm'),
          trailing:
              device.isConnectable ? const Icon(Icons.chevron_right) : null,
          onTap: device.isConnectable ? () => _connect(device) : null,
        );
      },
    );
  }
}

/// Reusable centered empty/guidance state with up to two actions.
class _EmptyState extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String message;
  final String primaryLabel;
  final IconData primaryIcon;
  final VoidCallback? onPrimary;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;

  const _EmptyState({
    required this.icon,
    this.iconColor,
    required this.title,
    required this.message,
    required this.primaryLabel,
    this.primaryIcon = Icons.refresh,
    required this.onPrimary,
    this.secondaryLabel,
    this.onSecondary,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 64, color: iconColor),
            const SizedBox(height: 16),
            Text(title, style: const TextStyle(fontSize: 18)),
            const SizedBox(height: 8),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.grey)),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: onPrimary,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(primaryIcon),
                  const SizedBox(width: 8),
                  Text(primaryLabel),
                ],
              ),
            ),
            if (secondaryLabel != null) ...[
              const SizedBox(height: 8),
              TextButton(
                onPressed: onSecondary,
                child: Text(secondaryLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

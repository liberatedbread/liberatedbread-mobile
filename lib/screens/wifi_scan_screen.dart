// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/error_text.dart';
import '../models/network_device.dart';
import '../providers/device_description_provider.dart';
import '../providers/network_scan_provider.dart';
import '../services/network_scan_service.dart';
import '../services/number_registry.dart';
import '../widgets/device_list_tile.dart';

/// Discovery of devices on the local network, alongside the BLE scan.
///
/// Half the catalogue is Wi-Fi hardware — bridges, plugs, printers — that a
/// Bluetooth scan can never see. Both mDNS and SSDP are used because they do
/// not overlap: modern local-first devices announce over mDNS only, while Wemo
/// and older Hue bridges are SSDP-only.
class WifiScanScreen extends ConsumerStatefulWidget {
  const WifiScanScreen({super.key});

  @override
  ConsumerState<WifiScanScreen> createState() => _WifiScanScreenState();
}

class _WifiScanScreenState extends ConsumerState<WifiScanScreen> {
  final Map<String, NetworkDevice> _found = {};
  bool _isScanning = false;
  bool _hasScanned = false;
  String? _error;
  bool _permissionDenied = false;
  StreamSubscription<NetworkDevice>? _scanSub;

  // Captured in initState: `ref` is unusable from dispose(), and the scan has
  // to be torn down there or a bound multicast socket outlives the screen.
  late final NetworkScanService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(networkScanServiceProvider);
  }

  Future<void> _startScan() async {
    unawaited(_scanSub?.cancel());
    _scanSub = null;

    setState(() {
      _isScanning = true;
      _error = null;
      _permissionDenied = false;
      _found.clear();
    });

    _scanSub = _service.scan().listen(
      (device) {
        if (!mounted) return;
        setState(() => _found[device.host] = device);
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          _isScanning = false;
          _hasScanned = true;
          if (e is LocalNetworkDeniedException) {
            _permissionDenied = true;
            _error = null;
          } else {
            _error = friendlyErrorText(
              e,
              context: 'network scan',
              fallback: 'Scanning failed. Check that you are on a Wi-Fi '
                  'network, then try again.',
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

  @override
  void dispose() {
    unawaited(_scanSub?.cancel());
    unawaited(_service.stopScan().catchError((Object _) {}));
    super.dispose();
  }

  String get _headline {
    if (_permissionDenied) return 'Local network access needed';
    if (_error != null) return 'Scan failed';
    if (_isScanning) return 'Looking for devices...';
    if (_found.isNotEmpty) {
      final n = _found.length;
      return '$n device${n == 1 ? '' : 's'} found';
    }
    if (_hasScanned) return 'No devices found';
    return 'Scan your Wi-Fi network';
  }

  String get _subhead {
    if (_permissionDenied) {
      return 'Allow local network access for Liberated Bread so it can see '
          'devices on your Wi-Fi.';
    }
    if (_error != null) return _error!;
    if (_isScanning) {
      return 'Asking over mDNS and SSDP. This takes a few seconds — some '
          'devices answer slowly on purpose.';
    }
    if (_found.isNotEmpty) return 'Tap a device to see what it advertises.';
    if (_hasScanned) {
      return 'Nothing answered. Check you are on the same network as your '
          'devices — a guest network usually blocks this.';
    }
    return 'Finds bridges, plugs and other devices that have no Bluetooth at '
        'all.';
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final registry = ref.watch(numberRegistryProvider);

    final ranked = rankNetworkDevices(
      _found.values.toList(),
      (device) => ref
          .watch(networkGuessProvider(NetworkIdentity.of(device)))
          .valueOrNull,
    );

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(title: const Text('Wi-Fi devices')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
          children: [
            Center(
              child: Icon(
                _isScanning ? Icons.wifi_tethering : Icons.wifi_find,
                size: 56,
                color: scheme.secondary,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              _headline,
              textAlign: TextAlign.center,
              style: text.headlineSmall
                  ?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
            ),
            const SizedBox(height: 10),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  _subhead,
                  textAlign: TextAlign.center,
                  style: text.bodyMedium?.copyWith(
                    color:
                        _error != null ? scheme.error : scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ),
            if (_permissionDenied) ...[
              const SizedBox(height: 24),
              Center(
                child: ActionPillButton(
                  onPressed: () => unawaited(
                      openAppSettings().catchError((Object _) => false)),
                  icon: Icons.settings,
                  label: 'Open settings',
                ),
              ),
            ],
            if (_hasScanned && !_isScanning && _found.isEmpty) ...[
              const SizedBox(height: 24),
              Center(
                child: ActionPillButton(
                  onPressed: _startScan,
                  icon: Icons.refresh,
                  label: 'Scan again',
                ),
              ),
            ],
            if (ranked.likelySupported.isNotEmpty) ...[
              const SizedBox(height: 36),
              SectionHeader(
                label: 'Likely supported',
                count: ranked.likelySupported.length,
              ),
              const SizedBox(height: 12),
              for (final entry in ranked.likelySupported) ...[
                _tile(entry, registry),
                const SizedBox(height: 10),
              ],
            ],
            if (ranked.other.isNotEmpty) ...[
              const SizedBox(height: 36),
              SectionHeader(
                label:
                    ranked.likelySupported.isEmpty ? 'Found' : 'Other devices',
                count: ranked.other.length,
              ),
              const SizedBox(height: 12),
              for (final entry in ranked.other) ...[
                _tile(entry, registry),
                const SizedBox(height: 10),
              ],
            ],
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        // See the note on ScanScreen's FAB: both live in HomeShell's
        // IndexedStack at the same time, so the tags have to differ.
        heroTag: 'wifi-scan-fab',
        onPressed: _isScanning ? null : _startScan,
        icon: _isScanning
            ? SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Theme.of(context)
                      .floatingActionButtonTheme
                      .foregroundColor,
                ),
              )
            : const Icon(Icons.wifi_find),
        label: Text(_isScanning ? 'Scanning...' : 'Scan'),
      ),
    );
  }

  Widget _tile(RankedNetworkDevice entry, AsyncValue<NumberRegistry> registry) {
    final device = entry.device;
    // A network device rarely publishes a MAC, but when it does (Hue's
    // bridgeid, Lutron's MACADDR TXT record) it is the one thing here the IEEE
    // registry can name — and unlike the IP, it does not move.
    final vendor = registry.maybeWhen(
      data: (r) => r.vendorForMac(device.advertisedMac),
      orElse: () => null,
    );
    return DeviceListTile(
      title: device.displayName,
      subtitle: _transportLabel(device),
      detail:
          device.port == null ? device.host : '${device.host}:${device.port}',
      icon: Icons.router_outlined,
      badge: entry.guess?.label,
      badgeIsClaim: entry.isLikelySupported,
      description: entry.guess == null ? _describe(device, vendor) : null,
      onTap: () => _showDetails(device, vendor),
    );
  }

  static String _transportLabel(NetworkDevice device) {
    final both = device.sources.length > 1;
    if (both) return 'mDNS + SSDP';
    return device.sources.first == NetworkDiscoverySource.mdns
        ? 'mDNS'
        : 'SSDP';
  }

  /// What the device said about itself, for one no spec matched.
  static String? _describe(NetworkDevice device, String? vendor) {
    final parts = <String>[
      if (vendor != null) vendor,
      // The service type is the most human-legible thing an unmatched device
      // offers: "_ipp._tcp" is a printer, and saying so beats saying nothing.
      ...device.serviceTypes.take(2).map(_prettyServiceType),
      if (device.serviceTypes.isEmpty && device.ssdpTargets.isNotEmpty)
        device.ssdpTargets.first,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  /// `_ipp._tcp.local` -> `_ipp._tcp`. The `.local` is on every one of them and
  /// carries no information.
  static String _prettyServiceType(String type) {
    final trimmed = stripLocalSuffix(type);
    return trimmed.isEmpty ? type : trimmed;
  }

  void _showDetails(NetworkDevice device, String? vendor) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) {
        final text = Theme.of(context).textTheme;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(device.displayName,
                    style:
                        text.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                const SizedBox(height: 16),
                _detailRow('Address', device.host),
                if (device.port != null) _detailRow('Port', '${device.port}'),
                if (device.hostname != null)
                  _detailRow('Hostname', device.hostname!),
                if (vendor != null) _detailRow('Address block', vendor),
                if (device.serviceTypes.isNotEmpty)
                  _detailRow('mDNS', device.serviceTypes.join('\n')),
                if (device.ssdpTargets.isNotEmpty)
                  _detailRow('SSDP', device.ssdpTargets.join('\n')),
                if (device.server != null) _detailRow('Server', device.server!),
                for (final entry in device.txt.entries)
                  _detailRow(entry.key, entry.value),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _detailRow(String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 110,
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
            Expanded(
              child: SelectableText(
                value,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      );
}

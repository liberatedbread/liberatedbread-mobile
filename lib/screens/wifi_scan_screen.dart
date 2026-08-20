// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';

import '../core/device_pictogram.dart';
import '../core/error_text.dart';
import '../models/network_device.dart';
import '../widgets/power_strip_icon.dart';
import '../widgets/three_d_printer_icon.dart';
import '../providers/device_description_provider.dart';
import '../providers/ha_provider.dart';
import '../providers/network_control_provider.dart';
import '../providers/network_scan_provider.dart';
import '../providers/saved_network_device_provider.dart';
import '../providers/scan_match_provider.dart';
import '../services/network_scan_service.dart';
import '../services/number_registry.dart';
import '../services/spec_codec.dart';
import '../widgets/adopt_device_card.dart';
import '../widgets/device_list_tile.dart';
import 'adopt_device_screen.dart';
import 'hub_device_screen.dart';
import 'network_device_screen.dart';

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

    // The catalogue's vendor SSDP targets ride along with the scan: a Roku
    // answers only an M-SEARCH for its own `roku:ecp` and is deaf to the
    // standard `ssdp:all`, so the scan has to ask every question the specs
    // know about. Sourced from the specs rather than spelled here — the scan
    // layer knows no product names. A catalogue that failed to load degrades
    // to the standard question alone.
    final identities = await ref
        .read(specIdentitiesProvider.future)
        .catchError((Object _) => const <SpecIdentityDto>[]);
    final targets = <String>{
      for (final identity in identities) ...identity.ssdpSearchTargets,
    }.toList();
    // The same idea one transport over: a device whose responder ignores the
    // `_services._dns-sd._udp.local` meta-query (a Snapmaker U1's embedded
    // zeroconf is one) is only found if the scan asks for its exact
    // `_vendor._tcp` type by name. Sourced from the catalogue like the SSDP
    // targets — the scan layer knows no product names.
    final mdnsTypes = <String>{
      for (final identity in identities)
        if (identity.mdnsServiceType case final type?) type,
    }.toList();
    if (!mounted) return;

    _scanSub = _service
        .scan(extraSearchTargets: targets, extraMdnsServiceTypes: mdnsTypes)
        .listen(
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
      appBar: AppBar(
        title: const Text('Wi-Fi devices'),
        actions: [
          IconButton(
            tooltip: 'Adopt a new Wi-Fi device',
            icon: const Icon(Icons.add_circle_outline),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const AdoptDeviceScreen(),
              ),
            ),
          ),
        ],
      ),
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
            const SizedBox(height: 24),
            // The adoption entry point lives above the scan results and stays
            // put across every scan state: a user with a just-reset device is
            // here to set it up, not to scan, and that device is invisible to
            // the scan below until they do. Its icon spins when the OS can see a
            // matching setup network.
            AdoptDeviceCard(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const AdoptDeviceScreen(),
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
    // A matched spec may declare controls for this device (a Wemo plug's
    // toggle, the Crock-Pot's cook mode). Resolved here, per tile, so the tap
    // can go straight to a control screen — and stays on the details sheet
    // for the majority of matches that declare none.
    final guess = entry.guess;
    final controls = guess == null
        ? null
        : ref
            .watch(networkControlsProvider(NetworkControlRequest(
              deviceName: guess.deviceName,
              manufacturer: guess.manufacturer,
              ssdpTargets: device.ssdpTargets,
            )))
            .valueOrNull;
    // The pictogram a TRANSPORT worked out from the device itself (a UniFi
    // camera's platform, a Kasa bulb's mic_type) wins over the shared spec's
    // category — that is the point of NetworkDevice.pictogram. Then the matched
    // spec's pictogram, then its category glyph.
    // A pictogram Material has no glyph for is drawn by a custom painter. The
    // transport's own token wins over the matched spec's (same precedence as
    // the Material path below), and a name that reads as a power strip is a
    // last resort for a plug that matched nothing.
    final customToken = DevicePictogram.isCustom(device.pictogram)
        ? device.pictogram
        : DevicePictogram.isCustom(guess?.pictogram)
            ? guess!.pictogram
            : device.displayName.toLowerCase().contains('power strip')
                ? 'power-strip'
                : null;
    final scheme = Theme.of(context).colorScheme;
    return DeviceListTile(
      title: device.displayName,
      subtitle: _transportLabel(device),
      detail:
          device.port == null ? device.host : '${device.host}:${device.port}',
      icon: DevicePictogram.iconFor(device.pictogram) ??
          entry.guess?.iconOr(Icons.router_outlined) ??
          Icons.router_outlined,
      iconWidget: switch (customToken) {
        'power-strip' =>
          PowerStripIcon(size: 24, color: scheme.onSurfaceVariant),
        '3d-printer' =>
          ThreeDPrinterIcon(size: 24, color: scheme.onSurfaceVariant),
        _ => null,
      },
      badge: entry.guess?.label,
      badgeIsClaim: entry.isLikelySupported,
      // Same rule as the BLE tab, and for the same reason: it is naming a
      // product that makes the description redundant, not merely matching
      // something. A badge reading "Supported device" or "Possibly supported"
      // has told the user nothing about which one — the vendor and the service
      // type underneath it are precisely what distinguishes this row.
      description:
          entry.guess?.namesAProduct == true ? null : _describe(device, vendor),
      onTap: controls != null
          ? () {
              // Opening controls is the network counterpart of a BLE
              // connect: the moment the device earns a saved record, so it
              // can join groups and be reached while out of sight. The spec
              // identity and category ride along — they are what the TVs
              // auto-group buckets by.
              unawaited(ref.read(savedNetworkDevicesProvider.notifier).touch(
                    device,
                    category: guess?.category?.wireName,
                    specKey: guess == null
                        ? null
                        : '${guess.deviceName}|${guess.manufacturer}',
                  ));
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  // A hub (instanced children, link-button pairing) gets the
                  // paired screen; everything else — SOAP devices and Roku's
                  // plain-HTTP remote alike — keeps the ordinary control
                  // screen, whose load path a Hue bridge would not survive.
                  builder: (_) => controls.isHub
                      ? HubDeviceScreen(device: device, controls: controls)
                      : NetworkDeviceScreen(device: device, controls: controls),
                ),
              );
            }
          // A UniFi camera's own admin page is a dead end — cameras are driven
          // through UniFi Protect, not individually — so it opens the details
          // sheet (which points at the Protect controller) rather than
          // click-and-go into nothing.
          : (_isUnifiCamera(device)
              ? () => _showDetails(device, vendor)
              // A recognize-only device we can't drive but whose spec knows
              // where its admin page lives (a NAS's DSM, a printer's web UI):
              // the tap opens that, the one useful action here.
              : (guess?.adminUrl != null
                  ? () => _openAdmin(guess!, device)
                  : () => _showDetails(device, vendor))),
    );
  }

  /// A UniFi camera or doorbell — recognized by the pictogram its transport
  /// derived from the platform string. Cameras are managed in UniFi Protect,
  /// not individually.
  static bool _isUnifiCamera(NetworkDevice device) =>
      device.answeredLanProtocols.contains('ubiquiti-discovery') &&
      (device.pictogram == 'ip-camera' || device.pictogram == 'video-doorbell');

  /// The UniFi Protect controller among the devices found this scan, if any —
  /// a UNVR, or a UDM/Cloud Key that runs Protect. Cameras point back to it.
  NetworkDevice? _unifiProtectController() {
    for (final d in _found.values) {
      final platform = (d.txt['platform'] ?? '').toUpperCase();
      if (d.pictogram == 'nvr' ||
          platform.startsWith('UNVR') ||
          platform.startsWith('UDM') ||
          platform.startsWith('UCKP') ||
          platform.startsWith('UCK-G2')) {
        return d;
      }
    }
    return null;
  }

  /// Open a device's own admin page, filling `{address}` with its host.
  void _openAdmin(ScanGuess guess, NetworkDevice device) {
    final uri =
        Uri.tryParse(guess.adminUrl!.replaceAll('{address}', device.host));
    if (uri == null) return;
    unawaited(ref.read(urlOpenerProvider)(uri));
  }

  static String _transportLabel(NetworkDevice device) {
    // A set, so a device heard on more than one transport (mDNS + SSDP) reads
    // as both, deduplicated and in a stable order. `sources` carries no
    // non-empty invariant, so an empty set is simply an empty label — naming
    // the transport is the least important thing on the row.
    final labels = <String>{
      for (final source in device.sources)
        switch (source) {
          NetworkDiscoverySource.mdns => 'mDNS',
          NetworkDiscoverySource.ssdp => 'SSDP',
          NetworkDiscoverySource.lanProbe => 'LAN',
        }
    };
    return labels.join(' + ');
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
      builder: (sheetContext) {
        final text = Theme.of(sheetContext).textTheme;
        // Scrollable, because the content is whatever the device chose to
        // advertise: a printer's TXT records alone can be taller than the
        // sheet, and a Column would overflow rather than let the user read
        // them.
        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(device.displayName,
                          style: text.titleLarge
                              ?.copyWith(fontWeight: FontWeight.w700)),
                    ),
                    // The details are the reason to open the sheet — a MAC to
                    // save, a TXT record to paste into a bug report. Copy the
                    // whole lot, since retyping a MAC or a serial off a phone
                    // screen is exactly the friction this removes.
                    IconButton(
                      icon: const Icon(Icons.copy_outlined),
                      tooltip: 'Copy details',
                      onPressed: () async {
                        final messenger = ScaffoldMessenger.of(sheetContext);
                        await Clipboard.setData(
                            ClipboardData(text: _detailsText(device, vendor)));
                        messenger.showSnackBar(const SnackBar(
                            content: Text('Device details copied')));
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _detailRow('Address', device.host),
                if (device.port != null) _detailRow('Port', '${device.port}'),
                if (device.hostname != null)
                  _detailRow('Hostname', device.hostname!),
                // The MAC the block below was looked up from. Shown next to
                // it, not instead of it: `Address` above is the IP, which DHCP
                // reassigns, while this one is the hardware and does not move.
                // Without it the "Address block" row cites a source the sheet
                // never displays.
                if (device.advertisedMac != null)
                  _detailRow('MAC', device.advertisedMac!),
                if (vendor != null) _detailRow('Address block', vendor),
                if (device.serviceTypes.isNotEmpty)
                  _detailRow('mDNS', device.serviceTypes.join('\n')),
                if (device.ssdpTargets.isNotEmpty)
                  _detailRow('SSDP', device.ssdpTargets.join('\n')),
                if (device.server != null) _detailRow('Server', device.server!),
                for (final entry in device.txt.entries)
                  _detailRow(entry.key, entry.value),
                // Additional context for a camera we can recognize but not
                // drive: it is managed in UniFi Protect, and if a controller
                // turned up in this scan, where to find it.
                if (_isUnifiCamera(device)) ...[
                  const SizedBox(height: 16),
                  _controllableViaNote(sheetContext),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// A footer note for a UniFi camera: it is driven through UniFi Protect, with
  /// a link to the controller when one was found on the same scan.
  Widget _controllableViaNote(BuildContext sheetContext) {
    final scheme = Theme.of(sheetContext).colorScheme;
    final text = Theme.of(sheetContext).textTheme;
    final controller = _unifiProtectController();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.info_outline, size: 18, color: scheme.onSurfaceVariant),
            const SizedBox(width: 8),
            Text('Likely controlled via UniFi Protect',
                style:
                    text.titleSmall?.copyWith(color: scheme.onSurfaceVariant)),
          ]),
          const SizedBox(height: 6),
          Text(
            controller != null
                ? 'This app can recognise the camera but not drive it directly. '
                    'Found a UniFi Protect controller at ${controller.host} '
                    '(${controller.displayName}).'
                : 'This app can recognise the camera but not drive it directly. '
                    'It is managed in the UniFi Protect app/controller.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          if (controller != null) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Open UniFi Protect'),
                onPressed: () {
                  final uri =
                      Uri.tryParse('https://${controller.host}/protect/');
                  if (uri != null) {
                    unawaited(ref.read(urlOpenerProvider)(uri));
                  }
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The details sheet as plain text for the clipboard — the same rows the
  /// sheet shows, one `Label: value` per line.
  static String _detailsText(NetworkDevice device, String? vendor) {
    final b = StringBuffer()..writeln(device.displayName);
    b.writeln('Address: ${device.host}');
    if (device.port != null) b.writeln('Port: ${device.port}');
    if (device.hostname != null) b.writeln('Hostname: ${device.hostname}');
    if (device.advertisedMac != null) b.writeln('MAC: ${device.advertisedMac}');
    if (vendor != null) b.writeln('Address block: $vendor');
    if (device.serviceTypes.isNotEmpty) {
      b.writeln('mDNS: ${device.serviceTypes.join(', ')}');
    }
    if (device.ssdpTargets.isNotEmpty) {
      b.writeln('SSDP: ${device.ssdpTargets.join(', ')}');
    }
    if (device.server != null) b.writeln('Server: ${device.server}');
    for (final entry in device.txt.entries) {
      b.writeln('${entry.key}: ${entry.value}');
    }
    return b.toString().trimRight();
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

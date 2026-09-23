// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The USB tab: programming cables plugged into this device.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/usb_bridges.dart';
import '../models/radio_target.dart';
import '../providers/serial_port_provider.dart';
import '../services/serial_port_service.dart';
import '../widgets/device_list_tile.dart';
import 'radio_device_screen.dart';

/// Cables plugged in, beside the Bluetooth and Wi-Fi tabs.
///
/// What arrives here is a USB-serial cable, and what is on its far end is a
/// radio: tapping one opens that radio's screen, the same one a radio found
/// in the Nearby list opens. The cable is all that can be listed — the radio
/// only says what it is once it is spoken to.
///
/// On a platform with no route to a serial adapter the tab still appears,
/// and says so, with what works instead.
class UsbScanScreen extends ConsumerStatefulWidget {
  /// Whether this is the tab on screen. Listing waits for it, and looks
  /// again each time the tab comes back: a cable is plugged in while the tab
  /// is elsewhere far more often than while someone watches it.
  final bool active;

  const UsbScanScreen({super.key, this.active = true});

  @override
  ConsumerState<UsbScanScreen> createState() => _UsbScanScreenState();
}

class _UsbScanScreenState extends ConsumerState<UsbScanScreen> {
  /// Null until the first listing finishes.
  List<SerialPortInfo>? _ports;
  bool _listing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.active) unawaited(_list());
  }

  @override
  void didUpdateWidget(UsbScanScreen old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) unawaited(_list());
  }

  Future<void> _list() async {
    final service = ref.read(serialPortServiceProvider);
    if (!service.availability.supported || _listing) return;
    setState(() {
      _listing = true;
      _error = null;
    });
    try {
      final ports = await service.listPorts();
      if (!mounted) return;
      setState(() {
        _ports = ports;
        _listing = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _listing = false;
        _error = friendlyErrorText(
          error,
          fallback: 'Could not list the cables plugged in.',
          context: 'USB port list',
        );
      });
    }
  }

  Future<void> _open(SerialPortInfo port) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RadioDeviceScreen(
        target: RadioTarget(
          transport: RadioTransport.usb,
          id: port.id,
          name: port.displayName,
        ),
      ),
    ));
    if (mounted && widget.active) unawaited(_list());
  }

  @override
  Widget build(BuildContext context) {
    final availability = ref.watch(serialPortServiceProvider).availability;
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: const Text('USB'),
        actions: [
          if (availability.supported)
            IconButton(
              tooltip: 'Look again',
              icon: const Icon(Icons.refresh),
              onPressed: _listing ? null : _list,
            ),
        ],
      ),
      body: SafeArea(
        child: availability.supported
            ? _body(context)
            : _NoSerialHere(reason: availability.reason ?? ''),
      ),
    );
  }

  String get _headline {
    final ports = _ports;
    if (_error != null) return 'Could not look for cables';
    if (ports == null) return 'Looking for cables…';
    if (ports.isEmpty) return 'No cable plugged in';
    return '${ports.length} ${ports.length == 1 ? 'cable' : 'cables'} '
        'plugged in';
  }

  Widget _body(BuildContext context) {
    final ports = _ports;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        Icon(Icons.usb, size: 48, color: scheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          _headline,
          textAlign: TextAlign.center,
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Text(
              _error ??
                  (ports != null && ports.isEmpty
                      ? 'Plug the programming cable into the radio\'s '
                          'accessory jack and into this device — on a phone, '
                          'through a USB-OTG adapter.'
                      : 'Tap a cable to reach the radio on the other end.'),
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(
                color: _error != null ? scheme.error : scheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Center(
            child: TextButton(
              onPressed: _listing ? null : _list,
              child: const Text('Try again'),
            ),
          ),
        ],
        if (ports != null && ports.isNotEmpty) ...[
          const SizedBox(height: 28),
          SectionHeader(label: 'Cables', count: ports.length),
          const SizedBox(height: 12),
          for (final port in ports) ...[
            _cableTile(port),
            const SizedBox(height: 10),
          ],
        ],
        const SizedBox(height: 28),
        Text(
          'Radios with their own Bluetooth, like the UV-5R Mini and Mini 5, '
          'need no cable: they appear in the Nearby tab.',
          textAlign: TextAlign.center,
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }

  Widget _cableTile(SerialPortInfo port) {
    final bridge = port.bridge;
    final ids = port.vendorId != null && port.productId != null
        ? usbIdLabel(port.vendorId!, port.productId!)
        : null;
    final details = [
      if (port.manufacturer != null) port.manufacturer!,
      if (ids != null) ids,
    ].join(' · ');
    final title = port.displayName;
    return DeviceListTile(
      title: title,
      // The chip, unless the title already is the chip.
      subtitle: (title == bridge?.name ? null : bridge?.name) ?? 'USB serial',
      detail: port.name,
      icon: Icons.usb,
      // A chip worth warning about says so; otherwise, what the device
      // reports, which is what tells two identical cables apart.
      description: bridge?.caution ?? (details.isEmpty ? null : details),
      onTap: () => _open(port),
    );
  }
}

/// What the tab says where there is no route to a serial adapter at all.
class _NoSerialHere extends StatelessWidget {
  final String reason;

  const _NoSerialHere({required this.reason});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    Widget point(IconData icon, String title, String body) => ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(icon),
          title: Text(title),
          subtitle: Text(body),
        );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
      children: [
        Icon(Icons.usb_off, size: 48, color: scheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(
          'No programming cables here',
          textAlign: TextAlign.center,
          style: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        Text(
          reason,
          textAlign: TextAlign.center,
          style: text.bodyMedium
              ?.copyWith(color: scheme.onSurfaceVariant, height: 1.5),
        ),
        const SizedBox(height: 28),
        const SectionHeader(label: 'What works instead'),
        const SizedBox(height: 8),
        point(
          Icons.bluetooth,
          'Radios with their own Bluetooth',
          'The UV-5R Mini and Mini 5 program with no cable at all. They '
              'appear in the Nearby tab.',
        ),
        point(
          Icons.settings_input_antenna,
          'Bluetooth programming adapters',
          'Adapters such as the BT-A1D and the TD-BL-1 plug into a radio\'s '
              'programming jack and talk Bluetooth instead of USB — the way to '
              'reach a cable radio from an iPhone. This app does not support '
              'them yet.',
        ),
        point(
          Icons.ios_share,
          'A computer',
          'Any plan can be exported for CHIRP from the Radio tab, and loaded '
              'onto the radio from a computer with a cable.',
        ),
      ],
    );
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../core/web_link.dart';
import '../models/network_device.dart';
import '../providers/ha_provider.dart' show urlOpenerProvider;
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/ipp_status_client.dart';
import '../services/print/photo_source.dart';
import '../services/share_in_service.dart';
import '../services/spec_codec.dart';
import '../widgets/ad_banner_bar.dart';
import '../widgets/print/add_system_printer_sheet.dart';
import 'print_shared_file_screen.dart';

/// An office or home printer's status, read over IPP: whether it is ready,
/// what is wrong, how much ink or toner is left, and what paper is loaded.
/// Printing goes through the system print dialog, which already reaches it.
class IppPrinterScreen extends ConsumerStatefulWidget {
  final NetworkDevice device;
  final NetworkControls controls;
  final String? category;
  final String? specKey;

  const IppPrinterScreen({
    super.key,
    required this.device,
    required this.controls,
    this.category,
    this.specKey,
  });

  @override
  ConsumerState<IppPrinterScreen> createState() => _IppPrinterScreenState();
}

class _IppPrinterScreenState extends ConsumerState<IppPrinterScreen> {
  static const _ippPort = 631;

  IppPrinterStatusDto? _status;
  String? _error;
  bool _loading = true;

  /// The IPP resource: the TXT `rp`, or IPP Everywhere's default.
  String get _resource {
    final rp = widget.device.txt['rp']?.trim();
    return (rp == null || rp.isEmpty) ? 'ipp/print' : rp;
  }

  /// Whether the printer advertised plain IPP at all; one seen only as a raw
  /// socket or LPD queue has no status surface to ask.
  bool get _speaksIpp => widget.device.serviceTypes.any(
    (t) => t.startsWith('_ipp._tcp') || t.startsWith('_ipps._tcp'),
  );

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    if (!_speaksIpp) {
      setState(() {
        _loading = false;
        _error =
            'This printer did not advertise IPP, so it has no status to '
            'read. Its admin page may show more.';
      });
      return;
    }
    final codec = ref.read(specCodecProvider);
    final client = ref.read(ippStatusClientProvider);
    try {
      final body = await codec.ippStatusRequest(
        printerUri: 'ipp://${widget.device.host}:$_ippPort/$_resource',
        requestId: 1,
      );
      final result = await client.fetch(
        host: widget.device.host,
        port: _ippPort,
        resourcePath: _resource,
        body: body,
      );
      if (!mounted) return;
      switch (result) {
        case IppFetchFailed(:final reason, :final secureOnly):
          setState(() {
            _loading = false;
            _error = secureOnly
                ? '$reason Its admin page shows the same status.'
                : reason;
          });
        case IppFetchOk(:final body):
          final status = await codec.decodeIppStatus(reply: body);
          if (!mounted) return;
          setState(() {
            _loading = false;
            _status = status;
            _error = status.ok
                ? null
                : 'The printer declined the status request '
                      '(IPP 0x${status.statusCode.toRadixString(16)}).';
          });
      }
    } on Object catch (e) {
      Log.net.warning('IPP status failed', error: e);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'The printer answered, but not with a status this app reads.';
      });
    }
  }

  Future<void> _printDocument() async {
    final navigator = Navigator.of(context);
    final bytes = await ref.read(photoSourceProvider).pickFile();
    if (bytes == null || !mounted) return;
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PrintSharedFileScreen(file: SharedFile(bytes: bytes)),
        ),
      ),
    );
  }

  Future<void> _openAdmin() async {
    final messenger = ScaffoldMessenger.of(context);
    final raw = widget.device.txt['adminurl']?.trim();
    final uri = Uri.tryParse(
      raw != null && raw.isNotEmpty ? raw : 'http://${widget.device.host}/',
    );
    var opened = false;
    if (isWebLink(uri)) {
      try {
        opened = await ref.read(urlOpenerProvider)(uri!);
      } on Object catch (e) {
        Log.ui.warning('could not open the printer admin page', error: e);
      }
    }
    if (!opened && mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the admin page.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final status = _status;
    return Scaffold(
      bottomNavigationBar: DeviceAdBannerBar(
        category: widget.category,
        specKey: widget.specKey,
      ),
      appBar: AppBar(
        title: Text(widget.device.displayName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            if (_loading)
              const _Card(
                child: Row(
                  children: [
                    SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 14),
                    Expanded(child: Text('Reading printer status…')),
                  ],
                ),
              )
            else if (_error != null && status == null)
              _Card(child: Text(_error!))
            else if (status != null) ...[
              _StateCard(status: status),
              if (status.markers.isNotEmpty) ...[
                const SizedBox(height: 12),
                _SuppliesCard(markers: status.markers),
              ],
              if (status.mediaReady.isNotEmpty) ...[
                const SizedBox(height: 12),
                _Card(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Paper loaded',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const SizedBox(height: 6),
                      for (final m in status.mediaReady) Text(mediaLabel(m)),
                    ],
                  ),
                ),
              ],
            ],
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => unawaited(_printDocument()),
              icon: const Icon(Icons.print_outlined),
              label: const Text('Print a document or photo'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => unawaited(_openAdmin()),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open admin page'),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => unawaited(
                showAddSystemPrinterSheet(
                  context,
                  printerName: widget.device.displayName,
                  host: widget.device.host,
                  resourcePath: _resource,
                ),
              ),
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Add to system printers'),
            ),
          ],
        ),
      ),
    );
  }
}

/// `iso_a4_210x297mm` → `A4 (210x297 mm)`, `na_letter_8.5x11in` → `Letter
/// (8.5x11 in)`: the PWG self-describing name, read aloud.
String mediaLabel(String pwg) {
  final parts = pwg.split('_');
  if (parts.length < 3) return pwg;
  final name = parts[1];
  final size = parts.sublist(2).join('_');
  final pretty = parts[0] == 'iso' || parts[0] == 'jis'
      ? name.toUpperCase()
      : name.isEmpty
      ? name
      : name[0].toUpperCase() + name.substring(1);
  final dims = RegExp(r'^([\d.]+x[\d.]+)(mm|in)$').firstMatch(size);
  return dims == null ? pretty : '$pretty (${dims[1]} ${dims[2]})';
}

/// `media-empty-error` → `Media empty`: a state reason, read aloud. The
/// severity suffix is dropped; the card's colour carries it.
String reasonLabel(String keyword) {
  final bare = keyword.replaceAll(RegExp(r'-(report|warning|error)$'), '');
  final words = bare.replaceAll('-', ' ');
  return words.isEmpty ? keyword : words[0].toUpperCase() + words.substring(1);
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );
  }
}

class _StateCard extends StatelessWidget {
  final IppPrinterStatusDto status;
  const _StateCard({required this.status});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hasError = status.stateReasons.any((r) => r.endsWith('-error'));
    final (icon, label, color) = switch (status.state) {
      'idle' when !hasError => (
        Icons.check_circle_outline,
        'Ready',
        scheme.tertiary,
      ),
      'processing' => (Icons.print_outlined, 'Printing', scheme.primary),
      'stopped' ||
      'idle' => (Icons.warning_amber, 'Needs attention', scheme.error),
      _ => (Icons.help_outline, 'State unknown', scheme.onSurfaceVariant),
    };
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color),
              const SizedBox(width: 10),
              Text(label, style: text.titleMedium),
            ],
          ),
          if (status.makeAndModel != null) ...[
            const SizedBox(height: 6),
            Text(
              status.makeAndModel!,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
          if (status.stateMessage != null) ...[
            const SizedBox(height: 8),
            Text(status.stateMessage!),
          ],
          if (status.stateReasons.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              status.stateReasons.map(reasonLabel).join(' · '),
              style: text.bodySmall?.copyWith(
                color: hasError ? scheme.error : scheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SuppliesCard extends StatelessWidget {
  final List<IppMarkerDto> markers;
  const _SuppliesCard({required this.markers});

  /// The first `#RRGGBB` of a marker's colour; a multi-colour cartridge
  /// joins several.
  static Color? _color(String? spec) {
    final m = RegExp(r'#([0-9A-Fa-f]{6})').firstMatch(spec ?? '');
    return m == null ? null : Color(0xFF000000 | int.parse(m[1]!, radix: 16));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Ink & toner', style: text.titleSmall),
          const SizedBox(height: 8),
          for (final m in markers) ...[
            Row(
              children: [
                Expanded(child: Text(m.name, style: text.bodyMedium)),
                Text(
                  m.level != null
                      ? '${m.level}%'
                      : m.someRemaining
                      ? 'Some left'
                      : 'Unknown',
                  style: text.bodySmall?.copyWith(
                    color:
                        m.level != null &&
                            m.lowLevel != null &&
                            m.level! <= m.lowLevel!
                        ? scheme.error
                        : scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Semantics(
              label: '${m.name} level',
              value: m.level != null ? '${m.level} percent' : 'unknown',
              child: LinearProgressIndicator(
                value: m.level != null ? m.level! / 100 : null,
                minHeight: 6,
                borderRadius: BorderRadius.circular(3),
                color: _color(m.color) ?? scheme.primary,
                backgroundColor: scheme.surfaceContainerHighest,
              ),
            ),
            const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

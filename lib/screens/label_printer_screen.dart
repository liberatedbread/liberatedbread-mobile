// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/brother_ql_print_service.dart';
import '../services/print/print_target.dart';
import '../services/spec_codec.dart';
import '../widgets/ad_banner_bar.dart';
import 'print_label_screen.dart';

/// Control screen for a raster label printer (Brother QL family).
///
/// A QL exposes no commands — its surface is a raw raster byte stream — so this
/// is a purpose-built screen rather than the entity control panel: it reads the
/// printer's status (loaded media, errors) over TCP and offers a "Print test
/// label" action that renders a test pattern sized to that media in Rust and
/// writes it. The label-supply promo rides the bottom bar.
class LabelPrinterScreen extends ConsumerStatefulWidget {
  final NetworkDevice device;
  final NetworkControls controls;

  /// For the device-targeted supply banner (label rolls).
  final String? category;
  final String? specKey;

  const LabelPrinterScreen({
    super.key,
    required this.device,
    required this.controls,
    this.category,
    this.specKey,
  });

  @override
  ConsumerState<LabelPrinterScreen> createState() => _LabelPrinterScreenState();
}

class _LabelPrinterScreenState extends ConsumerState<LabelPrinterScreen> {
  BrotherQlStatusDto? _status;
  bool _loading = true;
  bool _printing = false;
  String? _error;

  int get _port =>
      widget.controls.capabilities?.defaultPort ??
      widget.device.controlPort ??
      9100;

  @override
  void initState() {
    super.initState();
    unawaited(_loadStatus());
  }

  Future<void> _loadStatus() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final codec = ref.read(specCodecProvider);
    final printer = ref.read(brotherQlPrintServiceProvider);
    try {
      final request = await codec.brotherQlStatusRequest();
      final result = await printer.send(
        widget.device.host,
        _port,
        request,
        readStatus: true,
      );
      if (!mounted) return;
      switch (result) {
        case BrotherQlSendFailed(:final reason):
          setState(() {
            _loading = false;
            _error = reason;
          });
        case BrotherQlSendOk(:final statusReply):
          if (statusReply == null) {
            setState(() {
              _loading = false;
              // Reachable but silent: some firmware only answers status while
              // idle, and the printer still prints. Say so instead of failing.
              _status = null;
              _error = null;
            });
            return;
          }
          final status = await codec.decodeBrotherQlStatus(reply: statusReply);
          if (!mounted) return;
          setState(() {
            _loading = false;
            _status = status;
          });
      }
    } on Object catch (e) {
      Log.spec.warning('label printer status failed', error: e);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'Could not read the printer status.';
      });
    }
  }

  /// Whether the print button is offered: when the printer reported ready, OR
  /// when it is reachable but reported no status at all (some firmware only
  /// answers status while idle — the card says a test label should still
  /// print, so the button must honour that). A reported not-ready (real error)
  /// keeps it disabled.
  bool get _canPrint => _status == null || _status!.readyToPrint;

  BrotherQlJobParamsDto _printParams() => brotherParamsFor(_status);

  /// Open the composer on a target sized to the loaded roll.
  Future<void> _composeLabel() async {
    if (!_canPrint) return;
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final target = await BrotherQlTarget.resolve(
        codec: ref.read(specCodecProvider),
        transport: ref.read(brotherQlPrintServiceProvider),
        specYaml: widget.controls.specYaml,
        host: widget.device.host,
        port: _port,
        params: _printParams(),
        name: widget.device.displayName,
      );
      if (!mounted) return;
      await navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PrintLabelScreen(target: target),
        ),
      );
    } on Object catch (e) {
      Log.spec.warning('label composer failed to open', error: e);
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Could not size a label for this roll.'),
          ),
        );
      }
    }
  }

  Future<void> _printTestLabel() async {
    if (!_canPrint) return;
    final status = _status;
    final detail = status == null
        ? 'The printer did not report its media, so this assumes a standard '
              '62 mm continuous roll.'
        : 'This uses one ${status.mediaWidthMm} mm label to check the '
              'printer end to end.';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Print a test label?'),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Print'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _printing = true);
    final codec = ref.read(specCodecProvider);
    final printer = ref.read(brotherQlPrintServiceProvider);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final job = await codec.renderBrotherQlTestLabel(
        specYaml: widget.controls.specYaml,
        params: _printParams(),
      );
      final result = await printer.send(widget.device.host, _port, job);
      if (!mounted) return;
      switch (result) {
        case BrotherQlSendOk():
          messenger.showSnackBar(
            const SnackBar(content: Text('Test label sent.')),
          );
        case BrotherQlSendFailed(:final reason):
          messenger.showSnackBar(SnackBar(content: Text(reason)));
      }
    } on Object catch (e) {
      Log.spec.warning('label print failed', error: e);
      if (mounted) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not send the label.')),
        );
      }
    } finally {
      if (mounted) setState(() => _printing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      backgroundColor: scheme.surface,
      bottomNavigationBar: DeviceAdBannerBar(
        category: widget.category,
        specKey: widget.specKey,
      ),
      appBar: AppBar(
        title: Text(widget.device.displayName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : () => unawaited(_loadStatus()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            _StatusCard(
              loading: _loading,
              error: _error,
              status: _status,
              port: _port,
              host: widget.device.host,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _canPrint && !_loading && !_printing
                  ? () => unawaited(_composeLabel())
                  : null,
              icon: const Icon(Icons.edit_note),
              label: const Text('Compose a label'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _canPrint && !_loading && !_printing
                  ? () => unawaited(_printTestLabel())
                  : null,
              icon: _printing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.print_outlined),
              label: Text(_printing ? 'Sending…' : 'Print test label'),
            ),
            const SizedBox(height: 12),
            Text(
              'Label printing is local: the job goes straight to the printer '
              'over your network, no account or cloud.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

/// The media/error/reachability card, with designed loading and error states.
class _StatusCard extends StatelessWidget {
  final bool loading;
  final String? error;
  final BrotherQlStatusDto? status;
  final String host;
  final int port;

  const _StatusCard({
    required this.loading,
    required this.error,
    required this.status,
    required this.host,
    required this.port,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    Widget shell(Widget child) => Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: child,
    );

    if (loading) {
      return shell(
        Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 14),
            // Expanded so the line wraps at large text sizes instead of
            // overflowing past the spinner.
            Expanded(
              child: Text('Reading printer status…', style: text.bodyMedium),
            ),
          ],
        ),
      );
    }

    if (error != null) {
      return shell(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline, color: scheme.error),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                error!,
                style: text.bodyMedium?.copyWith(color: scheme.error),
              ),
            ),
          ],
        ),
      );
    }

    final s = status;
    if (s == null) {
      return shell(
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Printer reachable', style: text.titleMedium),
            const SizedBox(height: 6),
            Text(
              'Connected at $host:$port, but it did not report its status. '
              'Some firmware answers only while idle — a test label should still '
              'print.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      );
    }

    final mediaLabel = switch (s.mediaType) {
      'continuous' => '${s.mediaWidthMm} mm continuous',
      'die_cut' => '${s.mediaWidthMm}×${s.mediaLengthMm} mm die-cut',
      _ => 'No media loaded',
    };
    return shell(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                s.readyToPrint
                    ? Icons.check_circle_outline
                    : Icons.warning_amber,
                color: s.readyToPrint ? scheme.tertiary : scheme.error,
              ),
              const SizedBox(width: 10),
              Text(
                s.readyToPrint ? 'Ready to print' : 'Not ready',
                style: text.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          _row(context, 'Media', mediaLabel),
          if (s.errors.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                s.errors.join(' · '),
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, String label, String value) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          Expanded(child: Text(value, style: text.bodyMedium)),
        ],
      ),
    );
  }
}

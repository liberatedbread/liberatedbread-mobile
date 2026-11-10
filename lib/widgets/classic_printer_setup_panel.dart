// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import '../models/iot_device.dart';
import '../providers/classic_printer_provider.dart';
import '../providers/saved_device_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/classic_spp_service.dart';

class ClassicPrinterSetupPanel extends ConsumerStatefulWidget {
  final IoTDevice device;
  final String specYaml;
  final String specKey;

  const ClassicPrinterSetupPanel({
    super.key,
    required this.device,
    required this.specYaml,
    required this.specKey,
    this.protocolHandler = brotherQlHandler,
  });

  /// The spec's handler, which decides how the status is asked for and read.
  final String protocolHandler;

  @override
  ConsumerState<ClassicPrinterSetupPanel> createState() =>
      _ClassicPrinterSetupPanelState();
}

class _ClassicPrinterSetupPanelState
    extends ConsumerState<ClassicPrinterSetupPanel> {
  bool _busy = false;
  String? _error;
  _PanelStatus? _status;

  /// Ask for and read the status in the printer's own language: a QL's
  /// `ESC i S`, or a P-touch's invalidate + initialize + `ESC i S`.
  Future<_PanelStatus> _readStatus(ClassicSppService service) async {
    final codec = ref.read(specCodecProvider);
    if (widget.protocolHandler == brotherPtHandler) {
      final variant = await codec.rasterPrintVariantForName(
        specYaml: widget.specYaml,
        deviceName: widget.device.displayName,
      );
      final reply = await service.request(
        widget.device.id,
        await codec.brotherPtStatusRequest(
          specYaml: widget.specYaml,
          variant: variant,
        ),
      );
      final status = await codec.decodeBrotherPtStatus(reply: reply);
      return _PanelStatus(
        ready: status.readyToPrint,
        media: status.mediaWidthMm == 0
            ? 'No tape loaded'
            : '${status.mediaWidthMm} mm tape',
        errors: status.errors,
      );
    }
    final reply = await service.request(
      widget.device.id,
      await codec.brotherQlStatusRequest(),
    );
    final status = await codec.decodeBrotherQlStatus(reply: reply);
    return _PanelStatus(
      ready: status.readyToPrint,
      media: switch (status.mediaType) {
        'continuous' => '${status.mediaWidthMm} mm continuous media',
        'die_cut' =>
          '${status.mediaWidthMm}×${status.mediaLengthMm} mm '
              'die-cut labels',
        _ => 'No media loaded',
      },
      errors: status.errors,
    );
  }

  Future<void> _pairAndVerify() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final service = ref.read(classicSppServiceProvider);
    try {
      await service.pair(widget.device.id);
      if (!mounted) return;
      final status = await _readStatus(service);
      if (!mounted) return;
      setState(() => _status = status);
      Log.ble.info(
        'Classic SPP status verified for ${widget.device.id}: '
        '${status.media}, '
        '${status.errors.isEmpty ? 'no errors' : status.errors.join(', ')}',
      );
      try {
        final saved = ref.read(savedDevicesProvider.notifier);
        await saved.touch(
          id: widget.device.id,
          name: widget.device.displayName,
          seenAt: DateTime.now(),
        );
        await saved.recordMatch(
          id: widget.device.id,
          category: 'printer',
          specKey: widget.specKey,
        );
      } on Object catch (e) {
        Log.ble.debug('could not save the verified Classic printer', error: e);
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _status = null;
        _error = friendlyErrorText(
          e,
          context: 'Classic printer setup ${widget.device.id}',
          fallback: 'Could not verify the printer over Bluetooth SPP.',
        );
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = _status;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      children: [
        Icon(Icons.print_outlined, size: 52, color: scheme.secondary),
        const SizedBox(height: 16),
        Text(
          'Bluetooth Classic printer',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(
          'This printer has no BLE GATT interface. Pairing opens its Serial '
          'Port Profile instead; verification asks for its media and error '
          'status without printing anything.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 24),
        if (_error != null) ...[
          Text(
            _error!,
            textAlign: TextAlign.center,
            style: TextStyle(color: scheme.error),
          ),
          const SizedBox(height: 16),
        ],
        if (status != null) ...[
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      status.ready
                          ? Icons.check_circle_outline
                          : Icons.warning_amber,
                      color: status.ready ? scheme.tertiary : scheme.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        status.ready
                            ? 'Ready over Bluetooth SPP'
                            : 'Connected, but the printer needs attention',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(status.media),
                if (status.errors.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    status.errors.join(' · '),
                    style: TextStyle(color: scheme.error),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        FilledButton.icon(
          onPressed: _busy ? null : () => unawaited(_pairAndVerify()),
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.bluetooth_connected),
          label: Text(
            _busy
                ? 'Pairing and checking SPP…'
                : status == null
                ? 'Pair & verify'
                : 'Verify again',
          ),
        ),
      ],
    );
  }
}

/// What the panel shows of a status, whichever printer language it came in.
class _PanelStatus {
  final bool ready;
  final String media;
  final List<String> errors;

  const _PanelStatus({
    required this.ready,
    required this.media,
    required this.errors,
  });
}

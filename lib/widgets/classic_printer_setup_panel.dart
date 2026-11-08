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
import '../services/spec_codec.dart';

class ClassicPrinterSetupPanel extends ConsumerStatefulWidget {
  final IoTDevice device;
  final String specYaml;
  final String specKey;

  const ClassicPrinterSetupPanel({
    super.key,
    required this.device,
    required this.specYaml,
    required this.specKey,
  });

  @override
  ConsumerState<ClassicPrinterSetupPanel> createState() =>
      _ClassicPrinterSetupPanelState();
}

class _ClassicPrinterSetupPanelState
    extends ConsumerState<ClassicPrinterSetupPanel> {
  bool _busy = false;
  String? _error;
  BrotherQlStatusDto? _status;

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
      final codec = ref.read(specCodecProvider);
      final reply = await service.request(
        widget.device.id,
        await codec.brotherQlStatusRequest(),
      );
      final status = await codec.decodeBrotherQlStatus(reply: reply);
      if (!mounted) return;
      setState(() => _status = status);
      Log.ble.info(
        'Classic SPP status verified for ${widget.device.id}: '
        '${status.mediaType} ${status.mediaWidthMm} mm, '
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
                      status.readyToPrint
                          ? Icons.check_circle_outline
                          : Icons.warning_amber,
                      color: status.readyToPrint
                          ? scheme.tertiary
                          : scheme.error,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        status.readyToPrint
                            ? 'Ready over Bluetooth SPP'
                            : 'Connected, but the printer needs attention',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(switch (status.mediaType) {
                  'continuous' => '${status.mediaWidthMm} mm continuous media',
                  'die_cut' =>
                    '${status.mediaWidthMm}×${status.mediaLengthMm} mm '
                        'die-cut labels',
                  _ => 'No media loaded',
                }),
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

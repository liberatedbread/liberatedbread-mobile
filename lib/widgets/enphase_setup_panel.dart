// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import '../core/mono_text.dart';
import '../models/iot_device.dart';
import '../providers/enphase_provider.dart';
import '../providers/saved_device_provider.dart';
import '../services/enphase_ble_client.dart';

class EnphaseSetupPanel extends ConsumerStatefulWidget {
  final IoTDevice device;
  final String specKey;

  const EnphaseSetupPanel({
    super.key,
    required this.device,
    required this.specKey,
  });

  @override
  ConsumerState<EnphaseSetupPanel> createState() => _EnphaseSetupPanelState();
}

class _EnphaseSetupPanelState extends ConsumerState<EnphaseSetupPanel> {
  EnphaseClient? _activeClient;
  bool _busy = false;
  String? _error;
  EnphaseSessionReport? _report;

  Future<void> _unlockAndRead() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final client = ref.read(enphaseClientProvider)(widget.device.id);
    _activeClient = client;
    try {
      final report = await client.unlockAndRead();
      if (!mounted) return;
      setState(() => _report = report);
      try {
        final saved = ref.read(savedDevicesProvider.notifier);
        await saved.touch(
          id: widget.device.id,
          name: widget.device.displayName,
          seenAt: DateTime.now(),
        );
        await saved.recordMatch(
          id: widget.device.id,
          category: 'energy',
          specKey: widget.specKey,
        );
      } on Object catch (e) {
        Log.ble.debug('could not save the verified XBee link', error: e);
      }
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _report = null;
        _error = friendlyErrorText(
          e,
          context: 'Enphase BLE unlock ${widget.device.id}',
          fallback:
              'Could not unlock and read the XBee. Keep the unit powered '
              'and in range, then try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _busy = false);
      _activeClient = null;
    }
  }

  @override
  void dispose() {
    unawaited(_activeClient?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final report = _report;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
      children: [
        Icon(Icons.battery_charging_full, size: 52, color: scheme.secondary),
        const SizedBox(height: 16),
        Text(
          'Enphase Bluetooth access',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 12),
        Text(
          'Enpower and Encharge use a Digi XBee radio with an encrypted '
          'Bluetooth connection. There is no OS pairing prompt, pairing '
          'mode, or button to press.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: scheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'This check unlocks the link, then reads Zigbee pairing, '
          'commissioning, and gateway-serial status. It does not provision '
          'a site, change keys, reset the unit, or control relays.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.4),
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
        if (report != null) ...[
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
                    Icon(Icons.lock_open, color: scheme.tertiary),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Unlocked over encrypted XBee link',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                Text(
                  'The status encodings are not yet hardware-verified. '
                  'These are the raw payload bytes, without inferred values.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                for (final reply in report.replies) ...[
                  const Divider(height: 24),
                  Text(switch (reply.type) {
                    4 => 'Zigbee pairing status',
                    5 => 'Zigbee commissioning status',
                    8 => 'Gateway serial response',
                    _ => 'Status type ${reply.type}',
                  }, style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text('Source interface: ${reply.sourceInterface}'),
                  const SizedBox(height: 4),
                  SelectableText(
                    reply.payloadHex,
                    style: Theme.of(context).textTheme.bodyMedium?.monospaced,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 20),
        ],
        FilledButton.icon(
          onPressed: _busy ? null : () => unawaited(_unlockAndRead()),
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.lock_open),
          label: Text(
            _busy
                ? 'Unlocking and reading…'
                : report == null
                ? 'Unlock & read status'
                : 'Read status again',
          ),
        ),
      ],
    );
  }
}

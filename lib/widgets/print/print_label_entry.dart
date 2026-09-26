// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../providers/ble_provider.dart';
import '../../providers/spec_codec_provider.dart';
import '../../screens/print_label_screen.dart';
import '../../services/print/print_target.dart';
import '../../services/spec_codec.dart';

/// "Print a label" for a connected BLE raster printer — the way into the
/// label composer. Renders nothing for a device that is not a printer this
/// build can drive over BLE, so it can sit in any device panel.
class PrintLabelEntry extends ConsumerStatefulWidget {
  final String deviceId;
  final String specYaml;
  final String deviceName;

  const PrintLabelEntry({
    super.key,
    required this.deviceId,
    required this.specYaml,
    required this.deviceName,
  });

  @override
  ConsumerState<PrintLabelEntry> createState() => _PrintLabelEntryState();
}

class _PrintLabelEntryState extends ConsumerState<PrintLabelEntry> {
  RasterPrintDto? _raster;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(PrintLabelEntry old) {
    super.didUpdateWidget(old);
    if (old.specYaml != widget.specYaml) unawaited(_resolve());
  }

  Future<void> _resolve() async {
    try {
      final raster = await ref
          .read(specCodecProvider)
          .rasterPrintForSpec(specYaml: widget.specYaml);
      if (mounted) setState(() => _raster = raster);
    } on Object catch (e) {
      Log.spec.warning('raster print surface failed to resolve', error: e);
    }
  }

  void _open() {
    final raster = _raster!;
    final target = BleRasterTarget(
      codec: ref.read(specCodecProvider),
      ble: ref.read(bleServiceProvider),
      deviceId: widget.deviceId,
      specYaml: widget.specYaml,
      name: widget.deviceName,
      raster: raster,
    );
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PrintLabelScreen(target: target),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final raster = _raster;
    if (raster == null ||
        !raster.encodable ||
        raster.transport != 'ble_write_plan') {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _open,
          icon: const Icon(Icons.print_outlined),
          label: const Text('Print a label'),
        ),
      ),
    );
  }
}

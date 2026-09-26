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

  /// Which of the spec's variants the connected device is, when the panel
  /// has worked it out. A print surface scoped to other variants is not
  /// offered (a B21 matched to the NIIMBOT spec must not print a D110's
  /// 96-dot label); null or empty means unknown, and then it is.
  final Set<String>? matchedVariants;

  const PrintLabelEntry({
    super.key,
    required this.deviceId,
    required this.specYaml,
    required this.deviceName,
    this.matchedVariants,
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
    final variants = widget.matchedVariants;
    final otherModel =
        variants != null &&
        variants.isNotEmpty &&
        raster != null &&
        raster.variants.isNotEmpty &&
        !raster.variants.any(variants.contains);
    if (raster == null ||
        !raster.encodable ||
        raster.transport != 'ble_write_plan' ||
        otherModel) {
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

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/log.dart';
import '../../providers/ble_provider.dart';
import '../../providers/printer_provider.dart';
import '../../providers/spec_codec_provider.dart';
import '../../screens/print_label_screen.dart';
import '../../services/brother_ql_print_service.dart';
import '../../services/print/label_content.dart';
import '../../services/print/os_print_service.dart';
import '../../services/print/pdf_documents.dart';
import '../../services/print/print_target.dart';

/// An asset label for a device: its name and address, with the address as a
/// QR code so a phone can read it back off the sticker.
LabelContent deviceAssetLabel({required String name, required String address}) {
  final title = name.trim().isEmpty ? 'Device' : name.trim();
  return LabelContent(
    lines: [title, address],
    size: LabelTextSize.small,
    qrData: address,
  );
}

/// Pick one of the saved label printers, then open the composer on it with
/// [content] filled in. Tells the user when there is no printer to pick.
Future<void> printLabelOnSavedPrinter(
  BuildContext context,
  WidgetRef ref,
  LabelContent content,
) async {
  final picked = await _pickPrinter(context, ref);
  if (picked == null || !context.mounted) return;

  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  final LabelPrintTarget target;
  try {
    target = await _targetFor(ref, picked);
  } on Object catch (e) {
    Log.spec.warning('could not prepare "${picked.name}"', error: e);
    messenger.showSnackBar(
      SnackBar(content: Text('Could not prepare ${picked.name}.')),
    );
    return;
  }
  unawaited(
    navigator.push(
      MaterialPageRoute<void>(
        builder: (_) => PrintLabelScreen(target: target, initial: content),
      ),
    ),
  );
}

/// Pick a saved label printer, then open the composer in photo mode on
/// [bytes] — an image, or a PDF, which becomes its first page at the
/// printer's resolution.
Future<void> printFileOnSavedPrinter(
  BuildContext context,
  WidgetRef ref,
  Uint8List bytes,
) async {
  final picked = await _pickPrinter(context, ref);
  if (picked == null || !context.mounted) return;
  final navigator = Navigator.of(context);
  final messenger = ScaffoldMessenger.of(context);
  try {
    final target = await _targetFor(ref, picked);
    var photo = bytes;
    if (isPdf(bytes)) {
      final pages = await ref
          .read(osPrintServiceProvider)
          .rasterizePdf(bytes, dpi: target.geometry.dpi);
      if (pages.isEmpty) throw StateError('the PDF has no pages');
      photo = pages.first;
    }
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PrintLabelScreen(target: target, initialPhoto: photo),
        ),
      ),
    );
  } on Object catch (e) {
    Log.spec.warning('could not prepare "${picked.name}"', error: e);
    messenger.showSnackBar(
      SnackBar(content: Text('Could not prepare ${picked.name}.')),
    );
  }
}

/// The saved printer to use: the only one, or the user's pick; null when
/// there is none (the user is told) or the sheet was dismissed.
Future<SavedPrinter?> _pickPrinter(BuildContext context, WidgetRef ref) async {
  final printers = await ref.read(savedPrintersProvider.future);
  if (!context.mounted) return null;
  if (printers.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Save a label printer first — connect to it once and it will be '
          'offered here.',
        ),
      ),
    );
    return null;
  }
  if (printers.length == 1) return printers.single;
  return showModalBottomSheet<SavedPrinter>(
    context: context,
    showDragHandle: true,
    builder: (context) => _PrinterPicker(printers: printers),
  );
}

Future<LabelPrintTarget> _targetFor(WidgetRef ref, SavedPrinter printer) async {
  final codec = ref.read(specCodecProvider);
  final ble = printer.ble;
  if (ble != null) {
    return ConnectingBleTarget(
      BleRasterTarget(
        codec: codec,
        ble: ref.read(bleServiceProvider),
        deviceId: ble.id,
        specYaml: printer.specYaml,
        name: printer.name,
        raster: printer.raster,
      ),
    );
  }
  final network = printer.network!;
  final transport = ref.read(brotherQlPrintServiceProvider);
  final port = network.port ?? 9100;
  final status = await readBrotherStatus(
    codec: codec,
    transport: transport,
    host: network.host,
    port: port,
  );
  return BrotherQlTarget.resolve(
    codec: codec,
    transport: transport,
    specYaml: printer.specYaml,
    host: network.host,
    port: port,
    params: brotherParamsFor(status),
    name: printer.name,
  );
}

class _PrinterPicker extends StatelessWidget {
  final List<SavedPrinter> printers;

  const _PrinterPicker({required this.printers});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Print on',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          for (final printer in printers)
            ListTile(
              leading: Icon(printer.isBle ? Icons.bluetooth : Icons.wifi),
              title: Text(printer.name),
              subtitle: Text(
                printer.isBle ? 'Bluetooth' : printer.network!.host,
              ),
              onTap: () => Navigator.of(context).pop(printer),
            ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

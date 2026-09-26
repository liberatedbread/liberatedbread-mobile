// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../core/log.dart';
import '../providers/printer_provider.dart';
import '../services/print/os_print_service.dart';
import '../services/print/pdf_documents.dart';
import '../services/share_in_service.dart';
import '../widgets/print/printer_picker_sheet.dart';

/// "Print this" for a photo or PDF another app shared in: on a saved label
/// printer (through the composer's photo mode, a PDF as its first page) or
/// on a regular printer through the system print dialog.
class PrintSharedFileScreen extends ConsumerWidget {
  final SharedFile file;

  const PrintSharedFileScreen({super.key, required this.file});

  bool get _isPdf => isPdf(file.bytes);

  Future<void> _onPaper(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref
          .read(osPrintServiceProvider)
          .printDocument(
            name: file.name ?? (_isPdf ? 'Document' : 'Photo'),
            build: (format) =>
                _isPdf ? Future.value(file.bytes) : _photoPage(format),
          );
    } on Object catch (e) {
      Log.app.warning('printing a shared file failed', error: e);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the print dialog.')),
      );
    }
  }

  /// A photo fitted to one page of [format].
  Future<Uint8List> _photoPage(PdfPageFormat format) {
    final doc = pw.Document(creator: 'Liberated Bread');
    final image = pw.MemoryImage(file.bytes);
    doc.addPage(
      pw.Page(
        pageFormat: format,
        margin: const pw.EdgeInsets.all(24),
        build: (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
      ),
    );
    return doc.save();
  }

  Future<void> _onLabel(BuildContext context, WidgetRef ref) async {
    await printFileOnSavedPrinter(context, ref, file.bytes);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final hasLabelPrinter =
        ref.watch(savedPrintersProvider).valueOrNull?.isNotEmpty ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Print')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            Row(
              children: [
                Icon(
                  _isPdf ? Icons.picture_as_pdf_outlined : Icons.image_outlined,
                  color: scheme.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    file.name ?? (_isPdf ? 'A PDF document' : 'A photo'),
                    style: text.titleMedium,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: hasLabelPrinter
                  ? () => unawaited(_onLabel(context, ref))
                  : null,
              icon: const Icon(Icons.label_outline),
              label: const Text('On a label printer'),
            ),
            if (!hasLabelPrinter)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  'Save a label printer first — connect to it once and it '
                  'will be offered here.',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: () => unawaited(_onPaper(context, ref)),
              icon: const Icon(Icons.local_printshop_outlined),
              label: const Text('On a regular printer'),
            ),
          ],
        ),
      ),
    );
  }
}

/// Opens [PrintSharedFileScreen] for every file shared into the app — the
/// one it was launched with, and any that arrive while it runs. Sits just
/// under the navigator, around the home shell.
class ShareInListener extends ConsumerStatefulWidget {
  final Widget child;

  const ShareInListener({super.key, required this.child});

  @override
  ConsumerState<ShareInListener> createState() => _ShareInListenerState();
}

class _ShareInListenerState extends ConsumerState<ShareInListener> {
  StreamSubscription<SharedFile>? _subscription;

  @override
  void initState() {
    super.initState();
    final service = ref.read(shareInServiceProvider);
    _subscription = service.incoming.listen(_open);
    unawaited(
      service.initialShare().then((file) {
        if (file != null) _open(file);
      }),
    );
  }

  void _open(SharedFile file) {
    if (!mounted) return;
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PrintSharedFileScreen(file: file),
        ),
      ),
    );
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

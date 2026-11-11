// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

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
      // Read before the dialog opens: a photo that cannot be read fails
      // here, into the message below, rather than inside the dialog's layout
      // callback where it is an empty preview.
      final image = _isPdf ? null : await _photoImage();
      await ref
          .read(osPrintServiceProvider)
          .printDocument(
            name: file.name ?? (_isPdf ? 'Document' : 'Photo'),
            build: (format) => image == null
                ? Future.value(file.bytes)
                : _photoPage(format, image),
          );
    } on Object catch (e) {
      Log.app.warning('printing a shared file failed', error: e);
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not open the print dialog.')),
      );
    }
  }

  /// A photo fitted to one page of [format].
  ///
  /// The PDF library reads JPEG and PNG itself, and little else: an iPhone's
  /// camera photo is HEIC. What it cannot read the platform's own decoder
  /// usually can (it is what the label path uses), so that is the fallback,
  /// at no more than a page's worth of pixels.
  Future<pw.ImageProvider> _photoImage() async {
    try {
      return pw.MemoryImage(file.bytes);
    } on Object {
      final buffer = await ui.ImmutableBuffer.fromUint8List(file.bytes);
      final descriptor = await ui.ImageDescriptor.encoded(buffer);
      try {
        final landscape = descriptor.width >= descriptor.height;
        final longest = landscape ? descriptor.width : descriptor.height;
        final target = longest > _maxPhotoSide ? _maxPhotoSide : null;
        final codec = await descriptor.instantiateCodec(
          targetWidth: landscape ? target : null,
          targetHeight: landscape ? null : target,
        );
        final frame = await codec.getNextFrame();
        codec.dispose();
        try {
          final png = await frame.image.toByteData(
            format: ui.ImageByteFormat.png,
          );
          if (png == null) throw StateError('the photo would not re-encode');
          return pw.MemoryImage(png.buffer.asUint8List());
        } finally {
          frame.image.dispose();
        }
      } finally {
        descriptor.dispose();
        buffer.dispose();
      }
    }
  }

  /// A4 at 300 dpi along its long side, near enough.
  static const _maxPhotoSide = 3508;

  Future<Uint8List> _photoPage(PdfPageFormat format, pw.ImageProvider image) {
    final doc = pw.Document(creator: 'Liberated Bread');
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
    final waiting = service.takeWaiting();
    if (waiting != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _open(waiting));
    }
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

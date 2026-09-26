// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';

/// The operating system's own print path — AirPrint on iOS, the Android print
/// service, the GTK/CUPS dialog on Linux — for regular printers, plus the
/// PDF rasteriser a label printer needs to print a document page.
///
/// Printing to an office or home printer is deliberately the OS's job: it
/// already speaks every driverless printer on the network, and duplicating
/// that would be a worse copy. Tests override the provider.
abstract class OsPrintService {
  /// Open the system print dialog on a document [build] lays out for the
  /// paper the user picks. True when the job was handed to a printer, false
  /// when the dialog was cancelled.
  Future<bool> printDocument({
    required String name,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  });

  /// The first [maxPages] pages of [pdf] as PNGs at [dpi] — how a PDF gets
  /// onto a label printer, whose encoder takes pixels.
  Future<List<Uint8List>> rasterizePdf(
    Uint8List pdf, {
    required int dpi,
    int maxPages = 1,
  });
}

class PlatformOsPrintService implements OsPrintService {
  const PlatformOsPrintService();

  @override
  Future<bool> printDocument({
    required String name,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  }) => Printing.layoutPdf(name: name, onLayout: build);

  @override
  Future<List<Uint8List>> rasterizePdf(
    Uint8List pdf, {
    required int dpi,
    int maxPages = 1,
  }) async {
    final pages = <Uint8List>[];
    await for (final page in Printing.raster(
      pdf,
      pages: [for (var i = 0; i < maxPages; i++) i],
      dpi: dpi.toDouble(),
    )) {
      pages.add(await page.toPng());
    }
    return pages;
  }
}

final osPrintServiceProvider = Provider<OsPrintService>(
  (ref) => const PlatformOsPrintService(),
);

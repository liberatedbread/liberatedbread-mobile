// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:liberated_bread_mobile/services/print/os_print_service.dart';
import 'package:pdf/pdf.dart';

/// Records print-dialog jobs (building each document on A4, the way the
/// dialog would) and answers rasterisation from a canned page.
class FakeOsPrintService implements OsPrintService {
  final List<Uint8List> pages;
  FakeOsPrintService({this.pages = const []});

  final jobs = <({String name, Uint8List pdf})>[];
  final rasterized = <({int dpi, int length})>[];

  @override
  Future<bool> printDocument({
    required String name,
    required Future<Uint8List> Function(PdfPageFormat format) build,
  }) async {
    jobs.add((name: name, pdf: await build(PdfPageFormat.a4)));
    return true;
  }

  @override
  Future<List<Uint8List>> rasterizePdf(
    Uint8List pdf, {
    required int dpi,
    int maxPages = 1,
  }) async {
    rasterized.add((dpi: dpi, length: pdf.length));
    return pages;
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The PDFs handed to the system print dialog.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/print/pdf_documents.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:pdf/pdf.dart';

bool _looksLikePdf(Uint8List b) => ascii.decode(b.sublist(0, 5)) == '%PDF-';

void main() {
  test('pdfSafe keeps Latin-1 and maps the catalogue punctuation', () {
    expect(pdfSafe('Café — “quoted” … ok'), 'Café - "quoted" ... ok');
    expect(pdfSafe('line1\nline2\tx'), 'line1\nline2\tx');
    expect(pdfSafe('日本'), '??');
  });

  test('isPdf reads the signature, not a name', () {
    expect(isPdf(Uint8List.fromList(ascii.encode('%PDF-1.7'))), isTrue);
    expect(isPdf(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47])), isFalse);
    expect(isPdf(Uint8List(2)), isFalse);
  });

  test('a text document spans pages and survives any text', () async {
    final pdf = await textDocumentPdf(
      format: PdfPageFormat.a4,
      title: 'Diagnostics — today',
      subtitle: '3 line(s)',
      sections: [
        (
          heading: null,
          paragraphs: [for (var i = 0; i < 400; i++) 'line $i … “x” 日本'],
        ),
      ],
      monospace: true,
    );
    expect(_looksLikePdf(pdf), isTrue);
  });

  test('setup instructions print every section', () async {
    const instructions = SetupInstructionsDto(
      notes: 'Overview — with a dash.',
      methods: [
        SetupMethodDto(
          name: 'Pairing',
          description: 'Hold the button.',
          steps: [SetupStepDto(action: 'Hold for 5 s', expect: 'LED blinks')],
          stages: [],
          troubleshooting: [
            TroubleshootingDto(symptom: 'No LED', causes: ['Battery flat']),
          ],
        ),
      ],
      rejoin: RejoinDto(notes: 'One phone at a time.'),
    );
    final pdf = await setupInstructionsPdf(
      format: PdfPageFormat.letter,
      deviceName: 'Ember Mug',
      instructions: instructions,
    );
    expect(_looksLikePdf(pdf), isTrue);
  });

  test('a label prints at its physical size', () async {
    final pdf = await labelImagePdf(
      format: PdfPageFormat.a4,
      rgb: Uint8List(96 * 40 * 3),
      width: 96,
      height: 40,
      dpi: 203,
    );
    expect(_looksLikePdf(pdf), isTrue);
  });
}

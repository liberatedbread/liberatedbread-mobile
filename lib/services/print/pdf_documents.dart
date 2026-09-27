// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../spec_codec.dart';

/// Whether [bytes] is a PDF (by its `%PDF` signature, which is what a
/// shared or picked file's name cannot be trusted to say).
bool isPdf(Uint8List bytes) =>
    bytes.length >= 4 &&
    bytes[0] == 0x25 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x44 &&
    bytes[3] == 0x46;

/// One titled block of a printed document.
typedef PdfSection = ({String? heading, List<String> paragraphs});

/// The built-in PDF fonts are Latin-1 only, and the app's text is not: the
/// catalogue writes em dashes, curly quotes and ellipses throughout. Map the
/// common ones to their plain forms and drop what cannot print, rather than
/// print boxes.
String pdfSafe(String text) {
  const replacements = {
    '—': '-', // em dash
    '–': '-', // en dash
    '‘': "'",
    '’': "'",
    '“': '"',
    '”': '"',
    '…': '...',
    '•': '*',
    '→': '->',
    ' ': ' ',
    '‑': '-',
    '−': '-',
  };
  final out = StringBuffer();
  for (final rune in text.runes) {
    final char = String.fromCharCode(rune);
    final mapped = replacements[char];
    if (mapped != null) {
      out.write(mapped);
    } else if (rune == 0x0A || rune == 0x09 || (rune >= 0x20 && rune <= 0xFF)) {
      out.write(char);
    } else {
      out.write('?');
    }
  }
  return out.toString();
}

/// A plain printed document: a title, an optional subtitle, and sections of
/// paragraphs, flowing across as many pages of [format] as it needs.
/// [monospace] is for logs, where columns line up.
Future<Uint8List> textDocumentPdf({
  required PdfPageFormat format,
  required String title,
  String? subtitle,
  required List<PdfSection> sections,
  bool monospace = false,
}) {
  final doc = pw.Document(title: pdfSafe(title), creator: 'Liberated Bread');
  final body = monospace ? pw.Font.courier() : pw.Font.helvetica();
  final bold = pw.Font.helveticaBold();
  doc.addPage(
    pw.MultiPage(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(40),
      build: (context) => [
        pw.Text(pdfSafe(title), style: pw.TextStyle(font: bold, fontSize: 18)),
        if (subtitle != null) ...[
          pw.SizedBox(height: 4),
          pw.Text(
            pdfSafe(subtitle),
            style: pw.TextStyle(
              font: pw.Font.helvetica(),
              fontSize: 10,
              color: PdfColors.grey700,
            ),
          ),
        ],
        pw.SizedBox(height: 16),
        for (final section in sections) ...[
          if (section.heading != null) ...[
            pw.Text(
              pdfSafe(section.heading!),
              style: pw.TextStyle(font: bold, fontSize: 13),
            ),
            pw.SizedBox(height: 6),
          ],
          for (final paragraph in section.paragraphs)
            pw.Padding(
              padding: const pw.EdgeInsets.only(bottom: 6),
              child: pw.Text(
                pdfSafe(paragraph),
                style: pw.TextStyle(
                  font: body,
                  fontSize: monospace ? 8 : 10.5,
                  lineSpacing: 1.5,
                ),
              ),
            ),
          pw.SizedBox(height: 10),
        ],
      ],
    ),
  );
  return doc.save();
}

/// A device's setup and troubleshooting notes as a printed page — the same
/// order the screen shows them in.
Future<Uint8List> setupInstructionsPdf({
  required PdfPageFormat format,
  required String deviceName,
  required SetupInstructionsDto instructions,
}) {
  String step(SetupStepDto s, int i) => [
    '${i + 1}. ${s.action}',
    if (s.expect != null && s.expect!.trim().isNotEmpty)
      '   Expect: ${s.expect!.trim()}',
  ].join('\n');

  final troubleshooting = [
    for (final m in instructions.methods) ...[
      ...m.troubleshooting,
      for (final stage in m.stages) ...stage.troubleshooting,
    ],
  ];
  final rejoin = instructions.rejoin?.notes?.trim();
  final reset = instructions.factoryReset;

  return textDocumentPdf(
    format: format,
    title: deviceName,
    subtitle: 'Setup & troubleshooting',
    sections: [
      if (rejoin != null && rejoin.isNotEmpty)
        (heading: 'Reconnecting', paragraphs: [rejoin]),
      if (troubleshooting.isNotEmpty)
        (
          heading: "If it won't connect",
          paragraphs: [
            for (final t in troubleshooting)
              [t.symptom, for (final c in t.causes) '  - $c'].join('\n'),
          ],
        ),
      if ((instructions.notes ?? '').trim().isNotEmpty)
        (heading: 'Overview', paragraphs: [instructions.notes!.trim()]),
      for (final method in instructions.methods)
        if (method.description != null ||
            method.steps.isNotEmpty ||
            method.stages.isNotEmpty)
          (
            heading: method.name ?? 'Setup',
            paragraphs: [
              if (method.description != null) method.description!.trim(),
              for (final (i, s) in method.steps.indexed) step(s, i),
              for (final stage in method.stages) ...[
                if (stage.name != null) stage.name!,
                if (stage.description != null) stage.description!.trim(),
                for (final (i, s) in stage.steps.indexed) step(s, i),
              ],
            ],
          ),
      if (reset != null)
        (
          heading: 'Factory reset',
          paragraphs: [
            if (reset.effect != null) reset.effect!.trim(),
            for (final p in reset.procedures) ...[
              [
                p.name,
                if (p.holdSeconds != null) '(hold ${p.holdSeconds} s)',
              ].join(' '),
              for (final (i, s) in p.steps.indexed) step(s, i),
            ],
          ],
        ),
    ],
  );
}

/// A composed label on a regular printer: one page of [format] with the
/// label at its true physical size (its dots at [dpi]) in the top-left
/// corner, for a sheet of sticker paper or to cut out.
Future<Uint8List> labelImagePdf({
  required PdfPageFormat format,
  required Uint8List rgb,
  required int width,
  required int height,
  required int dpi,
}) {
  final rgba = Uint8List(width * height * 4);
  for (var i = 0; i < width * height; i++) {
    rgba[i * 4] = rgb[i * 3];
    rgba[i * 4 + 1] = rgb[i * 3 + 1];
    rgba[i * 4 + 2] = rgb[i * 3 + 2];
    rgba[i * 4 + 3] = 255;
  }
  final image = pw.RawImage(bytes: rgba, width: width, height: height);
  final doc = pw.Document(creator: 'Liberated Bread');
  doc.addPage(
    pw.Page(
      pageFormat: format,
      margin: const pw.EdgeInsets.all(36),
      build: (context) => pw.Align(
        alignment: pw.Alignment.topLeft,
        child: pw.SizedBox(
          // Points are 1/72 in; a dot is 1/dpi in.
          width: width * 72 / dpi,
          height: height * 72 / dpi,
          child: pw.Image(image, fit: pw.BoxFit.fill),
        ),
      ),
    ),
  );
  return doc.save();
}

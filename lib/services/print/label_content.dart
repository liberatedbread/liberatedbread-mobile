// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/foundation.dart' show immutable, listEquals;

/// How big a label's text is, in millimetres of line height. Resolved against
/// the target's dpi so the same choice reads the same on a 203 dpi thermal
/// roll and a 300 dpi Brother.
enum LabelTextSize {
  small(3),
  medium(5),
  large(8);

  const LabelTextSize(this.lineHeightMm);
  final double lineHeightMm;
}

/// What goes on a label: up to four lines of text, an optional date line and
/// an optional QR code. The composer edits one of these; the renderer turns it
/// into pixels at a printer's real dot width.
@immutable
class LabelContent {
  /// The most text lines a label takes — beyond four, a 12 mm tape is
  /// unreadable and a 62 mm one is a document.
  static const maxLines = 4;

  final List<String> lines;
  final LabelTextSize size;

  /// A pre-formatted date to print as the last line, or null for none. The
  /// caller formats it (with the locale it has) so the renderer stays pure.
  final String? dateLine;

  /// Text or a link to encode as a QR code beside the text, or null.
  final String? qrData;

  /// Lay the text along the tape (rotated 90°) rather than across the head.
  /// Narrow tapes want this: across a 12 mm head, a line fits three letters.
  final bool alongTape;

  const LabelContent({
    this.lines = const [''],
    this.size = LabelTextSize.medium,
    this.dateLine,
    this.qrData,
    this.alongTape = false,
  });

  /// The lines that print: the non-blank text lines, then the date.
  List<String> get printedLines => [
    for (final line in lines)
      if (line.trim().isNotEmpty) line.trim(),
    if (dateLine != null && dateLine!.trim().isNotEmpty) dateLine!.trim(),
  ];

  bool get hasQr => qrData != null && qrData!.trim().isNotEmpty;

  /// Whether printing this would put anything on the label.
  bool get isEmpty => printedLines.isEmpty && !hasQr;

  LabelContent copyWith({
    List<String>? lines,
    LabelTextSize? size,
    String? Function()? dateLine,
    String? Function()? qrData,
    bool? alongTape,
  }) => LabelContent(
    lines: lines ?? this.lines,
    size: size ?? this.size,
    dateLine: dateLine != null ? dateLine() : this.dateLine,
    qrData: qrData != null ? qrData() : this.qrData,
    alongTape: alongTape ?? this.alongTape,
  );

  @override
  bool operator ==(Object other) =>
      other is LabelContent &&
      listEquals(other.lines, lines) &&
      other.size == size &&
      other.dateLine == dateLine &&
      other.qrData == qrData &&
      other.alongTape == alongTape;

  @override
  int get hashCode =>
      Object.hash(Object.hashAll(lines), size, dateLine, qrData, alongTape);
}

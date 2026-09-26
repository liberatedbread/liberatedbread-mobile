// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/painting.dart';
import 'package:qr/qr.dart';

import 'label_content.dart';
import 'print_target.dart';

/// A label painted at the printer's real resolution, in head coordinates:
/// [width] dots across the head, [height] rows along the feed, RGBA with
/// straight alpha. Black on white; the codec reduces it to two colours.
@immutable
class RenderedLabel {
  final int width;
  final int height;
  final Uint8List rgba;

  const RenderedLabel({
    required this.width,
    required this.height,
    required this.rgba,
  });
}

/// The longest continuous label the composer will lay out, in dots. Far past
/// any sticker anyone means to print; it bounds a runaway layout instead.
const _maxLengthDots = 12000;

/// Paint [content] for a printer of [geometry].
///
/// The layout is a QR code (when there is one) beside a centred block of
/// text lines, inside a margin of about 1.5 mm. The dimension across the head
/// is always the printer's width; the dimension along the feed is the die-cut
/// label's length, or whatever the content needs on continuous stock. Text
/// shrinks to fit a fixed dimension, never grows past the chosen size.
///
/// With [LabelContent.alongTape] the same layout is drawn rotated 90°, so
/// lines run along the tape — the only readable way to use a 12 mm head.
Future<RenderedLabel> renderLabel(
  LabelContent content,
  LabelGeometry geometry,
) async {
  final dpi = geometry.dpi;
  final pad = math.max(2, (dpi * 1.5 / 25.4).round());
  final across = geometry.widthDots;
  final along = geometry.lengthDots;

  // Design space: the orientation the label is read in.
  final int? fixedW = content.alongTape ? along : across;
  final int? fixedH = content.alongTape ? across : along;

  final lines = content.printedLines;
  var fontPx = content.size.lineHeightMm * dpi / 25.4;

  List<TextPainter> layOut(double px) => [
    for (final line in lines)
      TextPainter(
        text: TextSpan(
          text: line,
          style: TextStyle(
            fontSize: px,
            height: 1.15,
            fontWeight: FontWeight.w600,
            color: const Color(0xFF000000),
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(),
  ];

  double blockWidth(List<TextPainter> ps) =>
      ps.fold(0.0, (w, p) => math.max(w, p.width));
  double blockHeight(List<TextPainter> ps) =>
      ps.fold(0.0, (h, p) => h + p.height);

  QrImage? qr;
  if (content.hasQr) {
    try {
      qr = QrImage(
        QrCode(
          payload: QrPayload.fromString(content.qrData!.trim()),
          errorCorrectLevel: QrErrorCorrectLevel.medium,
        ),
      );
    } on Object {
      // Too long for any QR version: print the text without it rather than
      // fail the whole label. The composer warns before it gets here.
      qr = null;
    }
  }

  var painters = layOut(fontPx);
  final gap = pad;
  final hasText = painters.isNotEmpty;

  double qrSideFor(List<TextPainter> ps) {
    if (qr == null) return 0;
    var side = fixedH != null
        ? (fixedH - 2 * pad).toDouble()
        : math.max(blockHeight(ps), fontPx * 3);
    if (fixedW != null) {
      final room = (fixedW - 2 * pad).toDouble();
      side = math.min(side, hasText ? room * 0.45 : room);
    }
    return math.max(0, side);
  }

  // Shrink the text to fit whichever dimensions are fixed. Two passes: the
  // QR side depends on the text height when the height is free.
  for (var pass = 0; pass < 2 && hasText; pass++) {
    final qrSide = qrSideFor(painters);
    var scale = 1.0;
    if (fixedW != null) {
      final room = fixedW - 2 * pad - (qr != null ? qrSide + gap : 0);
      final w = blockWidth(painters);
      if (w > room && w > 0) scale = math.min(scale, math.max(room, 1) / w);
    }
    if (fixedH != null) {
      final room = (fixedH - 2 * pad).toDouble();
      final h = blockHeight(painters);
      if (h > room && h > 0) scale = math.min(scale, math.max(room, 1) / h);
    }
    if (scale >= 1.0) break;
    for (final p in painters) {
      p.dispose();
    }
    fontPx = math.max(4, fontPx * scale * 0.98);
    painters = layOut(fontPx);
  }

  final qrSide = qrSideFor(painters);
  final textW = blockWidth(painters);
  final textH = blockHeight(painters);
  final contentW = qrSide + (qr != null && hasText ? gap : 0) + textW;
  final contentH = math.max(qrSide, textH);

  final designW = (fixedW ?? (contentW + 2 * pad).ceil())
      .clamp(1, _maxLengthDots)
      .toInt();
  final designH = (fixedH ?? (contentH + 2 * pad).ceil())
      .clamp(1, _maxLengthDots)
      .toInt();

  final headW = across;
  final headH = content.alongTape ? designW : designH;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  canvas.drawRect(
    Rect.fromLTWH(0, 0, headW.toDouble(), headH.toDouble()),
    Paint()..color = const Color(0xFFFFFFFF),
  );
  if (content.alongTape) {
    // Design x runs down the feed, design y across the head.
    canvas.translate(headW.toDouble(), 0);
    canvas.rotate(math.pi / 2);
  }

  // Centre the QR + text group in the design canvas.
  final left = math.max(pad.toDouble(), (designW - contentW) / 2);
  if (qr != null && qrSide > 0) {
    final count = qr.moduleCount;
    // One module of quiet zone each side, inside the label's own margin.
    final module = math.max(1, (qrSide / (count + 2)).floor()).toDouble();
    final drawn = module * (count + 2);
    final ox = left + (qrSide - drawn) / 2 + module;
    final oy = (designH - drawn) / 2 + module;
    final black = Paint()..color = const Color(0xFF000000);
    for (var r = 0; r < count; r++) {
      for (var c = 0; c < count; c++) {
        if (qr.isDark(r, c)) {
          canvas.drawRect(
            Rect.fromLTWH(ox + c * module, oy + r * module, module, module),
            black,
          );
        }
      }
    }
  }
  if (hasText) {
    final textLeft = left + (qr != null ? qrSide + gap : 0);
    var y = (designH - textH) / 2;
    for (final p in painters) {
      // Centred under each other when alone; flush left beside a QR code.
      final x = qr != null ? textLeft : textLeft + (textW - p.width) / 2;
      p.paint(canvas, Offset(x, y));
      y += p.height;
    }
  }

  final picture = recorder.endRecording();
  final image = await picture.toImage(headW, headH);
  try {
    final data = await image.toByteData(
      format: ui.ImageByteFormat.rawStraightRgba,
    );
    return RenderedLabel(
      width: headW,
      height: headH,
      rgba: data!.buffer.asUint8List(),
    );
  } finally {
    // Native memory the Dart heap does not see; the composer re-renders on
    // every keystroke.
    image.dispose();
    picture.dispose();
    for (final p in painters) {
      p.dispose();
    }
  }
}

/// Whether [data] fits in a QR code at all (version 40, medium correction).
bool fitsInQr(String data) {
  try {
    QrCode(
      payload: QrPayload.fromString(data),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    );
    return true;
  } on Object {
    return false;
  }
}

/// Paint a photo for a printer of [geometry], in head coordinates like
/// [renderLabel]: filling the head's width (or, [alongTape], its length
/// along the tape) and keeping its aspect; on a die-cut label, fitted inside
/// the label. Grey stays grey here — the codec's dithering turns it into
/// dot density.
///
/// Throws when [encoded] is not an image Flutter can decode.
Future<RenderedLabel> renderPhoto(
  Uint8List encoded,
  LabelGeometry geometry, {
  bool alongTape = false,
}) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(encoded);
  final descriptor = await ui.ImageDescriptor.encoded(buffer);
  try {
    final iw = descriptor.width;
    final ih = descriptor.height;
    final across = geometry.widthDots;
    final along = geometry.lengthDots;
    // Design space: the orientation the photo is seen in.
    final fixedW = alongTape ? along : across;
    final fixedH = alongTape ? across : along;

    // Scale to fill the fixed cross dimension, then fit the other one when
    // it is fixed too (die-cut).
    var scale = alongTape ? across / ih : across / iw;
    if (fixedW != null && iw * scale > fixedW) scale = fixedW / iw;
    if (fixedH != null && ih * scale > fixedH) scale = fixedH / ih;
    final drawW = math.max(1, (iw * scale).round());
    final drawH = math.max(1, (ih * scale).round());
    final designW = (fixedW ?? drawW).clamp(1, _maxLengthDots).toInt();
    final designH = (fixedH ?? drawH).clamp(1, _maxLengthDots).toInt();

    // Decode at the size it prints: a 12-megapixel photo is 48 MB of RGBA
    // that a 384-dot head would throw away.
    final codec = await descriptor.instantiateCodec(
      targetWidth: drawW,
      targetHeight: drawH,
    );
    final frame = await codec.getNextFrame();
    codec.dispose();
    final photo = frame.image;

    final headW = across;
    final headH = alongTape ? designW : designH;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, headW.toDouble(), headH.toDouble()),
      Paint()..color = const Color(0xFFFFFFFF),
    );
    if (alongTape) {
      canvas.translate(headW.toDouble(), 0);
      canvas.rotate(math.pi / 2);
    }
    canvas.drawImage(
      photo,
      Offset((designW - drawW) / 2, (designH - drawH) / 2),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final image = await picture.toImage(headW, headH);
    try {
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      return RenderedLabel(
        width: headW,
        height: headH,
        rgba: data!.buffer.asUint8List(),
      );
    } finally {
      image.dispose();
      picture.dispose();
      photo.dispose();
    }
  } finally {
    descriptor.dispose();
    buffer.dispose();
  }
}

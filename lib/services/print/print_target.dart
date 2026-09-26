// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

import '../brother_ql_print_service.dart';
import '../spec_codec.dart';

/// The canvas a label printer prints: dots across the head, the fixed length
/// of one die-cut label (null for continuous stock), and resolution.
@immutable
class LabelGeometry {
  final int widthDots;
  final int? lengthDots;
  final int dpi;

  /// The loaded roll's name, for the composer's header, when known.
  final String? mediaName;

  const LabelGeometry({
    required this.widthDots,
    required this.dpi,
    this.lengthDots,
    this.mediaName,
  });

  /// Continuous stock with no content yet still needs some length to show.
  int get defaultLengthDots => lengthDots ?? (dpi * 30 / 25.4).round();
}

/// How a print went. Like the transports underneath, a target never throws:
/// every failure is a result the print button can show.
sealed class PrintOutcome {
  const PrintOutcome();
}

class PrintOk extends PrintOutcome {
  const PrintOk();
}

class PrintFailed extends PrintOutcome {
  final String reason;
  const PrintFailed(this.reason);
}

/// A printer the label composer can print to.
abstract class LabelPrintTarget {
  /// The printer's name, for the composer's title.
  String get name;

  LabelGeometry get geometry;

  /// Print [copies] of a black-and-white RGB888 label of [width] x [height]
  /// (the output of [SpecCodec.prepareMonoRaster], at most
  /// [LabelGeometry.widthDots] wide).
  Future<PrintOutcome> printMono(
    Uint8List rgb,
    int width,
    int height, {
    int copies = 1,
  });
}

/// A Brother QL on the network: the job is encoded in Rust for the loaded
/// media and written to the raw TCP stream.
class BrotherQlTarget implements LabelPrintTarget {
  final SpecCodec codec;
  final BrotherQlPrintService transport;
  final String specYaml;
  final String host;
  final int port;
  final BrotherQlJobParamsDto params;

  @override
  final String name;

  @override
  final LabelGeometry geometry;

  BrotherQlTarget({
    required this.codec,
    required this.transport,
    required this.specYaml,
    required this.host,
    required this.port,
    required this.params,
    required this.name,
    required LabelCanvasDto canvas,
  }) : geometry = LabelGeometry(
         widthDots: canvas.widthDots,
         lengthDots: canvas.lengthDots,
         dpi: canvas.dpi,
         mediaName: canvas.mediaName,
       );

  /// Resolve the canvas for [params] and build the target.
  static Future<BrotherQlTarget> resolve({
    required SpecCodec codec,
    required BrotherQlPrintService transport,
    required String specYaml,
    required String host,
    required int port,
    required BrotherQlJobParamsDto params,
    required String name,
  }) async => BrotherQlTarget(
    codec: codec,
    transport: transport,
    specYaml: specYaml,
    host: host,
    port: port,
    params: params,
    name: name,
    canvas: await codec.brotherQlLabelCanvas(
      specYaml: specYaml,
      params: params,
    ),
  );

  @override
  Future<PrintOutcome> printMono(
    Uint8List rgb,
    int width,
    int height, {
    int copies = 1,
  }) async {
    final Uint8List job;
    try {
      job = await codec.renderBrotherQlJob(
        specYaml: specYaml,
        params: params,
        rgb: rgb,
        width: width,
        height: height,
      );
    } on Object {
      return const PrintFailed('Could not encode the label for this roll.');
    }
    for (var i = 0; i < copies; i++) {
      final result = await transport.send(host, port, job);
      if (result case BrotherQlSendFailed(:final reason)) {
        return PrintFailed(reason);
      }
    }
    return const PrintOk();
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

import '../../core/log.dart';
import '../ble_service.dart';
import '../ble_write_plan_runner.dart';
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

  /// False when the printer's spec says its protocol has not been run on
  /// real hardware; the composer says so before the first print.
  final bool hardwareTested;

  const LabelGeometry({
    required this.widthDots,
    required this.dpi,
    this.lengthDots,
    this.mediaName,
    this.hardwareTested = true,
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
    bool hardwareTested = true,
  }) : geometry = LabelGeometry(
         widthDots: canvas.widthDots,
         lengthDots: canvas.lengthDots,
         dpi: canvas.dpi,
         mediaName: canvas.mediaName,
         hardwareTested: hardwareTested,
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
    hardwareTested:
        (await codec.rasterPrintForSpec(specYaml: specYaml))?.hardwareTested ??
        true,
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

/// A BLE raster printer the app is connected to (cat printer, Fichero D11):
/// the label is encoded by the spec's image-upload handler into a GATT
/// write plan and written over the live connection.
class BleRasterTarget implements LabelPrintTarget {
  final SpecCodec codec;
  final BleService ble;
  final String deviceId;
  final String specYaml;

  @override
  final String name;

  @override
  final LabelGeometry geometry;

  BleRasterTarget({
    required this.codec,
    required this.ble,
    required this.deviceId,
    required this.specYaml,
    required this.name,
    required RasterPrintDto raster,
  }) : geometry = LabelGeometry(
         // 384 is the 58 mm roll every cat printer takes, and the widest
         // any BLE thermal printer in the catalogue is.
         widthDots: raster.printableDots ?? raster.headDots ?? 384,
         dpi: raster.dpi,
         hardwareTested: raster.hardwareTested,
       );

  @override
  Future<PrintOutcome> printMono(
    Uint8List rgb,
    int width,
    int height, {
    int copies = 1,
  }) async {
    var mtu = 23;
    try {
      mtu = await ble.mtu(deviceId);
    } on Object {
      // Sizing for the floor is always safe, just slower.
    }
    final ImageWritePlanDto plan;
    try {
      plan = await codec.encodeImageFrame(
        specYaml: specYaml,
        width: width,
        height: height,
        rgb: rgb,
        frameIndex: 0,
        maxPayloadPerWrite: writePayloadForMtu(mtu),
      );
    } on Object catch (e) {
      Log.ble.warning('print encode failed for $deviceId', error: e);
      return const PrintFailed('Could not encode the label for this printer.');
    }
    try {
      for (var i = 0; i < copies; i++) {
        await runImageWritePlan(ble, deviceId, plan);
      }
    } on DeviceRefusedException catch (e) {
      Log.ble.warning('printer $deviceId refused the job', error: e);
      return const PrintFailed(
        'The printer refused the label. Check the lid is shut and the '
        'labels are loaded.',
      );
    } on TimeoutException catch (e) {
      Log.ble.warning('printer $deviceId stopped answering', error: e);
      return const PrintFailed(
        'The printer stopped answering partway through. Check it is on and '
        'in range, then try again.',
      );
    } on Object catch (e) {
      Log.ble.warning('print write failed for $deviceId', error: e);
      return const PrintFailed(
        'The printer stopped responding. Check it is on and in range.',
      );
    }
    return const PrintOk();
  }
}

/// A BLE printer the app is NOT connected to — one picked from the saved
/// devices: connect for the print, then let go, the way a group run does. A
/// scan still running is stopped first; connecting mid-scan is flaky on both
/// platforms.
class ConnectingBleTarget implements LabelPrintTarget {
  final BleRasterTarget inner;
  final Duration connectTimeout;

  ConnectingBleTarget(
    this.inner, {
    this.connectTimeout = const Duration(seconds: 15),
  });

  @override
  String get name => inner.name;

  @override
  LabelGeometry get geometry => inner.geometry;

  @override
  Future<PrintOutcome> printMono(
    Uint8List rgb,
    int width,
    int height, {
    int copies = 1,
  }) async {
    final ble = inner.ble;
    final id = inner.deviceId;
    try {
      await ble.stopScan().catchError((Object _) {});
      await ble.connect(id).timeout(connectTimeout);
      await ble.discoverServices(id).timeout(connectTimeout);
    } on Object catch (e) {
      Log.ble.warning('print connect failed for $id', error: e);
      await ble.disconnect(id).catchError((Object _) {});
      return PrintFailed('Could not connect to ${inner.name}. Is it on?');
    }
    try {
      return await inner.printMono(rgb, width, height, copies: copies);
    } finally {
      await ble.disconnect(id).catchError((Object _) {});
    }
  }
}

/// The media to print on: what a Brother QL reported loaded, or a
/// conservative default — 62 mm continuous, the common DK-22205 roll — when
/// it stayed silent.
BrotherQlJobParamsDto brotherParamsFor(BrotherQlStatusDto? status) {
  if (status == null) {
    return const BrotherQlJobParamsDto(
      mediaWidthMm: 62,
      mediaLengthMm: 0,
      mediaDieCut: false,
      autoCut: true,
    );
  }
  return BrotherQlJobParamsDto(
    mediaWidthMm: status.mediaWidthMm,
    mediaLengthMm: status.mediaLengthMm,
    mediaDieCut: status.mediaType == 'die_cut',
    autoCut: true,
  );
}

/// Ask a Brother QL what is loaded, for a caller that has not asked yet (the
/// printer picker). Null when it does not answer — the caller then prints on
/// [brotherParamsFor]'s default.
Future<BrotherQlStatusDto?> readBrotherStatus({
  required SpecCodec codec,
  required BrotherQlPrintService transport,
  required String host,
  required int port,
}) async {
  try {
    final result = await transport.send(
      host,
      port,
      await codec.brotherQlStatusRequest(),
      readStatus: true,
    );
    if (result case BrotherQlSendOk(:final statusReply?)) {
      return await codec.decodeBrotherQlStatus(reply: statusReply);
    }
  } on Object catch (e) {
    Log.spec.debug('brother status read failed', error: e);
  }
  return null;
}

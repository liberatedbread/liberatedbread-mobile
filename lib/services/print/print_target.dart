// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable;

import '../../core/log.dart';
import '../ble_connect_within.dart';
import '../ble_service.dart';
import '../ble_write_plan_runner.dart';
import '../brother_ql_print_service.dart';
import '../classic_spp_service.dart';
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

  /// The longest label the printer takes, in feed dots, when its spec says.
  final int? maxLengthDots;

  const LabelGeometry({
    required this.widthDots,
    required this.dpi,
    this.lengthDots,
    this.mediaName,
    this.hardwareTested = true,
    this.maxLengthDots,
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
        // Pages of one job, not a job each: the printer can refuse a second
        // connection while it is still printing the first label, and a run
        // that stopped there had no way to say how many had come out.
        copies: copies,
      );
    } on Object {
      return const PrintFailed('Could not encode the label for this roll.');
    }
    final result = await transport.send(host, port, job);
    if (result case BrotherQlSendFailed(:final reason)) {
      return PrintFailed(reason);
    }
    return const PrintOk();
  }
}

/// A Brother P-touch Cube over Bluetooth Classic SPP: the job is encoded in
/// Rust for the variant's head and the loaded tape, written to the
/// printer's RFCOMM socket, and the printer's own status pushes say whether
/// it printed. Linux only, as [ClassicSppService] is.
class BrotherPtTarget implements LabelPrintTarget {
  final SpecCodec codec;
  final ClassicSppService spp;
  final String address;
  final String specYaml;
  final String? variant;
  final int tapeWidthMm;

  @override
  final String name;

  @override
  final LabelGeometry geometry;

  /// Status byte 18 is the status type; 01 completed, 02 error and 04
  /// turned off end a job (spec `protocol_details.job_sequence.after`).
  static const statusTypeOffset = 18;
  static const jobEndingStatusTypes = {0x01, 0x02, 0x04};
  static const _completed = 0x01;
  static const _turnedOff = 0x04;

  /// The vendor SDK waits this long after connecting to a Cube before it
  /// writes; Ircama allows a minute for the job to finish.
  static const settle = Duration(milliseconds: 500);
  static const jobTimeout = Duration(seconds: 60);

  /// Every Cube takes 12 mm tape: the width assumed when the printer does
  /// not say what is loaded.
  static const fallbackTapeMm = 12;

  BrotherPtTarget({
    required this.codec,
    required this.spp,
    required this.address,
    required this.specYaml,
    required this.variant,
    required this.tapeWidthMm,
    required this.name,
    required LabelCanvasDto canvas,
    bool hardwareTested = true,
    int? maxLengthDots,
  }) : geometry = LabelGeometry(
         widthDots: canvas.widthDots,
         dpi: canvas.dpi,
         mediaName: canvas.mediaName,
         hardwareTested: hardwareTested,
         maxLengthDots: maxLengthDots,
       );

  /// Pair if needed, ask the printer which tape is loaded, and build the
  /// target for that tape on [variant]'s head.
  static Future<BrotherPtTarget> resolve({
    required SpecCodec codec,
    required ClassicSppService spp,
    required String address,
    required String specYaml,
    required String? variant,
    required String name,
  }) async {
    var tape = fallbackTapeMm;
    try {
      await spp.pair(address);
      final reply = await spp.request(
        address,
        await codec.brotherPtStatusRequest(
          specYaml: specYaml,
          variant: variant,
        ),
      );
      final status = await codec.decodeBrotherPtStatus(reply: reply);
      if (status.mediaWidthMm > 0) tape = status.mediaWidthMm;
    } on Object catch (e) {
      Log.ble.warning('P-touch status read failed for $address', error: e);
    }
    final raster = await codec.rasterPrintForSpec(
      specYaml: specYaml,
      variant: variant,
    );
    return BrotherPtTarget(
      codec: codec,
      spp: spp,
      address: address,
      specYaml: specYaml,
      variant: variant,
      tapeWidthMm: tape,
      name: name,
      canvas: await codec.brotherPtLabelCanvas(
        specYaml: specYaml,
        variant: variant,
        tapeWidthMm: tape,
      ),
      hardwareTested: raster?.hardwareTested ?? true,
      maxLengthDots: raster?.maxLengthDots,
    );
  }

  @override
  Future<PrintOutcome> printMono(
    Uint8List rgb,
    int width,
    int height, {
    int copies = 1,
  }) async {
    final Uint8List job;
    try {
      job = await codec.renderBrotherPtJob(
        specYaml: specYaml,
        variant: variant,
        tapeWidthMm: tapeWidthMm,
        rgb: rgb,
        width: width,
        height: height,
      );
    } on Object catch (e) {
      Log.ble.warning('P-touch encode failed for $address', error: e);
      return const PrintFailed('Could not encode the label for this tape.');
    }
    for (var i = 0; i < copies; i++) {
      final List<Uint8List> frames;
      try {
        frames = await spp.sendJob(
          address,
          job,
          stopOffset: statusTypeOffset,
          stopValues: jobEndingStatusTypes,
          settle: settle,
          timeout: jobTimeout,
        );
      } on ClassicSppException catch (e) {
        return PrintFailed(e.message);
      } on Object catch (e) {
        Log.ble.warning('P-touch job failed for $address', error: e);
        return const PrintFailed('Could not send the label to the printer.');
      }
      if (frames.isEmpty) {
        return const PrintFailed('The printer did not answer the label.');
      }
      final BrotherPtStatusDto last;
      try {
        last = await codec.decodeBrotherPtStatus(reply: frames.last);
      } on Object {
        return const PrintFailed('The printer answered with something else.');
      }
      if (last.statusType == _completed) continue;
      if (last.statusType == _turnedOff) {
        return const PrintFailed('The printer turned off during the label.');
      }
      return PrintFailed(
        last.errors.isEmpty
            ? 'The printer stopped with an error and dropped the label.'
            : 'The printer stopped: ${last.errors.join(', ')}.',
      );
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
         maxLengthDots: raster.maxLengthDots,
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
    var connected = false;
    try {
      await ble.stopScan().catchError((Object _) {});
      await connectWithin(ble, id, connectTimeout);
      connected = true;
      await ble.discoverServices(id).timeout(connectTimeout);
    } on Object catch (e) {
      Log.ble.warning('print connect failed for $id', error: e);
      if (connected) await ble.disconnect(id).catchError((Object _) {});
      return PrintFailed('Could not connect to ${inner.name}. Is it on?');
    }
    try {
      return await inner.printMono(rgb, width, height, copies: copies);
    } finally {
      if (connected) await ble.disconnect(id).catchError((Object _) {});
    }
  }
}

/// One explicitly selected roll from the spec's media table. Round die-cut
/// labels use the same raster media-type byte as rectangular die-cut stock.
BrotherQlJobParamsDto brotherParamsForMedia(PrintMediaDto media) =>
    BrotherQlJobParamsDto(
      mediaWidthMm: media.widthMm.round(),
      mediaLengthMm: media.lengthMm?.round() ?? 0,
      mediaDieCut: media.kind != 'continuous',
      autoCut: true,
    );

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

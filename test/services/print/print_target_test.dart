// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The label print targets: what reaches the wire for a composed label, and
// that every failure comes back as a result instead of an exception.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ble_discovered_service.dart';
import 'package:liberated_bread_mobile/services/brother_ql_print_service.dart';
import 'package:liberated_bread_mobile/services/print/print_target.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../../fakes/fake_ble_service.dart';
import '../../fakes/fake_spec_codec.dart';

const _cat = RasterPrintDto(
  handler: 'cat_printer',
  transport: 'ble_write_plan',
  encodable: true,
  dpi: 203,
  dpiAssumed: false,
  headDots: 384,
  printableDots: 384,
  media: [],
  variants: [],
  hardwareTested: true,
);

class _ThrowingBle extends FakeBleService {
  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) => Future.error(const SocketException('gone'));
}

/// An MXW01-shaped printer: every status ask (`22 21 A1`) is answered on the
/// notify stream with its overall flag set and the "no paper" bit.
class _OutOfPaperPrinter extends FakeBleService {
  final StreamController<List<int>> _notify;
  _OutOfPaperPrinter._(this._notify) : super(notifyStream: _notify.stream);
  factory _OutOfPaperPrinter() =>
      _OutOfPaperPrinter._(StreamController<List<int>>.broadcast());

  static const status = [
    0x22, 0x21, 0xA1, 0x00, 0x0C, 0x00, //
    0, 0, 0, 80, 30, 0, 0x01, 0x01, 0, 0, 0, 0, 0x00, 0xFF,
  ];

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    await super.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
    if (value.length > 2 && value[2] == 0xA1) {
      scheduleMicrotask(() => _notify.add(status));
    }
  }
}

/// Each write takes [delay]: a printer slow enough to outlast a job deadline.
class _SlowBle extends FakeBleService {
  final Duration delay;
  _SlowBle(this.delay);

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async {
    await Future<void>.delayed(delay);
    await super.writeCharacteristic(deviceId, serviceUuid, charUuid, value);
  }
}

ImageWriteDto _ctl(int cmd) => ImageWriteDto(
  characteristicUuid: 'ae01',
  bytes: Uint8List.fromList([0x22, 0x21, cmd, 0x00, 0x01, 0x00, 0, 0, 0xFF]),
);

class _RecordingBrother extends BrotherQlPrintService {
  final BrotherQlSendResult result;
  _RecordingBrother([this.result = const BrotherQlSendOk(null)]);
  final sent = <List<int>>[];

  @override
  Future<BrotherQlSendResult> send(
    String host,
    int port,
    List<int> payload, {
    bool readStatus = false,
  }) async {
    sent.add(payload);
    return result;
  }
}

void main() {
  group('BleRasterTarget', () {
    test(
      'takes its width from the spec and writes the plan per copy',
      () async {
        final ble = FakeBleService(mtuToReturn: 185);
        final codec = FakeSpecCodec();
        final target = BleRasterTarget(
          codec: codec,
          ble: ble,
          deviceId: 'AA:BB',
          specYaml: 'cat-yaml',
          name: 'Cat printer',
          raster: _cat,
        );
        expect(target.geometry.widthDots, 384);
        expect(target.geometry.dpi, 203);

        final rgb = Uint8List(384 * 2 * 3);
        final outcome = await target.printMono(rgb, 384, 2, copies: 2);

        expect(outcome, isA<PrintOk>());
        final call = codec.encodeImageCalls.single;
        expect((call.specYaml, call.width, call.height), ('cat-yaml', 384, 2));
        // The negotiated MTU sizes the writes.
        expect(codec.encodeImageCalls.single.maxPayloadPerWrite, 182);
        // One plan, written once per copy.
        expect(ble.writes, hasLength(2));
        expect(ble.writes.every((w) => w.deviceId == 'AA:BB'), isTrue);
      },
    );

    test('a dropped link is a failed print, not an exception', () async {
      final target = BleRasterTarget(
        codec: FakeSpecCodec(),
        ble: _ThrowingBle(),
        deviceId: 'AA:BB',
        specYaml: 'cat-yaml',
        name: 'Cat printer',
        raster: _cat,
      );
      final outcome = await target.printMono(Uint8List(384 * 3), 384, 1);
      expect(outcome, isA<PrintFailed>());
    });

    // Before the fix the job had no write timeout: a write the stack never
    // completed held the print forever.
    test('a write that never completes fails the print', () async {
      final ble = FakeBleService(writeGate: Completer<void>().future);
      final target = BleRasterTarget(
        codec: FakeSpecCodec(),
        ble: ble,
        deviceId: 'AA:BB',
        specYaml: 'cat-yaml',
        name: 'Cat printer',
        raster: _cat,
        writeTimeout: const Duration(milliseconds: 50),
      );
      final outcome = await target
          .printMono(Uint8List(384 * 3), 384, 1)
          .timeout(const Duration(seconds: 5));
      expect(outcome, isA<PrintFailed>());
    });

    test('a job past its deadline is stopped, not left writing', () async {
      final ble = _SlowBle(const Duration(milliseconds: 40));
      final codec = FakeSpecCodec(
        imagePlan: ImageWritePlanDto(
          serviceUuid: 'srv',
          writes: [for (var i = 0; i < 20; i++) _ctl(0xAD)],
          nextFrameIndex: 0,
          replyWaits: const [],
        ),
      );
      final target = BleRasterTarget(
        codec: codec,
        ble: ble,
        deviceId: 'AA:BB',
        specYaml: 'cat-yaml',
        name: 'Cat printer',
        raster: _cat,
        jobTimeout: const Duration(milliseconds: 150),
      );
      final outcome = await target.printMono(Uint8List(384 * 3), 384, 1);
      expect((outcome as PrintFailed).reason, contains('took too long'));
      // Stopped well short of the plan; the last write is the abort.
      expect(ble.writes.length, lessThan(20));
      expect(codec.encodeCalls.last.commandName, 'cancel_print');
    });

    // Before the fix an MXW01 out of paper was asked for status until the
    // poll's deadline and reported as a printer that stopped answering.
    test('a printer that reports an error says why, and the job is '
        'cancelled', () async {
      final ble = _OutOfPaperPrinter();
      final codec = FakeSpecCodec(
        encoded: _ctl(0xAC).bytes,
        imagePlan: ImageWritePlanDto(
          serviceUuid: 'srv',
          writes: [_ctl(0xA2), _ctl(0xA9), _ctl(0xAD)],
          nextFrameIndex: 0,
          replyWaits: const [],
          completionPoll: CompletionPollDto(
            beforeWrite: 1,
            request: _ctl(0xA1),
            characteristicUuid: 'ae02',
            replyPrefix: Uint8List.fromList([0x22, 0x21, 0xA1]),
            doneOffset: 12,
            doneBytes: Uint8List.fromList([0x00]),
            intervalMs: 10,
            timeoutMs: 200,
          ),
        ),
      )..printRefusal = 'out of paper';
      final target = BleRasterTarget(
        codec: codec,
        ble: ble,
        deviceId: 'AA:BB',
        specYaml: 'mxw01-yaml',
        name: 'MXW01',
        raster: _cat,
      );
      final outcome = await target.printMono(Uint8List(384 * 3), 384, 1);
      expect(
        (outcome as PrintFailed).reason,
        'The printer will not print: out of paper.',
      );
      expect(codec.printRefusalReplies.last, _OutOfPaperPrinter.status);
      // Nothing past the status asks went out but the cancel.
      expect(ble.writes.map((w) => w.value[2]).toSet(), {0xA2, 0xA1, 0xAC});
      expect(codec.encodeCalls.single.commandName, 'cancel_print');
      expect(codec.encodeCalls.single.charUuid, 'ae01');
    });
  });

  group('BrotherQlTarget', () {
    const params = BrotherQlJobParamsDto(
      mediaWidthMm: 62,
      mediaLengthMm: 0,
      mediaDieCut: false,
      autoCut: true,
    );
    const canvas = LabelCanvasDto(widthDots: 696, dpi: 300);

    test('encodes once and sends the job per copy', () async {
      final transport = _RecordingBrother();
      final codec = FakeSpecCodec();
      final target = BrotherQlTarget(
        codec: codec,
        transport: transport,
        specYaml: 'brother-yaml',
        host: '192.168.1.50',
        port: 9100,
        params: params,
        name: 'QL',
        canvas: canvas,
      );
      expect(target.geometry.widthDots, 696);
      final outcome = await target.printMono(
        Uint8List(696 * 3),
        696,
        1,
        copies: 3,
      );
      expect(outcome, isA<PrintOk>());
      // One job carrying three pages, not three connections.
      expect(transport.sent, hasLength(1));
      expect(codec.brotherJobCopies, [3]);
    });

    test('a refused send stops and reports why', () async {
      final transport = _RecordingBrother(
        const BrotherQlSendFailed('Could not reach the printer.'),
      );
      final target = BrotherQlTarget(
        codec: FakeSpecCodec(),
        transport: transport,
        specYaml: 'brother-yaml',
        host: '192.168.1.50',
        port: 9100,
        params: params,
        name: 'QL',
        canvas: canvas,
      );
      final outcome = await target.printMono(
        Uint8List(696 * 3),
        696,
        1,
        copies: 3,
      );
      expect(outcome, isA<PrintFailed>());
      expect((outcome as PrintFailed).reason, 'Could not reach the printer.');
      expect(transport.sent, hasLength(1));
    });
  });

  group('ConnectingBleTarget', () {
    test('connects for the print and lets go after', () async {
      final ble = _OrderedBle();
      final target = ConnectingBleTarget(
        BleRasterTarget(
          codec: FakeSpecCodec(),
          ble: ble,
          deviceId: 'AA:BB',
          specYaml: 'cat-yaml',
          name: 'Cat printer',
          raster: _cat,
        ),
      );
      final outcome = await target.printMono(Uint8List(384 * 3), 384, 1);
      expect(outcome, isA<PrintOk>());
      expect(ble.calls, [
        'stopScan',
        'connect',
        'discover',
        'write',
        'disconnect',
      ]);
    });

    test('a printer that will not connect is a failed print', () async {
      final ble = _OrderedBle(connectFails: true);
      final target = ConnectingBleTarget(
        BleRasterTarget(
          codec: FakeSpecCodec(),
          ble: ble,
          deviceId: 'AA:BB',
          specYaml: 'cat-yaml',
          name: 'Cat printer',
          raster: _cat,
        ),
      );
      final outcome = await target.printMono(Uint8List(384 * 3), 384, 1);
      expect(outcome, isA<PrintFailed>());
      expect((outcome as PrintFailed).reason, contains('Cat printer'));
      expect(ble.calls, ['stopScan', 'connect']);
    });

    test('a connect timeout releases a late successful connection', () async {
      final gate = Completer<void>();
      final ble = FakeBleService(connectGate: gate);
      final target = ConnectingBleTarget(
        BleRasterTarget(
          codec: FakeSpecCodec(),
          ble: ble,
          deviceId: 'AA:BB',
          specYaml: 'cat-yaml',
          name: 'Cat printer',
          raster: _cat,
        ),
        connectTimeout: const Duration(milliseconds: 1),
      );

      final outcome = await target.printMono(Uint8List(384 * 3), 384, 1);
      expect(outcome, isA<PrintFailed>());
      expect(ble.events, contains('cancel:AA:BB'));
      expect(ble.disconnectedIds, isEmpty);

      gate.complete();
      for (var i = 0; i < 20 && ble.disconnectedIds.isEmpty; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(ble.disconnectedIds, ['AA:BB']);
      expect(
        ble.events.where((event) => event == 'disconnect:AA:BB').length,
        1,
      );
    });
  });
}

class _OrderedBle extends FakeBleService {
  final bool connectFails;
  _OrderedBle({this.connectFails = false});
  final calls = <String>[];

  @override
  Future<void> stopScan() async => calls.add('stopScan');

  @override
  Future<void> connect(String deviceId) async {
    calls.add('connect');
    if (connectFails) throw const SocketException('out of range');
  }

  @override
  Future<List<BleDiscoveredService>> discoverServices(String deviceId) async {
    calls.add('discover');
    return const [];
  }

  @override
  Future<void> writeCharacteristic(
    String deviceId,
    String serviceUuid,
    String charUuid,
    List<int> value,
  ) async => calls.add('write');

  @override
  Future<void> disconnect(String deviceId) async => calls.add('disconnect');
}

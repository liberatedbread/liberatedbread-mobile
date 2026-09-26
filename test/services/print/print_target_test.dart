// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The label print targets: what reaches the wire for a composed label, and
// that every failure comes back as a result instead of an exception.
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
      expect(target.geometry.widthDots, 696);
      final outcome = await target.printMono(
        Uint8List(696 * 3),
        696,
        1,
        copies: 3,
      );
      expect(outcome, isA<PrintOk>());
      expect(transport.sent, hasLength(3));
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
      expect(ble.calls, isNot(contains('write')));
      expect(ble.calls.last, 'disconnect');
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

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// BrotherPtTarget: a P-touch Cube label goes out over SPP as one job, and
// the printer's own status pushes decide the outcome.
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/classic_spp_service.dart';
import 'package:liberated_bread_mobile/services/print/print_target.dart';

import '../../fakes/fake_spec_codec.dart';

/// A 32-byte P-touch status frame: tape width, status type, error bits.
Uint8List _frame({int tape = 12, int type = 0, int error2 = 0, int phase = 0}) {
  final f = Uint8List(32)..setAll(0, [0x80, 0x20, 0x42, 0x30]);
  f[9] = error2;
  f[10] = tape;
  f[11] = 0x01;
  f[18] = type;
  f[19] = phase;
  return f;
}

class _Spp implements ClassicSppService {
  final Uint8List? statusReply;
  final List<Uint8List> Function()? frames;
  final Object? jobError;
  _Spp({this.statusReply, this.frames, this.jobError});

  int pairs = 0;
  final requests = <List<int>>[];
  final jobs = <List<int>>[];
  int? stopOffset;
  Set<int>? stopValues;
  Duration? settle;

  @override
  Future<void> pair(String address) async => pairs++;

  @override
  Future<Uint8List> request(
    String address,
    List<int> payload, {
    Duration timeout = const Duration(seconds: 12),
  }) async {
    requests.add(payload);
    final reply = statusReply;
    if (reply == null) throw const ClassicSppException('no answer');
    return reply;
  }

  @override
  Future<List<Uint8List>> sendJob(
    String address,
    List<int> job, {
    required int stopOffset,
    required Set<int> stopValues,
    Duration settle = Duration.zero,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    jobs.add(job);
    this.stopOffset = stopOffset;
    this.stopValues = stopValues;
    this.settle = settle;
    final error = jobError;
    if (error != null) throw error;
    return frames!();
  }
}

Future<BrotherPtTarget> _resolve(FakeSpecCodec codec, _Spp spp) =>
    BrotherPtTarget.resolve(
      codec: codec,
      spp: spp,
      address: 'A0:66:10:00:00:01',
      specYaml: 'cube-yaml',
      variant: 'PT-P710BT',
      name: 'PT-P710BT0001',
    );

void main() {
  test('the loaded tape sizes the canvas and the job', () async {
    final codec = FakeSpecCodec();
    final spp = _Spp(
      statusReply: _frame(tape: 24),
      frames: () => [_frame(tape: 24, type: 6, phase: 1), _frame(type: 1)],
    );
    final target = await _resolve(codec, spp);
    expect(spp.pairs, 1);
    expect(spp.requests.single, [0x1B, 0x40, 0x1B, 0x69, 0x53]);
    expect(target.tapeWidthMm, 24);
    expect(target.geometry.widthDots, 128);
    expect(target.geometry.mediaName, '24 mm TZe tape');

    final outcome = await target.printMono(Uint8List(128 * 3), 128, 1);
    expect(outcome, isA<PrintOk>());
    // The fake job carries the tape width, canvas width and height.
    expect(spp.jobs.single, [24, 128, 1]);
    expect(spp.stopOffset, 18);
    expect(spp.stopValues, {1, 2, 4});
    expect(spp.settle, const Duration(milliseconds: 500));
  });

  test('a printer that does not answer is assumed to hold 12 mm', () async {
    final spp = _Spp(frames: () => [_frame(type: 1)]);
    final target = await _resolve(FakeSpecCodec(), spp);
    expect(target.tapeWidthMm, 12);
    expect(target.geometry.widthDots, 70);
  });

  test('an error push is a failure that names the cause', () async {
    final spp = _Spp(
      statusReply: _frame(),
      frames: () => [_frame(type: 2, error2: 0x10)],
    );
    final target = await _resolve(FakeSpecCodec(), spp);
    final outcome = await target.printMono(Uint8List(3), 1, 1, copies: 2);
    expect(outcome, isA<PrintFailed>());
    expect((outcome as PrintFailed).reason, contains('printer error'));
    expect(spp.jobs, hasLength(1), reason: 'no second copy after a failure');
  });

  test('turned off and transport failures come back as results', () async {
    final off = _Spp(statusReply: _frame(), frames: () => [_frame(type: 4)]);
    final offOutcome = await (await _resolve(
      FakeSpecCodec(),
      off,
    )).printMono(Uint8List(3), 1, 1);
    expect((offOutcome as PrintFailed).reason, contains('turned off'));

    final broken = _Spp(
      statusReply: _frame(),
      jobError: const ClassicSppException('Could not send the label.'),
    );
    final brokenOutcome = await (await _resolve(
      FakeSpecCodec(),
      broken,
    )).printMono(Uint8List(3), 1, 1);
    expect((brokenOutcome as PrintFailed).reason, 'Could not send the label.');
  });
}

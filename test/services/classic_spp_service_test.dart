// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/classic_spp_service.dart';
import 'package:liberated_bread_mobile/services/linux_spp_transport.dart';

class _FakeAdapter implements ClassicBluetoothAdapter {
  @override
  bool pairable;
  final List<bool> writes = [];

  _FakeAdapter(this.pairable);

  @override
  Future<void> setPairable(bool value) async {
    writes.add(value);
    pairable = value;
  }
}

class _FakeDevice implements ClassicBluetoothDevice {
  @override
  bool paired;
  @override
  final ClassicBluetoothAdapter adapter;
  final Object? pairError;
  int pairCalls = 0;
  int cancelCalls = 0;

  _FakeDevice(this.adapter, {this.paired = false, this.pairError});

  @override
  Future<void> pair() async {
    pairCalls++;
    if (pairError != null) throw pairError!;
    paired = true;
  }

  @override
  Future<void> cancelPairing() async => cancelCalls++;
}

const _address = '60:98:66:AA:BB:CC';

void main() {
  test('an existing bond does not touch the adapter or pair again', () async {
    final adapter = _FakeAdapter(false);
    final device = _FakeDevice(adapter, paired: true);
    final service = BluezClassicSppService((_) async => device);

    await service.pair(_address);

    expect(device.pairCalls, 0);
    expect(adapter.writes, isEmpty);
  });

  test('pairing temporarily enables pairable and always restores it', () async {
    final adapter = _FakeAdapter(false);
    final device = _FakeDevice(adapter);
    final service = BluezClassicSppService((_) async => device);

    await service.pair(_address);

    expect(device.pairCalls, 1);
    expect(adapter.writes, [true, false]);
    expect(device.paired, isTrue);
  });

  test(
    'a failed pairing restores pairable and becomes useful guidance',
    () async {
      final adapter = _FakeAdapter(false);
      final device = _FakeDevice(adapter, pairError: StateError('denied'));
      final service = BluezClassicSppService((_) async => device);

      await expectLater(
        service.pair(_address),
        throwsA(isA<ClassicSppException>()),
      );
      expect(adapter.writes, [true, false]);
    },
  );

  test('SPP request returns the status frame unchanged', () async {
    final device = _FakeDevice(_FakeAdapter(true), paired: true);
    final status = Uint8List.fromList(List.generate(32, (i) => i));
    late List<int> sent;
    final service = BluezClassicSppService(
      (_) async => device,
      probe: (address, payload, timeout) async {
        sent = payload;
        return status;
      },
    );

    final reply = await service.request(_address, const [0x1b, 0x69, 0x53]);

    expect(reply, status);
    expect(sent, [0x1b, 0x69, 0x53]);
  });

  test(
    'an SPP job passes its stop rule through and returns the frames',
    () async {
      final device = _FakeDevice(_FakeAdapter(true), paired: true);
      final done = Uint8List(32)..[18] = 1;
      late int offset;
      late Set<int> values;
      late Duration settled;
      final service = BluezClassicSppService(
        (_) async => device,
        job:
            (
              address,
              payload, {
              required timeout,
              settle = Duration.zero,
              frameLength = 32,
              required stopOffset,
              required stopValues,
            }) async {
              offset = stopOffset;
              values = stopValues;
              settled = settle;
              return [done];
            },
      );

      final frames = await service.sendJob(
        _address,
        const [0x1A],
        stopOffset: 18,
        stopValues: const {1, 2, 4},
        settle: const Duration(milliseconds: 500),
      );

      expect(frames, [done]);
      expect(offset, 18);
      expect(values, {1, 2, 4});
      expect(settled, const Duration(milliseconds: 500));
    },
  );

  test('an SPP job that never finishes says so in words', () async {
    final device = _FakeDevice(_FakeAdapter(true), paired: true);
    final service = BluezClassicSppService(
      (_) async => device,
      job:
          (
            address,
            payload, {
            required timeout,
            settle = Duration.zero,
            frameLength = 32,
            required stopOffset,
            required stopValues,
          }) async => throw const SppTransportException('timeout', 'late'),
    );

    await expectLater(
      service.sendJob(
        _address,
        const [0x1A],
        stopOffset: 18,
        stopValues: const {1},
      ),
      throwsA(
        isA<ClassicSppException>().having(
          (e) => e.message,
          'message',
          contains('never said it had finished'),
        ),
      ),
    );
  });
}

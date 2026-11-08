// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/services/classic_spp_service.dart';

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
}

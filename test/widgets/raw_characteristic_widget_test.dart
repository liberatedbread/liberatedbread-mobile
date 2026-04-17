// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/ble_discovered_service.dart';
import 'package:opengreeniot_mobile/providers/ble_provider.dart';
import 'package:opengreeniot_mobile/widgets/raw_characteristic_widget.dart';

import '../fakes/fake_ble_service.dart';

Widget _wrap(Widget child, FakeBleService fake) => ProviderScope(
      overrides: [bleServiceProvider.overrideWithValue(fake)],
      child: MaterialApp(home: Scaffold(body: ListView(children: [child]))),
    );

const _charUuid = '00002a19-0000-1000-8000-00805f9b34fb';
const _serviceUuid = '0000180f-0000-1000-8000-00805f9b34fb';

void main() {
  testWidgets('readable characteristic shows hex value after read',
      (tester) async {
    final fake = FakeBleService(readValues: {
      _charUuid: const [0x55, 0xaa]
    });
    await tester.pumpWidget(_wrap(
      const RawCharacteristicWidget(
        deviceId: '01',
        serviceUuid: _serviceUuid,
        characteristic: BleDiscoveredCharacteristic(
          uuid: _charUuid,
          canRead: true,
          canWrite: false,
          canNotify: false,
        ),
      ),
      fake,
    ));

    await tester.pumpAndSettle();
    expect(find.text('55 aa'), findsOneWidget);
  });

  testWidgets('read error is surfaced in the subtitle', (tester) async {
    final fake = FakeBleService(readError: StateError('denied'));
    await tester.pumpWidget(_wrap(
      const RawCharacteristicWidget(
        deviceId: '01',
        serviceUuid: _serviceUuid,
        characteristic: BleDiscoveredCharacteristic(
          uuid: _charUuid,
          canRead: true,
          canWrite: false,
          canNotify: false,
        ),
      ),
      fake,
    ));

    await tester.pumpAndSettle();
    expect(find.textContaining('denied'), findsOneWidget);
  });

  testWidgets('non-readable characteristic renders no-value placeholder',
      (tester) async {
    await tester.pumpWidget(_wrap(
      const RawCharacteristicWidget(
        deviceId: '01',
        serviceUuid: _serviceUuid,
        characteristic: BleDiscoveredCharacteristic(
          uuid: _charUuid,
          canRead: false,
          canWrite: true,
          canNotify: false,
        ),
      ),
      FakeBleService(),
    ));

    await tester.pumpAndSettle();
    expect(find.text('(no value)'), findsOneWidget);
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/device_characteristic.dart';
import 'package:opengreeniot_mobile/screens/characteristic_screen.dart';

Widget _wrap(DeviceCharacteristic c) =>
    MaterialApp(home: CharacteristicScreen(characteristic: c));

void main() {
  testWidgets('title falls back to the UUID when there is no name',
      (tester) async {
    await tester
        .pumpWidget(_wrap(const DeviceCharacteristic(uuid: 'abcd-uuid')));
    // AppBar title shows the UUID; the body shows "UUID: abcd-uuid".
    expect(find.text('abcd-uuid'), findsOneWidget);
    expect(find.text('UUID: abcd-uuid'), findsOneWidget);
  });

  testWidgets('shows name, hex, decoded string and property chips',
      (tester) async {
    await tester.pumpWidget(_wrap(const DeviceCharacteristic(
      uuid: 'u',
      name: 'Battery Level',
      value: [72, 105], // "Hi"
      canRead: true,
      canNotify: true,
    )));

    expect(find.text('Battery Level'), findsOneWidget);
    expect(find.text('Hex: 48 69'), findsOneWidget);
    expect(find.text('String: Hi'), findsOneWidget);
    expect(find.text('Read'), findsOneWidget);
    expect(find.text('Notify'), findsOneWidget);
    expect(find.text('Write'), findsNothing);
  });

  testWidgets('omits the string line for non-printable values', (tester) async {
    await tester.pumpWidget(_wrap(const DeviceCharacteristic(
      uuid: 'u',
      value: [0, 1, 2],
      canWrite: true,
    )));

    expect(find.text('Hex: 00 01 02'), findsOneWidget);
    expect(find.textContaining('String:'), findsNothing);
    expect(find.text('Write'), findsOneWidget);
  });
}

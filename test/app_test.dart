// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/app.dart';
import 'package:opengreeniot_mobile/providers/ble_provider.dart';
import 'package:opengreeniot_mobile/screens/scan_screen.dart';

import 'fakes/fake_ble_service.dart';

void main() {
  testWidgets('app builds and shows the scan screen', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [bleServiceProvider.overrideWithValue(FakeBleService())],
      child: const OpenGreenIoTApp(),
    ));
    await tester.pump();

    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(ScanScreen), findsOneWidget);
  });
}

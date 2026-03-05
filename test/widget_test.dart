// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/app.dart';

void main() {
  testWidgets('App shows title', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: OpenGreenIoTApp()));
    expect(find.text('OpenGreenIoT'), findsOneWidget);
  });
}

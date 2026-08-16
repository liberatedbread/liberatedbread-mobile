// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/widgets/black_hat_icon.dart';

void main() {
  testWidgets('paints at its given size and colour without throwing',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(child: BlackHatIcon(size: 24, color: Colors.red)),
      ),
    ));
    expect(tester.takeException(), isNull);
    // It occupies exactly the box it was asked for.
    final size = tester.getSize(find.byType(BlackHatIcon));
    expect(size, const Size.square(24));
    expect(find.byType(CustomPaint), findsWidgets);
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// "Print this" for a file another app shared in.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/printer_provider.dart';
import 'package:liberated_bread_mobile/screens/print_shared_file_screen.dart';
import 'package:liberated_bread_mobile/services/print/os_print_service.dart';
import 'package:liberated_bread_mobile/services/share_in_service.dart';

import '../fakes/fake_os_print_service.dart';

final _pdf = SharedFile(
  bytes: Uint8List.fromList('%PDF-1.7 a document'.codeUnits),
  mime: 'application/pdf',
  name: 'shipping.pdf',
);

Future<FakeOsPrintService> _pump(WidgetTester tester, SharedFile file) async {
  final osPrint = FakeOsPrintService();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        osPrintServiceProvider.overrideWithValue(osPrint),
        savedPrintersProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(home: PrintSharedFileScreen(file: file)),
    ),
  );
  await tester.pumpAndSettle();
  return osPrint;
}

void main() {
  testWidgets('a shared PDF goes to the print dialog untouched', (
    tester,
  ) async {
    final osPrint = await _pump(tester, _pdf);
    expect(find.text('shipping.pdf'), findsOneWidget);

    await tester.tap(find.text('On a regular printer'));
    await tester.pumpAndSettle();

    expect(osPrint.jobs.single.name, 'shipping.pdf');
    expect(osPrint.jobs.single.pdf, _pdf.bytes);
  });

  testWidgets('with no saved label printer, it says how to get one', (
    tester,
  ) async {
    await _pump(tester, _pdf);
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('On a label printer'),
        matching: find.byType(FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(find.textContaining('Save a label printer first'), findsOneWidget);
  });
}

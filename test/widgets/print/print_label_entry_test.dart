// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// PrintLabelEntry: the device panel's way into the label composer, shown only
// for a printer this build can drive over BLE.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/providers/ble_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/print_label_screen.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';
import 'package:liberated_bread_mobile/widgets/print/print_label_entry.dart';

import '../../fakes/fake_ble_service.dart';
import '../../fakes/fake_spec_codec.dart';

RasterPrintDto _raster({
  String? transport = 'ble_write_plan',
  List<String> variants = const [],
}) => RasterPrintDto(
  handler: 'fichero_d11',
  transport: transport,
  encodable: transport != null,
  dpi: 203,
  dpiAssumed: false,
  printableDots: 96,
  media: const [],
  variants: variants,
  hardwareTested: true,
);

Future<void> _pump(
  WidgetTester tester,
  RasterPrintDto? raster, {
  Set<String>? matchedVariants,
}) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        specCodecProvider.overrideWithValue(
          FakeSpecCodec(rasterPrintResult: raster),
        ),
        bleServiceProvider.overrideWithValue(FakeBleService()),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: PrintLabelEntry(
            deviceId: 'AA:BB',
            specYaml: 'spec',
            deviceName: 'Fichero D11',
            matchedVariants: matchedVariants,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a BLE printer offers the composer', (tester) async {
    await _pump(tester, _raster());
    await tester.tap(find.text('Print a label'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(PrintLabelScreen), findsOneWidget);
    // A 96-dot head is narrow: the composer starts with text along the tape.
    final along = tester.widget<SwitchListTile>(
      find.widgetWithText(SwitchListTile, 'Text along the tape'),
    );
    expect(along.value, isTrue);
  });

  testWidgets('nothing shows for a device that is not a printer', (
    tester,
  ) async {
    await _pump(tester, null);
    expect(find.text('Print a label'), findsNothing);
  });

  testWidgets('nothing shows for a printer this build cannot drive', (
    tester,
  ) async {
    await _pump(tester, _raster(transport: null));
    expect(find.text('Print a label'), findsNothing);
  });

  testWidgets('a network printer is not offered from a BLE panel', (
    tester,
  ) async {
    await _pump(tester, _raster(transport: 'raw_stream'));
    expect(find.text('Print a label'), findsNothing);
  });

  testWidgets('a surface scoped to another model is not offered', (
    tester,
  ) async {
    await _pump(
      tester,
      _raster(variants: const ['D110']),
      matchedVariants: const {'B21'},
    );
    expect(find.text('Print a label'), findsNothing);
  });

  testWidgets('the right model, or an unknown one, is offered', (tester) async {
    await _pump(
      tester,
      _raster(variants: const ['D110']),
      matchedVariants: const {'D110'},
    );
    expect(find.text('Print a label'), findsOneWidget);
    await _pump(tester, _raster(variants: const ['D110']));
    expect(find.text('Print a label'), findsOneWidget);
  });
}

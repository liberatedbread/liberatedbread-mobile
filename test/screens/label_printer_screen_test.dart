// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// F-051: the "Reading printer status…" line sat beside its spinner as a bare
// Text, so at accessibility text sizes on a narrow phone it overflowed the
// status card.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/label_printer_screen.dart';
import 'package:liberated_bread_mobile/screens/print_label_screen.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

/// Never answers the status request, so the screen stays in its loading
/// state and no socket is ever opened.
class _HangingCodec extends FakeSpecCodec {
  @override
  Future<Uint8List> brotherQlStatusRequest() => Completer<Uint8List>().future;
}

final _printer = NetworkDevice(
  host: '192.168.1.40',
  name: 'Brother QL-820NWB',
  port: 9100,
  sources: const {NetworkDiscoverySource.mdns},
  discoveredAt: DateTime(2026, 1, 1),
);

const _controls = NetworkControls(
  specYaml: 'spec',
  entities: [],
  rasterPrintHandler: 'brother_ql_raster',
);

void main() {
  testWidgets('the loading state renders without overflow at 320 pt and 3x '
      'text', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [specCodecProvider.overrideWithValue(_HangingCodec())],
        child: MaterialApp(
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(3.0)),
              child: LabelPrinterScreen(device: _printer, controls: _controls),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Reading printer status…'), findsOneWidget);
  });

  testWidgets('Compose a label opens the composer sized to the roll', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    // The status request fails (the fake does not implement it), which the
    // screen reports and still lets a label be composed — the same honesty
    // it shows a printer that answers no status.
    final codec = FakeSpecCodec(
      brotherLabelCanvas: const LabelCanvasDto(
        widthDots: 696,
        dpi: 300,
        mediaName: '62mm continuous (DK-22205)',
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [specCodecProvider.overrideWithValue(codec)],
        child: MaterialApp(
          home: LabelPrinterScreen(device: _printer, controls: _controls),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(find.text('Compose a label'));
    // Not pumpAndSettle: the composer's preview spinner runs until its
    // (real, async) render lands, which a fake clock never lets happen.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(PrintLabelScreen), findsOneWidget);
    expect(
      find.text('Brother QL-820NWB · 62mm continuous (DK-22205)'),
      findsOneWidget,
    );
  });
}

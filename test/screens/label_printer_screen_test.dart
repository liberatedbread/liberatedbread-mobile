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
}

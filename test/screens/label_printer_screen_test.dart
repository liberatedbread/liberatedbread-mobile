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
import 'package:liberated_bread_mobile/services/brother_ql_print_service.dart';
import 'package:liberated_bread_mobile/src/rust/api/device_api.dart';

import '../fakes/fake_spec_codec.dart';

/// Never answers the status request, so the screen stays in its loading
/// state and no socket is ever opened.
class _HangingCodec extends FakeSpecCodec {
  @override
  Future<Uint8List> brotherQlStatusRequest() => Completer<Uint8List>().future;
}

/// Answers the status request with a fixed payload and decodes it to
/// [status], so the screen's print gate can be driven without a socket.
class _StatusCodec extends FakeSpecCodec {
  final BrotherQlStatusDto status;
  _StatusCodec(this.status);

  @override
  Future<Uint8List> brotherQlStatusRequest() async => Uint8List(3);

  @override
  Future<BrotherQlStatusDto> decodeBrotherQlStatus({
    required List<int> reply,
  }) async => status;
}

/// Plays back one scripted result per status read.
class _ScriptedPrinter extends BrotherQlPrintService {
  final List<BrotherQlSendResult> results;
  _ScriptedPrinter(this.results);

  @override
  Future<BrotherQlSendResult> send(
    String host,
    int port,
    List<int> payload, {
    bool readStatus = false,
  }) async => results.removeAt(0);
}

const _ready = BrotherQlStatusDto(
  mediaWidthMm: 29,
  mediaType: 'die_cut',
  mediaLengthMm: 90,
  statusType: 0,
  phase: 0,
  errors: [],
  readyToPrint: true,
);

Future<void> _pumpScreen(
  WidgetTester tester, {
  required List<BrotherQlSendResult> results,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        specCodecProvider.overrideWithValue(_StatusCodec(_ready)),
        brotherQlPrintServiceProvider.overrideWithValue(
          _ScriptedPrinter(results),
        ),
      ],
      child: MaterialApp(
        home: LabelPrinterScreen(device: _printer, controls: _controls),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

bool _printEnabled(WidgetTester tester) {
  final button = tester.widget<ButtonStyleButton>(
    find.ancestor(
      of: find.text('Print test label'),
      matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
    ),
  );
  return button.onPressed != null;
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

  // Before the fix _canPrint ignored _error, so an unreachable printer (a
  // null status) enabled Print and the dialog claimed it "did not report
  // its media".
  testWidgets('a failed status read keeps Print disabled', (tester) async {
    await _pumpScreen(
      tester,
      results: [const BrotherQlSendFailed('Could not reach the printer.')],
    );
    expect(find.text('Could not reach the printer.'), findsOneWidget);
    expect(_printEnabled(tester), isFalse);
  });

  // Before the fix a failed Refresh kept the previous roll's status, so
  // Print stayed enabled against stale media.
  testWidgets('a failed refresh after a good read disables Print', (
    tester,
  ) async {
    await _pumpScreen(
      tester,
      results: [
        BrotherQlSendOk(Uint8List(32)),
        const BrotherQlSendFailed('Could not reach the printer.'),
      ],
    );
    expect(_printEnabled(tester), isTrue);

    await tester.tap(find.byTooltip('Refresh'));
    await tester.pumpAndSettle();
    expect(find.text('Could not reach the printer.'), findsOneWidget);
    expect(_printEnabled(tester), isFalse);
  });

  testWidgets('reachable but silent still offers Print with the 62 mm '
      'fallback', (tester) async {
    await _pumpScreen(tester, results: [const BrotherQlSendOk(null)]);
    expect(_printEnabled(tester), isTrue);
    await tester.tap(find.text('Print test label'));
    await tester.pumpAndSettle();
    expect(find.textContaining('62 mm continuous roll'), findsOneWidget);
  });
}

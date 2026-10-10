// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// The IPP printer status screen: state, supplies, paper — and honesty about
// a printer that has no status to give.
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/network_device.dart';
import 'package:liberated_bread_mobile/providers/network_control_provider.dart';
import 'package:liberated_bread_mobile/providers/spec_codec_provider.dart';
import 'package:liberated_bread_mobile/screens/ipp_printer_screen.dart';
import 'package:liberated_bread_mobile/services/ipp_status_client.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

import '../fakes/fake_spec_codec.dart';

class _CannedClient extends IppStatusClient {
  final IppFetchResult result;
  _CannedClient(this.result);
  final paths = <String>[];

  @override
  Future<IppFetchResult> fetch({
    required String host,
    required int port,
    required String resourcePath,
    required Uint8List body,
  }) async {
    paths.add(resourcePath);
    return result;
  }
}

NetworkDevice _printer({List<String> types = const ['_ipp._tcp']}) =>
    NetworkDevice(
      host: '192.168.1.50',
      name: 'Office Laser',
      port: 631,
      sources: const {NetworkDiscoverySource.mdns},
      discoveredAt: DateTime(2026, 1, 1),
      serviceTypes: types,
      txt: const {'rp': 'ipp/print'},
    );

const _stopped = IppPrinterStatusDto(
  statusCode: 0,
  ok: true,
  state: 'stopped',
  stateReasons: ['media-empty-error', 'toner-low-report'],
  stateMessage: 'Load paper in tray 1',
  makeAndModel: 'Example LaserJet 400',
  markers: [
    IppMarkerDto(
      name: 'Black Toner',
      color: '#000000',
      kind: 'toner',
      level: 12,
      someRemaining: false,
      lowLevel: 15,
    ),
  ],
  mediaReady: ['iso_a4_210x297mm'],
  documentFormats: ['application/pdf'],
);

Future<_CannedClient> _pump(
  WidgetTester tester, {
  NetworkDevice? device,
  IppFetchResult? result,
}) async {
  final client = _CannedClient(result ?? IppFetchOk(Uint8List.fromList([1])));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        specCodecProvider.overrideWithValue(
          FakeSpecCodec(ippStatus: true, ippStatusResult: _stopped),
        ),
        ippStatusClientProvider.overrideWithValue(client),
      ],
      child: MaterialApp(
        home: IppPrinterScreen(
          device: device ?? _printer(),
          controls: const NetworkControls(
            specYaml: 'ipp',
            entities: [],
            ippStatus: true,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return client;
}

void main() {
  testWidgets('shows state, what is wrong, supplies and paper', (tester) async {
    final client = await _pump(tester);
    expect(client.paths.single, 'ipp/print');
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Load paper in tray 1'), findsOneWidget);
    expect(find.text('Media empty · Toner low'), findsOneWidget);
    expect(find.text('Black Toner'), findsOneWidget);
    expect(find.text('12%'), findsOneWidget);
    expect(find.text('A4 (210x297 mm)'), findsOneWidget);
    expect(find.text('Print a document or photo'), findsOneWidget);
  });

  testWidgets('a printer that is not reachable says so', (tester) async {
    await _pump(
      tester,
      result: const IppFetchFailed('Could not reach the printer.'),
    );
    expect(find.text('Could not reach the printer.'), findsOneWidget);
    expect(find.text('Open admin page'), findsOneWidget);
  });

  testWidgets('a raw-socket-only printer is not asked', (tester) async {
    final client = await _pump(
      tester,
      device: _printer(types: const ['_pdl-datastream._tcp']),
    );
    expect(client.paths, isEmpty);
    expect(find.textContaining('did not advertise IPP'), findsOneWidget);
  });

  test('media and reason keywords read aloud', () {
    expect(mediaLabel('na_letter_8.5x11in'), 'Letter (8.5x11 in)');
    expect(mediaLabel('iso_a4_210x297mm'), 'A4 (210x297 mm)');
    expect(mediaLabel('custom'), 'custom');
    expect(reasonLabel('marker-supply-low-warning'), 'Marker supply low');
  });
}

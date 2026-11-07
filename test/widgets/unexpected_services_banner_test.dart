// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/core/constants.dart';
import 'package:liberated_bread_mobile/models/svc_report.dart';
import 'package:liberated_bread_mobile/providers/ha_provider.dart';
import 'package:liberated_bread_mobile/providers/saved_device_provider.dart';
import 'package:liberated_bread_mobile/providers/svc_report_provider.dart';
import 'package:liberated_bread_mobile/services/svc_report_service.dart';
import 'package:liberated_bread_mobile/widgets/unexpected_services_banner.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _draft = SvcReport(
  reportId: 'draft',
  transport: SvcReportTransport.ble,
  specKey: 'Bulb|Acme',
  specDeviceName: 'Bulb',
  specManufacturer: 'Acme',
  advertisedName: 'ACME_1',
  unexpected: [SvcReportEntry(kind: 'gatt', id: 'fe59')],
  discovered: ['fe59', 'fff0'],
  declared: ['fff0'],
  appVersion: 'dev build',
  platform: 'android',
);

late SharedPreferences _prefs;

class _Harness {
  final posted = <Map<String, Object?>>[];
  final opened = <Uri>[];
  int status = 201;
  bool mailOpens = true;

  Widget build({SvcReport? report = _draft}) => ProviderScope(
    overrides: [
      sharedPreferencesProvider.overrideWithValue(_prefs),
      svcReportServiceProvider.overrideWithValue(
        SvcReportService(
          client: MockClient((request) async {
            posted.add(jsonDecode(request.body) as Map<String, Object?>);
            return http.Response('{}', status);
          }),
        ),
      ),
      urlOpenerProvider.overrideWithValue((uri) async {
        opened.add(uri);
        return mailOpens;
      }),
    ],
    child: MaterialApp(
      home: Scaffold(body: UnexpectedServicesBanner(report: report)),
    ),
  );
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _prefs = await SharedPreferences.getInstance();
  });

  testWidgets('renders nothing without a report', (tester) async {
    await tester.pumpWidget(_Harness().build(report: null));
    expect(find.textContaining('unexpected services'), findsNothing);
  });

  testWidgets('Send report posts AND opens the email, with one id', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    expect(find.text('Oh hey — unexpected services'), findsOneWidget);

    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();

    expect(h.posted, hasLength(1));
    expect(h.opened, hasLength(1));
    final id = h.posted.single['report_id'] as String;
    expect(id, isNot('draft'));
    expect(h.opened.single.path, AppConstants.svcReportsEmail);
    expect(h.opened.single.queryParameters['body'], contains(id));
    expect(find.textContaining('Report sent'), findsOneWidget);
    // Handled: the banner is gone and stays gone.
    expect(find.text('Oh hey — unexpected services'), findsNothing);
    expect(
      _prefs.getString(SvcReportHandledNotifier.storageKey),
      contains(_draft.itemKeys.single),
    );
  });

  testWidgets('Email only never touches the server', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.tap(find.text('Email only'));
    await tester.pumpAndSettle();
    expect(h.posted, isEmpty);
    expect(h.opened, hasLength(1));
  });

  testWidgets('server down: the email still goes, and says so', (tester) async {
    final h = _Harness()..status = 503;
    await tester.pumpWidget(h.build());
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't reach our server"), findsOneWidget);
    expect(find.text('Oh hey — unexpected services'), findsNothing);
  });

  testWidgets('both routes failing keeps the banner for a retry', (
    tester,
  ) async {
    final h = _Harness()
      ..status = 503
      ..mailOpens = false;
    await tester.pumpWidget(h.build());
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Couldn't send the report"), findsOneWidget);
    expect(find.text('Oh hey — unexpected services'), findsOneWidget);

    // The retry carries the same report id, so the backend can dedupe.
    h
      ..status = 201
      ..mailOpens = true;
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();
    expect(h.posted, hasLength(2));
    expect(h.posted[0]['report_id'], h.posted[1]['report_id']);
  });

  testWidgets('dismiss hides it without sending anything', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.text('Oh hey — unexpected services'), findsNothing);
    expect(h.posted, isEmpty);
    expect(h.opened, isEmpty);
  });

  testWidgets("What's sent? shows the exact payload", (tester) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.tap(find.text("What's sent?"));
    await tester.pumpAndSettle();
    expect(find.textContaining('"fe59"'), findsOneWidget);
    expect(h.posted, isEmpty);
  });

  testWidgets('a response-only report says "unexpected response"', (
    tester,
  ) async {
    const report = SvcReport(
      reportId: 'draft',
      transport: SvcReportTransport.wifi,
      specKey: 'Plug|Acme',
      specDeviceName: 'Plug',
      specManufacturer: 'Acme',
      advertisedName: null,
      unexpected: [],
      responses: [
        SvcReportResponse(
          problem: 'unmapped_state',
          where: 'command:get_sysinfo',
          entity: 'Power',
          detail: 'reply keys: a, b',
        ),
      ],
      discovered: [],
      declared: [],
      appVersion: 'dev build',
      platform: 'android',
    );
    final h = _Harness();
    await tester.pumpWidget(h.build(report: report));
    expect(find.text('Oh hey — unexpected response'), findsOneWidget);
    expect(find.textContaining('answered in a way'), findsOneWidget);
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();
    expect(h.posted.single['responses'], hasLength(1));
  });

  testWidgets('a new finding brings it back, without the handled one', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(h.build());
    await tester.tap(find.byTooltip('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Oh hey'), findsNothing);

    const withResponse = SvcReport(
      reportId: 'draft',
      transport: SvcReportTransport.ble,
      specKey: 'Bulb|Acme',
      specDeviceName: 'Bulb',
      specManufacturer: 'Acme',
      advertisedName: 'ACME_1',
      unexpected: [SvcReportEntry(kind: 'gatt', id: 'fe59')],
      responses: [
        SvcReportResponse(
          problem: 'undecodable_value',
          where: 'gatt:fff1',
          detail: '3 bytes',
          sample: '010203',
        ),
      ],
      discovered: ['fe59', 'fff0'],
      declared: ['fff0'],
      appVersion: 'dev build',
      platform: 'android',
    );
    await tester.pumpWidget(h.build(report: withResponse));
    await tester.pumpAndSettle();
    expect(find.text('Oh hey — unexpected response'), findsOneWidget);
    await tester.tap(find.text('Send report'));
    await tester.pumpAndSettle();
    final sent = h.posted.single;
    expect(sent['unexpected'], isEmpty);
    expect(sent['responses'], hasLength(1));
  });
}

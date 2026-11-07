// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/svc_report.dart';
import 'package:liberated_bread_mobile/services/svc_report_service.dart';

const _url = 'https://svc-reports.example.test/api/v1/reports';

const _report = SvcReport(
  reportId: '6f1c2f0e-3b7a-4e0f-9d4c-2a1b3c4d5e6f',
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

void main() {
  test('posts the report as JSON and accepts 201', () async {
    late http.Request seen;
    final service = SvcReportService(
      client: MockClient((request) async {
        seen = request;
        return http.Response('{"id":"x","status":"created"}', 201);
      }),
    );
    expect(await service.submit(_url, _report), isA<SvcReportAccepted>());
    expect(seen.method, 'POST');
    expect(seen.headers['content-type'], startsWith('application/json'));
    expect(jsonDecode(seen.body), _report.toJson());
  });

  test('a duplicate (200) is accepted too', () async {
    final service = SvcReportService(
      client: MockClient((_) async => http.Response('{}', 200)),
    );
    expect(await service.submit(_url, _report), isA<SvcReportAccepted>());
  });

  test('a server error is a failure, not a throw', () async {
    final service = SvcReportService(
      client: MockClient((_) async => http.Response('nope', 503)),
    );
    final result = await service.submit(_url, _report);
    expect(result, isA<SvcReportFailed>());
    expect((result as SvcReportFailed).reason, 'HTTP 503');
  });

  test('a network error is a failure, not a throw', () async {
    final service = SvcReportService(
      client: MockClient((_) async => throw http.ClientException('down')),
    );
    expect(await service.submit(_url, _report), isA<SvcReportFailed>());
  });

  test('refuses a plaintext endpoint without sending', () async {
    var sent = false;
    final service = SvcReportService(
      client: MockClient((_) async {
        sent = true;
        return http.Response('{}', 201);
      }),
    );
    expect(
      await service.submit('http://svc-reports.example.test/', _report),
      isA<SvcReportFailed>(),
    );
    expect(sent, isFalse);
  });
}

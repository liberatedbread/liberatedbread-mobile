// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:liberated_bread_mobile/models/ha_sensor.dart';
import 'package:liberated_bread_mobile/services/ha_api_client.dart';
import 'package:liberated_bread_mobile/services/http_ha_api_client.dart';

const _base = 'http://ha.local:8123';

void main() {
  group('registerDevice', () {
    test('posts to the registrations endpoint with bearer auth', () async {
      http.Request? seen;
      final client = HttpHaApiClient(MockClient((request) async {
        seen = request;
        return http.Response(
            jsonEncode({
              'webhook_id': 'wh123',
              'cloudhook_url': null,
              'remote_ui_url': null,
            }),
            201);
      }));

      final result = await client.registerDevice(
        baseUrl: _base,
        token: 'tok',
        deviceInfo: {'device_id': 'd1', 'app_id': 'app'},
      );

      expect(result.webhookId, 'wh123');
      expect(seen!.url.toString(), '$_base/api/mobile_app/registrations');
      expect(seen!.headers['Authorization'], 'Bearer tok');
      expect(seen!.headers['Content-Type'], startsWith('application/json'));
      expect(jsonDecode(seen!.body), {'device_id': 'd1', 'app_id': 'app'});
    });

    test('throws HaAuthException on 401', () {
      final client = HttpHaApiClient(
          MockClient((_) async => http.Response('unauthorized', 401)));
      expect(
        client.registerDevice(baseUrl: _base, token: 'bad', deviceInfo: {}),
        throwsA(isA<HaAuthException>()),
      );
    });

    test('throws HaNotFoundException on 404', () {
      final client =
          HttpHaApiClient(MockClient((_) async => http.Response('nope', 404)));
      expect(
        client.registerDevice(baseUrl: _base, token: 't', deviceInfo: {}),
        throwsA(isA<HaNotFoundException>()),
      );
    });

    test('throws HaServerException on 500', () {
      final client =
          HttpHaApiClient(MockClient((_) async => http.Response('boom', 500)));
      expect(
        client.registerDevice(baseUrl: _base, token: 't', deviceInfo: {}),
        throwsA(isA<HaServerException>()),
      );
    });

    test('wraps connection failures in HaNetworkException', () {
      final client = HttpHaApiClient(MockClient(
          (_) async => throw http.ClientException('connection refused')));
      expect(
        client.registerDevice(baseUrl: _base, token: 't', deviceInfo: {}),
        throwsA(isA<HaNetworkException>()),
      );
    });

    test('maps a non-JSON 2xx body to a typed HaApiException', () {
      final client = HttpHaApiClient(
          MockClient((_) async => http.Response('<html>not json</html>', 201)));
      expect(
        client.registerDevice(baseUrl: _base, token: 't', deviceInfo: {}),
        throwsA(isA<HaApiException>()),
      );
    });

    test('maps a 2xx JSON body missing webhook_id to a typed HaApiException',
        () {
      final client = HttpHaApiClient(MockClient(
          (_) async => http.Response(jsonEncode({'ok': true}), 201)));
      expect(
        client.registerDevice(baseUrl: _base, token: 't', deviceInfo: {}),
        throwsA(isA<HaApiException>()),
      );
    });
  });

  group('webhook messages', () {
    test('registerSensor posts a register_sensor payload', () async {
      http.Request? seen;
      final client = HttpHaApiClient(MockClient((request) async {
        seen = request;
        return http.Response('{"success": true}', 201);
      }));

      await client.registerSensor(
        baseUrl: _base,
        webhookId: 'wh123',
        sensor: const HaSensorRegistration(
          uniqueId: 'u1',
          name: 'Bulb Battery',
          type: 'sensor',
          state: 85,
          deviceClass: 'battery',
          unitOfMeasurement: '%',
          icon: 'mdi:battery',
        ),
      );

      expect(seen!.url.toString(), '$_base/api/webhook/wh123');
      expect(seen!.headers.containsKey('Authorization'), isFalse);
      expect(jsonDecode(seen!.body), {
        'type': 'register_sensor',
        'data': {
          'unique_id': 'u1',
          'name': 'Bulb Battery',
          'type': 'sensor',
          'state': 85,
          'device_class': 'battery',
          'unit_of_measurement': '%',
          'icon': 'mdi:battery',
        },
      });
    });

    test('updateSensorStates posts states and parses per-sensor results',
        () async {
      http.Request? seen;
      final client = HttpHaApiClient(MockClient((request) async {
        seen = request;
        return http.Response(
            jsonEncode({
              'u1': {'success': true},
              'u2': {
                'success': false,
                'error': {'code': 'not_registered', 'message': 'unknown'},
              },
            }),
            200);
      }));

      final results = await client.updateSensorStates(
        baseUrl: _base,
        webhookId: 'wh123',
        states: const [
          HaSensorState(uniqueId: 'u1', type: 'sensor', state: 85),
          HaSensorState(uniqueId: 'u2', type: 'binary_sensor', state: true),
        ],
      );

      expect(jsonDecode(seen!.body), {
        'type': 'update_sensor_states',
        'data': [
          {'unique_id': 'u1', 'type': 'sensor', 'state': 85},
          {'unique_id': 'u2', 'type': 'binary_sensor', 'state': true},
        ],
      });
      expect(results, hasLength(2));
      final u1 = results.singleWhere((r) => r.uniqueId == 'u1');
      final u2 = results.singleWhere((r) => r.uniqueId == 'u2');
      expect(u1.success, isTrue);
      expect(u2.success, isFalse);
      expect(u2.errorCode, 'not_registered');
    });

    test('tolerates an empty webhook response body', () async {
      final client =
          HttpHaApiClient(MockClient((_) async => http.Response('', 200)));
      final results = await client.updateSensorStates(
        baseUrl: _base,
        webhookId: 'wh123',
        states: const [
          HaSensorState(uniqueId: 'u1', type: 'sensor', state: 1),
        ],
      );
      expect(results, isEmpty);
    });

    test('maps a malformed update_sensor_states body to a typed HaApiException',
        () {
      final client = HttpHaApiClient(
          MockClient((_) async => http.Response('not json at all', 200)));
      expect(
        client.updateSensorStates(
          baseUrl: _base,
          webhookId: 'wh123',
          states: const [
            HaSensorState(uniqueId: 'u1', type: 'sensor', state: 1)
          ],
        ),
        throwsA(isA<HaApiException>()),
      );
    });

    test('maps an unexpected update_sensor_states shape to a typed exception',
        () {
      // `error` is a String where a Map is expected -> TypeError, now wrapped.
      final client = HttpHaApiClient(MockClient((_) async => http.Response(
          jsonEncode({
            'u1': {'success': false, 'error': 'boom'},
          }),
          200)));
      expect(
        client.updateSensorStates(
          baseUrl: _base,
          webhookId: 'wh123',
          states: const [
            HaSensorState(uniqueId: 'u1', type: 'sensor', state: 1)
          ],
        ),
        throwsA(isA<HaApiException>()),
      );
    });
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/ha_sensor.dart';
import 'ha_api_client.dart';

/// [HaApiClient] over HTTP, speaking Home Assistant's mobile_app API:
/// registration via `POST /api/mobile_app/registrations` (Bearer token),
/// then unauthenticated pushes to `POST /api/webhook/{webhook_id}`.
class HttpHaApiClient implements HaApiClient {
  static const _timeout = Duration(seconds: 10);

  final http.Client _client;

  HttpHaApiClient(this._client);

  @override
  Future<HaRegistrationResult> registerDevice({
    required String baseUrl,
    required String token,
    required Map<String, dynamic> deviceInfo,
  }) async {
    final response = await _post(
      Uri.parse('$baseUrl/api/mobile_app/registrations'),
      headers: {
        'Authorization': 'Bearer $token',
        'Content-Type': 'application/json',
      },
      body: jsonEncode(deviceInfo),
    );
    _throwForStatus(response);
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    return HaRegistrationResult(
      webhookId: json['webhook_id'] as String,
      cloudhookUrl: json['cloudhook_url'] as String?,
      remoteUiUrl: json['remote_ui_url'] as String?,
    );
  }

  @override
  Future<void> registerSensor({
    required String baseUrl,
    required String webhookId,
    required HaSensorRegistration sensor,
  }) async {
    final response = await _postWebhook(baseUrl, webhookId, {
      'type': 'register_sensor',
      'data': sensor.toWebhookJson(),
    });
    _throwForStatus(response);
  }

  @override
  Future<List<HaWebhookSensorResult>> updateSensorStates({
    required String baseUrl,
    required String webhookId,
    required List<HaSensorState> states,
  }) async {
    final response = await _postWebhook(baseUrl, webhookId, {
      'type': 'update_sensor_states',
      'data': [for (final s in states) s.toWebhookJson()],
    });
    _throwForStatus(response);
    return _parseUpdateResults(response.body);
  }

  Future<http.Response> _postWebhook(
    String baseUrl,
    String webhookId,
    Map<String, dynamic> payload,
  ) {
    return _post(
      Uri.parse('$baseUrl/api/webhook/$webhookId'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
  }

  Future<http.Response> _post(
    Uri url, {
    required Map<String, String> headers,
    required String body,
  }) async {
    try {
      return await _client
          .post(url, headers: headers, body: body)
          .timeout(_timeout);
    } on SocketException catch (e) {
      throw HaNetworkException('Could not reach ${url.host}: ${e.message}');
    } on TimeoutException {
      throw HaNetworkException('Connection to ${url.host} timed out');
    } on http.ClientException catch (e) {
      throw HaNetworkException('Could not reach ${url.host}: ${e.message}');
    }
  }

  void _throwForStatus(http.Response response) {
    final status = response.statusCode;
    if (status >= 200 && status < 300) return;
    if (status == 401 || status == 403) throw const HaAuthException();
    if (status == 404) throw const HaNotFoundException();
    throw HaServerException(status, response.body);
  }

  /// `update_sensor_states` returns `{unique_id: {"success": bool, ...}}`,
  /// with an `error.code` (e.g. `not_registered`) on failures.
  static List<HaWebhookSensorResult> _parseUpdateResults(String body) {
    if (body.isEmpty) return const [];
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) return const [];
    return [
      for (final entry in decoded.entries)
        if (entry.value is Map<String, dynamic>)
          HaWebhookSensorResult(
            uniqueId: entry.key,
            success: (entry.value as Map<String, dynamic>)['success'] == true,
            errorCode: ((entry.value as Map<String, dynamic>)['error']
                as Map<String, dynamic>?)?['code'] as String?,
          ),
    ];
  }
}

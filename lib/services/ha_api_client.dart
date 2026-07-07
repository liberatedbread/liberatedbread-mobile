// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

// Abstraction over the Home Assistant mobile_app HTTP API. The production
// implementation is [HttpHaApiClient]; tests inject a fake. This interface is
// also the seam where an MQTT publisher or a two-way command channel would
// plug in later without touching the UI.

import '../models/ha_sensor.dart';

/// Result of a successful mobile_app device registration.
class HaRegistrationResult {
  final String webhookId;
  final String? cloudhookUrl;
  final String? remoteUiUrl;

  const HaRegistrationResult({
    required this.webhookId,
    this.cloudhookUrl,
    this.remoteUiUrl,
  });
}

/// Per-sensor outcome of an `update_sensor_states` call.
class HaWebhookSensorResult {
  final String uniqueId;
  final bool success;

  /// e.g. `not_registered` when HA no longer knows this sensor.
  final String? errorCode;

  const HaWebhookSensorResult({
    required this.uniqueId,
    required this.success,
    this.errorCode,
  });
}

sealed class HaApiException implements Exception {
  final String message;
  const HaApiException(this.message);

  @override
  String toString() => message;
}

/// 401/403 - the long-lived access token was rejected.
class HaAuthException extends HaApiException {
  const HaAuthException() : super('Home Assistant rejected the access token');
}

/// 404 - no mobile_app endpoint at this URL.
class HaNotFoundException extends HaApiException {
  const HaNotFoundException()
      : super('No Home Assistant mobile_app API at this address');
}

/// Could not reach the server at all (DNS, refused, timeout).
class HaNetworkException extends HaApiException {
  const HaNetworkException(super.message);
}

/// Any other non-success HTTP response.
class HaServerException extends HaApiException {
  final int statusCode;
  const HaServerException(this.statusCode, String body)
      : super('Home Assistant returned HTTP $statusCode: $body');
}

abstract class HaApiClient {
  /// One-time registration with HA's mobile_app integration. Returns the
  /// webhook id used for all subsequent pushes.
  Future<HaRegistrationResult> registerDevice({
    required String baseUrl,
    required String token,
    required Map<String, dynamic> deviceInfo,
  });

  /// Register (or re-register - idempotent) one sensor entity.
  Future<void> registerSensor({
    required String baseUrl,
    required String webhookId,
    required HaSensorRegistration sensor,
  });

  /// Push current states for previously registered sensors.
  Future<List<HaWebhookSensorResult>> updateSensorStates({
    required String baseUrl,
    required String webhookId,
    required List<HaSensorState> states,
  });
}

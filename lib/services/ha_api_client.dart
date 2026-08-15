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

/// Human-readable text for [e], for any surface that shows HA failures.
///
/// Lives beside the exception hierarchy so the settings screen and the
/// background forwarder describe the same failure the same way — and so no
/// caller is tempted to interpolate the raw exception (which can carry a
/// socket message or a raw server response body) into the UI.
String friendlyHaMessage(HaApiException e) {
  return switch (e) {
    HaAuthException() => 'Home Assistant rejected the access token. '
        'Create a new long-lived token and try again.',
    HaNotFoundException() => 'That address does not look like a Home '
        'Assistant server (mobile_app API not found).',
    HaNetworkException() => 'Could not reach the server. Are you on the '
        'same network? For access away from home, see the Tailscale tip '
        'below.',
    HaServerException() => 'Home Assistant returned an error. Check that it '
        'is running and up to date, then try again.',
  };
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

/// One Home Assistant entity, as `/api/states` reports it.
///
/// Deliberately not modelled per-domain: the fields below are the ones every
/// entity has, and everything domain-specific (a vacuum's `battery_level`, its
/// `supported_features`) stays in [attributes] for the caller that understands
/// it to read. A typed vacuum class here would put HA's `vacuum` schema in the
/// middle of a client that otherwise knows nothing about domains.
class HaEntityState {
  /// e.g. `vacuum.dorita`. The domain is the part before the dot.
  final String entityId;

  /// The canonical state string — for a vacuum: `cleaning`, `docked`,
  /// `paused`, `idle`, `returning`, `error`, or `unavailable`.
  final String state;

  final Map<String, dynamic> attributes;

  const HaEntityState({
    required this.entityId,
    required this.state,
    this.attributes = const {},
  });

  /// The bit before the dot: `vacuum`, `sensor`, `binary_sensor`.
  String get domain => entityId.split('.').first;

  /// The bit after it, which sibling entities share — a vacuum's bin-full
  /// binary_sensor is `binary_sensor.<object_id>_bin_full`.
  String get objectId => entityId.substring(entityId.indexOf('.') + 1);

  /// What HA shows the user. Falls back to the object id rather than to the
  /// whole entity id: `dorita` reads better than `vacuum.dorita`.
  String get friendlyName {
    final name = attributes['friendly_name'];
    return name is String && name.isNotEmpty ? name : objectId;
  }

  /// An entity HA cannot currently reach reports `unavailable`/`unknown`, and
  /// its attributes go empty. Worth asking before trusting a reading: a
  /// battery that has stopped being reported is not a battery at 0%.
  bool get isAvailable => state != 'unavailable' && state != 'unknown';

  factory HaEntityState.fromJson(Map<String, dynamic> json) => HaEntityState(
        entityId: json['entity_id'] as String,
        state: json['state'] as String? ?? 'unknown',
        attributes:
            (json['attributes'] as Map?)?.cast<String, dynamic>() ?? const {},
      );
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

  // ── Reading and commanding ────────────────────────────────────────────────
  //
  // The three above push sensor readings INTO Home Assistant over the
  // mobile_app webhook. These three go the other way, over the REST API with
  // the same long-lived token the registration used: they let the app drive a
  // device Home Assistant already owns.
  //
  // That direction is the recommended one for a Roomba. The robot serves ONE
  // local client at a time and a new connection evicts the old, so an app and
  // a Home Assistant both talking to it directly fight over the slot. If HA is
  // in the house, HA should hold the robot and the app should ask HA.

  /// Every entity in [domain] (`vacuum`, `sensor`, …) that HA knows about.
  ///
  /// Filters client-side because `/api/states` has no domain parameter — it
  /// returns the whole state machine, which is also why the caller gets a
  /// filtered list rather than everything.
  Future<List<HaEntityState>> entitiesInDomain({
    required String baseUrl,
    required String token,
    required String domain,
  });

  /// One entity's current state, or null when HA has no such entity — a robot
  /// removed from HA is a different situation from one that is unreachable,
  /// and the caller should be able to say so.
  Future<HaEntityState?> entityState({
    required String baseUrl,
    required String token,
    required String entityId,
  });

  /// Call `<domain>.<service>` against [entityId] — `vacuum.start` and
  /// friends. Returns when HA has accepted the call, which is not the same as
  /// the robot having finished acting on it.
  Future<void> callService({
    required String baseUrl,
    required String token,
    required String domain,
    required String service,
    required String entityId,
  });
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:liberated_bread_mobile/models/ha_sensor.dart';
import 'package:liberated_bread_mobile/services/ha_api_client.dart';

/// Recording [HaApiClient] fake with configurable failures.
class FakeHaApiClient implements HaApiClient {
  final List<Map<String, dynamic>> registeredDevices = [];
  final List<HaSensorRegistration> registeredSensors = [];
  final List<List<HaSensorState>> stateUpdates = [];

  /// Thrown by the corresponding call when set.
  Object? registerDeviceError;
  Object? registerSensorError;
  Object? updateError;

  /// Delay before registerDevice completes (or throws), to simulate an
  /// in-flight request.
  Duration registerDeviceDelay = Duration.zero;

  /// uniqueId -> error code returned in `updateSensorStates` results
  /// (e.g. `not_registered`).
  Map<String, String> updateErrorCodes = {};

  String webhookId = 'wh-test-0123456789abcdef';

  // ── Reading and commanding ────────────────────────────────────────────────

  /// The state machine this fake HA is holding, by entity id. Tests seed it
  /// with whatever shape the case needs — including the awkward ones, like a
  /// vacuum reporting `unavailable` with no attributes at all.
  Map<String, HaEntityState> entities = {};

  /// Every service call made, in order: `(domain, service, entityId)`.
  final List<({String domain, String service, String entityId})> serviceCalls =
      [];

  Object? readError;
  Object? callServiceError;

  @override
  Future<List<HaEntityState>> entitiesInDomain({
    required String baseUrl,
    required String token,
    required String domain,
  }) async {
    final error = readError;
    if (error != null) throw error;
    return entities.values.where((e) => e.domain == domain).toList();
  }

  @override
  Future<HaEntityState?> entityState({
    required String baseUrl,
    required String token,
    required String entityId,
  }) async {
    final error = readError;
    if (error != null) throw error;
    return entities[entityId];
  }

  @override
  Future<void> callService({
    required String baseUrl,
    required String token,
    required String domain,
    required String service,
    required String entityId,
  }) async {
    final error = callServiceError;
    if (error != null) throw error;
    serviceCalls.add((domain: domain, service: service, entityId: entityId));
  }

  @override
  Future<HaRegistrationResult> registerDevice({
    required String baseUrl,
    required String token,
    required Map<String, dynamic> deviceInfo,
  }) async {
    if (registerDeviceDelay > Duration.zero) {
      await Future<void>.delayed(registerDeviceDelay);
    }
    final error = registerDeviceError;
    if (error != null) throw error;
    registeredDevices.add({...deviceInfo, 'base_url': baseUrl});
    return HaRegistrationResult(webhookId: webhookId);
  }

  @override
  Future<void> registerSensor({
    required String baseUrl,
    required String webhookId,
    required HaSensorRegistration sensor,
  }) async {
    final error = registerSensorError;
    if (error != null) throw error;
    registeredSensors.add(sensor);
  }

  @override
  Future<List<HaWebhookSensorResult>> updateSensorStates({
    required String baseUrl,
    required String webhookId,
    required List<HaSensorState> states,
  }) async {
    final error = updateError;
    if (error != null) throw error;
    stateUpdates.add(states);
    return [
      for (final state in states)
        HaWebhookSensorResult(
          uniqueId: state.uniqueId,
          success: !updateErrorCodes.containsKey(state.uniqueId),
          errorCode: updateErrorCodes[state.uniqueId],
        ),
    ];
  }
}

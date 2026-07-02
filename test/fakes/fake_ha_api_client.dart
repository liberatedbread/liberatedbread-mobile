// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:opengreeniot_mobile/models/ha_sensor.dart';
import 'package:opengreeniot_mobile/services/ha_api_client.dart';

/// Recording [HaApiClient] fake with configurable failures.
class FakeHaApiClient implements HaApiClient {
  final List<Map<String, dynamic>> registeredDevices = [];
  final List<HaSensorRegistration> registeredSensors = [];
  final List<List<HaSensorState>> stateUpdates = [];

  /// Thrown by the corresponding call when set.
  Object? registerDeviceError;
  Object? registerSensorError;
  Object? updateError;

  /// uniqueId -> error code returned in `updateSensorStates` results
  /// (e.g. `not_registered`).
  Map<String, String> updateErrorCodes = {};

  String webhookId = 'wh-test-0123456789abcdef';

  @override
  Future<HaRegistrationResult> registerDevice({
    required String baseUrl,
    required String token,
    required Map<String, dynamic> deviceInfo,
  }) async {
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

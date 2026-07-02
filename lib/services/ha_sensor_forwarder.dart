// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/ha_sensor_mapping.dart';
import '../models/ha_config.dart';
import '../models/ha_sensor.dart';
import 'ha_api_client.dart';
import 'spec_codec.dart';

/// Observable health of the forwarder, surfaced on the settings screen.
class HaForwarderStatus extends ChangeNotifier {
  DateTime? _lastSuccess;
  String? _lastError;

  DateTime? get lastSuccess => _lastSuccess;
  String? get lastError => _lastError;

  void _recordSuccess(DateTime at) {
    _lastSuccess = at;
    _lastError = null;
    notifyListeners();
  }

  void _recordError(String message) {
    _lastError = message;
    notifyListeners();
  }
}

/// Forwards spec-decoded BLE values to Home Assistant as sensor updates.
///
/// This is the app->HA half of companion mode. It sits behind the decoded-
/// value flow (see DecodedValueWidget) and never throws: forwarding is a
/// best-effort side channel that must not break local device control.
/// Webhook calls are serialized on a single queue and coalesced per sensor
/// (latest state wins) with a minimum interval between flushes, so a chatty
/// notify characteristic cannot hammer the HA server.
///
/// An MQTT publisher or a two-way HA->BLE command channel would plug in at
/// this same seam by swapping the [HaApiClient].
class HaSensorForwarder {
  final HaApiClient _api;
  final Future<HaConfig?> Function() _readConfig;
  final Duration _minSendInterval;

  final HaForwarderStatus status = HaForwarderStatus();

  final Map<String, String> _deviceNames = {};
  final Set<String> _registeredIds = {};
  final Map<String, HaSensorRegistration> _pendingRegistrations = {};
  final Map<String, HaSensorState> _pendingStates = {};
  Future<void> _queue = Future.value();
  bool _flushScheduled = false;
  DateTime? _lastFlush;

  HaSensorForwarder({
    required HaApiClient api,
    required Future<HaConfig?> Function() readConfig,
    Duration minSendInterval = const Duration(seconds: 1),
  })  : _api = api,
        _readConfig = readConfig,
        _minSendInterval = minSendInterval;

  /// Remember a device's display name for friendlier HA entity names.
  /// Called once per connection; forwarding works without it (falls back to
  /// the device id).
  void noteDeviceName(String deviceId, String name) {
    _deviceNames[deviceId] = name;
  }

  /// Queue freshly decoded values for forwarding. Safe to call unawaited and
  /// with forwarding unconfigured - it no-ops quietly. The returned future
  /// completes when the values have been flushed (or dropped).
  Future<void> onDecodedValues({
    required String deviceId,
    required CharacteristicDto specChar,
    required List<DecodedValueDto> values,
  }) {
    for (final value in values) {
      final sensor = mapDecodedValue(
        deviceId: deviceId,
        deviceName: _deviceNames[deviceId] ?? deviceId,
        specChar: specChar,
        value: value,
      );
      if (!_registeredIds.contains(sensor.uniqueId)) {
        _pendingRegistrations[sensor.uniqueId] = sensor;
      }
      _pendingStates[sensor.uniqueId] = sensor.toState();
    }
    return _scheduleFlush();
  }

  /// Completes when all currently queued work has finished (test hook).
  Future<void> get idle => _queue;

  Future<void> _scheduleFlush() {
    if (!_flushScheduled) {
      _flushScheduled = true;
      _queue = _queue.then((_) => _flush());
    }
    return _queue;
  }

  Future<void> _flush() async {
    try {
      final last = _lastFlush;
      if (last != null) {
        final wait = _minSendInterval - DateTime.now().difference(last);
        if (wait > Duration.zero) await Future<void>.delayed(wait);
      }
      // Values arriving during the wait above ride along in this flush.
      _flushScheduled = false;
      _lastFlush = DateTime.now();

      final config = await _readConfig();
      if (config == null || !config.enabled || !config.isRegistered) {
        _pendingRegistrations.clear();
        _pendingStates.clear();
        return;
      }

      final registrations = List.of(_pendingRegistrations.values);
      _pendingRegistrations.clear();
      final states = List.of(_pendingStates.values);
      _pendingStates.clear();

      for (final sensor in registrations) {
        await _api.registerSensor(
          baseUrl: config.baseUrl,
          webhookId: config.webhookId!,
          sensor: sensor,
        );
        _registeredIds.add(sensor.uniqueId);
      }
      if (states.isNotEmpty) {
        final results = await _api.updateSensorStates(
          baseUrl: config.baseUrl,
          webhookId: config.webhookId!,
          states: states,
        );
        // HA forgot a sensor (e.g. device entry re-added): re-register it on
        // the next sighting instead of updating into the void.
        for (final result in results) {
          if (!result.success && result.errorCode == 'not_registered') {
            _registeredIds.remove(result.uniqueId);
          }
        }
      }
      status._recordSuccess(DateTime.now());
    } catch (e) {
      _flushScheduled = false;
      status._recordError(e.toString());
    }
  }
}

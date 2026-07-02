// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/ha_config.dart';
import 'package:opengreeniot_mobile/services/ha_api_client.dart';
import 'package:opengreeniot_mobile/services/ha_sensor_forwarder.dart';
import 'package:opengreeniot_mobile/services/spec_codec.dart';

import '../fakes/fake_ha_api_client.dart';

const _registered = HaConfig(
  baseUrl: 'http://ha.local:8123',
  token: 't',
  deviceId: 'app1',
  webhookId: 'wh1',
);

const _statusChar = CharacteristicDto(
  uuid: '0000fff2-0000-1000-8000-00805f9b34fb',
  name: 'Status',
  canRead: true,
  canWrite: false,
  canNotify: true,
  commands: [],
  formatFields: [],
);

DecodedValueDto _brightness(int value) => DecodedValueDto(
      name: 'brightness',
      valueType: 'uint',
      display: '$value',
      uintValue: value,
    );

const _power = DecodedValueDto(
  name: 'power_state',
  valueType: 'bool',
  display: 'on',
  boolValue: true,
);

HaSensorForwarder _forwarder(
  FakeHaApiClient api, {
  HaConfig? config = _registered,
  Duration minSendInterval = Duration.zero,
}) {
  return HaSensorForwarder(
    api: api,
    readConfig: () async => config,
    minSendInterval: minSendInterval,
  );
}

void main() {
  test('does nothing when unconfigured', () async {
    final api = FakeHaApiClient();
    final forwarder = _forwarder(api, config: null);
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(1)]);
    expect(api.registeredSensors, isEmpty);
    expect(api.stateUpdates, isEmpty);
  });

  test('does nothing when forwarding is disabled', () async {
    final api = FakeHaApiClient();
    final forwarder =
        _forwarder(api, config: _registered.copyWith(enabled: false));
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(1)]);
    expect(api.stateUpdates, isEmpty);
  });

  test('registers each sensor once, then only updates', () async {
    final api = FakeHaApiClient();
    final forwarder = _forwarder(api);

    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(10)]);
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(20)]);

    expect(api.registeredSensors, hasLength(1));
    expect(api.registeredSensors.single.uniqueId, 'ogiot_d_fff2_brightness');
    expect(api.stateUpdates, hasLength(2));
    expect(api.stateUpdates.last.single.state, 20);
  });

  test('batches all fields of one decode into a single update', () async {
    final api = FakeHaApiClient();
    final forwarder = _forwarder(api);

    await forwarder.onDecodedValues(
      deviceId: 'd',
      specChar: _statusChar,
      values: [_power, _brightness(80)],
    );

    expect(api.registeredSensors, hasLength(2));
    expect(api.stateUpdates, hasLength(1));
    expect(api.stateUpdates.single, hasLength(2));
  });

  test('coalesces rapid updates while a flush interval is pending', () async {
    final api = FakeHaApiClient();
    final forwarder =
        _forwarder(api, minSendInterval: const Duration(milliseconds: 50));

    // First flush goes out immediately; the next three arrive inside the
    // 50ms interval and must collapse into one trailing flush with the
    // latest value.
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(1)]);
    final second = forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(2)]);
    final third = forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(3)]);
    await Future.wait([second, third]);

    expect(api.stateUpdates, hasLength(2));
    expect(api.stateUpdates.last.single.state, 3);
  });

  test('re-registers a sensor HA reports as not_registered', () async {
    final api = FakeHaApiClient();
    final forwarder = _forwarder(api);

    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(10)]);
    api.updateErrorCodes = {'ogiot_d_fff2_brightness': 'not_registered'};
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(20)]);
    api.updateErrorCodes = {};
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(30)]);

    // Initial registration plus the re-registration after HA forgot it.
    expect(api.registeredSensors, hasLength(2));
  });

  test('swallows API errors and records them on status', () async {
    final api = FakeHaApiClient()
      ..registerSensorError = const HaNetworkException('no route');
    final forwarder = _forwarder(api);

    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(10)]);

    expect(forwarder.status.lastError, contains('no route'));
    expect(forwarder.status.lastSuccess, isNull);

    // Recovery clears the error.
    api.registerSensorError = null;
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(11)]);
    expect(forwarder.status.lastError, isNull);
    expect(forwarder.status.lastSuccess, isNotNull);
  });

  test('swallows config-read errors', () async {
    final api = FakeHaApiClient();
    final forwarder = HaSensorForwarder(
      api: api,
      readConfig: () async => throw StateError('no store'),
      minSendInterval: Duration.zero,
    );
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(1)]);
    expect(forwarder.status.lastError, contains('no store'));
    expect(api.stateUpdates, isEmpty);
  });

  test('re-registers everything after the webhook changes', () async {
    final api = FakeHaApiClient();
    HaConfig? config = _registered;
    final forwarder = HaSensorForwarder(
      api: api,
      readConfig: () async => config,
      minSendInterval: Duration.zero,
    );

    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(10)]);
    expect(api.registeredSensors, hasLength(1));

    // Reconnect to a different HA instance / fresh registration.
    config = _registered.copyWith(webhookId: 'wh2');
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(20)]);

    expect(api.registeredSensors, hasLength(2));
    expect(api.stateUpdates, hasLength(2));
  });

  test('re-registers after a disconnect even if the webhook id repeats',
      () async {
    final api = FakeHaApiClient();
    HaConfig? config = _registered;
    final forwarder = HaSensorForwarder(
      api: api,
      readConfig: () async => config,
      minSendInterval: Duration.zero,
    );

    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(10)]);
    config = null; // disconnected
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(20)]);
    config = _registered; // reconnected
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(30)]);

    expect(api.registeredSensors, hasLength(2));
  });

  test('disabling forwarding does not invalidate the registration cache',
      () async {
    final api = FakeHaApiClient();
    HaConfig? config = _registered;
    final forwarder = HaSensorForwarder(
      api: api,
      readConfig: () async => config,
      minSendInterval: Duration.zero,
    );

    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(10)]);
    config = _registered.copyWith(enabled: false);
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(20)]);
    config = _registered;
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(30)]);

    // Same webhook throughout: one registration, and the disabled-period
    // reading was dropped rather than sent.
    expect(api.registeredSensors, hasLength(1));
    expect(api.stateUpdates, hasLength(2));
  });

  test('uses the noted device name in entity names', () async {
    final api = FakeHaApiClient();
    final forwarder = _forwarder(api);
    forwarder.noteDeviceName('d', 'Kitchen Bulb');

    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(10)]);

    expect(api.registeredSensors.single.name, 'Kitchen Bulb Status Brightness');
  });

  test('falls back to the device id when no name was noted', () async {
    final api = FakeHaApiClient();
    final forwarder = _forwarder(api);

    await forwarder.onDecodedValues(
        deviceId: 'AA:BB', specChar: _statusChar, values: [_brightness(10)]);

    expect(api.registeredSensors.single.name, startsWith('AA:BB '));
  });
}

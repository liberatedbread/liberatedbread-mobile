// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/core/log.dart';
import 'package:liberated_bread_mobile/models/ha_config.dart';
import 'package:liberated_bread_mobile/services/ha_api_client.dart';
import 'package:liberated_bread_mobile/services/ha_sensor_forwarder.dart';
import 'package:liberated_bread_mobile/services/spec_codec.dart';

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

const _batteryChar = CharacteristicDto(
  uuid: '00002a19-0000-1000-8000-00805f9b34fb',
  name: 'Battery Level',
  canRead: true,
  canWrite: false,
  canNotify: false,
  commands: [],
  formatFields: [],
);

const _battery = DecodedValueDto(
  name: 'battery_percent',
  valueType: 'uint',
  display: '90',
  uintValue: 90,
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

    // The status line the settings screen shows is written for a person; the
    // socket detail ('no route') goes to the log, not the screen.
    expect(forwarder.status.lastError, contains('Could not reach the server'));
    expect(forwarder.status.lastError, isNot(contains('no route')));
    expect(forwarder.status.lastSuccess, isNull);

    // Recovery clears the error.
    api.registerSensorError = null;
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(11)]);
    expect(forwarder.status.lastError, isNull);
    expect(forwarder.status.lastSuccess, isNotNull);
  });

  test('does not record a success when there is no work to send', () async {
    final api = FakeHaApiClient();
    final forwarder = _forwarder(api);

    // A decode that yields no values must not report a phantom update.
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: const []);

    expect(api.registeredSensors, isEmpty);
    expect(api.stateUpdates, isEmpty);
    expect(forwarder.status.lastSuccess, isNull);
    expect(forwarder.status.lastError, isNull);
  });

  test('logs what each flush sent, and what a failure put back', () async {
    final records = Log.captureRecords();
    addTearDown(Log.reset);
    final api = FakeHaApiClient();
    final forwarder = _forwarder(api);

    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(10)]);

    // The healthy path is debug: with a chatty notify characteristic this is
    // once per minSendInterval, so it must not be info.
    final flushed = records.singleWhere((r) => r.message.startsWith('flushed'));
    expect(flushed.level, LogLevel.debug);
    expect(flushed.category, 'ha');
    expect(flushed.message, 'flushed 1 state(s), 1 new registration(s)');

    records.clear();
    api.registerSensorError = const HaNetworkException('blip');
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _batteryChar, values: [_battery]);

    final failed = records.singleWhere((r) => r.level == LogLevel.warning);
    expect(failed.category, 'ha');
    expect(failed.message, contains('requeued 1 registration(s)'));
    // The raw failure rides on the record, not smuggled into the message.
    expect(failed.error, isA<HaNetworkException>());
  });

  test('re-queues a failed reading so a later flush recovers it', () async {
    final api = FakeHaApiClient()
      ..registerSensorError = const HaNetworkException('blip');
    final forwarder = _forwarder(api);

    // A one-shot read of a read-only characteristic fails to forward.
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _batteryChar, values: [_battery]);
    expect(forwarder.status.lastError, contains('Could not reach the server'));
    expect(forwarder.status.lastError, isNot(contains('blip')));
    expect(api.stateUpdates, isEmpty);

    // Network recovers; a reading from a *different* characteristic drives
    // the next flush. The re-queued battery reading rides along with it.
    api.registerSensorError = null;
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(50)]);

    final registeredIds = api.registeredSensors.map((s) => s.uniqueId).toSet();
    expect(registeredIds, {
      'ogiot_d_2a19_battery_percent',
      'ogiot_d_fff2_brightness',
    });
    final lastBatch = {
      for (final s in api.stateUpdates.last) s.uniqueId: s.state,
    };
    expect(lastBatch, {
      'ogiot_d_2a19_battery_percent': 90,
      'ogiot_d_fff2_brightness': 50,
    });
  });

  test('a newer reading supersedes a re-queued one for the same sensor',
      () async {
    final api = FakeHaApiClient()
      ..registerSensorError = const HaNetworkException('blip');
    final forwarder = _forwarder(api);

    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(10)]);
    api.registerSensorError = null;
    await forwarder.onDecodedValues(
        deviceId: 'd', specChar: _statusChar, values: [_brightness(20)]);

    // Only the latest value is sent, not the stale re-queued one.
    expect(api.stateUpdates.last.single.state, 20);
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
    // An untyped failure must not surface as Dart's 'Bad state: no store'.
    expect(
        forwarder.status.lastError, contains('Could not send the last update'));
    expect(forwarder.status.lastError, isNot(contains('Bad state')));
    expect(forwarder.status.lastError, isNot(contains('no store')));
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

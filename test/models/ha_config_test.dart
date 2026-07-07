// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:opengreeniot_mobile/models/ha_config.dart';

void main() {
  const registered = HaConfig(
    baseUrl: 'http://ha.local:8123',
    token: 'secret',
    deviceId: 'abc123',
    webhookId: 'wh1',
    enabled: true,
  );

  test('JSON round trip preserves all fields', () {
    final decoded = HaConfig.fromJson(
        jsonDecode(jsonEncode(registered.toJson())) as Map<String, dynamic>);
    expect(decoded.baseUrl, registered.baseUrl);
    expect(decoded.token, registered.token);
    expect(decoded.deviceId, registered.deviceId);
    expect(decoded.webhookId, registered.webhookId);
    expect(decoded.enabled, registered.enabled);
  });

  test('unregistered config omits webhook and is not registered', () {
    const config = HaConfig(
      baseUrl: 'http://ha.local:8123',
      token: 'secret',
      deviceId: 'abc123',
    );
    expect(config.isRegistered, isFalse);
    expect(config.toJson().containsKey('webhook_id'), isFalse);
    expect(registered.isRegistered, isTrue);
  });

  test('enabled defaults to true when absent from JSON', () {
    final config = HaConfig.fromJson({
      'base_url': 'u',
      'token': 't',
      'device_id': 'd',
    });
    expect(config.enabled, isTrue);
  });

  test('copyWith replaces only the given fields', () {
    final disabled = registered.copyWith(enabled: false);
    expect(disabled.enabled, isFalse);
    expect(disabled.baseUrl, registered.baseUrl);
    expect(disabled.webhookId, registered.webhookId);
  });
}

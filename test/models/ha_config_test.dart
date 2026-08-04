// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:liberated_bread_mobile/models/ha_config.dart';

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

  test('toString redacts the token and webhook id', () {
    // Defense in depth: `'$config'` is how a whole secret-bearing object ends
    // up in a log line, so the object refuses to render its own secrets.
    final text = registered.toString();
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('wh1')));
    expect(text, contains('<redacted>'));
    // The non-secret fields stay useful.
    expect(text, contains('http://ha.local:8123'));
    expect(text, contains('abc123'));
  });

  test('toString distinguishes an unset webhook from a redacted one', () {
    const unregistered = HaConfig(
      baseUrl: 'http://ha.local:8123',
      token: 'secret',
      deviceId: 'abc123',
    );
    expect(unregistered.toString(), contains('webhookId: <none>'));
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

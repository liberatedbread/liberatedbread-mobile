// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

import '../core/log.dart';

/// Persisted Home Assistant companion-mode configuration.
class HaConfig {
  /// Normalized base URL (no trailing slash), e.g. `http://ha.local:8123`.
  final String baseUrl;

  /// Long-lived access token, kept so the user can re-register later.
  final String token;

  /// Webhook id returned by mobile_app registration; null until registered.
  final String? webhookId;

  /// Stable random id identifying this app install to Home Assistant.
  final String deviceId;

  /// Whether sensor forwarding is currently enabled.
  final bool enabled;

  const HaConfig({
    required this.baseUrl,
    required this.token,
    required this.deviceId,
    this.webhookId,
    this.enabled = true,
  });

  bool get isRegistered => webhookId != null;

  HaConfig copyWith({
    String? baseUrl,
    String? token,
    String? webhookId,
    String? deviceId,
    bool? enabled,
  }) {
    return HaConfig(
      baseUrl: baseUrl ?? this.baseUrl,
      token: token ?? this.token,
      webhookId: webhookId ?? this.webhookId,
      deviceId: deviceId ?? this.deviceId,
      enabled: enabled ?? this.enabled,
    );
  }

  Map<String, dynamic> toJson() => {
        'base_url': baseUrl,
        'token': token,
        if (webhookId != null) 'webhook_id': webhookId,
        'device_id': deviceId,
        'enabled': enabled,
      };

  /// Deliberately redacted: [token] and [webhookId] are secrets, and the
  /// default `Instance of 'HaConfig'` gives a future call site nothing useful,
  /// which is how `'$config'` ends up in a log line. This makes interpolating
  /// the whole object both useful AND safe.
  @override
  String toString() => 'HaConfig(baseUrl: $baseUrl, token: ${redact(token)}, '
      'webhookId: ${redact(webhookId)}, deviceId: $deviceId, '
      'enabled: $enabled)';

  factory HaConfig.fromJson(Map<String, dynamic> json) => HaConfig(
        baseUrl: json['base_url'] as String,
        token: json['token'] as String,
        webhookId: json['webhook_id'] as String?,
        deviceId: json['device_id'] as String,
        enabled: json['enabled'] as bool? ?? true,
      );
}

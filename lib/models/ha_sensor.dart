// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0

// Payload models for Home Assistant's mobile_app webhook API.

/// A sensor definition for a `register_sensor` webhook message.
class HaSensorRegistration {
  final String uniqueId;
  final String name;

  /// `sensor` or `binary_sensor`.
  final String type;

  /// bool for binary sensors, num or String for regular sensors.
  final Object? state;
  final String? deviceClass;
  final String? unitOfMeasurement;
  final String? icon;

  const HaSensorRegistration({
    required this.uniqueId,
    required this.name,
    required this.type,
    required this.state,
    this.deviceClass,
    this.unitOfMeasurement,
    this.icon,
  });

  /// The `data` payload of a `register_sensor` webhook message.
  Map<String, dynamic> toWebhookJson() => {
        'unique_id': uniqueId,
        'name': name,
        'type': type,
        'state': state,
        if (deviceClass != null) 'device_class': deviceClass,
        if (unitOfMeasurement != null) 'unit_of_measurement': unitOfMeasurement,
        if (icon != null) 'icon': icon,
      };

  /// The state-only view of this sensor for `update_sensor_states`.
  HaSensorState toState() =>
      HaSensorState(uniqueId: uniqueId, type: type, state: state, icon: icon);
}

/// One entry in an `update_sensor_states` webhook message.
class HaSensorState {
  final String uniqueId;
  final String type;
  final Object? state;
  final String? icon;

  const HaSensorState({
    required this.uniqueId,
    required this.type,
    required this.state,
    this.icon,
  });

  Map<String, dynamic> toWebhookJson() => {
        'unique_id': uniqueId,
        'type': type,
        'state': state,
        if (icon != null) 'icon': icon,
      };
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import '../core/hex.dart';
import '../services/spec_codec.dart';
import 'ble_discovered_service.dart';

enum HealthMeasurementKind { pulseOximeter, bloodPressure }

enum HealthMeasurementMode { livePoll, historySync, savedRecords }

class HealthMeasurementPlan {
  final HealthMeasurementKind kind;
  final HealthMeasurementMode mode;
  final String serviceUuid;
  final String? commandUuid;
  final String responseUuid;
  final Set<String> handledCharacteristicUuids;

  const HealthMeasurementPlan({
    required this.kind,
    required this.mode,
    required this.serviceUuid,
    this.commandUuid,
    required this.responseUuid,
    required this.handledCharacteristicUuids,
  });
}

HealthMeasurementPlan? healthMeasurementPlan(
  DeviceSpecDto spec,
  List<BleDiscoveredService> discovered,
) {
  return switch (spec.categoryHierarchy.lastOrNull) {
    'pulse_oximetry' => _pulseOximeterPlan(spec, discovered),
    'blood_pressure' => _bloodPressurePlan(spec, discovered),
    _ => null,
  };
}

HealthMeasurementPlan? _pulseOximeterPlan(
  DeviceSpecDto spec,
  List<BleDiscoveredService> discovered,
) {
  final history = _findCommand(spec, 'get_measurements_page');
  if (history != null && _findCommand(spec, 'set_datetime') != null) {
    final response = history.service.characteristics
        .where(
          (char) =>
              char.canNotify &&
              char.formatFields.isNotEmpty &&
              _isDiscovered(discovered, history.service.uuid, char.uuid),
        )
        .firstOrNull;
    if (response == null ||
        !_isDiscovered(discovered, history.service.uuid, history.char.uuid)) {
      return null;
    }
    return HealthMeasurementPlan(
      kind: HealthMeasurementKind.pulseOximeter,
      mode: HealthMeasurementMode.historySync,
      serviceUuid: history.service.uuid,
      commandUuid: history.char.uuid,
      responseUuid: response.uuid,
      handledCharacteristicUuids: {
        normalizeUuid(history.char.uuid),
        normalizeUuid(response.uuid),
      },
    );
  }

  final poll = _findCommand(spec, 'poll_measurement');
  if (poll == null) return null;
  final response = poll.service.characteristics
      .where(
        (char) =>
            char.canNotify &&
            char.uuid != poll.char.uuid &&
            _isDiscovered(discovered, poll.service.uuid, char.uuid),
      )
      .firstOrNull;
  if (response == null ||
      !_isDiscovered(discovered, poll.service.uuid, poll.char.uuid)) {
    return null;
  }
  return HealthMeasurementPlan(
    kind: HealthMeasurementKind.pulseOximeter,
    mode: HealthMeasurementMode.livePoll,
    serviceUuid: poll.service.uuid,
    commandUuid: poll.char.uuid,
    responseUuid: response.uuid,
    handledCharacteristicUuids: {
      normalizeUuid(poll.char.uuid),
      normalizeUuid(response.uuid),
    },
  );
}

HealthMeasurementPlan? _bloodPressurePlan(
  DeviceSpecDto spec,
  List<BleDiscoveredService> discovered,
) {
  final systolic = spec.entities
      .where((entity) => entity.valueField == 'systolic_sfloat')
      .firstOrNull;
  final diastolic = spec.entities
      .where((entity) => entity.valueField == 'diastolic_sfloat')
      .firstOrNull;
  final charUuid = systolic?.stateCharacteristic;
  if (systolic == null ||
      diastolic?.stateCharacteristic != charUuid ||
      charUuid == null) {
    return null;
  }
  for (final service in spec.services) {
    for (final char in service.characteristics) {
      if (normalizeUuid(char.uuid) == normalizeUuid(charUuid) &&
          char.canNotify &&
          // The decoder reads a whole `flags` byte at fixed offsets. A
          // record laid out otherwise (QardioArm names each flag bit and
          // walks an optional tail) would be claimed here, have its own
          // cards hidden, and then never decode.
          char.formatFields.any((field) => field.name == 'flags') &&
          _isDiscovered(discovered, service.uuid, charUuid)) {
        final handled = spec.entities
            .where(
              (entity) =>
                  entity.deviceClass != 'battery' &&
                  entity.stateCharacteristic != null &&
                  normalizeUuid(entity.stateCharacteristic!) ==
                      normalizeUuid(charUuid),
            )
            .map((entity) => normalizeUuid(entity.stateCharacteristic!))
            .toSet();
        return HealthMeasurementPlan(
          kind: HealthMeasurementKind.bloodPressure,
          mode: HealthMeasurementMode.savedRecords,
          serviceUuid: service.uuid,
          responseUuid: char.uuid,
          handledCharacteristicUuids: handled,
        );
      }
    }
  }
  return null;
}

({ServiceDto service, CharacteristicDto char})? _findCommand(
  DeviceSpecDto spec,
  String name,
) {
  for (final service in spec.services) {
    for (final char in service.characteristics) {
      if (char.commands.any((command) => command.name == name)) {
        return (service: service, char: char);
      }
    }
  }
  return null;
}

bool _isDiscovered(
  List<BleDiscoveredService> services,
  String serviceUuid,
  String charUuid,
) => services.any(
  (service) =>
      normalizeUuid(service.uuid) == normalizeUuid(serviceUuid) &&
      service.characteristics.any(
        (char) =>
            normalizeUuid(char.uuid) == normalizeUuid(charUuid) &&
                char.canNotify ||
            normalizeUuid(char.uuid) == normalizeUuid(charUuid) &&
                char.canWrite,
      ),
);

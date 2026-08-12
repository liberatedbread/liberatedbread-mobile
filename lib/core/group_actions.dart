// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
//
// Resolves group operations ("turn all lights off", "read every battery")
// against one member device's spec and its discovered GATT services.
//
// Everything here works from the spec's *entity action roles*
// (`EntityActionDto.role`: turn_on / turn_off / set_brightness) and entity
// read bindings — never from raw command names. Roles are the catalogue's
// cross-device vocabulary: `power_off`, `screen_off` and `plug_turn_off` are
// three commands and one role. Working role-first is also what makes bulk
// sends safe by construction: the Rust side only resolves roles into
// [EntityActionDto]s, so `advanced: true` commands (factory_reset, calibration
// modes) and lock verbs are unreachable from a group operation — there is no
// blacklist to keep current.
//
// The shape mirrors `detectAlertActions` in find_device.dart: pure functions
// over (spec, discovered services) that return ready-to-send descriptors, with
// the same admission rule — a command's service|characteristic pair must have
// been discovered on THIS unit and be writable, because a spec may describe a
// bigger variant than the hardware in front of us.

import 'package:flutter/material.dart';

import '../models/ble_discovered_service.dart';
import '../services/spec_codec.dart';
import 'decoded_number.dart';
import 'entity_live_value.dart';
import 'find_device.dart' show discoveredPairKey, discoveredWritablePairs;
import 'hex.dart';

/// The Bluetooth SIG Battery Service and its Battery Level characteristic —
/// the no-spec-needed battery path, mirrored from
/// `rust/src/protocol/profiles/battery.rs`.
const String batteryServiceUuid = '0000180f-0000-1000-8000-00805f9b34fb';
const String batteryLevelCharUuid = '00002a19-0000-1000-8000-00805f9b34fb';

// Normalized once: these two are compared inside per-service and
// per-characteristic loops that hot paths re-enter per member.
final String _normalizedBatteryService = normalizeUuid(batteryServiceUuid);
final String _normalizedBatteryLevel = normalizeUuid(batteryLevelCharUuid);

/// The decoded field name the SIG battery profile emits, pinned by
/// `rust/src/protocol/profiles/battery.rs`. Spec-declared battery entities do
/// NOT get to assume this — a spec `format:` on 2a19 overrides the profile
/// and may name the field anything, which is why the spec path reads
/// `entity.valueField` instead.
const String _sigBatteryField = 'battery_percent';

/// A bulk operation a group can run across its members.
enum GroupOp {
  turnOn(Icons.power_settings_new, 'Turn all on'),
  turnOff(Icons.power_off_outlined, 'Turn all off'),
  setBrightness(Icons.brightness_6_outlined, 'Set brightness'),
  readBattery(Icons.battery_4_bar_outlined, 'Read batteries'),
  readSensors(Icons.sensors, 'Read sensors');

  final IconData icon;
  final String label;

  const GroupOp(this.icon, this.label);

  String get roleName => switch (this) {
        turnOn => 'turn_on',
        turnOff => 'turn_off',
        setBrightness => 'set_brightness',
        readBattery || readSensors => '',
      };

  /// Whether this op writes commands (vs. reading values). Derived from
  /// [roleName] — command ops are exactly the ones bound to an entity action
  /// role — so a new op cannot be in one partition and out of the other.
  bool get isCommand => roleName.isNotEmpty;

  /// Whether the runner can attempt this op for a member with no resolved
  /// spec. Battery reads can: the SIG Battery Service decodes through the
  /// standard profile with no spec at all. Both the runner's skip logic and
  /// the detail screen's button enablement derive from this, so the two
  /// cannot disagree about what a spec-less member may do.
  bool get worksWithoutSpec => this == readBattery;
}

/// One encodable command write resolved for a member: encode [commandName] on
/// [charUuid] with [params] against the member's spec YAML, then write to the
/// action's own service/characteristic pair (the spec-form UUIDs, exactly as
/// the light/switch control cards send).
class GroupWrite {
  final String serviceUuid;
  final String charUuid;
  final String commandName;
  final Map<String, double> params;

  const GroupWrite({
    required this.serviceUuid,
    required this.charUuid,
    required this.commandName,
    required this.params,
  });
}

/// One value read resolved for a member.
///
/// [specBased] says which decode dialect applies: the member's spec YAML
/// (entity semantics in [entity]), or the SIG battery profile with no spec at
/// all. [serviceUuid] is the *discovered* service that owns the
/// characteristic, which is what both the read and the decode take.
class GroupRead {
  final String serviceUuid;
  final String charUuid;
  final bool specBased;
  final EntityDto? entity;
  final String label;

  const GroupRead({
    required this.serviceUuid,
    required this.charUuid,
    required this.specBased,
    this.entity,
    required this.label,
  });
}

/// Which group operations [spec] supports at all, knowable before any
/// connection. Used for eligibility badges and to skip members without
/// spending radio time on them.
///
/// `readBattery` is special-cased by callers: a member whose spec says
/// nothing about batteries may still expose the SIG Battery Service, so the
/// runner attempts the read for every member regardless of this set — this
/// only reports what the *spec* promises (including a declared SIG battery
/// service, format block or not, since the profile can decode 2a19 without
/// one).
Set<GroupOp> supportedGroupOps(DeviceSpecDto spec) {
  final ops = <GroupOp>{};
  for (final (entity: _, :action) in _controlActions(spec)) {
    switch (action.role) {
      case 'turn_on':
        ops.add(GroupOp.turnOn);
      case 'turn_off':
        ops.add(GroupOp.turnOff);
      case 'set_brightness':
        ops.add(GroupOp.setBrightness);
    }
  }
  for (final entity in spec.entities) {
    if (_isSpecBatteryEntity(entity)) ops.add(GroupOp.readBattery);
    if (_isSensorEntity(entity)) ops.add(GroupOp.readSensors);
  }
  if (_declaresSigBattery(spec)) ops.add(GroupOp.readBattery);
  return ops;
}

/// The control-entity actions a group command op may bind: light/switch
/// entities' sendable actions. ONE definition, consumed by both
/// [supportedGroupOps] (eligibility) and [resolveGroupWrites] (execution) —
/// two hand-kept copies of this filter would let a badge promise what a run
/// then never writes, or vice versa.
Iterable<({EntityDto entity, EntityActionDto action})> _controlActions(
  DeviceSpecDto spec,
) sync* {
  for (final entity in spec.entities) {
    if (entity.platform != 'light' && entity.platform != 'switch') continue;
    for (final action in entity.actions) {
      if (action.commandName == null) continue;
      yield (entity: entity, action: action);
    }
  }
}

bool _isSpecBatteryEntity(EntityDto entity) =>
    entity.deviceClass == 'battery' &&
    entity.hasFormat &&
    entity.stateCharacteristic != null;

/// Sensor-snapshot candidates: the same platforms the device screen renders
/// as readings, minus batteries (they have their own op).
bool _isSensorEntity(EntityDto entity) =>
    (entity.platform == null ||
        entity.platform == 'sensor' ||
        entity.platform == 'binary_sensor') &&
    entity.deviceClass != 'battery' &&
    entity.hasFormat &&
    entity.stateCharacteristic != null;

bool _declaresSigBattery(DeviceSpecDto spec) {
  for (final service in spec.services) {
    if (normalizeUuid(service.uuid) != _normalizedBatteryService) continue;
    for (final char in service.characteristics) {
      if (normalizeUuid(char.uuid) == _normalizedBatteryLevel) return true;
    }
  }
  return false;
}

/// Map [percent] (0–100) onto an action's declared parameter range. The
/// catalogue's brightness ranges genuinely differ — 0–100, 5–100, 0–255,
/// 1–255 — so a group brightness has to be a percentage re-encoded per
/// device; the defaults (0 and 255) match what the light card assumes when a
/// spec declares no bounds.
double brightnessDeviceValue(EntityActionDto action, double percent) {
  final min = action.min ?? 0;
  final max = action.max ?? 255;
  final fraction = percent.clamp(0.0, 100.0) / 100.0;
  return (min + (max - min) * fraction).roundToDouble();
}

/// Parameter values for one group write, mirroring the control cards: only
/// the UI-owned parameters are sent (the encoder fills the rest from spec
/// defaults). For brightness roles the slider value goes into
/// `brightness`/`level`; on/off actions that carry parameters (a light whose
/// `turn_on` is really "set full color") get full-on values — white at full
/// brightness — since a group turn-on has no per-device card state to draw
/// from. Unrecognized parameters get 0.0, exactly as the light card sends.
Map<String, double> _paramsFor(EntityActionDto action, {double? brightness}) =>
    {
      for (final p in action.userParams)
        p: switch (p) {
          'brightness' || 'level' => brightness ?? (action.max ?? 255),
          'red' || 'green' || 'blue' => 255.0,
          _ => 0.0,
        },
    };

/// Resolve the concrete writes a command op performs on one member, given the
/// services discovery actually found. Empty means the member cannot take part
/// (report it as skipped, never silently dropped).
List<GroupWrite> resolveGroupWrites({
  required GroupOp op,
  required DeviceSpecDto spec,
  required List<BleDiscoveredService> services,
  double? brightnessPercent,
}) {
  assert(op.isCommand, 'read ops resolve through resolve*Reads');

  // The admission set detectAlertActions uses, from the one shared builder:
  // writable pairs, because vendor channels reuse characteristic UUIDs
  // across services.
  final writable = discoveredWritablePairs(services);

  final writes = <GroupWrite>[];
  for (final (:entity, :action) in _controlActions(spec)) {
    if (action.role != op.roleName) continue;
    if (!writable.containsKey(
      discoveredPairKey(action.serviceUuid, action.characteristicUuid),
    )) {
      continue;
    }
    writes.add(GroupWrite(
      serviceUuid: action.serviceUuid,
      charUuid: action.characteristicUuid,
      commandName: action.commandName!,
      params: switch (op) {
        GroupOp.setBrightness => _paramsFor(
            action,
            brightness: brightnessDeviceValue(action, brightnessPercent ?? 100),
          ),
        // Switch cards send no parameters for on/off; light actions carrying
        // user params get full-on defaults (see _paramsFor).
        _ => entity.platform == 'switch' ? const {} : _paramsFor(action),
      },
    ));
  }
  return writes;
}

/// Resolve battery reads for one member. The spec's own battery entities win
/// when any resolve — the spec knows the device's dialect, and its `format:`
/// on 2a19 would override the profile's field name anyway (same precedence
/// detectAlertActions gives spec commands over the Immediate Alert profile).
/// The SIG path is the fallback and needs no spec at all, which is why every
/// member gets offered a battery read.
List<GroupRead> resolveBatteryReads({
  DeviceSpecDto? spec,
  required List<BleDiscoveredService> services,
}) {
  final reads = <GroupRead>[];
  final seenChars = <String>{};

  if (spec != null) {
    for (final entity in spec.entities) {
      if (!_isSpecBatteryEntity(entity)) continue;
      final stateChar = entity.stateCharacteristic!;
      final owning = _owningReadableService(spec, services, stateChar);
      if (owning == null) continue;
      if (!seenChars.add(normalizeUuid(stateChar))) continue;
      reads.add(GroupRead(
        serviceUuid: owning,
        charUuid: stateChar,
        specBased: true,
        entity: entity,
        label: entity.name,
      ));
    }
  }
  if (reads.isNotEmpty) return reads;

  // SIG fallback: only the Battery Level under the Battery Service itself,
  // for the same reason detectAlertActions pins Alert Level to Immediate
  // Alert — 2a19 hanging off some vendor service is not the standard profile.
  for (final service in services) {
    if (normalizeUuid(service.uuid) != _normalizedBatteryService) continue;
    for (final char in service.characteristics) {
      if (normalizeUuid(char.uuid) != _normalizedBatteryLevel) continue;
      if (!char.canRead) continue;
      return [
        GroupRead(
          serviceUuid: service.uuid,
          charUuid: char.uuid,
          specBased: false,
          label: 'Battery',
        ),
      ];
    }
  }
  return reads;
}

/// Resolve the sensor-snapshot reads for one member: the first [cap] distinct
/// readings the device screen would show, in spec order. Capped because a
/// group snapshot is a glance ("is the greenhouse OK"), not the device
/// screen — airthings alone declares 25 entities.
List<GroupRead> resolveSensorReads({
  required DeviceSpecDto spec,
  required List<BleDiscoveredService> services,
  int cap = 6,
}) {
  final reads = <GroupRead>[];
  // Same dedupe key as the control panel: a family spec binds one logical
  // reading once per variant, and real hardware carries exactly one of them.
  final seen = <String>{};
  for (final entity in spec.entities) {
    if (reads.length >= cap) break;
    if (!_isSensorEntity(entity)) continue;
    final stateChar = entity.stateCharacteristic!;
    final owning = _owningReadableService(spec, services, stateChar);
    if (owning == null) continue;
    if (!seen.add('${entity.platform}|${entity.name}')) continue;
    reads.add(GroupRead(
      serviceUuid: owning,
      charUuid: stateChar,
      specBased: true,
      entity: entity,
      label: entity.name,
    ));
  }
  return reads;
}

/// The discovered service owning [charUuid] with read permission, or null.
///
/// "Owning" is decided by the SPEC, not by discovery order: characteristic
/// UUIDs repeat across services (the same hazard the write path pair-keys
/// against), and binding to the first discovered twin would read another
/// channel's bytes and decode them with this entity's format — a garbage
/// number reported as a healthy reading. Only when the spec declares the
/// characteristic under no service at all does discovery order decide,
/// which then can't be wrong two ways.
String? _owningReadableService(
  DeviceSpecDto spec,
  List<BleDiscoveredService> services,
  String charUuid,
) {
  final target = normalizeUuid(charUuid);
  final declaredUnder = <String>{
    for (final service in spec.services)
      if (service.characteristics.any((c) => normalizeUuid(c.uuid) == target))
        normalizeUuid(service.uuid),
  };
  for (final service in services) {
    if (declaredUnder.isNotEmpty &&
        !declaredUnder.contains(normalizeUuid(service.uuid))) {
      continue;
    }
    for (final char in service.characteristics) {
      if (normalizeUuid(char.uuid) == target && char.canRead) {
        return service.uuid;
      }
    }
  }
  return null;
}

/// Render one completed group read for a member row: "87 %", "23.5 °C",
/// "heating". Null when the decode produced nothing displayable.
///
/// Spec-based reads go through [EntityLiveValue] — the ONE place the
/// value-picking, scaling and unit rules live — so a group row and the
/// device screen cannot disagree about what the same characteristic read
/// means. The SIG path reads the profile's pinned `battery_percent` field
/// and states the unit the SIG defines for it.
String? groupReadingDisplay(GroupRead read, List<DecodedValueDto> decoded) {
  if (decoded.isEmpty) return null;
  if (!read.specBased) {
    final value =
        decoded.where((d) => d.name == _sigBatteryField).firstOrNull ??
            decoded.first;
    return '${labelledTextOf(value)} %';
  }
  final entity = read.entity;
  if (entity == null) return null;
  final live = EntityLiveValue(
    entity: entity,
    status: EntityValueStatus.live,
    decoded: decoded,
  );
  final text = live.display;
  if (text == null) return null;
  final unit = live.unit;
  return unit == null ? text : '$text $unit';
}

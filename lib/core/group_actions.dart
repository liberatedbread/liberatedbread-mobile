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
// modes) are unreachable from a group operation — there is no blacklist to
// keep current.
//
// Lock verbs are the exception roles cannot carry. The schema has no lock
// platform, so a lock's bolt is a `switch` whose turn_off IS unlock (SESAME,
// Yale), and every switch on a lock asks first on the device screen because
// which way retracts a bolt is not something a spec states. A group run has
// nobody to ask, so a lock's switches — and any switch marked as a lock,
// whatever device it is on — never bind a group command ([_isLockControl]).
// Locks stay groupable for what is safe in bulk: reading their batteries.
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
import 'device_category.dart';
import 'entity_action_params.dart';
import 'entity_live_value.dart';
import 'find_device.dart' show discoveredPairKey, discoveredWritablePairs;
import 'hex.dart';
import 'pride_flags.dart';

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
  readSensors(Icons.sensors, 'Read sensors'),

  /// Flags on what can show a picture, the rainbow on the lights. Bound to no
  /// one role, since what it sends depends on what each member can show: see
  /// [resolvePrideSurface].
  prideMode(Icons.flag_outlined, 'Pride mode');

  final IconData icon;
  final String label;

  const GroupOp(this.icon, this.label);

  String get roleName => switch (this) {
    turnOn => 'turn_on',
    turnOff => 'turn_off',
    setBrightness => 'set_brightness',
    readBattery || readSensors || prideMode => '',
  };

  /// Whether this op writes commands (vs. reading values). Derived from
  /// [roleName] — every other command op is bound to an entity action role —
  /// so a new op cannot be in one partition and out of the other.
  bool get isCommand => roleName.isNotEmpty || this == prideMode;

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
Set<GroupOp> supportedGroupOps(
  DeviceSpecDto spec, {
  List<String>? matchedVariants,
}) {
  final ops = <GroupOp>{};
  for (final (entity: _, :action) in _controlActions(
    spec,
    matchedVariants: matchedVariants,
  )) {
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
  if (imageSurfaceForPride(spec) != null ||
      _prideColorActions(spec, matchedVariants: matchedVariants).isNotEmpty ||
      _prideRainbowEffects(spec, matchedVariants: matchedVariants).isNotEmpty) {
    ops.add(GroupOp.prideMode);
  }
  return ops;
}

/// One side of a panel with a reported size that could not be learned: a size
/// the panel's bound allows, small enough to fit whatever it turns out to be.
int initialPanelSide(int? max) =>
    max == null || max >= 16 ? 16 : max.clamp(1, 16);

/// One side of a panel of stated size. A side a spec leaves open (a scrolling
/// badge states only its height) follows the [other], and neither gets past
/// what is plausibly a screen.
int fixedPanelSide(int? side, {int? other}) =>
    (side ?? other ?? 64).clamp(1, 256);

/// What a member shows when it holds pictures rather than a colour.
enum PridePicture {
  /// A display: a flag, or several in turn where it can hold an animation.
  flags,

  /// Lights with an addressable canvas, like a string laid out in rows: the
  /// rainbow along its length. A flag is meant to be read as a picture, and a
  /// strand does not read as one.
  rainbow,
}

/// What [spec]'s image surface is good for in pride mode, or null when it has
/// no surface this build can encode, or one that would be wasted on this.
///
/// By category and not merely by capability, because the catalogue's other
/// image surfaces are printers: a group's pride mode must not run a label
/// roll out, and a pair of glasses is not showing anybody a flag.
///
/// One-bit surfaces sit it out too: their encoders light a pixel on a
/// threshold that every stripe of a flag clears, so a Magic Display would go
/// solid and report a flag it is not showing.
PridePicture? imageSurfaceForPride(DeviceSpecDto spec) {
  final upload = spec.imageUpload;
  if (upload == null || !upload.encodable) return null;
  if (upload.format == '1bit-bitmap') return null;
  return switch (DeviceCategory.parse(spec.category)) {
    DeviceCategory.display => PridePicture.flags,
    DeviceCategory.light => PridePicture.rainbow,
    _ => null,
  };
}

/// Whether [userParams] can state a colour as three channels, by the names the
/// light cards fill. A packed `rgb` or a lone `hue` is the network path's
/// [networkColorValues]; no BLE spec binds either.
bool _carriesRgb(List<String> userParams) =>
    userParams.contains('red') &&
    userParams.contains('green') &&
    userParams.contains('blue');

/// The `set_color` actions a colour can be written through.
List<({EntityDto entity, EntityActionDto action})> _prideColorActions(
  DeviceSpecDto spec, {
  List<String>? matchedVariants,
}) => [
  for (final bound in _controlActions(spec, matchedVariants: matchedVariants))
    if (bound.entity.platform == 'light' &&
        bound.action.role == 'set_color' &&
        _carriesRgb(bound.action.userParams))
      bound,
];

/// A light with no colour to set but a rainbow among its effects: the
/// `set_effect` action, and the value that picks the rainbow.
///
/// The BLE twin of the network path's rainbow effect, with one difference:
/// here the spec states the effect list itself (a parameter's `labels`), so
/// the index is known before anything is sent. The Lumalou's night light is
/// the case — ten presets, the tenth a rainbow, and no RGB at all.
List<({EntityDto entity, EntityActionDto action, double value})>
_prideRainbowEffects(DeviceSpecDto spec, {List<String>? matchedVariants}) {
  final withColor = {
    for (final bound in _prideColorActions(
      spec,
      matchedVariants: matchedVariants,
    ))
      bound.entity.name,
  };
  return [
    for (final bound in _controlActions(spec, matchedVariants: matchedVariants))
      if (bound.entity.platform == 'light' &&
          bound.action.role == 'set_effect' &&
          !withColor.contains(bound.entity.name))
        if (_rainbowValue(spec, bound.action) case final value?)
          (entity: bound.entity, action: bound.action, value: value),
  ];
}

/// The raw value of the rainbow among [action]'s effect labels, or null when
/// it takes no single labelled value or none of them is a rainbow. Labels pair
/// with `allowed` when the parameter lists values, and count up from `min`
/// otherwise.
double? _rainbowValue(DeviceSpecDto spec, EntityActionDto action) {
  if (action.userParams.length != 1) return null;
  final name = action.userParams.single;
  final service = normalizeUuid(action.serviceUuid);
  final characteristic = normalizeUuid(action.characteristicUuid);
  for (final s in spec.services) {
    if (normalizeUuid(s.uuid) != service) continue;
    for (final c in s.characteristics) {
      if (normalizeUuid(c.uuid) != characteristic) continue;
      for (final command in c.commands) {
        if (command.name != action.commandName) continue;
        for (final p in command.parameters) {
          if (p.name != name) continue;
          final labels = p.labels;
          if (labels == null) return null;
          final index = rainbowEffectIndex(labels);
          if (index == null) return null;
          final allowed = p.allowed;
          if (allowed != null) {
            return index < allowed.length ? allowed[index].toDouble() : null;
          }
          final value = (p.min ?? 0) + index;
          final max = p.max;
          return max == null || value <= max ? value : null;
        }
      }
    }
  }
  return null;
}

/// The writes that put one [color] on a member's lights: on first, for the
/// lights whose colour command does not itself wake them, then the colour.
/// A light with no colour but a rainbow effect takes the rainbow instead.
/// Empty when it has no light that takes either, or this unit lacks the
/// characteristic.
List<GroupWrite> resolvePrideColorWrites({
  required DeviceSpecDto spec,
  required List<BleDiscoveredService> services,
  required Rgb color,
  List<String>? matchedVariants,
}) {
  final writable = discoveredWritablePairs(services);
  bool found(EntityActionDto action) => writable.containsKey(
    discoveredPairKey(action.serviceUuid, action.characteristicUuid),
  );
  final writes = <GroupWrite>[];
  for (final (:entity, :action) in _prideColorActions(
    spec,
    matchedVariants: matchedVariants,
  )) {
    if (!found(action)) continue;
    for (final on in entity.actions) {
      if (on.role != 'turn_on' || on.commandName == null || !found(on)) {
        continue;
      }
      writes.add(
        GroupWrite(
          serviceUuid: on.serviceUuid,
          charUuid: on.characteristicUuid,
          commandName: on.commandName!,
          params: _paramsFor(on, color: color),
        ),
      );
    }
    writes.add(
      GroupWrite(
        serviceUuid: action.serviceUuid,
        charUuid: action.characteristicUuid,
        commandName: action.commandName!,
        params: _paramsFor(action, color: color),
      ),
    );
  }
  for (final (:entity, :action, :value) in _prideRainbowEffects(
    spec,
    matchedVariants: matchedVariants,
  )) {
    if (!found(action)) continue;
    // On first, unless "on" is the effect's own command with another value
    // (the Lumalou's is warm white): that would only flash before the
    // rainbow replaced it.
    for (final on in entity.actions) {
      if (on.role != 'turn_on' ||
          on.commandName == null ||
          on.commandName == action.commandName ||
          !found(on)) {
        continue;
      }
      writes.add(
        GroupWrite(
          serviceUuid: on.serviceUuid,
          charUuid: on.characteristicUuid,
          commandName: on.commandName!,
          params: _paramsFor(on),
        ),
      );
    }
    writes.add(
      GroupWrite(
        serviceUuid: action.serviceUuid,
        charUuid: action.characteristicUuid,
        commandName: action.commandName!,
        params: action.withFixed({action.userParams.single: value}),
      ),
    );
  }
  return writes;
}

/// The control-entity actions a group command op may bind: light/switch
/// entities' sendable actions. ONE definition, consumed by both
/// [supportedGroupOps] (eligibility) and [resolveGroupWrites] (execution) —
/// two hand-kept copies of this filter would let a badge promise what a run
/// then never writes, or vice versa.
///
/// When the narrowing is null or empty (a codec failure, or a unit whose
/// name matches no variant — a renamed seeblue), only the FIRST variant-scoped
/// entity of each name is kept: the device panel's first-wins name dedupe.
/// Without it a group `turn_on` wrote seeblue's `direct_power_on` AND
/// `ledglow_v2_power_on` to the one ffe9 characteristic back to back — the
/// wrong dialect on the wire, with no human in the loop — where the device
/// screen sends one. Unscoped entities are never deduped: two plain switches
/// may legitimately share a characteristic and a role.
Iterable<({EntityDto entity, EntityActionDto action})> _controlActions(
  DeviceSpecDto spec, {
  List<String>? matchedVariants,
}) sync* {
  // Nor a vehicle: a group "turn off" has no human looking at the board it
  // reaches, and a skateboard's lights going dark mid-ride is not a lamp.
  // Their switches stay on the device screen, one deliberate tap at a time.
  final category = DeviceCategory.parse(spec.category);
  if (category == DeviceCategory.lock || category == DeviceCategory.vehicle) {
    return;
  }
  final unnarrowed = matchedVariants == null || matchedVariants.isEmpty;
  final scopedNames = <String>{};
  for (final entity in spec.entities) {
    if (entity.platform != 'light' && entity.platform != 'switch') continue;
    if (_isLockControl(entity.key, entity.deviceClass)) continue;
    if (!entityIsForVariants(entity, matchedVariants)) continue;
    if (unnarrowed &&
        entity.variants.isNotEmpty &&
        !scopedNames.add(entity.name)) {
      continue;
    }
    for (final action in entity.actions) {
      if (action.commandName == null) continue;
      yield (entity: entity, action: action);
    }
  }
}

/// Whether [entity] belongs to the model in front of us.
///
/// The one rule, shared by the device panel, the treadmill card and the group
/// path — because the group path did not have it and that is a silent double
/// write. A family spec can declare two same-named entities on two protocol
/// dialects sharing one writable characteristic (seeblue's and leds2rave4's
/// lights, KingSmith's two treadmill generations), so a `turn_on` that walks
/// every entity encodes and writes BOTH dialects back to back — the exact bug
/// the device screen's narrowing exists to prevent.
///
/// A null or empty narrowing means "do not narrow": showing everything is what
/// shipped before variant scoping existed, and narrowing a device we could not
/// identify would leave it with nothing at all.
bool entityIsForVariants(EntityDto entity, List<String>? matchedVariants) =>
    matchedVariants == null ||
    matchedVariants.isEmpty ||
    entity.variants.isEmpty ||
    entity.variants.any(matchedVariants.contains);

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

/// The range a brightness action is taken to span when its spec declares
/// no bounds. One definition, because it used to be written per path and
/// the network group copy said 0..100 while the device screen's cards said
/// 0..255: a group "50%" then sent 50 where the card's midpoint sent 128,
/// landing a 0..255 device at about 20%. The light cards should read these
/// too rather than restating 0 and 255.
const double kUndeclaredBrightnessMin = 0;
const double kUndeclaredBrightnessMax = 255;

/// Map [percent] (0–100) onto a declared parameter range, rounded to a
/// whole device value, falling back to [kUndeclaredBrightnessMin] and
/// [kUndeclaredBrightnessMax] for a bound the spec left out. The
/// catalogue's brightness ranges genuinely differ — 0–100, 5–100, 0–255,
/// 1–255 — so a group brightness has to be a percentage re-encoded per
/// device.
double brightnessFromPercent(double? min, double? max, double percent) {
  final lo = min ?? kUndeclaredBrightnessMin;
  final hi = max ?? kUndeclaredBrightnessMax;
  final fraction = percent.clamp(0.0, 100.0) / 100.0;
  return (lo + (hi - lo) * fraction).roundToDouble();
}

/// [brightnessFromPercent] for a BLE entity action.
double brightnessDeviceValue(EntityActionDto action, double percent) =>
    brightnessFromPercent(action.min, action.max, percent);

/// Parameter values for one group write, mirroring the control cards: only
/// the UI-owned parameters are sent (the encoder fills the rest from spec
/// defaults). For brightness roles the slider value goes into
/// `brightness`/`level`; on/off actions that carry parameters (a light whose
/// `turn_on` is really "set full color") get full-on values — white at full
/// brightness — since a group turn-on has no per-device card state to draw
/// from.
///
/// A parameter this has no value for is OMITTED, exactly as the light card
/// does (`LightControlCard._paramsFor`). It used to send 0.0, and 0.0 is a
/// real value: a spec naming its knob `warmth` would get a zero written to
/// every member of the group, silently. Omitting hands the decision to the
/// encoder — the spec's own default, or a visible ParameterMissing.
Map<String, double> _paramsFor(
  EntityActionDto action, {
  double? brightness,
  Rgb? color,
}) {
  final values = <String, double>{};
  for (final p in action.userParams) {
    final value = switch (p) {
      'brightness' ||
      'level' => brightness ?? (action.max ?? kUndeclaredBrightnessMax),
      'red' => (color?.r ?? 255).toDouble(),
      'green' => (color?.g ?? 255).toDouble(),
      'blue' => (color?.b ?? 255).toDouble(),
      _ => null,
    };
    if (value == null) continue;
    values[p] = value;
  }
  return action.withFixed(values);
}

/// Resolve the concrete writes a command op performs on one member, given the
/// services discovery actually found. Empty means the member cannot take part
/// (report it as skipped, never silently dropped).
List<GroupWrite> resolveGroupWrites({
  required GroupOp op,
  required DeviceSpecDto spec,
  required List<BleDiscoveredService> services,
  double? brightnessPercent,

  /// The variants this device matched, so a family spec writes ONE dialect.
  List<String>? matchedVariants,
}) {
  assert(op.isCommand, 'read ops resolve through resolve*Reads');

  // The admission set detectAlertActions uses, from the one shared builder:
  // writable pairs, because vendor channels reuse characteristic UUIDs
  // across services.
  final writable = discoveredWritablePairs(services);

  final writes = <GroupWrite>[];
  for (final (:entity, :action) in _controlActions(
    spec,
    matchedVariants: matchedVariants,
  )) {
    if (action.role != op.roleName) continue;
    if (!writable.containsKey(
      discoveredPairKey(action.serviceUuid, action.characteristicUuid),
    )) {
      continue;
    }
    writes.add(
      GroupWrite(
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
      ),
    );
  }
  return writes;
}

/// Resolve battery reads for one member. The spec's own battery entities win
/// when any resolve — the spec knows the device's dialect, and its `format:`
/// on 2a19 would override the profile's field name anyway (same precedence
/// detectAlertActions gives spec commands over the Immediate Alert profile).
/// The SIG path is the fallback and needs no spec at all, which is why every
/// member gets offered a battery read.
///
/// [matchedVariants] narrows the spec's entities to the model in front of
/// us ([entityIsForVariants]) before the per-characteristic dedupe, so a
/// family spec's two variant bindings on one characteristic decode with the
/// matched variant's format rather than whichever is declared first.
List<GroupRead> resolveBatteryReads({
  DeviceSpecDto? spec,
  required List<BleDiscoveredService> services,
  List<String>? matchedVariants,
}) {
  final reads = <GroupRead>[];
  final seenChars = <String>{};

  if (spec != null) {
    for (final entity in spec.entities) {
      if (!_isSpecBatteryEntity(entity)) continue;
      if (!entityIsForVariants(entity, matchedVariants)) continue;
      final stateChar = entity.stateCharacteristic!;
      final owning = _owningReadableService(spec, services, stateChar);
      if (owning == null) continue;
      if (!seenChars.add(normalizeUuid(stateChar))) continue;
      reads.add(
        GroupRead(
          serviceUuid: owning,
          charUuid: stateChar,
          specBased: true,
          entity: entity,
          label: entity.name,
        ),
      );
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
///
/// [matchedVariants] narrows exactly as the device panel does, BEFORE the
/// name dedupe claims a key: without it the first-declared variant's
/// binding won, so two variants sharing one characteristic in different
/// formats decoded the group snapshot in the wrong dialect while the device
/// screen read it right.
List<GroupRead> resolveSensorReads({
  required DeviceSpecDto spec,
  required List<BleDiscoveredService> services,
  int cap = 6,
  List<String>? matchedVariants,
}) {
  final reads = <GroupRead>[];
  // Same dedupe key as the control panel: a family spec binds one logical
  // reading once per variant, and real hardware carries exactly one of them.
  final seen = <String>{};
  for (final entity in spec.entities) {
    if (reads.length >= cap) break;
    if (!_isSensorEntity(entity)) continue;
    if (!entityIsForVariants(entity, matchedVariants)) continue;
    final stateChar = entity.stateCharacteristic!;
    final owning = _owningReadableService(spec, services, stateChar);
    if (owning == null) continue;
    if (!seen.add('${entity.platform}|${entity.name}')) continue;
    reads.add(
      GroupRead(
        serviceUuid: owning,
        charUuid: stateChar,
        specBased: true,
        entity: entity,
        label: entity.name,
      ),
    );
  }
  return reads;
}

/// One direct network write a group op resolved: send [action] on [entity]
/// with [values] — no state read required first (a discrete on/off, or a
/// valued brightness).
class GroupNetworkSend {
  final NetworkEntityDto entity;
  final NetworkActionDto action;
  final Map<String, String> values;

  const GroupNetworkSend({
    required this.entity,
    required this.action,
    required this.values,
  });
}

/// One toggle a group turn-off may send ONLY after establishing the entity
/// is on: the toggle contract. [entity] names the state command to read and
/// decode; the runner sends [action] when the reading answers `isOn == true`,
/// skips when it answers false, and skips when the read fails or answers
/// nothing — unknown blocks the toggle, and nothing else.
class GroupNetworkGatedToggle {
  final NetworkEntityDto entity;
  final NetworkActionDto action;

  const GroupNetworkGatedToggle({required this.entity, required this.action});
}

/// What one network member does for one command op: the direct sends, plus
/// the state-gated toggles a turn-off may add. Both empty means the member
/// cannot take part (report it skipped, never silently dropped).
class GroupNetworkPlan {
  final List<GroupNetworkSend> direct;
  final List<GroupNetworkGatedToggle> gated;

  /// Pride mode's `set_effect`s, whose index is not known until the device
  /// lists its effects: which number means "Rainbow" varies by build, so the
  /// runner has to ask ([rainbowEffectIndex]).
  final List<GroupNetworkSend> rainbowEffects;

  const GroupNetworkPlan({
    this.direct = const [],
    this.gated = const [],
    this.rainbowEffects = const [],
  });

  bool get isEmpty => direct.isEmpty && gated.isEmpty && rainbowEffects.isEmpty;
}

/// The transport a Yeelight LAN action resolves to: the handler's name, since
/// the spec's own `tcp-json` already means Kasa's cipher downstream.
const kYeelightTransport = 'yeelight_lan';

/// The transport a legacy LimitlessLED action resolves to, for the same reason
/// with bare `udp` and Rabbit Air.
const kLimitlessledTransport = 'limitlessled_legacy_8899';

/// The transport a Philips encrypted-CoAP purifier action resolves to: the
/// handler's name, since `coap` is also the IKEA gateway's DTLS surface.
const kPhilipsAirTransport = 'philips_air_coap';

/// Transports the group path can actually drive headlessly today. `udp`
/// (Rabbit Air) is deliberately absent: its every exchange needs the stored
/// per-device key, and a bulk operation silently reaching for stored
/// credentials is a surprise; it can join when someone asks for it. An
/// action on any other transport (a LIFX handler's `lifx`, an LG WebSocket)
/// resolves nothing here and the member reports an honest skip. Yeelight,
/// LimitlessLED and the Philips purifier take no credential at all, and a
/// group send to any of them is the same request a press on its card makes.
const Set<String> kGroupSendableTransports = {
  'http',
  'soap',
  'tcp-json',
  kYeelightTransport,
  kLimitlessledTransport,
  kPhilipsAirTransport,
};

bool _groupSendable(NetworkActionDto action) =>
    kGroupSendableTransports.contains(action.transport) &&
    // Actions parameterized by pairing credentials or hub-child ids need
    // context a bulk send does not carry — the same visible-failure rule
    // the renderer applies, applied before the send exists.
    action.credentials.isEmpty &&
    action.instanceParams.isEmpty;

/// The control entities a network group op may bind — switch and light
/// platforms, exactly the BLE rule. ONE definition consumed by both
/// [supportedNetworkGroupOps] and [resolveNetworkGroupPlan], for the same
/// no-drift reason as [_controlActions].
Iterable<NetworkEntityDto> _networkControlEntities(
  List<NetworkEntityDto> entities,
) => entities.where(
  (e) =>
      (e.platform == 'light' || e.platform == 'switch') &&
      !_isLockControl(e.key, e.deviceClass),
);

/// Whether a switch is marked as a lock: the entity key or device class the
/// device screen also reads a bolt from. Never a group command — see the
/// header.
bool _isLockControl(String? key, String? deviceClass) =>
    key == 'lock' || deviceClass == 'lock';

NetworkActionDto? _networkAction(NetworkEntityDto entity, String role) {
  for (final action in entity.actions) {
    if (action.role == role && _groupSendable(action)) return action;
  }
  return null;
}

/// The `set_brightness` action a group op may actually send on [entity], or
/// null.
///
/// ONE definition, consumed by both [supportedNetworkGroupOps] and
/// [resolveNetworkGroupPlan], because they disagreed: the support check asked
/// only "is there a sendable set_brightness", while the resolver also requires
/// a user parameter to put the level in — there is nowhere to write the number
/// otherwise, and a send with no level would be a bare request that either
/// does nothing or means something else entirely. A spec declaring
/// `set_brightness` with an empty `userParams` therefore lit the Brightness
/// button, opened the percentage sheet, and resolved an empty plan: every
/// member skipped, nothing sent, and the only feedback was a run that touched
/// no device.
NetworkActionDto? _networkBrightnessAction(NetworkEntityDto entity) {
  if (entity.platform != 'light') return null;
  final action = _networkAction(entity, 'set_brightness');
  if (action == null || action.userParams.isEmpty) return null;
  return action;
}

/// Whether [entity] declares a power state a gated toggle can read: a
/// non-empty state command, over a transport the group state-read path
/// speaks (SOAP and plain HTTP — the two the description-based read serves).
bool _hasReadableState(NetworkEntityDto entity) =>
    entity.stateCommand.isNotEmpty &&
    (entity.transport == null ||
        entity.transport == 'http' ||
        entity.transport == 'soap');

/// Which group operations these network [entities] support at all — the
/// network sibling of [supportedGroupOps], feeding the same buttons and the
/// same skip logic.
Set<GroupOp> supportedNetworkGroupOps(List<NetworkEntityDto> entities) {
  final ops = <GroupOp>{};
  for (final entity in _networkControlEntities(entities)) {
    if (_networkAction(entity, 'turn_on') != null) ops.add(GroupOp.turnOn);
    if (_networkAction(entity, 'turn_off') != null ||
        (_networkAction(entity, 'toggle') != null &&
            _hasReadableState(entity))) {
      ops.add(GroupOp.turnOff);
    }
    if (_networkBrightnessAction(entity) != null) {
      ops.add(GroupOp.setBrightness);
    }
    if (_networkPrideColorAction(entity) != null ||
        _networkRainbowEffectAction(entity) != null) {
      ops.add(GroupOp.prideMode);
    }
  }
  return ops;
}

/// The index of the rainbow in a device's list of effect [names], preferring
/// the one called just that over a variation on it. Null when it has none.
int? rainbowEffectIndex(List<String> names) {
  final lower = [for (final n in names) n.toLowerCase().trim()];
  final exact = lower.indexOf('rainbow');
  if (exact >= 0) return exact;
  final loose = lower.indexWhere((n) => n.contains('rainbow'));
  return loose >= 0 ? loose : null;
}

/// The largest packed 24-bit colour, which is how a packed `rgb` parameter
/// declares itself.
const _kPackedRgbMax = 0xFFFFFF;

/// The colour wheel a legacy LimitlessLED hue byte runs round, as the spec
/// anchors it (`rgbw_commands.set_color`): red 0xB0, green 0x60, royal blue
/// 0x10, wrapping through 0x00 violet and 0xF0 lavender back up to red.
///
/// Null for a colour with no hue, white or black or grey: the wheel has no such
/// position, and red would be a lie.
int? limitlessledHueByte(Rgb color) {
  final hsv = HSVColor.fromColor(
    Color.fromARGB(255, color.r, color.g, color.b),
  );
  if (hsv.saturation == 0 || hsv.value == 0) return null;
  final h = hsv.hue;
  final byte = switch (h) {
    < 120 => 0xB0 - h / 120 * 0x50,
    < 240 => 0x60 - (h - 120) / 120 * 0x50,
    _ => 0x10 - (h - 240) / 120 * 0x60,
  };
  return byte.round() & 0xFF;
}

/// The values [action] states [color] in, by what its parameters declare: three
/// channels, one packed 0xRRGGBB (Yeelight's `rgb`), or the hue byte of a legacy
/// LimitlessLED bridge. Null when it takes none of those, or this colour cannot
/// be said in the one it takes.
///
/// A lone `hue` is keyed on the transport as well as the name, because a hue
/// scale is the protocol's own: degrees on one device, a wheel from violet on
/// another, and a number that means nothing on a third.
Map<String, String>? networkColorValues(NetworkActionDto action, Rgb color) {
  final params = action.userParams;
  if (_carriesRgb(params)) {
    return {'red': '${color.r}', 'green': '${color.g}', 'blue': '${color.b}'};
  }
  if (params.length != 1) return null;
  if (params.first == 'rgb' && action.max == _kPackedRgbMax) {
    return {'rgb': '${(color.r << 16) | (color.g << 8) | color.b}'};
  }
  if (params.first == 'hue' && action.transport == kLimitlessledTransport) {
    final hue = limitlessledHueByte(color);
    return hue == null ? null : {'hue': '$hue'};
  }
  return null;
}

/// The `set_color` a group can state a colour through, or null.
NetworkActionDto? _networkPrideColorAction(NetworkEntityDto entity) {
  if (entity.platform != 'light') return null;
  final action = _networkAction(entity, 'set_color');
  // Asked with a colour every encoding can say; which colour turns up later is
  // the rainbow's, and all of those have a hue.
  return action != null &&
          networkColorValues(action, const (r: 255, g: 0, b: 0)) != null
      ? action
      : null;
}

/// The parameter a light's `set_effect` takes the effect's index in.
const groupEffectParam = 'effect';

/// A `set_effect` by index on a light with no colour to set, or null: the one
/// way to reach an addressable strip whose spec offers effects and not
/// colours. The index comes from the device, see
/// [GroupNetworkPlan.rainbowEffects].
NetworkActionDto? _networkRainbowEffectAction(NetworkEntityDto entity) {
  if (entity.platform != 'light' || _networkPrideColorAction(entity) != null) {
    return null;
  }
  final action = _networkAction(entity, 'set_effect');
  return action != null &&
          action.transport == 'http' &&
          action.userParams.contains(groupEffectParam)
      ? action
      : null;
}

/// Resolve what one member sends for a command op, role-first with no GATT
/// admission step — there is no discovered service tree on this side; the
/// admission is that the action resolved as sendable at all.
///
/// The turn-off policy, in full: a discrete `turn_off` is sent outright; a
/// `toggle` is added ONLY when the entity also declares a readable power
/// state, and the runner sends it only on a reading that says "on" — a
/// failed or empty read blocks the toggle and nothing else. An entity with
/// only a toggle and no state resolves nothing, which is the honest answer
/// for a device that cannot be turned off without risking turning it on.
GroupNetworkPlan resolveNetworkGroupPlan({
  required GroupOp op,
  required List<NetworkEntityDto> entities,
  double? brightnessPercent,

  /// The colour this member takes in pride mode.
  Rgb? prideColor,
}) {
  assert(op.isCommand, 'read ops have no network resolution yet');
  final direct = <GroupNetworkSend>[];
  final gated = <GroupNetworkGatedToggle>[];
  final rainbowEffects = <GroupNetworkSend>[];
  for (final entity in _networkControlEntities(entities)) {
    switch (op) {
      case GroupOp.turnOn:
        final action = _networkAction(entity, 'turn_on');
        if (action != null) {
          direct.add(
            GroupNetworkSend(entity: entity, action: action, values: const {}),
          );
        }
      case GroupOp.turnOff:
        final off = _networkAction(entity, 'turn_off');
        if (off != null) {
          direct.add(
            GroupNetworkSend(entity: entity, action: off, values: const {}),
          );
          break;
        }
        final toggle = _networkAction(entity, 'toggle');
        if (toggle != null && _hasReadableState(entity)) {
          gated.add(GroupNetworkGatedToggle(entity: entity, action: toggle));
        }
      case GroupOp.setBrightness:
        final action = _networkBrightnessAction(entity);
        if (action != null) {
          // Through the shared helper: this copy used to default a missing
          // max to 100 while the device screen's card defaulted to 255.
          final value = brightnessFromPercent(
            action.min,
            action.max,
            brightnessPercent ?? 100,
          ).round();
          direct.add(
            GroupNetworkSend(
              entity: entity,
              action: action,
              values: {action.userParams.first: '$value'},
            ),
          );
        }
      case GroupOp.prideMode:
        final color = prideColor ?? prideColorAt(0);
        final action = _networkPrideColorAction(entity);
        final effect = _networkRainbowEffectAction(entity);
        if (action == null && effect == null) break;
        final on = _networkAction(entity, 'turn_on');
        if (on != null) {
          direct.add(
            GroupNetworkSend(entity: entity, action: on, values: const {}),
          );
        }
        final values = action == null
            ? null
            : networkColorValues(action, color);
        if (action != null && values != null) {
          direct.add(
            GroupNetworkSend(entity: entity, action: action, values: values),
          );
        }
        if (effect != null) {
          rainbowEffects.add(
            GroupNetworkSend(entity: entity, action: effect, values: const {}),
          );
        }
      case GroupOp.readBattery || GroupOp.readSensors:
        break;
    }
  }
  return GroupNetworkPlan(
    direct: direct,
    gated: gated,
    rainbowEffects: rainbowEffects,
  );
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

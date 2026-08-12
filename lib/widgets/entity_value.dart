// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/decoded_number.dart';
import '../core/error_text.dart';
import '../core/hex.dart';
import '../providers/ble_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';

/// How far an entity's live state has gotten.
enum EntityValueStatus {
  /// The entity's characteristic has no `format:` block (or no state
  /// characteristic at all) — there will never be a value to show.
  unavailable,

  /// First read in flight.
  loading,

  /// The read or decode failed; [EntityLiveValue.error] says why.
  error,

  /// [EntityLiveValue.decoded] holds the latest decoded fields.
  live,
}

/// Immutable snapshot of one entity's decoded state, with the value-picking
/// and scaling rules every card shares.
class EntityLiveValue {
  final EntityDto entity;
  final EntityValueStatus status;
  final String? error;

  /// The latest full decode, in the characteristic's field order. Empty until
  /// the first successful decode.
  final List<DecodedValueDto> decoded;

  const EntityLiveValue({
    required this.entity,
    required this.status,
    this.error,
    this.decoded = const [],
  });

  /// The decoded field carrying this entity's reading: `state_mapping.value`
  /// when the spec names one, else the first decoded field (the common
  /// single-field case).
  DecodedValueDto? get primary {
    final field = entity.valueField;
    if (field == null) return decoded.firstOrNull;
    return fieldNamed(field);
  }

  /// Why [primary] is null even though a decode succeeded — a spec mapping
  /// problem worth showing verbatim, distinct from a transport error.
  String? get primaryError {
    if (status != EntityValueStatus.live || primary != null) return null;
    final field = entity.valueField;
    return field == null
        ? 'The spec decoded no fields for this characteristic.'
        : 'The spec maps this reading to "$field", which the format block '
            'does not define.';
  }

  DecodedValueDto? fieldNamed(String name) =>
      decoded.where((d) => d.name == name).firstOrNull;

  /// The reading rendered for display, through the spec's full number
  /// semantics.
  ///
  /// Devices commonly report fixed-point integers — Ember's mug sends
  /// centidegrees, so a raw 5320 is 53.2 °C — and just as commonly an offset
  /// one, like Gerbing's `raw * 0.5 + 85` °F. Both halves of that transform,
  /// plus the `values:` code table that turns an enumerated raw into a word,
  /// live in [labelledTextOf] so this card, the GATT browser, the setpoint
  /// control and the Home Assistant forwarder cannot disagree about what one
  /// characteristic read means.
  ///
  /// The entity's `state_mapping.scale` is passed as an override rather than
  /// a fallback: see [decodedNumberOf] for why it replaces the field's
  /// transform instead of compounding with it.
  String? get display {
    final value = primary;
    if (value == null) return null;
    return labelledTextOf(
      value,
      scaleOverride: entity.valueScale,
      precision: entity.precision,
    );
  }

  /// The reading as a number in decoded units, for controls that seed from
  /// device state rather than render text. Null when the field is not numeric.
  double? get decodedNumber {
    final value = primary;
    if (value == null) return null;
    return decodedNumberOf(value, scaleOverride: entity.valueScale);
  }

  /// The unit to render beside [display]: the entity's own, or the format
  /// field's when the entity does not name one — and neither when the spec
  /// says the unit follows a device setting (see [unitOf]).
  String? get unit {
    final value = primary;
    if (value == null) return entity.unit;
    return unitOf(value, entityUnit: entity.unit);
  }

  /// Whether the bound field's unit is a device setting rather than a
  /// constant of the protocol, so a UI must not present [unit] as fact.
  bool get unitIsDeviceSetting {
    final value = primary;
    return value != null && unitFollowsDeviceSetting(value);
  }

  /// Whether the entity currently reads as "on", by the spec's own rules.
  ///
  /// Resolution order mirrors what the mappings mean:
  /// 1. `state_mapping.is_on` names a dedicated power field (lights);
  /// 2. otherwise the primary value is judged — a bool speaks for itself,
  ///    and a number compares against `on_value` when declared, else any
  ///    nonzero value counts (which is also what `on_when: nonzero` spells
  ///    out explicitly).
  ///
  /// `null` when there is no decoded state to judge.
  bool? get isOn {
    final field = entity.isOnField;
    final value = field != null ? fieldNamed(field) : primary;
    if (value == null) return null;
    final b = value.boolValue;
    if (b != null) return b;
    final raw = value.intValue ?? value.uintValue;
    if (raw == null) return null;
    final onValue = entity.onValue;
    if (onValue != null) return raw == onValue;
    return raw != 0;
  }

  /// A numeric field's raw value, for seeding controls from device state
  /// (brightness slider, color swatch).
  int? rawOf(String? fieldName) {
    if (fieldName == null) return null;
    final value = fieldNamed(fieldName);
    if (value == null) return null;
    final raw = value.intValue ?? value.uintValue;
    if (raw != null) return raw.toInt();
    final b = value.boolValue;
    if (b != null) return b ? 1 : 0;
    return null;
  }
}

/// Owns the read/notify/decode loop for one entity and hands each snapshot to
/// [builder].
///
/// This is the plumbing every entity-backed card shares — extracted from the
/// sensor card so switch/light/binary-sensor cards reflect device state
/// without re-implementing it. Behaviour it preserves exactly:
/// - one initial read, then a notify subscription when the spec says the
///   characteristic streams;
/// - a dropped notify stream (or an undecodable notification) never
///   overwrites the last good value — the device screen's connection watcher
///   owns surfacing disconnects;
/// - an entity with no decodable state reports [EntityValueStatus.unavailable]
///   immediately and touches no BLE at all.
class EntityValueBuilder extends ConsumerStatefulWidget {
  final String deviceId;

  /// Discovered service that owns the entity's state characteristic.
  final String serviceUuid;
  final EntityDto entity;
  final String specYaml;
  final Widget Function(BuildContext context, EntityLiveValue value) builder;

  const EntityValueBuilder({
    super.key,
    required this.deviceId,
    required this.serviceUuid,
    required this.entity,
    required this.specYaml,
    required this.builder,
  });

  @override
  ConsumerState<EntityValueBuilder> createState() => _EntityValueBuilderState();
}

class _EntityValueBuilderState extends ConsumerState<EntityValueBuilder> {
  late EntityLiveValue _value;
  StreamSubscription<List<int>>? _notifySub;

  @override
  void initState() {
    super.initState();
    final stateChar = widget.entity.stateCharacteristic;
    if (stateChar == null || !widget.entity.hasFormat) {
      _value = EntityLiveValue(
        entity: widget.entity,
        status: EntityValueStatus.unavailable,
      );
      return;
    }
    _value = EntityLiveValue(
      entity: widget.entity,
      status: EntityValueStatus.loading,
    );
    unawaited(_seed(stateChar));
    if (widget.entity.canNotify) _subscribe(stateChar);
  }

  /// Read once to seed the card — unless discovery says the characteristic
  /// is notify-only. Those used to get the read anyway and wear its failure
  /// as "Could not read this value" until the first notification arrived;
  /// waiting in `loading` is the honest state. The check goes through the
  /// service's per-connection discovery cache (no extra radio work), and any
  /// failure to answer falls back to attempting the read — a wrong error
  /// beats a silently skipped seed.
  Future<void> _seed(String stateChar) async {
    try {
      final services =
          await ref.read(bleServiceProvider).discoverServices(widget.deviceId);
      final target = normalizeUuid(stateChar);
      final char = services
          .where(
              (s) => normalizeUuid(s.uuid) == normalizeUuid(widget.serviceUuid))
          .expand((s) => s.characteristics)
          .where((c) => normalizeUuid(c.uuid) == target)
          .firstOrNull;
      if (char != null && !char.canRead && char.canNotify) return;
    } catch (_) {
      // Discovery unavailable: proceed with the read as before.
    }
    if (!mounted) return;
    await _read(stateChar);
  }

  @override
  void dispose() {
    unawaited(_notifySub?.cancel());
    super.dispose();
  }

  Future<void> _read(String stateChar) async {
    try {
      final bytes = await ref.read(bleServiceProvider).readCharacteristic(
            widget.deviceId,
            widget.serviceUuid,
            stateChar,
          );
      await _decodeAndSet(stateChar, bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _value = EntityLiveValue(
          entity: widget.entity,
          status: EntityValueStatus.error,
          error: friendlyErrorText(
            e,
            context: 'read $stateChar',
            fallback: 'Could not read this value.',
          ),
          // Keep any earlier reading so a transient failure doesn't blank
          // the card.
          decoded: _value.decoded,
        );
      });
    }
  }

  void _subscribe(String stateChar) {
    _notifySub = ref
        .read(bleServiceProvider)
        .subscribeCharacteristic(widget.deviceId, widget.serviceUuid, stateChar)
        .listen(
      (bytes) =>
          unawaited(_decodeAndSet(stateChar, bytes).catchError((Object _) {})),
      onError: (Object _) {
        // A dropped notify stream leaves the last value on screen; the
        // connection-state watcher on the device screen owns surfacing the
        // disconnect, so this must not overwrite a good reading with an
        // error.
      },
    );
  }

  Future<void> _decodeAndSet(String stateChar, List<int> bytes) async {
    final decoded = await ref.read(specCodecProvider).decodeValue(
          specYaml: widget.specYaml,
          serviceUuid: widget.serviceUuid,
          charUuid: stateChar,
          bytes: bytes,
        );
    if (!mounted) return;
    setState(() {
      _value = EntityLiveValue(
        entity: widget.entity,
        status: EntityValueStatus.live,
        decoded: decoded,
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _value);
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/entity_live_value.dart';
import '../core/error_text.dart';
import '../core/hex.dart';
import '../providers/ble_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';

// The model half (EntityLiveValue and its status enum) lives in core so
// non-widget consumers share the same value-picking rules; re-exported here
// so this file remains the one import every entity card needs.
export '../core/entity_live_value.dart' show EntityLiveValue, EntityValueStatus;

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
  /// is notify-only AND this entity actually subscribes. Those used to get
  /// the read anyway and wear its failure as "Could not read this value"
  /// until the first notification arrived; waiting in `loading` is the
  /// honest state — but only while a subscription exists to end the wait.
  /// The spec side must agree ([EntityDto.canNotify] gates [_subscribe], and
  /// covers only `notify` where discovery's flag also covers indicate), or
  /// an indicate-only or spec-drifted entity would have no read, no
  /// subscription, and a spinner forever. The check goes through the
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
      if (widget.entity.canNotify &&
          char != null &&
          !char.canRead &&
          char.canNotify) {
        return;
      }
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
      onError: (Object error) {
        // A dropped notify stream leaves the last value on screen; the
        // connection-state watcher on the device screen owns surfacing the
        // disconnect, so this must not overwrite a good reading with an
        // error. But a subscription that fails before ANY value arrived is
        // a different statement — for a notify-only characteristic the seed
        // read was skipped, making this failure the card's only signal
        // ("pair this device" on a refused CCCD write), and swallowing it
        // would leave a spinner forever.
        if (!mounted || _value.status != EntityValueStatus.loading) return;
        setState(() {
          _value = EntityLiveValue(
            entity: widget.entity,
            status: EntityValueStatus.error,
            error: friendlyErrorText(
              error,
              context: 'subscribe $stateChar',
              fallback: 'Could not read this value.',
            ),
          );
        });
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

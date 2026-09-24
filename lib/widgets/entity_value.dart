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

  /// Bumped every time [_start] opens a loop. An in-flight read or a
  /// notification decoded against the PREVIOUS entity resolves after the
  /// switch, and its answer belongs to a characteristic this builder is no
  /// longer watching — applying it would put the old device's reading under
  /// the new entity's name.
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _start();
  }

  /// Re-run the whole loop when the thing being watched changes.
  ///
  /// This builder is placed by cards that are rebuilt with a NEW entity under
  /// the same element — a spec-match refinement renaming or re-binding the
  /// entity, a variant resolving, a screen swapping which entity a card
  /// surfaces. Without this the state kept reading, subscribing to and
  /// decoding the entity it was first built with: the card's title said one
  /// characteristic and its reading came from another, indefinitely, because
  /// nothing else ever re-seeds [_value].
  ///
  /// Compared on the fields the loop actually uses — the device, the service,
  /// the entity's own binding, and the spec the decode runs against. An
  /// unrelated rebuild changes none of them and costs nothing.
  @override
  void didUpdateWidget(covariant EntityValueBuilder old) {
    super.didUpdateWidget(old);
    if (old.deviceId == widget.deviceId &&
        old.serviceUuid == widget.serviceUuid &&
        old.specYaml == widget.specYaml &&
        old.entity.name == widget.entity.name &&
        old.entity.stateCharacteristic == widget.entity.stateCharacteristic &&
        old.entity.canNotify == widget.entity.canNotify &&
        old.entity.hasFormat == widget.entity.hasFormat) {
      return;
    }
    unawaited(_notifySub?.cancel());
    _notifySub = null;
    setState(_start);
  }

  /// Seed [_value] and open the read/notify loop for the current entity.
  /// Assigns rather than setStates — the two callers own that (initState is
  /// before the first build, [didUpdateWidget] wraps it).
  void _start() {
    final generation = ++_generation;
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
    unawaited(_seed(stateChar, generation));
    if (widget.entity.canNotify) _subscribe(stateChar, generation);
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
  Future<void> _seed(String stateChar, int generation) async {
    try {
      final services = await ref
          .read(bleServiceProvider)
          .discoverServices(widget.deviceId);
      final target = normalizeUuid(stateChar);
      final char = services
          .where(
            (s) => normalizeUuid(s.uuid) == normalizeUuid(widget.serviceUuid),
          )
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
    if (!mounted || generation != _generation) return;
    await _read(stateChar, generation);
  }

  @override
  void dispose() {
    unawaited(_notifySub?.cancel());
    super.dispose();
  }

  Future<void> _read(String stateChar, int generation) async {
    try {
      final bytes = await ref
          .read(bleServiceProvider)
          .readCharacteristic(widget.deviceId, widget.serviceUuid, stateChar);
      await _decodeAndSet(stateChar, bytes, generation);
    } catch (e) {
      if (!mounted || generation != _generation) return;
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

  void _subscribe(String stateChar, int generation) {
    _notifySub = ref
        .read(bleServiceProvider)
        .subscribeCharacteristic(widget.deviceId, widget.serviceUuid, stateChar)
        .listen(
          (bytes) => unawaited(
            _decodeAndSet(
              stateChar,
              bytes,
              generation,
            ).catchError((Object _) {}),
          ),
          onError: (Object error) {
            // A dropped notify stream leaves the last value on screen; the
            // connection-state watcher on the device screen owns surfacing the
            // disconnect, so this must not overwrite a good reading with an
            // error. But a subscription that fails before ANY value arrived is
            // a different statement — for a notify-only characteristic the seed
            // read was skipped, making this failure the card's only signal
            // ("pair this device" on a refused CCCD write), and swallowing it
            // would leave a spinner forever.
            if (!mounted ||
                generation != _generation ||
                _value.status != EntityValueStatus.loading) {
              return;
            }
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

  Future<void> _decodeAndSet(
    String stateChar,
    List<int> bytes,
    int generation,
  ) async {
    final decoded = await ref
        .read(specCodecProvider)
        .decodeValue(
          specYaml: widget.specYaml,
          serviceUuid: widget.serviceUuid,
          charUuid: stateChar,
          bytes: bytes,
        );
    if (!mounted || generation != _generation) return;
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

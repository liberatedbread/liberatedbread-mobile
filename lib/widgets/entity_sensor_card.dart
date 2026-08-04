// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../providers/ble_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';

/// A live reading declared by a spec's `entities:` block.
///
/// This is the payoff of spec-driven rendering: the spec says "Internal
/// Temperature, device_class temperature, unit F, read it from characteristic
/// X", and this widget turns that into a labelled reading without any
/// device-specific code. Adding a device becomes a spec refresh, not an app
/// change.
class EntitySensorCard extends ConsumerStatefulWidget {
  final String deviceId;
  final String serviceUuid;
  final EntityDto entity;
  final String specYaml;

  const EntitySensorCard({
    super.key,
    required this.deviceId,
    required this.serviceUuid,
    required this.entity,
    required this.specYaml,
  });

  @override
  ConsumerState<EntitySensorCard> createState() => _EntitySensorCardState();
}

class _EntitySensorCardState extends ConsumerState<EntitySensorCard> {
  String? _value;

  /// Resolved at decode time: the entity's own unit, or the format field's when
  /// the entity does not name one.
  String? _unit;
  String? _error;
  bool _loading = true;
  StreamSubscription<List<int>>? _notifySub;

  @override
  void initState() {
    super.initState();
    _unit = widget.entity.unit;
    // An entity whose characteristic has no `format:` block can't be decoded.
    // Say so plainly instead of reading bytes we can't interpret: it's a gap in
    // the spec, and reporting it is more useful than a blank tile.
    if (!widget.entity.hasFormat) {
      _loading = false;
      _error = 'No format block in the spec yet, so this reading cannot be '
          'decoded.';
      return;
    }
    unawaited(_read());
    if (widget.entity.canNotify) _subscribe();
  }

  @override
  void dispose() {
    unawaited(_notifySub?.cancel());
    super.dispose();
  }

  Future<void> _read() async {
    try {
      final bytes = await ref.read(bleServiceProvider).readCharacteristic(
            widget.deviceId,
            widget.serviceUuid,
            widget.entity.stateCharacteristic,
          );
      await _decodeAndSet(bytes);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyErrorText(
          e,
          context: 'read ${widget.entity.stateCharacteristic}',
          fallback: 'Could not read this value.',
        );
        _loading = false;
      });
    }
  }

  void _subscribe() {
    _notifySub = ref
        .read(bleServiceProvider)
        .subscribeCharacteristic(
          widget.deviceId,
          widget.serviceUuid,
          widget.entity.stateCharacteristic,
        )
        .listen(
      (bytes) => unawaited(_decodeAndSet(bytes).catchError((Object _) {})),
      onError: (Object _) {
        // A dropped notify stream leaves the last read value on screen; the
        // connection-state watcher on the device screen owns surfacing the
        // disconnect, so this must not overwrite a good reading with an error.
      },
    );
  }

  Future<void> _decodeAndSet(List<int> bytes) async {
    final decoded = await ref.read(specCodecProvider).decodeValue(
          specYaml: widget.specYaml,
          serviceUuid: widget.serviceUuid,
          charUuid: widget.entity.stateCharacteristic,
          bytes: bytes,
        );
    if (!mounted) return;

    // `state_mapping.value` names the field carrying the reading; when the spec
    // omits it, a single-field format is the common case, so fall back to the
    // first decoded field rather than showing nothing.
    final field = widget.entity.valueField;
    final match = field == null
        ? decoded.firstOrNull
        : decoded.where((d) => d.name == field).firstOrNull;

    setState(() {
      _loading = false;
      if (match == null) {
        _error = field == null
            ? 'The spec decoded no fields for this characteristic.'
            : 'The spec maps this reading to "$field", which the format block '
                'does not define.';
        return;
      }
      _error = null;
      _value = _format(match);
      _unit = widget.entity.unit ?? match.unit;
    });
  }

  /// Render the decoded value, applying the spec's scale when it declares one.
  ///
  /// Devices commonly report fixed-point integers — Ember's mug sends
  /// centidegrees, so a raw 5320 is 53.2 °C. The multiplier lives in the spec,
  /// so a device that needs different scaling is a data change, not a code
  /// change. Specs declare it in either of two places, and both are in real
  /// use: on the entity as `state_mapping.scale` (ember-mug), or on the format
  /// field itself (airthings-wave-family, xiaomi-miflora, and any spec using
  /// the Bluetooth SIG environmental characteristics).
  ///
  /// The entity wins when both are present: it describes this specific reading
  /// rather than the field's general encoding. They must never compound — two
  /// multiplications would be silently wrong rather than visibly broken.
  /// Without any scale the decoder's own display string is used unchanged,
  /// which keeps non-numeric values (strings, bools) intact.
  String _format(DecodedValueDto decoded) {
    final scale = widget.entity.valueScale ?? decoded.scale;
    if (scale == null) return decoded.display;

    final raw = decoded.intValue ?? decoded.uintValue;
    if (raw == null) return decoded.display;

    final scaled = raw * scale;
    // Show as many decimals as the scale implies rather than a fixed 2: a
    // scale of 0.01 wants 2 places, 0.1 wants 1, and an integral scale none.
    final decimals = scale >= 1
        ? 0
        : scale
            .toString()
            .split('.')
            .last
            .replaceAll(RegExp(r'0+$'), '')
            .length;
    return scaled.toStringAsFixed(decimals);
  }

  IconData get _icon => switch (widget.entity.deviceClass) {
        'temperature' => Icons.thermostat,
        'battery' => Icons.battery_full,
        'humidity' => Icons.water_drop_outlined,
        'pressure' => Icons.speed,
        'signal_strength' => Icons.signal_cellular_alt,
        _ => Icons.sensors,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(13),
            ),
            child: Icon(_icon, color: scheme.onSecondaryContainer, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.entity.name,
                        style: text.titleSmall
                            ?.copyWith(fontWeight: FontWeight.w700),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (widget.entity.canNotify)
                      Tooltip(
                        message: 'Updates live',
                        child: Icon(Icons.bolt,
                            size: 16, color: scheme.onSurfaceVariant),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                _buildValue(scheme, text),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildValue(ColorScheme scheme, TextTheme text) {
    if (_loading) {
      return Row(
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Text('Reading...',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        ],
      );
    }

    if (_error != null) {
      return Text(
        _error!,
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          _value ?? '--',
          style: text.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            // Tabular figures keep a live-updating reading from shifting width
            // digit by digit.
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (_unit != null) ...[
          const SizedBox(width: 4),
          Text(
            _unit!,
            style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ],
    );
  }
}

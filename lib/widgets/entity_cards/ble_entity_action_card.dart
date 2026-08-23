// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/entity_icon.dart';
import '../../core/error_text.dart';
import '../../providers/ble_provider.dart';
import '../../providers/spec_codec_provider.dart';
import '../../services/spec_codec.dart';
import '../entity_value.dart';

/// The BLE control card for the platforms the unified role table added:
/// `button`, `select`, `fan` and `cover`.
///
/// One widget rather than four because they share everything but the row of
/// controls: resolved spec actions sent through the codec, live state through
/// [EntityValueBuilder] when the entity binds a discovered characteristic,
/// and the same honest degradations as [SwitchControlCard] — a control only
/// renders when its role resolved, and state is only claimed when it can be
/// read.
class BleEntityActionCard extends ConsumerStatefulWidget {
  final String deviceId;

  /// Discovered service owning the entity's state characteristic; null when
  /// the entity has no state binding (or this device does not carry it).
  final String? stateServiceUuid;
  final EntityDto entity;
  final String specYaml;

  const BleEntityActionCard({
    super.key,
    required this.deviceId,
    required this.stateServiceUuid,
    required this.entity,
    required this.specYaml,
  });

  @override
  ConsumerState<BleEntityActionCard> createState() =>
      _BleEntityActionCardState();
}

class _BleEntityActionCardState extends ConsumerState<BleEntityActionCard> {
  String? _sendingRole;
  String? _status;
  bool _failed = false;

  /// The value the user last commanded (a picked option, a held slider),
  /// shown until a fresh decode supersedes it.
  double? _assumed;
  List<DecodedValueDto>? _assumedBaseline;

  EntityActionDto? _action(String role) =>
      widget.entity.actions.where((a) => a.role == role).firstOrNull;

  Future<void> _send(EntityActionDto action,
      {Map<String, double> params = const {}, double? assume}) async {
    final commandName = action.commandName;
    if (commandName == null) return;
    setState(() {
      _sendingRole = action.role;
      _status = null;
      _failed = false;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final bytes = await codec.encodeCommand(
        specYaml: widget.specYaml,
        charUuid: action.characteristicUuid,
        commandName: commandName,
        params: params,
      );
      await ref.read(bleServiceProvider).writeCharacteristic(
            widget.deviceId,
            action.serviceUuid,
            action.characteristicUuid,
            bytes.toList(),
          );
      if (!mounted) return;
      setState(() {
        _sendingRole = null;
        _status = 'Sent';
        _failed = false;
        if (assume != null) _assumed = assume;
      });
    } catch (e) {
      if (!mounted) return;
      final text = friendlyErrorText(
        e,
        context: 'send ${action.commandName}',
        fallback: 'The device did not accept that command.',
      );
      setState(() {
        _sendingRole = null;
        _status = text;
        _failed = true;
      });
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(text)));
    }
  }

  @override
  Widget build(BuildContext context) {
    final stateService = widget.stateServiceUuid;
    if (stateService == null) return _buildCard(context, null);
    return EntityValueBuilder(
      deviceId: widget.deviceId,
      serviceUuid: stateService,
      entity: widget.entity,
      specYaml: widget.specYaml,
      builder: _buildCard,
    );
  }

  Widget _buildCard(BuildContext context, EntityLiveValue? value) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    if (value != null && !identical(value.decoded, _assumedBaseline)) {
      _assumed = null;
    }

    final body = switch (widget.entity.platform) {
      'button' => _buttonRow(),
      'select' => _selectBody(value),
      'fan' => _fanBody(value, text),
      'cover' => _coverBody(value),
      _ => const SizedBox.shrink(),
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  entityIcon(widget.entity),
                  color: scheme.onSecondaryContainer,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.entity.name,
                      style:
                          text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    _stateLine(value, scheme, text),
                  ],
                ),
              ),
            ],
          ),
          Padding(padding: const EdgeInsets.only(top: 10), child: body),
        ],
      ),
    );
  }

  /// A momentary action: the whole card is one press.
  Widget _buttonRow() {
    final press = _action('press');
    return Align(
      alignment: Alignment.centerLeft,
      child: FilledButton.tonalIcon(
        onPressed: (press == null || _sendingRole != null)
            ? null
            : () => unawaited(_send(press)),
        icon: const Icon(Icons.touch_app, size: 18),
        label: const Text('Press'),
      ),
    );
  }

  /// The spec's option table as chips; the current one is the decoded state
  /// when readable, else the last option sent.
  Widget _selectBody(EntityLiveValue? value) {
    final action = _action('select_option');
    final current = _assumed ?? value?.decodedNumber;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final option in widget.entity.options)
          ChoiceChip(
            label: Text(option.label),
            selected: current != null &&
                double.tryParse(option.raw) == current,
            onSelected: (action == null || _sendingRole != null)
                ? null
                : (_) {
                    final raw = double.tryParse(option.raw);
                    if (raw == null) return;
                    _assumedBaseline = value?.decoded;
                    final param = action.userParams.firstOrNull;
                    unawaited(_send(action,
                        params: param == null ? const {} : {param: raw},
                        assume: raw));
                  },
          ),
      ],
    );
  }

  Widget _fanBody(EntityLiveValue? value, TextTheme text) {
    final turnOn = _action('turn_on');
    final turnOff = _action('turn_off');
    final percentage = _action('set_percentage');
    final oscillating = _action('set_oscillating');
    final busy = _sendingRole != null;
    final min = percentage?.min ?? 0;
    final max = percentage?.max ?? 100;
    final speed = _assumed ?? value?.decodedNumber;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (turnOn != null || turnOff != null)
          Wrap(
            spacing: 8,
            children: [
              if (turnOn != null)
                OutlinedButton(
                  onPressed: busy ? null : () => unawaited(_send(turnOn)),
                  child: const Text('On'),
                ),
              if (turnOff != null)
                OutlinedButton(
                  onPressed: busy ? null : () => unawaited(_send(turnOff)),
                  child: const Text('Off'),
                ),
            ],
          ),
        if (percentage != null && max > min)
          Slider(
            value: (speed ?? min).clamp(min, max),
            min: min,
            max: max,
            onChanged: busy ? null : (v) => setState(() => _assumed = v),
            onChangeEnd: busy
                ? null
                : (v) {
                    final param = percentage.userParams.firstOrNull;
                    _assumedBaseline = value?.decoded;
                    unawaited(_send(percentage,
                        params: param == null
                            ? const {}
                            : {param: v.roundToDouble()},
                        assume: v));
                  },
          ),
        if (oscillating != null)
          Row(
            children: [
              Text('Oscillate', style: text.bodyMedium),
              const Spacer(),
              for (final (label, raw) in const [('On', 1.0), ('Off', 0.0)])
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: OutlinedButton(
                    onPressed: busy
                        ? null
                        : () {
                            final param =
                                oscillating.userParams.firstOrNull;
                            unawaited(_send(oscillating,
                                params: param == null
                                    ? const {}
                                    : {param: raw}));
                          },
                    child: Text(label),
                  ),
                ),
            ],
          ),
      ],
    );
  }

  Widget _coverBody(EntityLiveValue? value) {
    final open = _action('open_cover');
    final close = _action('close_cover');
    final stop = _action('stop_cover');
    final position = _action('set_cover_position');
    final busy = _sendingRole != null;
    final positionValue = value?.decodedNumber;
    final min = position?.min ?? 0;
    final max = position?.max ?? 100;

    Widget motion(EntityActionDto? action, IconData icon, String label) =>
        Expanded(
          child: OutlinedButton.icon(
            onPressed:
                (action == null || busy) ? null : () => unawaited(_send(action)),
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        );

    return Column(
      children: [
        Row(
          children: [
            motion(open, Icons.arrow_upward, 'Open'),
            const SizedBox(width: 8),
            motion(stop, Icons.stop, 'Stop'),
            const SizedBox(width: 8),
            motion(close, Icons.arrow_downward, 'Close'),
          ],
        ),
        // The slider claims to show where the cover is, so it is earned only
        // by a live position; the motions above promise nothing.
        if (position != null && positionValue != null && max > min)
          Slider(
            value: positionValue.clamp(min, max),
            min: min,
            max: max,
            onChanged: busy ? null : (_) {},
            onChangeEnd: busy
                ? null
                : (v) {
                    final param = position.userParams.firstOrNull;
                    _assumedBaseline = value?.decoded;
                    unawaited(_send(position,
                        params: param == null
                            ? const {}
                            : {param: v.roundToDouble()},
                        assume: v));
                  },
          ),
      ],
    );
  }

  Widget _stateLine(EntityLiveValue? value, ColorScheme scheme, TextTheme text) {
    final style = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (_sendingRole != null) return Text('Sending...', style: style);
    if (_status != null && _failed) {
      return Text(_status!,
          style: text.bodySmall?.copyWith(color: scheme.error));
    }
    if (_status != null) return Text(_status!, style: style);
    if (value == null) {
      // A button is momentary and never claimed state; anything else without
      // a binding says so instead of implying its controls reflect anything.
      return Text(
          widget.entity.platform == 'button'
              ? 'Momentary'
              : 'State unknown — commands send blind',
          style: style);
    }
    return switch (value.status) {
      EntityValueStatus.unavailable => Text(
          'State not decodable yet (no format block in the spec).',
          style: style),
      EntityValueStatus.loading => Text('Reading...', style: style),
      EntityValueStatus.error =>
        Text(value.error ?? 'Could not read state.', style: style),
      EntityValueStatus.live =>
        Text(value.display ?? 'State unreadable', style: style),
    };
  }
}

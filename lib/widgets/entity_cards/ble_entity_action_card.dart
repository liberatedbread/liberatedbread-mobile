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
import '../unclaimed_actions.dart';

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

  /// The fan slider's position while a drag is in progress, cleared when the
  /// gesture ends and the value is sent. Kept apart from [_assumed] because
  /// [_buildCard] clears that whenever the live value's decode is not the
  /// one it was set against — and during a drag it never is: the baseline is
  /// only recorded at release. Routing the drag through [_assumed] meant
  /// every `onChanged` was undone by the rebuild it triggered, so the thumb
  /// sat pinned at the device's reported speed for the whole gesture and
  /// only the release value went out. A live value never supersedes a drag
  /// the user's finger is still on.
  double? _dragging;

  EntityActionDto? _action(String role) =>
      widget.entity.actions.where((a) => a.role == role).firstOrNull;

  /// Every resolved action in the shape [UnclaimedActions] compares against.
  /// A role with no user parameter is a fixed command, which is drawable as a
  /// button without knowing anything else about the role.
  List<({String role, bool takesValue})> get _resolvedActions => [
    for (final action in widget.entity.actions)
      (role: action.role, takesValue: action.userParams.isNotEmpty),
  ];

  /// Whatever the platform's own builder below did not draw. Each of the four
  /// builders knows one role set, and the table resolves roles none of them
  /// ask for — a fan's `toggle` is drawn by nobody — which otherwise reaches
  /// the user as a card with a title, a state line and an empty control area.
  ///
  /// Padded only when something is unclaimed, so a card that draws every role
  /// it resolved keeps the layout it had.
  Widget _unclaimed(Set<String> claimed) {
    final actions = _resolvedActions;
    if (actions.every((a) => claimed.contains(a.role))) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: UnclaimedActions(
        actions: actions,
        claimed: claimed,
        onSend: _sendRole,
        sendingRole: _sendingRole,
      ),
    );
  }

  /// An unclaimed action goes out through the same codec write as a drawn
  /// one, so a role this card never learned about cannot acquire a second
  /// send path with its own encoding and its own error handling.
  Future<void> _sendRole(String role) async {
    final action = _action(role);
    if (action == null) return;
    await _send(action);
  }

  Future<void> _send(
    EntityActionDto action, {
    Map<String, double> params = const {},
    double? assume,
  }) async {
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
      await ref
          .read(bleServiceProvider)
          .writeCharacteristic(
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
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(text)));
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
      // A platform routed here without a builder claims nothing, so every
      // action it resolved is drawn below rather than nowhere.
      _ => _unclaimed(const {}),
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
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton.tonalIcon(
            onPressed: (press == null || _sendingRole != null)
                ? null
                : () => unawaited(_send(press)),
            icon: const Icon(Icons.touch_app, size: 18),
            label: const Text('Press'),
          ),
        ),
        _unclaimed(const {'press'}),
      ],
    );
  }

  /// The spec's option table as chips; the current one is the decoded state
  /// when readable, else the last option sent.
  Widget _selectBody(EntityLiveValue? value) {
    final action = _action('select_option');
    final current = _assumed ?? value?.decodedNumber;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final option in widget.entity.options)
              ChoiceChip(
                label: Text(option.label),
                selected:
                    current != null && double.tryParse(option.raw) == current,
                onSelected: (action == null || _sendingRole != null)
                    ? null
                    : (_) {
                        final raw = double.tryParse(option.raw);
                        if (raw == null) return;
                        _assumedBaseline = value?.decoded;
                        final param = action.userParams.firstOrNull;
                        unawaited(
                          _send(
                            action,
                            params: param == null ? const {} : {param: raw},
                            assume: raw,
                          ),
                        );
                      },
              ),
          ],
        ),
        _unclaimed(const {'select_option'}),
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
    final speed = _dragging ?? _assumed ?? value?.decodedNumber;

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
            semanticFormatterCallback: (v) =>
                '${widget.entity.name} ${v.round()}',
            value: (speed ?? min).clamp(min, max),
            min: min,
            max: max,
            onChanged: busy ? null : (v) => setState(() => _dragging = v),
            onChangeEnd: busy
                ? null
                : (v) {
                    final param = percentage.userParams.firstOrNull;
                    _dragging = null;
                    _assumedBaseline = value?.decoded;
                    unawaited(
                      _send(
                        percentage,
                        params: param == null
                            ? const {}
                            : {param: v.roundToDouble()},
                        assume: v,
                      ),
                    );
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
                            final param = oscillating.userParams.firstOrNull;
                            unawaited(
                              _send(
                                oscillating,
                                params: param == null ? const {} : {param: raw},
                              ),
                            );
                          },
                    child: Text(label),
                  ),
                ),
            ],
          ),
        _unclaimed(const {
          'turn_on',
          'turn_off',
          'set_percentage',
          'set_oscillating',
        }),
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
            onPressed: (action == null || busy)
                ? null
                : () => unawaited(_send(action)),
            icon: Icon(icon, size: 18),
            label: Text(label),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
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
            semanticFormatterCallback: (v) =>
                '${widget.entity.name} ${v.round()}',
            value: positionValue.clamp(min, max),
            min: min,
            max: max,
            onChanged: busy ? null : (_) {},
            onChangeEnd: busy
                ? null
                : (v) {
                    final param = position.userParams.firstOrNull;
                    _assumedBaseline = value?.decoded;
                    unawaited(
                      _send(
                        position,
                        params: param == null
                            ? const {}
                            : {param: v.roundToDouble()},
                        assume: v,
                      ),
                    );
                  },
          ),
        _unclaimed(const {
          'open_cover',
          'close_cover',
          'stop_cover',
          'set_cover_position',
        }),
      ],
    );
  }

  Widget _stateLine(
    EntityLiveValue? value,
    ColorScheme scheme,
    TextTheme text,
  ) {
    final style = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (_sendingRole != null) return Text('Sending...', style: style);
    if (_status != null && _failed) {
      return Text(
        _status!,
        style: text.bodySmall?.copyWith(color: scheme.error),
      );
    }
    if (_status != null) return Text(_status!, style: style);
    if (value == null) {
      // A button is momentary and never claimed state; anything else without
      // a binding says so instead of implying its controls reflect anything.
      return Text(
        widget.entity.platform == 'button'
            ? 'Momentary'
            : 'State unknown — commands send blind',
        style: style,
      );
    }
    return switch (value.status) {
      EntityValueStatus.unavailable => Text(
        'State not decodable yet (no format block in the spec).',
        style: style,
      ),
      EntityValueStatus.loading => Text('Reading...', style: style),
      EntityValueStatus.error => Text(
        value.error ?? 'Could not read state.',
        style: style,
      ),
      EntityValueStatus.live => Text(
        value.display ?? 'State unreadable',
        style: style,
      ),
    };
  }
}

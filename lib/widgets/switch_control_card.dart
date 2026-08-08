// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../providers/ble_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';
import 'entity_value.dart';

/// A spec-declared `switch` entity as a working control.
///
/// Everything here is resolved spec data: the toggle sends the entity's
/// `turn_on`/`turn_off` actions, a `press` action renders as a momentary
/// button (SwitchBot's bot in press mode), and the shown state follows the
/// spec's own on/off rules via [EntityLiveValue.isOn].
///
/// Two honest degradations, both present in the catalogue:
/// - No state binding (govee's plug declares only commands): the toggle is
///   replaced by On/Off buttons, which promise nothing about current state.
/// - No sendable actions (ember's temperature-control switch binds prose):
///   the card shows live state with no way to change it, which is exactly
///   what the spec supports today.
class SwitchControlCard extends ConsumerStatefulWidget {
  final String deviceId;

  /// Discovered service owning the entity's state characteristic; null when
  /// the entity has no state binding (or the characteristic was not
  /// discovered on this device).
  final String? stateServiceUuid;
  final EntityDto entity;
  final String specYaml;

  const SwitchControlCard({
    super.key,
    required this.deviceId,
    required this.stateServiceUuid,
    required this.entity,
    required this.specYaml,
  });

  @override
  ConsumerState<SwitchControlCard> createState() => _SwitchControlCardState();
}

class _SwitchControlCardState extends ConsumerState<SwitchControlCard> {
  /// Role currently being sent, disabling its control meanwhile.
  String? _sendingRole;
  String? _status;
  bool _failed = false;

  /// The position the user last commanded, shown until the device reports a
  /// fresh state. Cleared when a newer decode arrives (tracked by list
  /// identity — each decode builds a new list).
  bool? _assumed;
  List<DecodedValueDto>? _assumedBaseline;

  EntityActionDto? _action(String role) => widget.entity.actions
      .where((a) => a.role == role)
      .firstOrNull;

  Future<void> _send(EntityActionDto action, {bool? assume}) async {
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
        commandName: action.commandName,
        params: const {},
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
    if (stateService == null) {
      return _buildTile(context, null);
    }
    return EntityValueBuilder(
      deviceId: widget.deviceId,
      serviceUuid: stateService,
      entity: widget.entity,
      specYaml: widget.specYaml,
      builder: _buildTile,
    );
  }

  Widget _buildTile(BuildContext context, EntityLiveValue? value) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // A decode newer than the last command supersedes the assumed position.
    if (value != null && !identical(value.decoded, _assumedBaseline)) {
      _assumed = null;
    }
    final deviceOn = value?.isOn;
    final shownOn = _assumed ?? deviceOn;

    final turnOn = _action('turn_on');
    final turnOff = _action('turn_off');
    final press = _action('press');
    // A toggle claims to show the current position, so it is earned only
    // when state is genuinely readable; command-only switches (govee's plug)
    // and undecodable ones get On/Off buttons, which promise nothing.
    final canReadState = value != null && widget.entity.hasFormat;
    final hasToggle = turnOn != null && turnOff != null && canReadState;

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
                  shownOn == true
                      ? Icons.toggle_on
                      : Icons.toggle_off_outlined,
                  color: shownOn == true
                      ? scheme.primary
                      : scheme.onSecondaryContainer,
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
                    _stateLine(value, shownOn, scheme, text),
                  ],
                ),
              ),
              if (hasToggle)
                Switch(
                  value: shownOn ?? false,
                  onChanged: _sendingRole != null
                      ? null
                      : (on) {
                          _assumedBaseline = value?.decoded;
                          _send(on ? turnOn : turnOff, assume: on);
                        },
                ),
            ],
          ),
          if (!hasToggle && (turnOn != null || turnOff != null) ||
              press != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                children: [
                  if (!hasToggle && turnOn != null)
                    OutlinedButton(
                      onPressed: _sendingRole != null
                          ? null
                          : () {
                              _assumedBaseline = value?.decoded;
                              _send(turnOn, assume: true);
                            },
                      child: const Text('On'),
                    ),
                  if (!hasToggle && turnOff != null)
                    OutlinedButton(
                      onPressed: _sendingRole != null
                          ? null
                          : () {
                              _assumedBaseline = value?.decoded;
                              _send(turnOff, assume: false);
                            },
                      child: const Text('Off'),
                    ),
                  if (press != null)
                    OutlinedButton.icon(
                      onPressed: _sendingRole != null
                          ? null
                          : () => _send(press),
                      icon: const Icon(Icons.touch_app, size: 16),
                      label: const Text('Press'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _stateLine(
    EntityLiveValue? value,
    bool? shownOn,
    ColorScheme scheme,
    TextTheme text,
  ) {
    final style = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (_sendingRole != null) return Text('Sending...', style: style);
    if (_status != null && _failed) {
      return Text(_status!,
          style: text.bodySmall?.copyWith(color: scheme.error));
    }
    if (value == null) {
      // Command-only entity: no state characteristic to consult, so say so
      // instead of implying the buttons reflect anything.
      return Text('State unknown — commands send blind', style: style);
    }
    return switch (value.status) {
      EntityValueStatus.unavailable => Text(
          'State not decodable yet (no format block in the spec).',
          style: style,
        ),
      EntityValueStatus.loading => Text('Reading...', style: style),
      EntityValueStatus.error =>
        Text(value.error ?? 'Could not read state.', style: style),
      EntityValueStatus.live => Text(
          switch (shownOn) {
            true => _assumed != null ? 'On (sent)' : 'On',
            false => _assumed != null ? 'Off (sent)' : 'Off',
            null => 'State unreadable',
          },
          style: style,
        ),
    };
  }
}

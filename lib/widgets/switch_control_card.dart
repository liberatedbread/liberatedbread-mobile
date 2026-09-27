// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../providers/ble_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';
import 'entity_value.dart';
import 'unclaimed_actions.dart';

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
///
/// A `switch` also resolves `toggle`, which none of the controls above can
/// present — a single-channel power role says nothing about which way it
/// leaves the device. That one, and anything a later `PLATFORM_ROLES` gains,
/// goes to [UnclaimedActions] beneath the controls, so no resolved action
/// ends up drawn by nobody.
class SwitchControlCard extends ConsumerStatefulWidget {
  final String deviceId;

  /// Discovered service owning the entity's state characteristic; null when
  /// the entity has no state binding (or the characteristic was not
  /// discovered on this device).
  final String? stateServiceUuid;
  final EntityDto entity;
  final String specYaml;

  /// Whether this switch is a lock's bolt — on locks, off unlocks (the
  /// SESAME and August/Yale specs say so in exactly those words). A lock drawn
  /// as a generic switch read "On"/"Off" beside "State unknown — commands
  /// send blind", so the button that opens the front door was labelled Off.
  /// As a lock it says Lock/Unlock, and unlocking asks first.
  final bool isLock;

  const SwitchControlCard({
    super.key,
    required this.deviceId,
    required this.stateServiceUuid,
    required this.entity,
    required this.specYaml,
    this.isLock = false,
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

  /// The roles this card takes responsibility for: on/off reaches the device
  /// through the toggle or the On/Off pair, and `press` is the momentary
  /// button. Listed once so what the card draws and what it hands on can
  /// never disagree.
  static const _claimedRoles = {'turn_on', 'turn_off', 'press'};

  EntityActionDto? _action(String role) =>
      widget.entity.actions.where((a) => a.role == role).firstOrNull;

  /// Send an unclaimed role through the controls' own path, so it shares the
  /// codec, the busy state and the error handling rather than growing a
  /// second sender that drifts from this one.
  Future<void> _sendRole(String role) async {
    final action = _action(role);
    if (action == null) return;
    // An unclaimed role promises nothing about the resulting position —
    // `toggle` inverts whatever the device holds — so an assumption left by
    // an earlier tap would keep reporting "On (sent)" for a switch that this
    // send may have just turned off.
    setState(() => _assumed = null);
    await _send(action);
  }

  /// [_send] for the on/off pair, with a lock's unlock confirmed first. A
  /// mis-tap that opens a door is not the same as one that turns off a lamp.
  Future<void> _sendDirection(
    EntityActionDto action, {
    required bool on,
  }) async {
    if (widget.isLock && !on) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text('Unlock ${widget.entity.name}?'),
          content: const Text('This opens the lock for anyone at the door.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Unlock'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    await _send(action, assume: on);
  }

  Future<void> _send(EntityActionDto action, {bool? assume}) async {
    // Only a setpoint action can be a direct write with no command behind it;
    // a switch role always names one. Guarding rather than asserting keeps a
    // malformed remote spec from crashing the panel.
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
        params: const {},
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

    // Every role the resolver produced, so one this card does not draw still
    // reaches the screen instead of falling between the two role lists.
    final resolved = [
      for (final action in widget.entity.actions)
        (role: action.role, takesValue: action.userParams.isNotEmpty),
    ];
    final hasUnclaimed = resolved.any((a) => !_claimedRoles.contains(a.role));

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
                  widget.isLock
                      ? switch (shownOn) {
                          true => Icons.lock,
                          false => Icons.lock_open,
                          null => Icons.lock_outline,
                        }
                      : shownOn == true
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
                      style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
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
                          // `value` is promoted non-null here: hasToggle
                          // implies canReadState implies a live builder.
                          _assumedBaseline = value.decoded;
                          _sendDirection(on ? turnOn : turnOff, on: on);
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
                              _sendDirection(turnOn, on: true);
                            },
                      child: Text(widget.isLock ? 'Lock' : 'On'),
                    ),
                  if (!hasToggle && turnOff != null)
                    OutlinedButton(
                      onPressed: _sendingRole != null
                          ? null
                          : () {
                              _assumedBaseline = value?.decoded;
                              _sendDirection(turnOff, on: false);
                            },
                      child: Text(widget.isLock ? 'Unlock' : 'Off'),
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
          // Guarded here rather than left to the widget's own empty case: a
          // card that draws all of its roles would otherwise carry this
          // row's spacing below its last control forever.
          if (hasUnclaimed)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: UnclaimedActions(
                actions: resolved,
                claimed: _claimedRoles,
                onSend: _sendRole,
                sendingRole: _sendingRole,
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
      return Text(
        _status!,
        style: text.bodySmall?.copyWith(color: scheme.error),
      );
    }
    if (value == null) {
      // Command-only entity: no state characteristic to consult, so say so
      // instead of implying the buttons reflect anything.
      return Text(
        widget.isLock
            ? switch (_assumed) {
                true => 'Lock sent — the lock does not report back',
                false => 'Unlock sent — the lock does not report back',
                null => "The lock doesn't report whether it is locked",
              }
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
      EntityValueStatus.live => Text(switch (shownOn) {
        true when widget.isLock =>
          _assumed != null ? 'Locked (sent)' : 'Locked',
        false when widget.isLock =>
          _assumed != null ? 'Unlocked (sent)' : 'Unlocked',
        true => _assumed != null ? 'On (sent)' : 'On',
        false => _assumed != null ? 'Off (sent)' : 'Off',
        null => 'State unreadable',
      }, style: style),
    };
  }
}

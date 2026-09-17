// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import '../core/unit_display.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/value_format.dart';
import '../providers/ble_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../core/entity_icon.dart';
import '../services/spec_codec.dart';
import 'entity_value.dart';
import 'unclaimed_actions.dart';

/// The role this card draws itself, in the vocabulary the resolver emits.
const _setpointRole = 'set_value';

/// What this card is responsible for presenting. A spec that resolves only
/// the setpoint leaves nothing over, and [UnclaimedActions] draws nothing.
const _claimedRoles = {_setpointRole};

/// A spec-declared `number` or `climate` entity as a working setpoint: what
/// the device reads now, and a control to change it.
///
/// Everything here is in DECODED units — degrees, percent — because that is
/// what the user picks and what the spec's `min`/`max`/`step` describe.
/// Turning a chosen value into bytes is the codec's job
/// ([SpecCodec.encodeEntityValue]), so this widget never learns whether a
/// device speaks centidegrees, `raw * 0.5 + 85`, or plain percent.
///
/// Degrades honestly in both directions. An entity whose write never resolved
/// (Ember's target temperature splits its value across two bytes in a way
/// only prose explains) still shows its live reading and declared range, with
/// no control that would send the wrong thing. An entity that can be written
/// but not read (no `format:` block) gets the control and says the current
/// value is unknown.
///
/// The setpoint is the only role this card knows how to shape a control for.
/// Anything else the entity resolved — a `climate` that also binds power, as
/// frigidaire's does — goes to [UnclaimedActions], so a role this card was
/// never taught still reaches the screen instead of vanishing.
class SetpointControlCard extends ConsumerStatefulWidget {
  final String deviceId;

  /// Discovered service owning the entity's state characteristic; null when
  /// there is no readable state on this device.
  final String? stateServiceUuid;
  final EntityDto entity;
  final String specYaml;

  const SetpointControlCard({
    super.key,
    required this.deviceId,
    required this.stateServiceUuid,
    required this.entity,
    required this.specYaml,
  });

  @override
  ConsumerState<SetpointControlCard> createState() =>
      _SetpointControlCardState();
}

class _SetpointControlCardState extends ConsumerState<SetpointControlCard> {
  /// The role in flight, which holds every control on the card inert until
  /// the write lands — one BLE write at a time, whichever control began it.
  String? _sendingRole;
  bool get _sending => _sendingRole != null;

  String? _errorText;

  /// The value the user is dialling in, in decoded units. Null until they
  /// touch the control or a reading seeds it.
  double? _pending;
  bool _touched = false;

  /// The last value successfully sent, shown until the device reports back.
  double? _sent;

  EntityActionDto? _action(String role) =>
      widget.entity.actions.where((a) => a.role == role).firstOrNull;

  bool get _writable => _action(_setpointRole) != null;

  /// Every action the entity resolved, in the shape [UnclaimedActions] reads.
  List<({String role, bool takesValue})> get _resolvedActions => [
    for (final action in widget.entity.actions)
      (role: action.role, takesValue: action.userParams.isNotEmpty),
  ];

  /// Whether anything is left over for [UnclaimedActions]. The spacing above
  /// it is gated on this, so an entity whose only action is its setpoint lays
  /// out exactly as it did before that widget existed.
  bool get _hasUnclaimed =>
      widget.entity.actions.any((a) => !_claimedRoles.contains(a.role));

  double? get _min => widget.entity.setpointMin;
  double? get _max => widget.entity.setpointMax;

  /// Granularity the spec declares, falling back to something sane for the
  /// range: a 0-100 percentage steps by 1, a 49-63 °C range by 0.5.
  double get _step {
    final declared = widget.entity.setpointStep;
    if (declared != null && declared > 0) return declared;
    final span = (_max ?? 100) - (_min ?? 0);
    return span > 50 ? 1 : 0.5;
  }

  /// How many decimals the step implies, so 0.5 shows "56.5" and 1 shows
  /// "60" rather than "60.0".
  int get _decimals => decimalsForStep(_step);

  /// One write, with the busy flag, error line and snackbar this card already
  /// shows. Everything it sends comes through here — the setpoint and any
  /// action it does not draw a control for — so a role the card was never
  /// taught cannot acquire error handling that drifts from the slider's.
  ///
  /// [encode] runs inside the guarded section because a spec that cannot
  /// build the bytes fails the send just as surely as a refused write, and
  /// the user is owed the same message either way.
  Future<void> _write({
    required String role,
    required String attempt,
    required String fallback,
    required Future<EntityWriteDto> Function() encode,
    double? applied,
  }) async {
    setState(() {
      _sendingRole = role;
      _errorText = null;
    });
    try {
      final write = await encode();
      await ref
          .read(bleServiceProvider)
          .writeCharacteristic(
            widget.deviceId,
            write.serviceUuid,
            write.characteristicUuid,
            write.bytes.toList(),
          );
      if (!mounted) return;
      setState(() {
        _sendingRole = null;
        if (applied != null) _sent = applied;
      });
    } catch (e) {
      if (!mounted) return;
      final text = friendlyErrorText(e, context: attempt, fallback: fallback);
      setState(() {
        _sendingRole = null;
        _errorText = text;
      });
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(text)));
    }
  }

  Future<void> _send(double value) => _write(
    role: _setpointRole,
    attempt: 'set ${widget.entity.name}',
    fallback: 'The device did not accept that value.',
    applied: value,
    encode: () => ref
        .read(specCodecProvider)
        .encodeEntityValue(
          specYaml: widget.specYaml,
          entityName: widget.entity.name,
          value: value,
        ),
  );

  /// Send an action this card draws no control for, exactly as a spec-driven
  /// command goes out anywhere else in the app.
  Future<void> _sendRole(String role) async {
    final action = _action(role);
    final commandName = action?.commandName;
    // Only a setpoint action can be a bare value write with no command behind
    // it, and a value is the one thing an unclaimed fixed action has no way
    // to supply. Guarding rather than asserting keeps a malformed remote spec
    // from crashing the panel.
    if (action == null || commandName == null) return;
    await _write(
      role: role,
      attempt: 'send $commandName',
      fallback: 'The device did not accept that command.',
      encode: () async => EntityWriteDto(
        serviceUuid: action.serviceUuid,
        characteristicUuid: action.characteristicUuid,
        bytes: await ref
            .read(specCodecProvider)
            .encodeCommand(
              specYaml: widget.specYaml,
              charUuid: action.characteristicUuid,
              commandName: commandName,
              params: const {},
            ),
      ),
    );
  }

  /// The entity's unit, spelled for a reader (see [displayUnit]) — the
  /// catalogue's `C` is a comparison key, not something to print.
  String? get _unit => displayUnit(widget.entity.unit);

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

    // The device's own reading seeds the control until the user takes over,
    // so the slider opens where the device actually is.
    final reading = _readingOf(value);
    if (!_touched && reading != null) _pending = reading;

    // A control that says nothing about itself gets a knob rather than the
    // sensor card's dial; everything above that last step is shared, so an
    // entity declaring `icon: mdi:heat-wave` gets it here too — which is
    // where Gerbing's heat levels actually live.
    final icon = entityIcon(widget.entity, fallback: Icons.tune);

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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(icon, color: scheme.onSecondaryContainer, size: 22),
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
                            style: text.titleSmall?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (widget.entity.canNotify)
                          Tooltip(
                            message: 'Updates live',
                            child: Icon(
                              Icons.bolt,
                              size: 16,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    _currentValue(value, scheme, text),
                  ],
                ),
              ),
            ],
          ),
          if (_writable) ...[
            const SizedBox(height: 6),
            _control(scheme, text),
          ] else if (setpointRange(_min, _max) case final range?)
            // Read-only: the range is still worth stating — it is what the
            // device accepts, even though this build cannot send it. Same
            // guard as the control, so a spec whose bounds do not make a
            // range says nothing rather than "Accepts 100–2.55".
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Accepts ${_fmt(range.min)}–${_fmt(range.max)}'
                '${_unit == null ? '' : ' $_unit'}, '
                'but this spec does not describe how to set it yet.',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),
          // Whatever else the entity resolved. A climate that binds power
          // beside its target temperature resolved those actions all along;
          // nothing here asked for them, so nothing put them on screen.
          if (_hasUnclaimed) const SizedBox(height: 10),
          UnclaimedActions(
            actions: _resolvedActions,
            claimed: _claimedRoles,
            onSend: _sendRole,
            // The only thing this card blocks on is its own write, and
            // `sendingRole` already disables the row for that.
            sendingRole: _sendingRole,
          ),
        ],
      ),
    );
  }

  /// The live reading in decoded units, when there is one to show.
  ///
  /// Goes through the same shared transform every other surface uses, which
  /// is also the one `encodeEntityValue` inverts when sending — so what the
  /// slider reads back and what a chosen value writes cannot drift apart.
  double? _readingOf(EntityLiveValue? value) {
    if (value == null || value.status != EntityValueStatus.live) return null;
    return value.decodedNumber;
  }

  Widget _currentValue(
    EntityLiveValue? value,
    ColorScheme scheme,
    TextTheme text,
  ) {
    final style = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (_errorText != null) {
      return Text(
        _errorText!,
        style: text.bodySmall?.copyWith(color: scheme.error),
      );
    }
    if (value == null || value.status == EntityValueStatus.unavailable) {
      // Write-only setpoint: honest about not knowing where the device is.
      return Text(
        _sent == null ? 'Current value unknown' : 'Set to ${_fmt(_sent!)}',
        style: style,
      );
    }
    return switch (value.status) {
      EntityValueStatus.loading => Text('Reading...', style: style),
      EntityValueStatus.error => Text(
        value.error ?? 'Could not read this value.',
        style: style,
      ),
      EntityValueStatus.unavailable => Text(
        'Current value unknown',
        style: style,
      ),
      EntityValueStatus.live => _reading(value, scheme, text),
    };
  }

  Widget _reading(EntityLiveValue value, ColorScheme scheme, TextTheme text) {
    final reading = _readingOf(value);
    if (reading == null) {
      return Text(
        value.primaryError ?? 'The decoded value is not a number.',
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    final unit = value.unit;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          _fmt(reading),
          style: text.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (unit != null) ...[
          const SizedBox(width: 4),
          Text(
            unit,
            style: text.titleSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        // A unit that follows a device setting is not a fact about the
        // protocol — the same raw number means °C or °F depending on how the
        // device is configured, so the reading must not imply otherwise.
        if (value.unitIsDeviceSetting) ...[
          const SizedBox(width: 6),
          Tooltip(
            message:
                'The device decides this unit; it is not fixed by the '
                'protocol.',
            child: Icon(
              Icons.help_outline,
              size: 15,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }

  Widget _control(ColorScheme scheme, TextTheme text) {
    // Not `(_min, _max)` directly: an absent, inverted or zero-width pair
    // cannot drive a Slider (whose `min <= max` is an assert) or `clamp`
    // (which throws on an inverted range), and specs load from arbitrary
    // remote packs. `setpointRange` folds all three cases into "no usable
    // range", which the stepper branch below already handles honestly.
    final range = setpointRange(_min, _max);
    final target = _pending ?? range?.min ?? _min ?? 0;

    // Without a usable range a slider would be inventing bounds, so offer
    // steppers around the current value instead.
    if (range == null) {
      return Row(
        children: [
          Text('Set to ${_fmt(target)}', style: text.bodyMedium),
          const Spacer(),
          _StepButton(
            icon: Icons.remove,
            // Named, because "button" is all a screen reader can say about a
            // bare minus sign — and this one moves a thermostat.
            label: 'Decrease ${widget.entity.name}',
            onTap: _sending ? null : () => _nudge(-_step),
          ),
          const SizedBox(width: 8),
          _StepButton(
            icon: Icons.add,
            label: 'Increase ${widget.entity.name}',
            onTap: _sending ? null : () => _nudge(_step),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: _sending ? null : () => _send(target),
            child: Text(_sending ? 'Sending...' : 'Set'),
          ),
        ],
      );
    }

    final (min, max) = (range.min, range.max);
    final clamped = target.clamp(min, max).toDouble();
    // Discrete stops so the slider can only land on values the device can
    // actually hold — `step` is the device's real resolution, not cosmetic.
    // Null past the division cap: a uint32 setpoint stepped by 1 asks for 4.3
    // billion stops, and a continuous slider is the honest rendering when the
    // steps are finer than the screen.
    final divisions = divisionsForStep(min, max, _step);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text('Set to', style: text.bodySmall),
            const SizedBox(width: 6),
            Text(
              '${_fmt(clamped)}${_unit == null ? '' : ' $_unit'}',
              style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const Spacer(),
            if (_sending)
              Text(
                'Sending...',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
          ],
        ),
        Slider(
          semanticFormatterCallback: (v) => '${widget.entity.name} ${_fmt(v)}',
          min: min,
          max: max,
          divisions: divisions,
          value: clamped,
          label: _fmt(clamped),
          onChanged: _sending
              ? null
              : (v) => setState(() {
                  _touched = true;
                  // Snap to the device's declared step even when the range
                  // is too wide for divisions and the slider runs
                  // continuous — otherwise the label shows a value the
                  // write path rounds away, and display and device
                  // disagree.
                  _pending = snapToStep(v, min, max, _step);
                }),
          // Sent on release rather than per-frame: each change is a BLE
          // write, and a dragged slider would flood the device. Snapped the
          // same way onChanged snaps the label — the Slider hands back its
          // own unsnapped value here, and the write must match the display.
          onChangeEnd: _sending
              ? null
              : (v) => _send(snapToStep(v, min, max, _step)),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              _fmt(min),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
            Text(
              _fmt(max),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ],
    );
  }

  void _nudge(double delta) {
    final base = _pending ?? _min ?? 0;
    var next = base + delta;
    if (_min != null) next = next < _min! ? _min! : next;
    if (_max != null) next = next > _max! ? _max! : next;
    setState(() {
      _touched = true;
      _pending = next;
    });
  }

  String _fmt(double v) => v.toStringAsFixed(_decimals);
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  const _StepButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => IconButton.outlined(
    tooltip: label,
    onPressed: onTap,
    icon: Icon(icon, size: 18),
    constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
  );
}

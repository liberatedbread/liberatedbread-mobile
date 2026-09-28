// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/group_actions.dart';
import '../core/log.dart';
import '../core/unit_display.dart';
import '../providers/device_spec_match_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';
import 'decoded_value_widget.dart';
import 'entity_value.dart';
import 'light_swatches.dart';
import 'unclaimed_actions.dart';

/// A spec-declared `light` entity as working controls: power, brightness,
/// color — whichever subset of roles actually resolved to sendable commands.
///
/// The subset varies by device and that variance is the honest state of the
/// catalogue: elk-bledom resolves brightness and color but no power (its
/// on/off command keeps an un-defaulted, ambiguous protocol byte), ember's
/// LED resolves only `set_color` (which carries brightness in the same
/// write), and the example bulb resolves everything. Rendering only what
/// resolved means every visible control genuinely works.
class LightControlCard extends ConsumerStatefulWidget {
  final String deviceId;

  /// Discovered service owning the entity's state characteristic; null when
  /// the entity has no state binding (or the characteristic was not
  /// discovered on this device).
  final String? stateServiceUuid;
  final EntityDto entity;
  final String specYaml;

  /// The parsed spec, read only for the brightness parameter's declared
  /// unit; null shows the bare number, as the typed card does for a
  /// parameter that declares none.
  final DeviceSpecDto? spec;

  const LightControlCard({
    super.key,
    required this.deviceId,
    required this.stateServiceUuid,
    required this.entity,
    required this.specYaml,
    this.spec,
  });

  @override
  ConsumerState<LightControlCard> createState() => _LightControlCardState();
}

class _LightControlCardState extends ConsumerState<LightControlCard> {
  bool _sending = false;

  /// Which role is in flight. `_sending` says that something is, which is all
  /// the status line needs; a button that has to show its own wait needs to
  /// know the send was ITS send.
  String? _sendingRole;
  String? _errorText;

  /// Assumed power position after a send, until a newer decode reports truth.
  bool? _assumedOn;
  List<DecodedValueDto>? _assumedBaseline;

  /// Local control positions. Seeded once from device state when it arrives;
  /// after the user touches a control their position wins.
  double? _brightness;
  Color? _color;
  bool _touchedBrightness = false;
  bool _touchedColor = false;
  bool _seeded = false;

  EntityActionDto? get _turnOn => _action('turn_on');
  EntityActionDto? get _turnOff => _action('turn_off');
  EntityActionDto? get _setBrightness => _action('set_brightness');
  EntityActionDto? get _setColor => _action('set_color');

  EntityActionDto? _action(String role) =>
      widget.entity.actions.where((a) => a.role == role).firstOrNull;

  /// The roles above: the ones this card is responsible for presenting,
  /// whether or not a given device resolved them. A light also resolves
  /// `toggle` and `set_effect`, which no lookup here asks for — so before
  /// [UnclaimedActions] a spec could bind either, have Rust resolve it, and
  /// have it reach no pixel and no report.
  static const _claimedRoles = <String>{
    'turn_on',
    'turn_off',
    'set_brightness',
    'set_color',
  };

  /// Every resolved action in the shape [UnclaimedActions] reads. A role that
  /// takes a user parameter gets named there rather than drawn, since a
  /// control invented without knowing the value's shape is a dead control.
  List<({String role, bool takesValue})> get _resolvedActions => widget
      .entity
      .actions
      .map((a) => (role: a.role, takesValue: a.userParams.isNotEmpty))
      .toList(growable: false);

  /// Gates the spacer as well as the widget: a light whose every resolved
  /// role is claimed must keep the exact layout it had, and a leading
  /// `SizedBox` in front of an empty widget is still 8 pixels.
  bool get _hasUnclaimed =>
      widget.entity.actions.any((a) => !_claimedRoles.contains(a.role));

  /// Whether a brightness slider makes sense: either a dedicated brightness
  /// command resolved, or the color command carries a brightness parameter
  /// (ember's LED packs both into one write).
  bool get _hasBrightnessControl =>
      _setBrightness != null ||
      (_setColor?.userParams.contains('brightness') ?? false);

  double get _brightnessMin => _setBrightness?.min ?? kUndeclaredBrightnessMin;
  double get _brightnessMax => _setBrightness?.max ?? kUndeclaredBrightnessMax;

  /// The unit the spec declares on the parameter the slider sends, spelled
  /// the way the typed command card spells it — so the two cards for one
  /// parameter say the same thing. This used to be guessed from the bounds
  /// (0 or 1 to 100 read as "%"), which put "40%" beside elk-bledom's
  /// unitless brightness while its typed card said a bare 40, and left
  /// idotmatrix's 5..100 without one.
  String? get _brightnessUnit {
    final spec = widget.spec;
    final action = _setBrightness ?? _setColor;
    final commandName = action?.commandName;
    if (spec == null || action == null || commandName == null) return null;
    final service = findServiceForUuid(spec, action.serviceUuid);
    final char = service == null
        ? null
        : findCharForUuid(service, action.characteristicUuid);
    final command = char?.commands
        .where((c) => c.name == commandName)
        .firstOrNull;
    final param = command?.parameters
        .where((p) => p.name == 'brightness' || p.name == 'level')
        .where((p) => action.userParams.contains(p.name))
        .firstOrNull;
    // The unit describes the DISPLAY value (raw * scale + offset), and the
    // slider shows the raw one it sends. A scaled parameter's unit beside
    // the raw number would state a quantity that is not there — the typed
    // card converts before it labels; this card does not.
    if (param == null || param.scale != null || param.valueOffset != null) {
      return null;
    }
    return displayUnit(param.unit);
  }

  String _brightnessLabel(double v) {
    final unit = _brightnessUnit;
    return unit == null ? '${v.round()}' : '${v.round()} $unit';
  }

  double get _effectiveBrightness =>
      (_brightness ?? _brightnessMax).clamp(_brightnessMin, _brightnessMax);

  /// Parameter values for one action, drawn from the card's current state.
  /// Only the parameters the action declares as UI-owned are sent; the
  /// encoder fills the rest from spec defaults.
  ///
  /// A parameter this card has no value for is OMITTED, not zeroed. It used
  /// to send 0.0, which is a real value: a spec naming its knob `warmth`
  /// got a zero written to the hardware, silently, and the card looked like
  /// it had worked. Omitting hands the decision back to the encoder, which
  /// either fills the spec's own default or fails the send visibly with
  /// ParameterMissing — both honest answers, unlike a zero nobody chose.
  Map<String, double> _paramsFor(EntityActionDto action) {
    final color = _color ?? lightSwatches.first;
    final values = <String, double>{};
    for (final p in action.userParams) {
      final value = switch (p) {
        'brightness' || 'level' => _effectiveBrightness.roundToDouble(),
        'red' => color.r * 255.0,
        'green' => color.g * 255.0,
        'blue' => color.b * 255.0,
        _ => null,
      };
      if (value == null) {
        Log.ui.debug(
          'light card: no value for "$p" on ${action.role} '
          '(${action.commandName}) — leaving it to the spec default',
        );
        continue;
      }
      values[p] = value;
    }
    return values;
  }

  Future<void> _send(EntityActionDto action, {bool? assumeOn}) async {
    // Only a setpoint action can be a direct write with no command behind it;
    // a light role always names one. Guarding rather than asserting keeps a
    // malformed remote spec from crashing the panel.
    final commandName = action.commandName;
    if (commandName == null) return;
    setState(() {
      _sending = true;
      _sendingRole = action.role;
      _errorText = null;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final container = ProviderScope.containerOf(context, listen: false);
      final bytes = await codec.encodeCommand(
        specYaml: widget.specYaml,
        // Scoped to the write's service: a twin UUID under another service
        // must not lend this send its command table.
        serviceUuid: action.serviceUuid,
        charUuid: action.characteristicUuid,
        commandName: commandName,
        params: _paramsFor(action),
      );
      // Through the shared writer, so the readings in this service re-read.
      await writeServiceCommand(
        container,
        deviceId: widget.deviceId,
        serviceUuid: action.serviceUuid,
        charUuid: action.characteristicUuid,
        bytes: bytes.toList(),
        stateServiceUuid: widget.stateServiceUuid,
      );
      if (!mounted) return;
      setState(() {
        _sending = false;
        _sendingRole = null;
        if (assumeOn != null) _assumedOn = assumeOn;
      });
    } catch (e) {
      if (!mounted) return;
      final text = friendlyErrorText(
        e,
        context: 'send ${action.commandName}',
        fallback: 'The device did not accept that command.',
      );
      setState(() {
        _sending = false;
        _sendingRole = null;
        _errorText = text;
      });
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(text)));
    }
  }

  /// Send the user's brightness: through the dedicated command when one
  /// resolved, else by re-sending the color command that carries it — but
  /// only once a color is known, since sending a made-up color to change
  /// brightness would visibly repaint the device.
  void _onBrightnessCommitted() {
    final dedicated = _setBrightness;
    if (dedicated != null) {
      _send(dedicated);
      return;
    }
    final color = _setColor;
    if (color != null &&
        color.userParams.contains('brightness') &&
        _color != null) {
      _send(color);
    }
  }

  /// Send a role this card draws no control for, down the same path as every
  /// control above: same encoder, same busy state, same error text. A second
  /// sender here would be a second way for a write to go wrong quietly.
  ///
  /// No power assumption is passed. A `toggle` names no destination — its new
  /// position is only knowable from the next decode, and assuming one would
  /// paint a state the device may never have reached.
  Future<void> _sendRole(String role) async {
    final action = _action(role);
    if (action == null) return;
    // An unclaimed role promises nothing about the resulting position —
    // `toggle` inverts whatever the device holds — so an assumption left by an
    // earlier On/Off tap would keep the card reading "On (sent)" for a light
    // this send may have just turned off. A write-only light never produces
    // the live decode that would clear it. Same clearing the switch card does.
    setState(() => _assumedOn = null);
    await _send(action);
  }

  /// Seed control positions from the first live decode, and let a newer
  /// decode supersede an assumed power state. Untouched controls follow the
  /// device; touched ones belong to the user.
  void _absorb(EntityLiveValue? value) {
    if (value == null || value.status != EntityValueStatus.live) return;
    if (!identical(value.decoded, _assumedBaseline)) _assumedOn = null;
    if (_seeded && (_touchedBrightness || _touchedColor)) return;

    final entity = widget.entity;
    if (!_touchedBrightness) {
      final raw = value.rawOf(entity.brightnessField);
      if (raw != null) {
        _brightness = raw.toDouble().clamp(_brightnessMin, _brightnessMax);
      }
    }
    if (!_touchedColor) {
      final r = value.rawOf(entity.colorRedField);
      final g = value.rawOf(entity.colorGreenField);
      final b = value.rawOf(entity.colorBlueField);
      if (r != null && g != null && b != null) {
        _color = Color.fromARGB(
          255,
          r.clamp(0, 255),
          g.clamp(0, 255),
          b.clamp(0, 255),
        );
      }
    }
    _seeded = true;
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

    _absorb(value);
    final shownOn = _assumedOn ?? value?.isOn;

    final turnOn = _turnOn;
    final turnOff = _turnOff;
    final hasToggle = turnOn != null && turnOff != null;

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
                  color: shownOn == true && _color != null
                      ? _color!.withValues(alpha: 0.25)
                      : scheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(13),
                ),
                child: Icon(
                  shownOn == true ? Icons.lightbulb : Icons.lightbulb_outline,
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
                    _statusLine(value, shownOn, scheme, text),
                  ],
                ),
              ),
              if (hasToggle)
                Switch(
                  value: shownOn ?? false,
                  onChanged: _sending
                      ? null
                      : (on) {
                          _assumedBaseline = value?.decoded;
                          _send(on ? turnOn : turnOff, assumeOn: on);
                        },
                ),
            ],
          ),
          if (!hasToggle && (turnOn != null || turnOff != null))
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Wrap(
                spacing: 8,
                children: [
                  if (turnOn != null)
                    OutlinedButton(
                      onPressed: _sending
                          ? null
                          : () {
                              _assumedBaseline = value?.decoded;
                              _send(turnOn, assumeOn: true);
                            },
                      child: const Text('On'),
                    ),
                  if (turnOff != null)
                    OutlinedButton(
                      onPressed: _sending
                          ? null
                          : () {
                              _assumedBaseline = value?.decoded;
                              _send(turnOff, assumeOn: false);
                            },
                      child: const Text('Off'),
                    ),
                ],
              ),
            ),
          if (_hasBrightnessControl) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  Icons.brightness_6,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                Expanded(
                  child: Slider(
                    // Without this a screen reader announces the bare number
                    // — "40" — and which of a light card's several numbers it
                    // is has to be guessed from focus order.
                    semanticFormatterCallback: (v) =>
                        'Brightness ${_brightnessLabel(v)}',
                    min: _brightnessMin,
                    max: _brightnessMax,
                    value: _effectiveBrightness,
                    label: _brightnessLabel(_effectiveBrightness),
                    onChanged: _sending
                        ? null
                        : (v) => setState(() {
                            _touchedBrightness = true;
                            _brightness = v;
                          }),
                    onChangeEnd: _sending
                        ? null
                        : (_) => _onBrightnessCommitted(),
                  ),
                ),
                Text(
                  _brightnessLabel(_effectiveBrightness),
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ],
          if (_setColor != null) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final swatch in lightSwatches)
                  SwatchButton(
                    color: swatch,
                    selected: _color == swatch,
                    enabled: !_sending,
                    onTap: () {
                      setState(() {
                        _touchedColor = true;
                        _color = swatch;
                      });
                      _send(_setColor!);
                    },
                  ),
              ],
            ),
          ],
          if (_hasUnclaimed) ...[
            const SizedBox(height: 8),
            UnclaimedActions(
              actions: _resolvedActions,
              claimed: _claimedRoles,
              onSend: _sendRole,
              sendingRole: _sendingRole,
              enabled: !_sending,
            ),
          ],
        ],
      ),
    );
  }

  Widget _statusLine(
    EntityLiveValue? value,
    bool? shownOn,
    ColorScheme scheme,
    TextTheme text,
  ) {
    final style = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (_sending) return Text('Sending...', style: style);
    if (_errorText != null) {
      return Text(
        _errorText!,
        style: text.bodySmall?.copyWith(color: scheme.error),
      );
    }
    // Lights commonly have no readable state at all (most strips are
    // write-only); a working blind control is normal, so only a live decode
    // earns a state line.
    if (value == null || value.status != EntityValueStatus.live) {
      return Text('Ready', style: style);
    }
    return Text(switch (shownOn) {
      true => _assumedOn != null ? 'On (sent)' : 'On',
      false => _assumedOn != null ? 'Off (sent)' : 'Off',
      null => 'Ready',
    }, style: style);
  }
}

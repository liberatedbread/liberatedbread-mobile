// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../providers/ble_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';
import 'entity_value.dart';

/// Preset swatches offered by the color picker. Plain RGB values sent
/// verbatim; the device's own gamma/order handling is the spec template's
/// business.
const _swatches = <Color>[
  Color(0xFFFFFFFF), // white
  Color(0xFFFFE4B5), // warm white
  Color(0xFFFF0000),
  Color(0xFFFF6600),
  Color(0xFFFFAA00),
  Color(0xFFFFFF00),
  Color(0xFFAAFF00),
  Color(0xFF00FF00),
  Color(0xFF00FFAA),
  Color(0xFF00FFFF),
  Color(0xFF00AAFF),
  Color(0xFF0000FF),
  Color(0xFF6600FF),
  Color(0xFFAA00FF),
  Color(0xFFFF00FF),
  Color(0xFFFF0066),
];

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

  const LightControlCard({
    super.key,
    required this.deviceId,
    required this.stateServiceUuid,
    required this.entity,
    required this.specYaml,
  });

  @override
  ConsumerState<LightControlCard> createState() => _LightControlCardState();
}

class _LightControlCardState extends ConsumerState<LightControlCard> {
  bool _sending = false;
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

  /// Whether a brightness slider makes sense: either a dedicated brightness
  /// command resolved, or the color command carries a brightness parameter
  /// (ember's LED packs both into one write).
  bool get _hasBrightnessControl =>
      _setBrightness != null ||
      (_setColor?.userParams.contains('brightness') ?? false);

  double get _brightnessMin => _setBrightness?.min ?? 0;
  double get _brightnessMax => _setBrightness?.max ?? 255;

  double get _effectiveBrightness =>
      (_brightness ?? _brightnessMax).clamp(_brightnessMin, _brightnessMax);

  /// Parameter values for one action, drawn from the card's current state.
  /// Only the parameters the action declares as UI-owned are sent; the
  /// encoder fills the rest from spec defaults.
  Map<String, double> _paramsFor(EntityActionDto action) {
    final color = _color ?? _swatches.first;
    return {
      for (final p in action.userParams)
        p: switch (p) {
          'brightness' || 'level' => _effectiveBrightness.roundToDouble(),
          'red' => color.r * 255.0,
          'green' => color.g * 255.0,
          'blue' => color.b * 255.0,
          _ => 0.0,
        },
    };
  }

  Future<void> _send(EntityActionDto action, {bool? assumeOn}) async {
    setState(() {
      _sending = true;
      _errorText = null;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final bytes = await codec.encodeCommand(
        specYaml: widget.specYaml,
        charUuid: action.characteristicUuid,
        commandName: action.commandName,
        params: _paramsFor(action),
      );
      await ref.read(bleServiceProvider).writeCharacteristic(
            widget.deviceId,
            action.serviceUuid,
            action.characteristicUuid,
            bytes.toList(),
          );
      if (!mounted) return;
      setState(() {
        _sending = false;
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
        _errorText = text;
      });
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text(text)));
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
        _brightness =
            raw.toDouble().clamp(_brightnessMin, _brightnessMax);
      }
    }
    if (!_touchedColor) {
      final r = value.rawOf(entity.colorRedField);
      final g = value.rawOf(entity.colorGreenField);
      final b = value.rawOf(entity.colorBlueField);
      if (r != null && g != null && b != null) {
        _color = Color.fromARGB(255, r.clamp(0, 255), g.clamp(0, 255),
            b.clamp(0, 255));
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
                  shownOn == true
                      ? Icons.lightbulb
                      : Icons.lightbulb_outline,
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
                      style: text.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w700),
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
                Icon(Icons.brightness_6,
                    size: 18, color: scheme.onSurfaceVariant),
                Expanded(
                  child: Slider(
                    min: _brightnessMin,
                    max: _brightnessMax,
                    value: _effectiveBrightness,
                    label: '${_effectiveBrightness.round()}',
                    onChanged: _sending
                        ? null
                        : (v) => setState(() {
                              _touchedBrightness = true;
                              _brightness = v;
                            }),
                    onChangeEnd: _sending ? null : (_) => _onBrightnessCommitted(),
                  ),
                ),
                Text(
                  '${_effectiveBrightness.round()}',
                  style: text.bodySmall
                      ?.copyWith(color: scheme.onSurfaceVariant),
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
                for (final swatch in _swatches)
                  _SwatchButton(
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
      return Text(_errorText!,
          style: text.bodySmall?.copyWith(color: scheme.error));
    }
    // Lights commonly have no readable state at all (most strips are
    // write-only); a working blind control is normal, so only a live decode
    // earns a state line.
    if (value == null || value.status != EntityValueStatus.live) {
      return Text('Ready', style: style);
    }
    return Text(
      switch (shownOn) {
        true => _assumedOn != null ? 'On (sent)' : 'On',
        false => _assumedOn != null ? 'Off (sent)' : 'Off',
        null => 'Ready',
      },
      style: style,
    );
  }
}

class _SwatchButton extends StatelessWidget {
  final Color color;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _SwatchButton({
    required this.color,
    required this.selected,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Dark checkmark on light swatches, light on dark ones.
    final luminance = color.computeLuminance();
    return InkWell(
      onTap: enabled ? onTap : null,
      borderRadius: BorderRadius.circular(19),
      child: Container(
        width: 38,
        height: 38,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outlineVariant,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? Icon(
                Icons.check,
                size: 18,
                color: luminance > 0.5 ? Colors.black87 : Colors.white,
              )
            : null,
      ),
    );
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';

/// Preset swatches, matching the BLE light card so a colour means the same on
/// either screen. Plain RGB, sent verbatim; the device's gamma is its business.
const _swatches = <Color>[
  Color(0xFFFFFFFF),
  Color(0xFFFFE4B5),
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

/// A LIFX `light` entity as working controls: power, colour, brightness,
/// colour temperature and — on a multizone strip — per-zone colour.
///
/// The Wi-Fi counterpart of [LightControlCard], one transport over: it renders
/// each action's bytes through the Rust codec and sends them over UDP with
/// [LifxControlClient], and reads the strip's live state the same way (a
/// request whose reply the codec decodes). Only the roles that actually
/// resolved are drawn, so a bulb without multizone shows no zone row.
///
/// LIFX control is fire-and-forget UDP: a set is not acknowledged, so the card
/// shows an *assumed* position immediately and lets a later live read correct
/// it. A device that never answers a read (write-only firmware, or a mock host)
/// simply keeps its assumed positions — the controls still work.
class NetworkLightCard extends ConsumerStatefulWidget {
  final NetworkEntityDto entity;
  final String specYaml;

  /// The device's IP, from discovery.
  final String host;

  /// The device MAC in `d0:73:d5:…` form, or empty when discovery has not
  /// supplied one — an empty target still addresses the single host we unicast
  /// to, which is what LIFX firmware accepts.
  final String targetMac;

  const NetworkLightCard({
    super.key,
    required this.entity,
    required this.specYaml,
    required this.host,
    required this.targetMac,
  });

  @override
  ConsumerState<NetworkLightCard> createState() => _NetworkLightCardState();
}

class _NetworkLightCardState extends ConsumerState<NetworkLightCard> {
  bool _sending = false;
  String? _errorText;

  /// Assumed power position after a send, until a live read reports truth.
  bool? _assumedOn;

  /// Local control positions, seeded from the first live read; after the user
  /// touches a control their position wins.
  Color _color = _swatches.first;
  double _brightness = 255;
  double _kelvin = 3500;
  bool _seeded = false;

  /// The strip's zones, once a live read reports them. Empty until then; drives
  /// the per-zone row. `_selectedZone` null means "the whole strip".
  List<Color> _zoneColors = const [];
  int? _selectedZone;

  NetworkActionDto? _action(String role) {
    for (final action in widget.entity.actions) {
      if (action.role == role) return action;
    }
    return null;
  }

  NetworkActionDto? get _turnOn => _action('turn_on');
  NetworkActionDto? get _turnOff => _action('turn_off');
  NetworkActionDto? get _setColor => _action('set_color');
  NetworkActionDto? get _setBrightness => _action('set_brightness');
  NetworkActionDto? get _setColorTemperature =>
      _action('set_color_temperature');
  NetworkActionDto? get _setZoneColor => _action('set_zone_color');

  bool get _hasBrightness =>
      _setBrightness != null ||
      (_setColor?.userParams.contains('brightness') ?? false);

  @override
  void initState() {
    super.initState();
    // Read live state without blocking the first frame: the controls render
    // immediately and correct themselves if the device answers.
    unawaited(_readState());
    if (_setZoneColor != null) unawaited(_readZones());
  }

  Map<String, double> _colorParams({double? brightnessOverride}) {
    final params = <String, double>{
      'red': _color.r * 255.0,
      'green': _color.g * 255.0,
      'blue': _color.b * 255.0,
    };
    if (_hasBrightness) {
      params['brightness'] =
          (brightnessOverride ?? _brightness).roundToDouble();
    }
    return params;
  }

  /// Render one action's bytes and fire them at the strip. Fire-and-forget:
  /// no reply is awaited, so [assumeOn] records the position to show meanwhile.
  Future<void> _send(
    String action,
    Map<String, double> params, {
    bool? assumeOn,
  }) async {
    setState(() {
      _sending = true;
      _errorText = null;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final client = ref.read(lifxControlClientProvider);
      final bytes = await codec.renderLifxCommand(
        action: action,
        params: params,
        targetMac: widget.targetMac,
        sequence: client.nextSequence(),
      );
      await client.send(widget.host, bytes);
      if (!mounted) return;
      setState(() {
        _sending = false;
        if (assumeOn != null) _assumedOn = assumeOn;
      });
    } catch (e) {
      if (!mounted) return;
      final text = friendlyErrorText(
        e,
        context: 'send $action',
        fallback: 'The strip did not accept that command.',
      );
      setState(() {
        _sending = false;
        _errorText = text;
      });
    }
  }

  /// Apply the current colour: to the whole strip, or to the selected zone.
  void _applyColor() {
    final zone = _selectedZone;
    if (zone != null && _setZoneColor != null) {
      final params = _colorParams()..['zone'] = zone.toDouble();
      _send('set_zone_color', params);
      if (zone < _zoneColors.length) {
        setState(() => _zoneColors = [
              for (var i = 0; i < _zoneColors.length; i++)
                i == zone ? _color : _zoneColors[i],
            ]);
      }
    } else {
      _send('set_color', _colorParams());
    }
  }

  Future<void> _readState() async {
    try {
      final codec = ref.read(specCodecProvider);
      final client = ref.read(lifxControlClientProvider);
      final seq = client.nextSequence();
      final req = await codec.buildLifxStateRequest(
          targetMac: widget.targetMac, sequence: seq);
      final reply = await client.request(widget.host, req, sequence: seq);
      if (reply == null || !mounted) return;
      final state = await codec.decodeLifxState(bytes: reply);
      if (!mounted || _seeded) return;
      setState(() {
        _assumedOn = state.powerOn;
        _color = Color.fromARGB(255, state.red, state.green, state.blue);
        _brightness = state.brightness.toDouble();
        if (state.kelvin > 0) _kelvin = state.kelvin.toDouble();
        _seeded = true;
      });
    } catch (_) {
      // A read that fails leaves the assumed positions in place; the controls
      // still work. Nothing to surface — the user did not ask for a read.
    }
  }

  Future<void> _readZones() async {
    try {
      final codec = ref.read(specCodecProvider);
      final client = ref.read(lifxControlClientProvider);
      final seq = client.nextSequence();
      final req = await codec.buildLifxZonesRequest(
          targetMac: widget.targetMac, start: 0, end: 255, sequence: seq);
      final reply = await client.request(widget.host, req, sequence: seq);
      if (reply == null || !mounted) return;
      final zones = await codec.decodeLifxZones(bytes: reply);
      if (!mounted || zones.colors.isEmpty) return;
      setState(() {
        _zoneColors = [
          for (final c in zones.colors)
            Color.fromARGB(255, c.red, c.green, c.blue),
        ];
      });
    } catch (_) {
      // As with state: a strip that will not report its zones still takes
      // per-zone writes; the row just launches without live colours.
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final turnOn = _turnOn;
    final turnOff = _turnOff;
    final hasToggle = turnOn != null && turnOff != null;
    final shownOn = _assumedOn;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: shownOn == true
                        ? _color.withValues(alpha: 0.25)
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
                      Text(widget.entity.name,
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                      const SizedBox(height: 2),
                      _statusLine(shownOn, scheme, text),
                    ],
                  ),
                ),
                if (hasToggle)
                  Switch(
                    value: shownOn ?? false,
                    onChanged: _sending
                        ? null
                        : (on) => _send(
                              on ? 'turn_on' : 'turn_off',
                              const {},
                              assumeOn: on,
                            ),
                  ),
              ],
            ),
            if (_hasBrightness) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(Icons.brightness_6,
                      size: 18, color: scheme.onSurfaceVariant),
                  Expanded(
                    child: Slider(
                      min: 0,
                      max: 255,
                      value: _brightness.clamp(0, 255),
                      label: '${_brightness.round()}',
                      onChanged: _sending
                          ? null
                          : (v) => setState(() => _brightness = v),
                      onChangeEnd: _sending ? null : (_) => _commitBrightness(),
                    ),
                  ),
                  Text('${_brightness.round()}',
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ],
            if (_setColorTemperature != null) ...[
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.thermostat,
                      size: 18, color: scheme.onSurfaceVariant),
                  Expanded(
                    child: Slider(
                      min: (_setColorTemperature!.min ?? 1500).toDouble(),
                      max: (_setColorTemperature!.max ?? 9000).toDouble(),
                      value: _kelvin.clamp(
                        _setColorTemperature!.min ?? 1500,
                        _setColorTemperature!.max ?? 9000,
                      ),
                      label: '${_kelvin.round()}K',
                      onChanged:
                          _sending ? null : (v) => setState(() => _kelvin = v),
                      onChangeEnd: _sending
                          ? null
                          : (_) => _send('set_color_temperature', {
                                'kelvin': _kelvin.roundToDouble(),
                                if (_hasBrightness)
                                  'brightness': _brightness.roundToDouble(),
                              }),
                    ),
                  ),
                  Text('${_kelvin.round()}K',
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ],
            if (_setZoneColor != null && _zoneColors.length > 1) ...[
              const SizedBox(height: 10),
              _zoneRow(scheme, text),
            ],
            if (_setColor != null || _setZoneColor != null) ...[
              const SizedBox(height: 10),
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
                        setState(() => _color = swatch);
                        _applyColor();
                      },
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  void _commitBrightness() {
    final dedicated = _setBrightness;
    if (dedicated != null) {
      _send('set_brightness', {'brightness': _brightness.roundToDouble()});
      return;
    }
    // Brightness rides on the colour command: re-send the current colour with
    // the new brightness. Scoped to the selected zone when one is chosen.
    _applyColor();
  }

  /// The per-zone selector: an "All" chip plus one tappable chip per zone,
  /// tinted by its live colour. Selecting a zone scopes the colour swatches to
  /// it; "All" writes the whole strip.
  Widget _zoneRow(ColorScheme scheme, TextTheme text) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Zones',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            ChoiceChip(
              label: const Text('All'),
              selected: _selectedZone == null,
              onSelected:
                  _sending ? null : (_) => setState(() => _selectedZone = null),
            ),
            for (var i = 0; i < _zoneColors.length; i++)
              InkWell(
                onTap:
                    _sending ? null : () => setState(() => _selectedZone = i),
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: _zoneColors[i],
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _selectedZone == i
                          ? scheme.primary
                          : scheme.outlineVariant,
                      width: _selectedZone == i ? 3 : 1,
                    ),
                  ),
                  child: _selectedZone == i
                      ? Icon(Icons.check,
                          size: 14,
                          color: _zoneColors[i].computeLuminance() > 0.5
                              ? Colors.black87
                              : Colors.white)
                      : null,
                ),
              ),
          ],
        ),
      ],
    );
  }

  Widget _statusLine(bool? shownOn, ColorScheme scheme, TextTheme text) {
    final style = text.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    if (_sending) return Text('Sending...', style: style);
    if (_errorText != null) {
      return Text(_errorText!,
          style: text.bodySmall?.copyWith(color: scheme.error));
    }
    return Text(
      switch (shownOn) {
        true => 'On',
        false => 'Off',
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
            ? Icon(Icons.check,
                size: 18,
                color: luminance > 0.5 ? Colors.black87 : Colors.white)
            : null,
      ),
    );
  }
}

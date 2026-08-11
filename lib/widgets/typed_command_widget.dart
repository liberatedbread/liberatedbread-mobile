// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/value_format.dart';
import '../providers/ble_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';
import '../core/error_text.dart';

/// Renders the commands of a spec-described writable characteristic as typed
/// controls: fixed commands as buttons, parameterized commands as labeled
/// sliders/switches with a Send button.
class TypedCommandWidget extends StatelessWidget {
  final String deviceId;
  final String serviceUuid;
  final String specYaml;
  final CharacteristicDto specChar;

  const TypedCommandWidget({
    super.key,
    required this.deviceId,
    required this.serviceUuid,
    required this.specYaml,
    required this.specChar,
  });

  @override
  Widget build(BuildContext context) {
    final encodable =
        specChar.commands.where((c) => c.isEncodable).toList(growable: false);
    // Advanced commands (a treadmill's calibration, a raised speed ceiling)
    // are a signpost, not a gate: they stay sendable, but out of the ordinary
    // flow — collected under a collapsed, warning-marked section instead of
    // sitting between the everyday commands, and each asks for confirmation
    // the first time it is sent (see _CommandControl).
    final ordinary = [
      for (final c in encodable)
        if (!c.advanced) c
    ];
    final advanced = [
      for (final c in encodable)
        if (c.advanced) c
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            humanizeName(specChar.name),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          for (final command in ordinary)
            _CommandControl(
              deviceId: deviceId,
              serviceUuid: serviceUuid,
              specYaml: specYaml,
              charUuid: specChar.uuid,
              command: command,
            ),
          if (advanced.isNotEmpty)
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              leading: Icon(
                Icons.warning_amber_rounded,
                color: Theme.of(context).colorScheme.error,
              ),
              title: const Text('Advanced commands'),
              subtitle: Text(
                '${advanced.length} command${advanced.length == 1 ? '' : 's'} '
                'that can change how the device behaves',
                style: const TextStyle(fontSize: 12),
              ),
              children: [
                for (final command in advanced)
                  _CommandControl(
                    deviceId: deviceId,
                    serviceUuid: serviceUuid,
                    specYaml: specYaml,
                    charUuid: specChar.uuid,
                    command: command,
                  ),
              ],
            ),
          ..._unsupportedNotice(context),
        ],
      ),
    );
  }

  /// Commands the spec documents but this build cannot send. Shown as a muted
  /// line rather than dropped silently, so a spec author can tell "not
  /// implemented" apart from "my YAML didn't load".
  List<Widget> _unsupportedNotice(BuildContext context) {
    final blocked =
        specChar.commands.where((c) => !c.isEncodable).toList(growable: false);
    if (blocked.isEmpty) return const [];
    final kinds = {
      for (final c in blocked)
        if (c.unsupportedEncoding != null) c.unsupportedEncoding!,
    };
    final detail = kinds.isEmpty ? '' : ' (${kinds.join(', ')})';
    return [
      Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Text(
          '${blocked.length} command${blocked.length == 1 ? '' : 's'} in this '
          'spec use an encoding this app cannot send yet$detail.',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ),
    ];
  }
}

/// One command — fixed (a single button) or parameterized (controls + Send).
class _CommandControl extends ConsumerStatefulWidget {
  final String deviceId;
  final String serviceUuid;
  final String specYaml;
  final String charUuid;
  final CommandDto command;

  const _CommandControl({
    required this.deviceId,
    required this.serviceUuid,
    required this.specYaml,
    required this.charUuid,
    required this.command,
  });

  @override
  ConsumerState<_CommandControl> createState() => _CommandControlState();
}

class _CommandControlState extends ConsumerState<_CommandControl> {
  final Map<String, double> _values = {};
  bool _sending = false;
  String? _status;
  bool _failed = false;

  /// Whether the user has confirmed this advanced command's warning. The flag
  /// lives in the control's state rather than anywhere longer-lived, so a
  /// remount asks again — re-asking is the safe direction for a command the
  /// spec flags as able to change how the hardware behaves.
  bool _advancedConfirmed = false;

  @override
  void initState() {
    super.initState();
    for (final p in widget.command.parameters) {
      // Parameters the encoder fills itself (checksum, sequence,
      // packet_length) get no control and no seed value: offering a
      // "checksum" slider lets the user write over a byte the protocol
      // computes, and seeding a value would send exactly that.
      if (p.auto != null) continue;
      final allowed = p.allowed;
      // Enumerated parameters default to the first allowed value (the specs
      // have no separate default concept); everything else starts at the
      // bottom of its range. The condition mirrors _buildParam: only numeric
      // non-bool parameters get the dropdown treatment.
      _values[p.name] = allowed != null &&
              allowed.isNotEmpty &&
              isNumericValueType(p.valueType)
          ? allowed.first.toDouble()
          : rangeFor(p.valueType, p.min, p.max).min;
    }
  }

  Future<void> _send() async {
    // Advanced commands ask once before their first send, showing the spec's
    // own reason — "calibration changes how command values map to belt speed"
    // says something a generic warning cannot. The command stays available
    // afterwards: the flag is a signpost, not a gate.
    if (widget.command.advanced && !_advancedConfirmed) {
      final confirmed = await _confirmAdvanced();
      if (!confirmed || !mounted) return;
      setState(() => _advancedConfirmed = true);
    }
    setState(() {
      _sending = true;
      _status = null;
      _failed = false;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final ble = ref.read(bleServiceProvider);
      final bytes = await codec.encodeCommand(
        specYaml: widget.specYaml,
        charUuid: widget.charUuid,
        commandName: widget.command.name,
        params: {
          for (final e in _values.entries) e.key: e.value.roundToDouble(),
        },
      );
      await ble.writeCharacteristic(
        widget.deviceId,
        widget.serviceUuid,
        widget.charUuid,
        bytes.toList(),
      );
      if (mounted) {
        setState(() {
          _sending = false;
          _status = 'Sent';
          _failed = false;
        });
        _showSnack('Sent ${humanizeName(widget.command.name)}');
      }
    } catch (e) {
      if (mounted) {
        final text = friendlyErrorText(
          e,
          context: 'send ${widget.command.name}',
          fallback: 'The device did not accept that command.',
        );
        setState(() {
          _sending = false;
          _status = text;
          _failed = true;
        });
        _showSnack(text);
      }
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  /// The first-send gate for an advanced command: the spec's `advancedReason`
  /// when it gave one, a generic warning otherwise. True means send.
  Future<bool> _confirmAdvanced() async {
    final command = widget.command;
    final reason = command.advancedReason;
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: Icon(
          Icons.warning_amber_rounded,
          color: Theme.of(context).colorScheme.error,
        ),
        title: Text(humanizeName(command.name)),
        content: Text(
          reason != null && reason.trim().isNotEmpty
              ? reason
              : 'This command can change how the device behaves in ways that '
                  'outlast this app. Send it only if you know what it does.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final command = widget.command;
    final label = humanizeName(command.name);
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontWeight: FontWeight.bold)),
            if (command.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(
                  command.description,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
            const SizedBox(height: 8),
            // Encoder-filled parameters (auto: checksum/sequence/…) are
            // excluded here exactly as in initState — no control, no value.
            for (final p in command.parameters)
              if (p.auto == null) _buildParam(p),
            Row(
              children: [
                Expanded(
                  child: _status == null
                      ? const SizedBox.shrink()
                      : Text(
                          _status!,
                          style: TextStyle(
                            fontSize: 12,
                            color: _failed ? Colors.red : Colors.green,
                          ),
                        ),
                ),
                command.isFixed
                    ? ElevatedButton(
                        onPressed: _sending ? null : _send,
                        child: Text(_sending ? 'Sending...' : label),
                      )
                    : ElevatedButton.icon(
                        onPressed: _sending ? null : _send,
                        icon: const Icon(Icons.send, size: 16),
                        label: Text(_sending ? 'Sending...' : 'Send'),
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildParam(ParameterDto p) {
    final range = rangeFor(p.valueType, p.min, p.max);
    final value = (_values[p.name] ?? range.min).clamp(range.min, range.max);
    if (p.valueType == 'bool') {
      // A bool's two states already enumerate its whole domain, so the switch
      // wins even if a spec (oddly) declares `allowed` on a bool parameter.
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(humanizeName(p.name)),
        value: value >= 0.5,
        onChanged: (on) => setState(() => _values[p.name] = on ? 1.0 : 0.0),
      );
    }
    if (!isNumericValueType(p.valueType)) {
      // A slider for a string/bytes parameter would send bytes the spec never
      // meant; say so instead of pretending 0..255 is valid input.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          '${humanizeName(p.name)}: unsupported parameter type '
          '(${p.valueType})',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      );
    }
    final allowed = p.allowed;
    if (allowed != null && allowed.isNotEmpty) {
      return _buildAllowedParam(p, allowed);
    }
    // Presentation transform. `min`/`max` (and `range`) are RAW — what the
    // encoder validates against — while scale/valueOffset/unit describe what
    // the number means: display = raw * scale + valueOffset. A parameter
    // declaring any of the three gets its slider in decoded units, so a
    // treadmill speed reads "3.0 km/h" while the value stored in _values (and
    // sent) stays the raw 30. A zero scale is a malformed spec — every raw
    // value would collapse to one display value — so it falls back to the raw
    // rendering below rather than dividing by it.
    if ((p.scale != null || p.valueOffset != null || p.unit != null) &&
        (p.scale ?? 1) != 0) {
      var displayMin = displayValueFor(range.min, p.scale, p.valueOffset);
      var displayMax = displayValueFor(range.max, p.scale, p.valueOffset);
      // A negative scale flips the range; the slider needs it well-ordered.
      if (displayMin > displayMax) {
        (displayMin, displayMax) = (displayMax, displayMin);
      }
      // The encoder holds integers, so one raw step is |scale| in display
      // space — that is the finest stop the control can honestly offer.
      final step = (p.scale ?? 1).abs();
      final decimals = decimalsForStep(step);
      final unitSuffix = p.unit == null ? '' : ' ${p.unit}';
      final displayValue = displayValueFor(value, p.scale, p.valueOffset)
          .clamp(displayMin, displayMax)
          .toDouble();
      String fmt(double d) => d.toStringAsFixed(decimals);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${humanizeName(p.name)}: ${fmt(displayValue)}$unitSuffix',
            style: const TextStyle(fontSize: 13),
          ),
          Slider(
            min: displayMin,
            max: displayMax,
            // Null past the division cap (a uint16 speed in 0.01 km/h counts
            // asks for thousands of stops); the drag still snaps through
            // snapToStep, so a continuous slider stays honest.
            divisions: divisionsForStep(displayMin, displayMax, step),
            value: displayValue,
            label: '${fmt(displayValue)}$unitSuffix',
            onChanged: (v) => setState(() {
              final snapped = snapToStep(v, displayMin, displayMax, step);
              _values[p.name] =
                  rawValueFor(snapped, p.scale, p.valueOffset).roundToDouble();
            }),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${humanizeName(p.name)}: ${value.round()}',
          style: const TextStyle(fontSize: 13),
        ),
        Slider(
          min: range.min,
          max: range.max,
          divisions: divisionsFor(range.min, range.max),
          value: value.toDouble(),
          label: '${value.round()}',
          onChanged: (v) => setState(() => _values[p.name] = v.roundToDouble()),
        ),
      ],
    );
  }

  /// Enumerated parameter: the spec says the device accepts only these
  /// values, so offer exactly those in a dropdown instead of a free slider.
  /// Entries read "Label (value)" when the spec pairs labels with the values
  /// and just the raw value otherwise; either way the chosen *allowed value*
  /// (never a label or an index) is what gets encoded and sent.
  ///
  /// The Rust DTO boundary already drops labels whose length doesn't match
  /// `allowed`, but a hand-built DTO (fakes, remote packs gone weird) could
  /// still mispair them — so the pairing is re-checked here and unusable
  /// labels are ignored in favor of raw values.
  Widget _buildAllowedParam(ParameterDto p, List<BigInt> allowed) {
    final labels = p.labels;
    final paired = labels != null && labels.length == allowed.length;
    // The dropdown is keyed by index rather than value: indexes are plain
    // ints (allowed values are BigInt) and stay unique even if a malformed
    // spec repeats a value.
    final current = _values[p.name];
    var selected = allowed.indexWhere((v) => v.toDouble() == current);
    if (selected < 0) selected = 0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: DropdownButtonFormField<int>(
        initialValue: selected,
        isExpanded: true,
        decoration: InputDecoration(
          labelText: humanizeName(p.name),
          border: const OutlineInputBorder(),
        ),
        items: [
          for (var i = 0; i < allowed.length; i++)
            DropdownMenuItem(
              value: i,
              child: Text(
                allowedEntryLabel(paired ? labels[i] : null, allowed[i]),
              ),
            ),
        ],
        onChanged: (i) {
          if (i == null) return;
          setState(() => _values[p.name] = allowed[i].toDouble());
        },
      ),
    );
  }
}

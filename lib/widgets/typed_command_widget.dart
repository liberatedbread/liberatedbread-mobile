// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import '../core/unit_display.dart';
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
    final encodable = specChar.commands
        .where((c) => c.isEncodable)
        .toList(growable: false);
    // Advanced commands (a treadmill's calibration, a raised speed ceiling)
    // are a signpost, not a gate: they stay sendable, but out of the ordinary
    // flow — collected under a collapsed, warning-marked section instead of
    // sitting between the everyday commands, and each asks for confirmation
    // the first time it is sent (see _CommandControl).
    final ordinary = [
      for (final c in encodable)
        if (!c.advanced) c,
    ];
    final advanced = [
      for (final c in encodable)
        if (c.advanced) c,
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
    final blocked = specChar.commands
        .where((c) => !c.isEncodable)
        .toList(growable: false);
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
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
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

  /// Whether the defaulted parameters are on screen. See [_defaulted].
  bool _showDefaulted = false;

  @override
  void initState() {
    super.initState();
    for (final p in widget.command.parameters) {
      // A parameter the SPEC fills gets no control and no seed value. Which
      // ones those are is the spec's answer, not this widget's: `userSettable`
      // is the schema's own rule ("none of auto, default, source") applied in
      // Rust, where the entity resolver reads the same predicate. This loop
      // used to test `auto` alone, so 150 defaulted parameters across eight
      // specs drew knobs the user could write over — SmartDawn's `power_on`,
      // which is a fixed "turn on", offered four sliders for DDP filler, one
      // of them a 0..4294967295 range over a connection id.
      //
      // Omitting the value is safe on the wire: the encoder resolves supplied
      // value, then the spec's `default`, then a visible failure, so a
      // defaulted parameter still encodes to its default. A `source` one has
      // no default and fails visibly, which is the contract.
      if (!p.userSettable) continue;
      _seed(p);
    }
  }

  /// The starting value for one parameter's control.
  void _seed(ParameterDto p) {
    {
      final allowed = choicesFor(p);
      final isDropdown =
          allowed != null &&
          allowed.isNotEmpty &&
          isNumericValueType(p.valueType);
      // Enumerated parameters start at the first allowed value and everything
      // else at the bottom of its range. The condition mirrors _buildParam:
      // only numeric non-bool parameters get the dropdown treatment.
      // A defaulted parameter starts where the spec put it, so revealing one
      // and sending without touching it puts the same bytes on the wire as
      // leaving it hidden. A user-owned one starts at the bottom of its range,
      // which is what it has always done.
      final declared = p.default_;
      if (declared != null &&
          (!isDropdown ||
              allowed.any((v) => v.toDouble() == declared.toDouble()))) {
        final range = rangeFor(p.valueType, p.min, p.max);
        _values[p.name] = isDropdown
            ? declared.toDouble()
            : declared.toDouble().clamp(range.min, range.max).toDouble();
        return;
      }
      _values[p.name] = isDropdown
          ? allowed.first.toDouble()
          : rangeFor(p.valueType, p.min, p.max).min;
    }
  }

  /// Whether [name]'s value crosses the FFI on a send.
  ///
  /// A user-owned parameter always does. A defaulted one does only while its
  /// section is open: the encoder resolves supplied value, then the spec's
  /// `default`, so omitting it puts exactly the bytes on the wire that the
  /// collapsed label promises.
  bool _isSendable(String name) {
    if (_showDefaulted) return true;
    return widget.command.parameters
        .where((p) => p.name == name)
        .every((p) => p.userSettable);
  }

  /// Parameters the spec DEFAULTS but does not compute — a value the device
  /// will accept from the caller, with an answer already supplied.
  ///
  /// These are the awkward middle of the schema's rule. Most are protocol
  /// filler that no user should be handed (SmartDawn's `power_on` defaults
  /// four DDP header fields), and drawing them was the bug. But some are real
  /// knobs whose command needs a value for a second axis the caller usually
  /// does not care about: the Urevo's `slope` beside its speed, the LIFX
  /// strip's `kelvin` beside its colour, the Govee thermometer's history
  /// window — and hiding those outright takes away the only place they can be
  /// set at all.
  ///
  /// Nothing in the spec distinguishes the two, and guessing from the shape of
  /// a range is the kind of inference this codebase does not do. So neither is
  /// on the default surface and both are one tap away, seeded at the value the
  /// spec chose.
  ///
  /// `auto` and `source` are NOT here: the encoder computes the first and the
  /// client fetches the second, so there is nothing for a user to set.
  List<ParameterDto> get _defaulted => [
    for (final p in widget.command.parameters)
      if (!p.userSettable && p.auto == null && p.source == null) p,
  ];

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
        // Only what is on screen. A defaulted parameter is sent when the
        // user has opened the section and can see it; collapsed, it goes back
        // to being the encoder's to fill — which is what the collapsed label
        // says it is. Without this, expanding SmartDawn's `power_on`, dragging
        // its DDP connection-id slider and collapsing again put the edited
        // filler on the wire under a label promising the spec filled it in,
        // with no control anywhere to see or undo it.
        params: {
          for (final e in _values.entries)
            if (_isSendable(e.key)) e.key: e.value.roundToDouble(),
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
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(msg)));
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
    // Theme roles, not Colors.* literals: grey and green fail contrast on the
    // light surface and none of them adapt to dark mode.
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
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
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: 8),
            // Spec-filled parameters are excluded here exactly as in
            // initState, and by the same one-word question, so the controls on
            // screen and the values in `_values` cannot disagree.
            for (final p in command.parameters)
              if (p.userSettable) _buildParam(p),
            if (_defaulted.isNotEmpty) ...[
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(0, 40)),
                  onPressed: () => setState(() {
                    _showDefaulted = !_showDefaulted;
                    if (_showDefaulted) {
                      // Seeded on reveal rather than at mount, so a command
                      // nobody expands sends exactly what it sent before: the
                      // encoder fills each default itself.
                      for (final p in _defaulted) {
                        if (!_values.containsKey(p.name)) _seed(p);
                      }
                    }
                  }),
                  child: Text(
                    _showDefaulted
                        ? 'Hide the spec\'s defaults'
                        : '${_defaulted.length} value${_defaulted.length == 1 ? '' : 's'} the spec fills in',
                  ),
                ),
              ),
              if (_showDefaulted)
                for (final p in _defaulted) _buildParam(p),
            ],
            Row(
              children: [
                Expanded(
                  child: _status == null
                      ? const SizedBox.shrink()
                      : Text(
                          _status!,
                          style: text.bodySmall?.copyWith(
                            color: _failed ? scheme.error : scheme.tertiary,
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
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final allowed = choicesFor(p);
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
      final unit = displayUnit(p.unit);
      final unitSuffix = unit == null ? '' : ' $unit';
      final displayValue = displayValueFor(
        value,
        p.scale,
        p.valueOffset,
      ).clamp(displayMin, displayMax).toDouble();
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
              _values[p.name] = rawValueFor(
                snapped,
                p.scale,
                p.valueOffset,
              ).roundToDouble();
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

/// The values to offer [p] as a choice rather than a slider, or null.
///
/// `allowed` when the spec lists its values (a set with gaps, or a labelled
/// range the Rust layer expanded), and otherwise a small integer range: the
/// catalogue writes a contiguous set as `min`/`max` rather than a list that
/// restates it, and a 0..3 orientation or a 0..1 flag is four or two things
/// to pick, not a slider to aim along. Ranges with a unit or a scale are
/// quantities, not options, and stay sliders whatever their size.
@visibleForTesting
List<BigInt>? choicesFor(ParameterDto p) {
  final allowed = p.allowed;
  if (allowed != null && allowed.isNotEmpty) return allowed;
  final min = p.min;
  final max = p.max;
  if (min == null || max == null) return null;
  if (p.scale != null || p.valueOffset != null || p.unit != null) return null;
  if (min != min.roundToDouble() || max != max.roundToDouble()) return null;
  final count = max - min + 1;
  if (count < 2 || count > maxRangeChoices) return null;
  return [for (var v = min.toInt(); v <= max.toInt(); v++) BigInt.from(v)];
}

/// The widest unlabelled range [choicesFor] offers as a picker. Eight covers
/// every small mode/direction table in the catalogue; a wider range reads
/// better as a slider.
const int maxRangeChoices = 8;

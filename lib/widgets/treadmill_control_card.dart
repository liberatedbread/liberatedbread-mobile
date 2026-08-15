// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/value_format.dart';
import '../models/ble_discovered_service.dart';
import '../providers/ble_provider.dart';
import '../providers/device_spec_match_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';

/// Step of the speed steppers and slider, in DISPLAY units (km/h where the
/// spec declares one). Walking pads move in half-km/h clicks in their stock
/// apps even where the wire protocol resolves finer (KingSmith's WiLink takes
/// arbitrary 0.1 km/h), so the control commits the coarser, familiar step.
const double _speedStep = 0.5;

/// A resolved treadmill verb: where to write, which command to encode, and
/// the parameters to send. [params] carries fixed arguments discovered at
/// resolution time — KingSmith's FTMS `stop_or_pause` splits into Stop and
/// Pause only through its `action` byte (1 = stop, 2 = pause).
class _ResolvedVerb {
  final String serviceUuid;
  final String charUuid;
  final CommandDto command;
  final Map<String, double> params;

  const _ResolvedVerb(
    this.serviceUuid,
    this.charUuid,
    this.command,
    this.params,
  );
}

/// A resolved speed command with the parameter that carries the speed and
/// its range mapped to display units (km/h). `min`/`max` on the DTO are RAW;
/// the card lives on the decoded side of the transform because that is what
/// the user dials in, and converts back when sending.
class _ResolvedSpeed {
  final String serviceUuid;
  final String charUuid;
  final CommandDto command;
  final ParameterDto parameter;
  final double minDisplay;
  final double maxDisplay;

  const _ResolvedSpeed(
    this.serviceUuid,
    this.charUuid,
    this.command,
    this.parameter,
    this.minDisplay,
    this.maxDisplay,
  );
}

/// Every encodable command of the matched spec, but only on characteristics
/// the connected device actually carries — the same ground-truth check the
/// panel applies to entity actions, because the spec may describe a variant
/// with more hardware (or a second protocol generation, as KingSmith's
/// WiLink-plus-FTMS spec does) than the unit in front of us.
List<({String serviceUuid, String charUuid, CommandDto command})>
    _encodableCommands(
        DeviceSpecDto spec, List<BleDiscoveredService> services) {
  final found = <({String serviceUuid, String charUuid, CommandDto command})>[];
  for (final service in services) {
    final specService = findServiceForUuid(spec, service.uuid);
    if (specService == null) continue;
    for (final char in service.characteristics) {
      final specChar = findCharForUuid(specService, char.uuid);
      if (specChar == null) continue;
      for (final command in specChar.commands) {
        if (!command.isEncodable) continue;
        found.add((
          serviceUuid: service.uuid,
          charUuid: specChar.uuid,
          command: command,
        ));
      }
    }
  }
  return found;
}

/// The verbs and speed command this spec/device pair offers, or null when
/// none of them resolve — the card renders nothing then and the generic
/// per-characteristic command widgets remain the control surface.
({
  _ResolvedVerb? start,
  _ResolvedVerb? pause,
  _ResolvedVerb? stop,
  _ResolvedSpeed? speed,
})? _resolve(DeviceSpecDto spec, List<BleDiscoveredService> services) {
  final commands = _encodableCommands(spec, services);

  // Command names are a convention, not a schema field: the walking-pad specs
  // that exist today (and the FTMS standard they borrow) use these spellings,
  // so the card resolves by name, most specific first.
  _ResolvedVerb? byName(List<String> names,
      [Map<String, double> params = const {}]) {
    for (final name in names) {
      for (final c in commands) {
        if (c.command.name == name) {
          return _ResolvedVerb(c.serviceUuid, c.charUuid, c.command, params);
        }
      }
    }
    return null;
  }

  final start = byName(const [
    'start_belt',
    'start_or_resume',
    'start_prepared',
    'start',
    // UREVO's proprietary FT/UR classes: prepare/ready is the belt's start,
    // and continue resumes from a pause the same button would.
    'ur_training_prepared',
    'ur_training_continue',
    'ft_prepared',
  ]);
  var pause = byName(const ['pause', 'training_pause', 'ur_training_pause']);
  var stop = byName(const [
    'stop',
    'training_stop',
    // KingSmith's WiLink belt has no stop opcode of its own; stop_belt is the
    // speed-0 frame the spec names for exactly this button. UREVO's classes
    // each carry their own stop.
    'stop_belt',
    'ur_training_stop',
    'ft_stop',
  ]);
  // FTMS's Treadmill Control Point has one Stop-or-Pause opcode whose action
  // byte picks the verb; it stands in for whichever dedicated verb the spec
  // does not name.
  if (pause == null || stop == null) {
    final shared = byName(const ['stop_or_pause']);
    if (shared != null) {
      pause ??= _ResolvedVerb(shared.serviceUuid, shared.charUuid,
          shared.command, const {'action': 2});
      stop ??= _ResolvedVerb(shared.serviceUuid, shared.charUuid,
          shared.command, const {'action': 1});
    }
  }

  _ResolvedSpeed? speed;
  final speedEntry = byName(const [
    'set_speed',
    'set_target_speed',
    'set_speed_and_slope',
    // UREVO's combined speed+slope write; its slope param defaults to 0 in the
    // spec, so the card can drive speed alone without owning an incline.
    'ur_set_speed_and_slope',
  ]);
  if (speedEntry != null) {
    // The speed parameter is the caller-owned one that reads as a speed —
    // unit km/h when the spec says so, else the first caller-owned numeric
    // parameter. Encoder-filled parameters (auto: checksum, ...) are never
    // candidates: they carry no user intent.
    final candidates = speedEntry.command.parameters.where(
      (p) => p.auto == null && isNumericValueType(p.valueType),
    );
    final parameter = candidates.where((p) => p.unit == 'km/h').firstOrNull ??
        candidates.firstOrNull;
    if (parameter != null) {
      // A zero scale is a malformed spec (every raw value collapses to one
      // display value); treat it as the identity rather than dividing by it.
      final scale = parameter.scale == null || parameter.scale == 0
          ? 1.0
          : parameter.scale!;
      final offset = parameter.valueOffset ?? 0.0;
      final rawRange =
          rangeFor(parameter.valueType, parameter.min, parameter.max);
      var minDisplay = rawRange.min * scale + offset;
      var maxDisplay = rawRange.max * scale + offset;
      // A negative scale flips the range; the slider needs it well-ordered.
      if (minDisplay > maxDisplay) {
        (minDisplay, maxDisplay) = (maxDisplay, minDisplay);
      }
      speed = _ResolvedSpeed(
        speedEntry.serviceUuid,
        speedEntry.charUuid,
        speedEntry.command,
        parameter,
        minDisplay,
        maxDisplay,
      );
    }
  }

  if (start == null && pause == null && stop == null && speed == null) {
    return null;
  }
  return (start: start, pause: pause, stop: stop, speed: speed);
}

/// The prominent control surface for a treadmill: target speed with steppers
/// and a slider on top, and the transport verbs (Start / Pause / Stop) as
/// large buttons below.
///
/// This is a convenience layer over the spec's ordinary commands, resolved by
/// name (see [_resolve]) — the per-characteristic command widgets below it
/// stay in place and remain the fallback for everything the card does not
/// cover. When none of the verbs resolve for the matched spec, the card
/// renders nothing at all.
///
/// A treadmill is motorised equipment under a person, so the card sends
/// deliberately: steppers and verb buttons send on tap, the slider only on
/// release — a dragged slider would otherwise flood the belt with a write per
/// pixel.
class TreadmillControlCard extends ConsumerStatefulWidget {
  final String deviceId;
  final String specYaml;
  final DeviceSpecDto spec;
  final List<BleDiscoveredService> services;

  const TreadmillControlCard({
    super.key,
    required this.deviceId,
    required this.specYaml,
    required this.spec,
    required this.services,
  });

  @override
  ConsumerState<TreadmillControlCard> createState() =>
      _TreadmillControlCardState();
}

class _TreadmillControlCardState extends ConsumerState<TreadmillControlCard> {
  /// The target speed being dialled in, in display units. Null until the
  /// first build seeds it from the resolved range — the card has no live
  /// speed reading to open from, so it opens at the bottom of the range.
  double? _speedDisplay;

  /// Label of the send currently in flight; the speed and Start/Pause
  /// controls disable while one is, so a double-tap cannot interleave two
  /// writes to a moving belt. Stop is deliberately NOT gated on this — see
  /// [_stopInFlight].
  String? _sending;

  /// Monotonic id of the newest send; see the ticket check in [_send].
  int _sendTicket = 0;
  String? _status;
  bool _failed = false;

  /// Stop must never wait behind another write: a speed write can stall for
  /// many seconds behind the BLE stack's mutex, and that is exactly the
  /// moment the belt is moving under someone. Stop therefore overlaps any
  /// in-flight send; only a second Stop is held back. (The find screen makes
  /// the same call for its ring-stop button, for the same reason.)
  bool _stopInFlight = false;

  /// Commands whose advanced-command warning has been acknowledged this
  /// session. Mirrors TypedCommandWidget: the flag is a signpost, not a
  /// gate, so each command asks once.
  final Set<String> _advancedAcked = {};

  Future<void> _send({
    required String serviceUuid,
    required String charUuid,
    required String commandName,
    required Map<String, double> params,
    required String label,
  }) async {
    // A Stop overlapping a stalled ordinary write makes two sends share
    // [_sending]; only the newest owns it. Without the ticket, the stalled
    // write's completion cleared the flag while Stop was still queued
    // behind it — unlocking Start exactly when a confirmed Start would
    // queue AFTER the emergency stop and restart the belt.
    final ticket = ++_sendTicket;
    setState(() {
      _sending = label;
      _status = null;
      _failed = false;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final ble = ref.read(bleServiceProvider);
      final bytes = await codec.encodeCommand(
        specYaml: widget.specYaml,
        serviceUuid: serviceUuid,
        charUuid: charUuid,
        commandName: commandName,
        params: params,
      );
      await ble.writeCharacteristic(
        widget.deviceId,
        serviceUuid,
        charUuid,
        bytes.toList(),
      );
      if (mounted) {
        setState(() {
          if (_sendTicket == ticket) _sending = null;
          _status = 'Sent $label';
          _failed = false;
        });
        _showSnack('Sent $label');
      }
    } catch (e) {
      // Encoding failures land here too — e.g. a speed command with a second
      // caller-owned parameter this card cannot know (a slope byte) fails with
      // ParameterMissing rather than a fabricated value. The status line says
      // so; the raw command widgets below remain the way to send it.
      if (mounted) {
        final text = friendlyErrorText(
          e,
          context: 'send $commandName',
          fallback: 'The treadmill did not accept that command.',
        );
        setState(() {
          if (_sendTicket == ticket) _sending = null;
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

  Future<void> _sendVerb(_ResolvedVerb verb) => _send(
        serviceUuid: verb.serviceUuid,
        charUuid: verb.charUuid,
        commandName: verb.command.name,
        params: verb.params,
        label: humanizeName(
            verb.params.isEmpty ? verb.command.name : _verbLabel(verb)),
      );

  /// Show the spec's advanced-command warning once per command, mirroring
  /// TypedCommandWidget. Returns whether to proceed. Stop never routes
  /// through here: an emergency halt must not wait on a dialog.
  Future<bool> _ackAdvanced(CommandDto command) async {
    if (!command.advanced || _advancedAcked.contains(command.name)) {
      return true;
    }
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
              : 'The spec marks this as an advanced command.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    if (result == true) _advancedAcked.add(command.name);
    return result ?? false;
  }

  /// Start asks every time, not once: it sets motorised equipment moving
  /// under a person, and FTMS start_or_resume on some pads resumes at the
  /// previous speed rather than the minimum.
  Future<void> _startBelt(_ResolvedVerb verb) async {
    if (!await _ackAdvanced(verb.command) || !mounted) return;
    final resumes = verb.command.name == 'start_or_resume';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Start the belt?'),
        content: Text(
          resumes
              ? 'The belt will start moving, possibly at its previous '
                  'speed rather than the minimum.'
              : 'The belt will start moving.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton.icon(
            onPressed: () => Navigator.of(context).pop(true),
            icon: const Icon(Icons.play_arrow),
            label: const Text('Start'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _sendVerb(verb);
  }

  Future<void> _pauseBelt(_ResolvedVerb verb) async {
    if (!await _ackAdvanced(verb.command) || !mounted) return;
    await _sendVerb(verb);
  }

  /// See [_stopInFlight] for why this ignores [_sending].
  Future<void> _stopBelt(_ResolvedVerb verb) async {
    setState(() => _stopInFlight = true);
    try {
      await _sendVerb(verb);
    } finally {
      if (mounted) setState(() => _stopInFlight = false);
    }
  }

  /// What to call a verb that shares its command with another (stop_or_pause
  /// sends Stop and Pause through one opcode): the button's word, not the
  /// command's name, so the status line says what the user tapped.
  String _verbLabel(_ResolvedVerb verb) => switch (verb.params['action']) {
        1 => 'stop',
        2 => 'pause',
        _ => verb.command.name,
      };

  Future<void> _sendSpeed(_ResolvedSpeed speed, double display) async {
    if (!await _ackAdvanced(speed.command) || !mounted) return;
    // Back across the presentation transform: the card displays km/h, the
    // encoder validates and coerces the RAW value (raw min/max, integer
    // counts). Only the speed parameter is supplied; encoder-filled (auto)
    // parameters need nothing, and a spec whose speed command carries further
    // caller-owned parameters without defaults fails honestly in _send.
    final parameter = speed.parameter;
    final scale = parameter.scale == null || parameter.scale == 0
        ? 1.0
        : parameter.scale!;
    final raw =
        ((display - (parameter.valueOffset ?? 0.0)) / scale).roundToDouble();
    return _send(
      serviceUuid: speed.serviceUuid,
      charUuid: speed.charUuid,
      commandName: speed.command.name,
      params: {parameter.name: raw},
      label: 'Speed ${_fmtSpeed(speed, display)}',
    );
  }

  void _nudgeSpeed(_ResolvedSpeed speed, double delta) {
    final current = _speedDisplay ?? speed.minDisplay;
    final next =
        (current + delta).clamp(speed.minDisplay, speed.maxDisplay).toDouble();
    setState(() => _speedDisplay = next);
    // A stepper tap is a deliberate choice, not a drag tick: it commits.
    unawaited(_sendSpeed(speed, next));
  }

  int _speedDecimals(_ResolvedSpeed speed) {
    final parameter = speed.parameter;
    final scale = parameter.scale == null || parameter.scale == 0
        ? 1.0
        : parameter.scale!;
    final scaleDecimals = decimalsForStep(scale.abs());
    final stepDecimals = decimalsForStep(_speedStep);
    return scaleDecimals > stepDecimals ? scaleDecimals : stepDecimals;
  }

  String _fmtSpeed(_ResolvedSpeed speed, double value) {
    final unit = speed.parameter.unit;
    final suffix = unit == null ? '' : ' $unit';
    return '${value.toStringAsFixed(_speedDecimals(speed))}$suffix';
  }

  @override
  Widget build(BuildContext context) {
    final resolved = _resolve(widget.spec, widget.services);
    if (resolved == null) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final speed = resolved.speed;
    if (speed != null) _speedDisplay ??= speed.minDisplay;

    return Card(
      margin: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (speed != null) ...[
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          humanizeName(speed.parameter.name),
                          style: text.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        Text(
                          _fmtSpeed(speed, _speedDisplay!),
                          style: text.headlineSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton.outlined(
                    onPressed: _sending == null
                        ? () => _nudgeSpeed(speed, -_speedStep)
                        : null,
                    icon: const Icon(Icons.remove),
                    constraints:
                        const BoxConstraints(minWidth: 48, minHeight: 48),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    onPressed: _sending == null
                        ? () => _nudgeSpeed(speed, _speedStep)
                        : null,
                    icon: const Icon(Icons.add),
                    constraints:
                        const BoxConstraints(minWidth: 48, minHeight: 48),
                  ),
                ],
              ),
              Slider(
                min: speed.minDisplay,
                max: speed.maxDisplay,
                // Discrete half-km/h stops where the range allows; null past
                // the division cap, with snapToStep keeping a continuous drag
                // on the same stops.
                divisions: divisionsForStep(
                    speed.minDisplay, speed.maxDisplay, _speedStep),
                value: _speedDisplay!
                    .clamp(speed.minDisplay, speed.maxDisplay)
                    .toDouble(),
                label: _fmtSpeed(speed, _speedDisplay!),
                onChanged: _sending != null
                    ? null
                    : (v) => setState(() => _speedDisplay = snapToStep(
                        v, speed.minDisplay, speed.maxDisplay, _speedStep)),
                // Commit on release, not per drag tick: each commit is a BLE
                // write to a moving belt.
                onChangeEnd: _sending != null
                    ? null
                    : (v) => unawaited(_sendSpeed(
                        speed,
                        snapToStep(v, speed.minDisplay, speed.maxDisplay,
                            _speedStep))),
              ),
              const SizedBox(height: 8),
            ],
            Row(
              children: [
                if (resolved.start != null) ...[
                  Expanded(
                    child: FilledButton.icon(
                      onPressed: _sending == null
                          ? () => unawaited(_startBelt(resolved.start!))
                          : null,
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 52)),
                      icon: const Icon(Icons.play_arrow),
                      label: const Text('Start'),
                    ),
                  ),
                ],
                if (resolved.pause != null) ...[
                  if (resolved.start != null) const SizedBox(width: 8),
                  Expanded(
                    child: FilledButton.tonalIcon(
                      onPressed: _sending == null
                          ? () => unawaited(_pauseBelt(resolved.pause!))
                          : null,
                      style: FilledButton.styleFrom(
                          minimumSize: const Size(0, 52)),
                      icon: const Icon(Icons.pause),
                      label: const Text('Pause'),
                    ),
                  ),
                ],
                if (resolved.stop != null) ...[
                  if (resolved.start != null || resolved.pause != null)
                    const SizedBox(width: 8),
                  Expanded(
                    // Stop is the verb that must read as urgent at a glance,
                    // on equipment that can throw a walker off balance. It
                    // stays live while other writes are in flight — a
                    // stalled speed write must not grey out the one control
                    // that halts the belt.
                    child: FilledButton.icon(
                      onPressed: _stopInFlight
                          ? null
                          : () => unawaited(_stopBelt(resolved.stop!)),
                      style: FilledButton.styleFrom(
                        minimumSize: const Size(0, 52),
                        backgroundColor: scheme.error,
                        foregroundColor: scheme.onError,
                      ),
                      icon: const Icon(Icons.stop),
                      label: const Text('Stop'),
                    ),
                  ),
                ],
              ],
            ),
            if (_sending != null || _status != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  _sending != null ? 'Sending ${_sending!}...' : _status!,
                  style: TextStyle(
                    fontSize: 12,
                    color: _sending != null
                        ? scheme.onSurfaceVariant
                        : _failed
                            ? scheme.error
                            : Colors.green,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

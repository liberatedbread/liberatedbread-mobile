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
          for (final command in specChar.commands)
            if (command.isEncodable)
              _CommandControl(
                deviceId: deviceId,
                serviceUuid: serviceUuid,
                specYaml: specYaml,
                charUuid: specChar.uuid,
                command: command,
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

  @override
  void initState() {
    super.initState();
    for (final p in widget.command.parameters) {
      _values[p.name] = rangeFor(p.valueType, p.min, p.max).min;
    }
  }

  Future<void> _send() async {
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
            for (final p in command.parameters) _buildParam(p),
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
      return SwitchListTile(
        contentPadding: EdgeInsets.zero,
        title: Text(humanizeName(p.name)),
        value: value >= 0.5,
        onChanged: (on) => setState(() => _values[p.name] = on ? 1.0 : 0.0),
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
}

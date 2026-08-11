// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/soap_control_service.dart';
import '../services/spec_codec.dart';

/// Controls for a network device whose matched spec declares entities — the
/// Wi-Fi counterpart of the BLE device screen's typed control panel.
///
/// The flow on every load and after every write is the same three steps, and
/// each is owned by the layer that knows it:
/// 1. fetch the device's own `setup.xml` and resolve control URLs from its
///    service list (transport — [SoapControlClient]);
/// 2. render and send one state request per distinct `state_command`
///    (what to send comes from the spec, via the codec);
/// 3. hand the returned values back to the codec per entity for decoding.
///
/// Writes carrying `read_back` parameters re-read the state they depend on
/// immediately before sending: the Crock-Pot's set-mode action carries the
/// cook time with it, and sending a stale one silently rewinds the timer.
class NetworkDeviceScreen extends ConsumerStatefulWidget {
  final NetworkDevice device;
  final NetworkControls controls;

  const NetworkDeviceScreen({
    super.key,
    required this.device,
    required this.controls,
  });

  @override
  ConsumerState<NetworkDeviceScreen> createState() =>
      _NetworkDeviceScreenState();
}

class _NetworkDeviceScreenState extends ConsumerState<NetworkDeviceScreen> {
  SoapDeviceDescription? _description;
  final Map<String, Map<String, String>> _stateByCommand = {};
  final Map<String, NetworkReadingDto?> _readings = {};

  /// Name of the entity a send is in flight for, disabling its control.
  String? _sending;
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  List<NetworkEntityDto> get _entities => widget.controls.entities;

  /// Every distinct state call the declared entities need — usually one.
  Set<String> get _stateCommands =>
      _entities.map((e) => e.stateCommand).toSet();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final port = widget.device.port;
      if (port == null) {
        // Discovery hands us the SSDP LOCATION port for every UPnP device, so
        // this is a mDNS-only sighting — not a device this screen can drive.
        throw const SoapTransportException(
            'the device did not advertise a control port');
      }
      final client = ref.read(soapControlClientProvider);
      _description ??= await client.fetchDescription(widget.device.host, port);
      await _refreshState();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyErrorText(
          e,
          context: 'device control',
          fallback: 'Could not reach the device. It may have moved ports — '
              'try scanning again.',
        );
      });
    }
  }

  /// Send every state request and re-decode every entity from the replies.
  Future<void> _refreshState() async {
    final codec = ref.read(specCodecProvider);
    final client = ref.read(soapControlClientProvider);
    final description = _description!;

    for (final command in _stateCommands) {
      final request = await codec.renderNetworkStateRequest(
        specYaml: widget.controls.specYaml,
        stateCommand: command,
      );
      final path = description.controlPathFor(request);
      if (path == null) continue;
      _stateByCommand[command] =
          await client.send(description.host, description.port, path, request);
    }
    for (final entity in _entities) {
      final returned = _stateByCommand[entity.stateCommand];
      _readings[entity.name] = returned == null
          ? null
          : await codec.readNetworkEntity(
              specYaml: widget.controls.specYaml,
              entityName: entity.name,
              returned: returned,
            );
    }
    if (mounted) setState(() {});
  }

  /// Send one action, with its read-back values fetched fresh first.
  Future<void> _send(
    NetworkEntityDto entity,
    NetworkActionDto action, {
    String? value,
  }) async {
    setState(() {
      _sending = entity.name;
      _error = null;
    });
    try {
      final codec = ref.read(specCodecProvider);
      final client = ref.read(soapControlClientProvider);
      final description = _description!;

      final values = <String, String>{};
      if (value != null && action.userParams.isNotEmpty) {
        values[action.userParams.first] = value;
      }
      // The spec says which settings this action carries that the user is NOT
      // changing, and where to read them. Fetched fresh, not from the last
      // refresh: the device's own countdown moves between refreshes, and
      // sending a stale cook time rewinds it.
      for (final readBack in action.readBack) {
        final request = await codec.renderNetworkStateRequest(
          specYaml: widget.controls.specYaml,
          stateCommand: readBack.command,
        );
        final path = description.controlPathFor(request);
        if (path == null) continue;
        final returned = await client.send(
            description.host, description.port, path, request);
        final current = returned[readBack.field];
        if (current != null) values.putIfAbsent(readBack.param, () => current);
      }

      final request = await codec.renderNetworkCommand(
        specYaml: widget.controls.specYaml,
        commandName: action.commandName,
        values: values,
      );
      final path = description.controlPathFor(request);
      if (path == null) {
        throw SoapTransportException(
            'the device does not list ${request.service}');
      }
      await client.send(description.host, description.port, path, request);
      // The reply acknowledges the request, it does not report the resulting
      // state — the Crock-Pot doesn't always take a setting. Read back.
      await _refreshState();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyErrorText(
          e,
          context: 'device control',
          fallback: 'The device did not accept that. Try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _sending = null);
    }
  }

  NetworkActionDto? _actionFor(NetworkEntityDto entity, String role) {
    for (final action in entity.actions) {
      if (action.role == role) return action;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final description = _description;

    return Scaffold(
      backgroundColor: scheme.surface,
      appBar: AppBar(
        title: Text(description?.friendlyName ?? widget.device.displayName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : () => unawaited(_load()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _error!,
                  style: text.bodyMedium?.copyWith(color: scheme.error),
                ),
              ),
            if (_loading) ...[
              const SizedBox(height: 48),
              const Center(child: CircularProgressIndicator()),
              const SizedBox(height: 16),
              Center(
                child: Text('Asking the device...',
                    style: text.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant)),
              ),
            ] else if (description == null) ...[
              // Never reached the device: no cards. A toggle for a device
              // whose description was never fetched has nowhere to send.
              Center(
                child: Padding(
                  padding: const EdgeInsets.only(top: 32),
                  child: FilledButton.icon(
                    onPressed: () => unawaited(_load()),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Try again'),
                  ),
                ),
              ),
            ] else ...[
              for (final entity in _entities) ...[
                _entityCard(entity),
                const SizedBox(height: 12),
              ],
              const SizedBox(height: 16),
              _deviceInfo(description),
            ],
          ],
        ),
      ),
    );
  }

  Widget _entityCard(NetworkEntityDto entity) {
    switch (entity.platform) {
      case 'switch':
        return _switchCard(entity);
      case 'select':
        return _selectCard(entity);
      case 'number':
        return _numberCard(entity);
      default:
        return _sensorCard(entity);
    }
  }

  Widget _card({required Widget child}) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
          child: child,
        ),
      );

  Widget _switchCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final isOn = reading?.isOn;
    final turnOn = _actionFor(entity, 'turn_on');
    final turnOff = _actionFor(entity, 'turn_off');
    final busy = _sending == entity.name;

    return _card(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entity.name,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                if (isOn == null)
                  Text('State unknown',
                      style: Theme.of(context).textTheme.bodySmall),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
          else
            Switch(
              value: isOn ?? false,
              onChanged: (turnOn == null || turnOff == null)
                  ? null
                  : (wantOn) =>
                      unawaited(_send(entity, wantOn ? turnOn : turnOff)),
            ),
        ],
      ),
    );
  }

  Widget _selectCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final action = _actionFor(entity, 'select_option');
    final busy = _sending == entity.name;
    final currentRaw =
        reading?.kind == NetworkReadingKind.option ? reading?.raw : null;

    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(entity.name,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
              ),
              if (busy)
                const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
            ],
          ),
          if (reading?.kind == NetworkReadingKind.unknownOption)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                // Never renamed to a known option: an unrecognised Crock-Pot
                // mode shown as "off" tells a user their cooker is off while
                // it is heating.
                'Unrecognized state (${reading!.raw})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: [
              for (final option in entity.options)
                ChoiceChip(
                  label: Text(option.label),
                  selected: option.raw == currentRaw,
                  onSelected: (busy || action == null)
                      ? null
                      : (_) =>
                          unawaited(_send(entity, action, value: option.raw)),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _numberCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final action = _actionFor(entity, 'set_value');
    final busy = _sending == entity.name;
    final unit = entity.unit;

    return _card(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(entity.name,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600)),
                Text(
                  reading == null
                      ? 'Unknown'
                      : '${reading.raw}${unit == null ? '' : ' $unit'}',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
          if (busy)
            const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2))
          else if (action != null)
            IconButton(
              tooltip: 'Set ${entity.name}',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => unawaited(_editNumber(entity, action)),
            ),
        ],
      ),
    );
  }

  Future<void> _editNumber(
      NetworkEntityDto entity, NetworkActionDto action) async {
    final controller = TextEditingController(
        text: _readings[entity.name]?.number?.toStringAsFixed(0) ?? '');
    final min = entity.setpointMin;
    final max = entity.setpointMax;
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Set ${entity.name}'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: InputDecoration(
            suffixText: entity.unit,
            helperText: switch ((min, max)) {
              (final double lo, final double hi) =>
                'Between ${lo.toStringAsFixed(0)} and ${hi.toStringAsFixed(0)}',
              (final double lo, null) => 'At least ${lo.toStringAsFixed(0)}',
              _ => null,
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Send'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (entered == null || entered.isEmpty || !mounted) return;
    final value = double.tryParse(entered);
    if (value == null ||
        (min != null && value < min) ||
        (max != null && value > max)) {
      setState(() => _error = 'That is not a value the device accepts.');
      return;
    }
    await _send(entity, action, value: value.toStringAsFixed(0));
  }

  Widget _sensorCard(NetworkEntityDto entity) {
    final reading = _readings[entity.name];
    final unit = entity.unit;
    final value = switch (reading?.kind) {
      null => 'Unknown',
      NetworkReadingKind.option => reading!.label ?? reading.raw,
      NetworkReadingKind.onOff => (reading!.isOn ?? false) ? 'On' : 'Off',
      _ => '${reading!.raw}${unit == null ? '' : ' $unit'}',
    };
    return _card(
      child: Row(
        children: [
          Expanded(
            child: Text(entity.name,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
          ),
          Text(value, style: Theme.of(context).textTheme.bodyLarge),
        ],
      ),
    );
  }

  Widget _deviceInfo(SoapDeviceDescription? description) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final rows = <(String, String)>[
      ('Address', '${widget.device.host}:${widget.device.port ?? '?'}'),
      if (description?.serialNumber != null)
        ('Serial', description!.serialNumber!),
      if (description?.firmwareVersion != null)
        ('Firmware', description!.firmwareVersion!),
      if (description?.udn != null) ('UDN', description!.udn!),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final (label, value) in rows)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 90,
                  child: Text(label,
                      style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                          fontWeight: FontWeight.w600)),
                ),
                Expanded(child: SelectableText(value, style: text.bodySmall)),
              ],
            ),
          ),
      ],
    );
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/ble_discovered_service.dart';
import '../providers/ble_provider.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/rabbit_air_ble_client.dart';
import '../services/rabbit_air_ble_control.dart';
import '../services/rabbit_air_control_service.dart';
import '../services/rabbit_air_control_transport.dart';
import '../services/rabbit_air_key_store.dart';
import '../services/spec_codec.dart';

/// The Rabbit Air control surface — power, mode, fan speed, sensors and the
/// two extra switches — rendered the same over either transport.
///
/// Extracted from NetworkDeviceScreen so the BLE device screen can offer the
/// identical panel: a purifier matched over BLE speaks the very same
/// envelopes, just framed onto a GATT characteristic instead of UDP. What
/// differs between the two screens lives behind [RabbitAirControlTransport];
/// what is the same — the key-entry card, the clock-sync-then-poll flow, the
/// entity cards, the send-and-re-poll discipline — lives here, once.
///
/// Renders a Column: embed it in the parent's scroll view. The parent's
/// refresh affordance calls [RabbitAirControlsPanelState.refresh] through a
/// GlobalKey.
class RabbitAirControlsPanel extends ConsumerStatefulWidget {
  final String specYaml;
  final List<NetworkEntityDto> entities;
  final RabbitAirControlTransport transport;

  const RabbitAirControlsPanel({
    super.key,
    required this.specYaml,
    required this.entities,
    required this.transport,
  });

  @override
  ConsumerState<RabbitAirControlsPanel> createState() =>
      RabbitAirControlsPanelState();
}

class RabbitAirControlsPanelState
    extends ConsumerState<RabbitAirControlsPanel> {
  final Map<String, Map<String, String>> _stateByCommand = {};
  final Map<String, NetworkReadingDto?> _readings = {};

  /// Names of entities a send is in flight for, disabling their controls.
  final Set<String> _sending = {};

  /// The user key this session is driving the device under, or null when
  /// none is stored — which is what brings up the key-entry card instead of
  /// the controls.
  String? _key;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(refresh());
  }

  /// Every distinct state call the declared entities need — usually one
  /// (`get_state`).
  Set<String> get _stateCommands => widget.entities
      .map((e) => e.stateCommand)
      .where((command) => command.isNotEmpty)
      .toSet();

  /// (Re)load: resolve the key, sync the device clock (once per session, via
  /// the spec's `time_sync` command), then poll every state command and
  /// re-decode every entity from the replies.
  Future<void> refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _key ??= await widget.transport.userKey();
      final key = _key;
      if (key != null) await _refreshState();
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyErrorText(
          e,
          context: 'device control',
          fallback: 'Could not reach the purifier. Try again.',
        );
      });
    }
  }

  Future<void> _refreshState() async {
    final key = _key;
    if (key == null) return; // No key, nothing to poll — the card is up.
    final codec = ref.read(specCodecProvider);
    final transport = widget.transport;

    await transport.syncClock(specYaml: widget.specYaml, userKey: key);
    for (final command in _stateCommands) {
      final request = await codec.renderNetworkRabbitAirStateRequest(
        specYaml: widget.specYaml,
        stateCommand: command,
        requestId: transport.nextRequestId(),
        deviceTs: transport.deviceTs(),
      );
      final reply = await transport.send(request, userKey: key);
      _stateByCommand[command] = rabbitAirStateFields(reply);
    }
    await _decodeEntities();
  }

  /// Decode every entity from whatever `_stateByCommand` currently holds.
  Future<void> _decodeEntities() async {
    final codec = ref.read(specCodecProvider);
    for (final entity in widget.entities) {
      final returned = _stateByCommand[entity.stateCommand];
      _readings[entity.name] = returned == null
          ? null
          : await codec.readNetworkEntity(
              specYaml: widget.specYaml,
              entityName: entity.name,
              returned: returned,
            );
    }
    if (mounted) setState(() {});
  }

  /// Send one action, then re-poll: the reply acknowledges the request, it
  /// does not report the resulting state, so the control snaps to the
  /// purifier's true state whether or not the write took.
  Future<void> _send(
    NetworkEntityDto entity,
    NetworkActionDto action, {
    String? value,
  }) async {
    if (_sending.contains(entity.name)) return;
    setState(() {
      _sending.add(entity.name);
      _error = null;
    });
    try {
      final key = _key;
      if (key == null) {
        throw const RabbitAirControlException(
            'no user key is stored for this purifier');
      }
      final values = <String, String>{};
      if (value != null && action.userParams.isNotEmpty) {
        values[action.userParams.first] = value;
      }
      final codec = ref.read(specCodecProvider);
      final transport = widget.transport;
      await transport.syncClock(specYaml: widget.specYaml, userKey: key);
      final request = await codec.renderNetworkRabbitAirCommand(
        specYaml: widget.specYaml,
        commandName: action.commandName,
        values: values,
        requestId: transport.nextRequestId(),
        deviceTs: transport.deviceTs(),
      );
      await transport.send(request, userKey: key);
      if (_stateCommands.isNotEmpty) await _refreshState();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = friendlyErrorText(
          e,
          context: 'device control',
          fallback: 'The purifier did not accept that. Try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _sending.remove(entity.name));
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
    final entities = widget.entities;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                style:
                    text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ] else if (_key == null) ...[
          // Every exchange with this purifier is encrypted under its user
          // key, and none is stored — so the entry card IS the control
          // surface until the owner supplies one.
          _rabbitAirKeyCard(),
        ] else ...[
          // Readings and plain controls first, in the order the spec
          // declares them — but not a select: the mode picker goes last, so
          // the layout keeps a stable position as readings land.
          for (final entity
              in entities.where((entity) => entity.platform != 'select')) ...[
            _entityCard(entity),
            const SizedBox(height: 12),
          ],
          for (final entity
              in entities.where((entity) => entity.platform == 'select')) ...[
            _entityCard(entity),
            const SizedBox(height: 12),
          ],
        ],
      ],
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

  /// The card shown for a purifier with no stored user key: what the key is,
  /// where the owner finds it, and the way in. The key is a long-lived local
  /// secret — entered once here, stored in the platform keychain, and never
  /// sent anywhere but to the purifier it belongs to.
  Widget _rabbitAirKeyCard() {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.key_outlined, color: scheme.onSecondaryContainer),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    'This purifier needs its user key',
                    style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSecondaryContainer),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Rabbit Air encrypts local control with a per-device key. Find '
              'it in the Rabbit Air app: open the device page, tap the '
              'three-dot menu, choose Rename, then tap the device name — the '
              'screen reveals the Thing ID and the 32-character User key.',
              style:
                  text.bodySmall?.copyWith(color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: () => unawaited(_promptRabbitAirKey()),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('Enter user key'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The key-entry dialog: 32 hex characters, validated before anything is
  /// stored — a typo here is a purifier that never answers, so the dialog
  /// says so immediately instead. On save the panel reloads, and the first
  /// poll proves the key against the device.
  Future<void> _promptRabbitAirKey() async {
    final controller = TextEditingController();
    String? validation;
    final entered = await showDialog<String>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Rabbit Air user key'),
          content: TextField(
            controller: controller,
            autofocus: true,
            autocorrect: false,
            maxLength: 32,
            decoration: InputDecoration(
              isDense: true,
              border: const OutlineInputBorder(),
              hintText: '32 hex characters, from the Rabbit Air app',
              helperText: 'Device page → Rename → tap the device name',
              errorText: validation,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final key = controller.text.trim();
                if (!RabbitAirKeyStore.isValidUserKey(key)) {
                  setDialogState(() => validation =
                      'The user key is exactly 32 hex characters (0-9, a-f).');
                  return;
                }
                Navigator.of(context).pop(key);
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    // The controller is deliberately NOT disposed here: the dialog's pop
    // animation still builds the TextField for a few frames after showDialog
    // returns, and a focused field schedules a caret frame that would touch
    // a disposed controller. It is dialog-scoped and collected with the tree.
    if (entered == null || !mounted) return;
    await widget.transport.saveUserKey(entered);
    setState(() => _key = entered);
    await refresh();
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
    final busy = _sending.contains(entity.name);

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
    final busy = _sending.contains(entity.name);
    // Rabbit Air selects take their options from the spec's own table, so
    // "which is current" is decoded from a state reading.
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
                // Never renamed to a known option: an unrecognised mode
                // shown as "off" would lie about a running purifier.
                'Unrecognized state (${reading!.raw})',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
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
    final busy = _sending.contains(entity.name);
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

  Widget _sensorCard(NetworkEntityDto entity) =>
      RabbitAirReadingCard(entity: entity, reading: _readings[entity.name]);
}

/// A Rabbit Air entity rendered as a pure reading: the name, and the decoded
/// value with its unit. This is the controls panel's sensor card, shared with
/// the setup-mode info panel, where EVERY entity is read-only — a switch's
/// on/off, a select's current option and a number's value all read through
/// the same [NetworkReadingDto] kinds.
class RabbitAirReadingCard extends StatelessWidget {
  final NetworkEntityDto entity;
  final NetworkReadingDto? reading;

  const RabbitAirReadingCard({
    super.key,
    required this.entity,
    required this.reading,
  });

  @override
  Widget build(BuildContext context) {
    final unit = entity.unit;
    final value = switch (reading?.kind) {
      null => 'Unknown',
      NetworkReadingKind.option => reading!.label ?? reading!.raw,
      NetworkReadingKind.onOff => (reading!.isOn ?? false) ? 'On' : 'Off',
      _ => '${reading!.raw}${unit == null ? '' : ' $unit'}',
    };
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
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
      ),
    );
  }
}

/// The BLE device screen's Rabbit Air surface: owns the BLE transport pieces
/// (a [RabbitAirBleClient] bound to the screen's existing connection, and the
/// [RabbitAirBleControl] over it) so the shared [RabbitAirControlsPanel] can
/// stay transport-agnostic. The connection itself stays the device screen's —
/// disposing this widget releases only the notification subscription.
class RabbitAirBleControlsPanel extends ConsumerStatefulWidget {
  final String deviceId;
  final String specYaml;
  final List<NetworkEntityDto> entities;

  /// The services the device screen already discovered, forwarded so the
  /// client skips a second discovery round-trip.
  final List<BleDiscoveredService> services;

  const RabbitAirBleControlsPanel({
    super.key,
    required this.deviceId,
    required this.specYaml,
    required this.entities,
    required this.services,
  });

  @override
  ConsumerState<RabbitAirBleControlsPanel> createState() =>
      _RabbitAirBleControlsPanelState();
}

class _RabbitAirBleControlsPanelState
    extends ConsumerState<RabbitAirBleControlsPanel> {
  late final RabbitAirBleClient _client;
  late final RabbitAirBleControl _transport;

  @override
  void initState() {
    super.initState();
    final codec = ref.read(specCodecProvider);
    _client = RabbitAirBleClient(ref.read(bleServiceProvider), codec);
    _transport = RabbitAirBleControl(
      client: _client,
      codec: codec,
      keyStore: ref.read(rabbitAirKeyStoreProvider),
      deviceId: widget.deviceId,
      specYaml: widget.specYaml,
      services: widget.services,
    );
  }

  @override
  void dispose() {
    unawaited(_client.disconnect());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
        children: [
          RabbitAirControlsPanel(
            specYaml: widget.specYaml,
            entities: widget.entities,
            transport: _transport,
          ),
        ],
      );
}

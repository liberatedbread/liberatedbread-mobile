// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/entity_icon.dart';
import '../core/error_text.dart';
import '../core/log.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/http_control_service.dart';
import '../services/query_source_reader.dart';
import '../services/soap_control_service.dart';
import '../services/spec_codec.dart';

/// Controls for a network device whose matched spec declares entities — the
/// Wi-Fi counterpart of the BLE device screen's typed control panel.
///
/// For a SOAP device, the flow on every load and after every write is the
/// same three steps, each owned by the layer that knows it:
/// 1. fetch the device's own `setup.xml` and resolve control URLs from its
///    service list (transport — [SoapControlClient]);
/// 2. render and send one state request per distinct `state_command`
///    (what to send comes from the spec, via the codec);
/// 3. hand the returned values back to the codec per entity for decoding.
///
/// Writes carrying `read_back` parameters re-read the state they depend on
/// immediately before sending: the Crock-Pot's set-mode action carries the
/// cook time with it, and sending a stale one silently rewinds the timer.
///
/// A plain-HTTP action (a Roku remote key) skips all of that: there is no
/// description to fetch and no state to poll — the rendered method and path
/// are the whole exchange, sent through [HttpControlClient]. Which path a
/// send takes is the action's own `transport`, so one spec may mix both.
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

  /// Names of entities a send is in flight for, disabling their controls.
  ///
  /// A set rather than one slot because remote buttons overlap: a volume
  /// press must not wait for a slow PowerOn to settle, and two in-flight
  /// sends clearing one shared flag would re-enable both early.
  final Set<String> _sending = {};

  /// Options fetched from the device for entities that declare an
  /// `options_source` — the installed-channel list — by entity name.
  final Map<String, List<QueryEntry>> _fetchedOptions = {};

  /// Which of those options is current, by entity name. Absent means the
  /// device named none: on Roku's home screen no channel is foreground, and
  /// showing nothing selected is the true answer.
  final Map<String, String?> _currentOption = {};

  /// Whether the device refused a command while its queries kept answering —
  /// the "control by mobile apps" gate. Sticky for the screen's life so the
  /// note stays up after the error text is replaced by the next attempt.
  bool _controlRefused = false;

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  List<NetworkEntityDto> get _entities => widget.controls.entities;

  /// Every distinct state call the declared entities need — usually one.
  ///
  /// A `button` entity carries an empty state command (a keypress has no
  /// state to poll), and rendering a request from the empty string would ask
  /// the device a malformed question.
  Set<String> get _stateCommands => _entities
      .map((e) => e.stateCommand)
      .where((command) => command.isNotEmpty)
      .toSet();

  /// Whether anything on this screen needs the UPnP description document.
  ///
  /// SOAP is what it exists for: state reads and SOAP sends resolve their
  /// control URL from it. A device whose declared surface is entirely plain
  /// HTTP (a Roku remote) has no `setup.xml` to fetch — asking for one turns
  /// a working device into a permanent error screen.
  bool get _needsDescription =>
      _stateCommands.isNotEmpty ||
      _entities
          .any((e) => e.actions.any((action) => action.transport != 'http'));

  /// Loaded enough to draw controls: the description is fetched, or nothing
  /// on this screen wants it.
  bool get _ready => _description != null || !_needsDescription;

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
      if (_needsDescription) {
        final client = ref.read(soapControlClientProvider);
        _description ??=
            await client.fetchDescription(widget.device.host, port);
        await _refreshState();
      }
      await _refreshQuerySources();
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

  /// Fetch the option lists — and current selections — that live on the
  /// device rather than in the spec.
  ///
  /// Separate from [_refreshState] because it is a different transport and a
  /// different failure: these are plain GETs whose answers are XML lists, and
  /// on the devices this exists for they keep answering even when commands
  /// are refused. So a failure here costs the list and nothing else — the
  /// buttons beside it still work, and the screen must not become an error
  /// page over a channel list.
  Future<void> _refreshQuerySources() async {
    final client = ref.read(httpControlClientProvider);
    final port = widget.device.port;
    if (port == null) return;

    for (final entity in _entities) {
      final options = entity.optionsSource;
      if (options == null) continue;
      try {
        final body = await client.send(
          widget.device.host,
          port,
          HttpRequestDto(
              method: options.method, path: options.path, body: ''),
        );
        _fetchedOptions[entity.name] = readQuerySource(body, options);

        final state = entity.stateSource;
        if (state == null) continue;
        final current = await client.send(
          widget.device.host,
          port,
          HttpRequestDto(method: state.method, path: state.path, body: ''),
        );
        _currentOption[entity.name] = readCurrentValue(current, state);
      } catch (e) {
        // Logged, not surfaced: an absent list is visible on its own, and a
        // banner about it would bury the controls that do work.
        Log.net.debug('query source failed for ${entity.name}: $e');
      }
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
      _sending.add(entity.name);
      _error = null;
    });
    try {
      final values = <String, String>{};
      if (value != null && action.userParams.isNotEmpty) {
        values[action.userParams.first] = value;
      }
      if (action.transport == 'http') {
        await _sendHttp(action, values);
      } else {
        await _sendSoap(action, values);
      }
      // The reply acknowledges the request, it does not report the resulting
      // state — the Crock-Pot doesn't always take a setting. Read back
      // whatever state this screen polls; a remote of stateless buttons has
      // none.
      if (_stateCommands.isNotEmpty) await _refreshState();
      // A launch changes which option is current, and nothing else reports
      // that — re-read the selection the device now names.
      if (entity.stateSource != null) await _refreshQuerySources();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        // A refusal is a device setting, not a transient failure: remember it
        // so the screen can explain the gate instead of leaving the user to
        // read one error at a time.
        if (e is ControlRefusedException) _controlRefused = true;
        _error = friendlyErrorText(
          e,
          context: 'device control',
          fallback: 'The device did not accept that. Try again.',
        );
      });
    } finally {
      if (mounted) setState(() => _sending.remove(entity.name));
    }
  }

  /// The plain-HTTP send: render, POST to the discovered port, done. The
  /// method and path are the whole request, and the address is the one
  /// discovery already established.
  Future<void> _sendHttp(
      NetworkActionDto action, Map<String, String> values) async {
    final codec = ref.read(specCodecProvider);
    final request = await codec.renderNetworkHttpCommand(
      specYaml: widget.controls.specYaml,
      commandName: action.commandName,
      values: values,
    );
    // The port null-check in _load has already run by the time any control
    // is tappable.
    await ref
        .read(httpControlClientProvider)
        .send(widget.device.host, widget.device.port!, request);
  }

  /// The SOAP send: read back the settings this action carries but is not
  /// changing, render the envelope, and POST it to the control URL the
  /// device's own description names.
  Future<void> _sendSoap(
      NetworkActionDto action, Map<String, String> values) async {
    final codec = ref.read(specCodecProvider);
    final client = ref.read(soapControlClientProvider);
    final description = _description!;

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
      final returned =
          await client.send(description.host, description.port, path, request);
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
            ] else if (!_ready) ...[
              // Never reached the device: no cards. A toggle for a device
              // whose description was never fetched has nowhere to send.
              // Controls that need nothing fetched (a remote of plain-HTTP
              // buttons) never take this branch.
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
              // The device answered our questions but refused a command. That
              // is a setting on the device, and saying so beats leaving the
              // user to conclude the app is broken — discovery worked, the
              // lists loaded, only control is gated.
              if (_controlRefused) ...[
                _controlGateNote(),
                const SizedBox(height: 12),
              ],
              // The remote's buttons share one card: twenty-seven separate
              // cards would bury the D-pad below the fold, and a remote is
              // one control surface, not a list of readings.
              if (_buttons.isNotEmpty) ...[
                _remoteCard(_buttons),
                const SizedBox(height: 12),
              ],
              for (final entity in _entities
                  .where((entity) => entity.platform != 'button')) ...[
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

  List<NetworkEntityDto> get _buttons =>
      _entities.where((entity) => entity.platform == 'button').toList();

  /// The note shown once a device has refused a command.
  ///
  /// Deliberately says what still worked. A user whose TV ignores every
  /// button is entitled to wonder whether the app found the right device at
  /// all; naming the setting — and pointing out that finding it and reading
  /// from it both succeeded — turns a mystery into one toggle to flip.
  Widget _controlGateNote() {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: scheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, color: scheme.onSecondaryContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'The device is refusing commands',
                    style: text.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSecondaryContainer),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'It answered discovery and lets this app read from it, so '
                    'the connection is fine — it just will not take commands '
                    'over the network yet. On a Roku that is Settings > '
                    'System > Advanced system settings > "Control by mobile '
                    'apps"; other devices word it as network or external '
                    'control. Enable it there, then try again.',
                    style: text.bodySmall
                        ?.copyWith(color: scheme.onSecondaryContainer),
                  ),
                ],
              ),
            ),
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

  /// Every `button` entity as one card of momentary controls, in the spec's
  /// own declaration order — the spec lays its buttons out the way the
  /// physical remote does, and preserving that order is what makes the card
  /// read as a remote.
  Widget _remoteCard(List<NetworkEntityDto> buttons) {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Remote',
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final entity in buttons) _remoteButton(entity),
            ],
          ),
        ],
      ),
    );
  }

  Widget _remoteButton(NetworkEntityDto entity) {
    final action = _actionFor(entity, 'press');
    final busy = _sending.contains(entity.name);
    final icon = entityIconFor(icon: entity.icon);
    final label = Text(entity.name);
    final onPressed = (busy || action == null)
        ? null
        : () => unawaited(_send(entity, action));
    // The spec's icon when it names one this app can draw; a plain label
    // otherwise — for a remote key like OK the name IS the picture.
    if (icon == null && !busy) {
      return FilledButton.tonal(onPressed: onPressed, child: label);
    }
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2))
          : Icon(icon),
      label: label,
    );
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
    // Options either come from the spec's own table or from the device, and
    // where they came from decides how "which is current" is answered: a
    // spec-optioned select decodes it from a state reading, a device-optioned
    // one is told directly by the query the options came from.
    final fetched = _fetchedOptions[entity.name];
    final options = fetched != null
        ? [
            for (final entry in fetched)
              if (entry.value != null)
                NetworkOptionDto(
                    raw: entry.value!,
                    label: entry.label.isEmpty ? entry.value! : entry.label),
          ]
        : entity.options;
    final currentRaw = fetched != null
        ? _currentOption[entity.name]
        : (reading?.kind == NetworkReadingKind.option ? reading?.raw : null);

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
          // A device-sourced list that came back empty is worth a word: the
          // chips are simply absent otherwise, which reads as a bug rather
          // than as a device that answered with nothing.
          if (entity.optionsSource != null && options.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                _loading
                    ? 'Asking the device...'
                    : 'The device listed nothing here.',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final option in options)
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

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import '../providers/ble_provider.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../screens/rabbit_air_setup_screen.dart';
import '../services/rabbit_air_ble_client.dart';
import '../services/rabbit_air_control_service.dart';
import '../services/spec_codec.dart';
import 'rabbit_air_controls_panel.dart';

/// The read-only view of a Rabbit Air purifier in SETUP mode (advertising as
/// "RabbitAirSetup").
///
/// A setup-mode unit answers the CLEARTEXT command envelope — no user key,
/// no `ts` — so a unit that has never been provisioned can still be read:
/// cmd 255 is its identity (Thing ID, MAC, Wi-Fi firmware), cmd 4 its full
/// live state with the same field names the LAN `get_state` carries. This
/// panel exchanges those through [RabbitAirBleClient], decodes the state
/// with the same flattening and entity decoding the controls panel uses, and
/// renders every entity as a [RabbitAirReadingCard] — strictly read-only,
/// no toggles and no key prompt (there is no key yet).
///
/// The "Set up Wi-Fi" card lives at the bottom of this view: a user looking
/// at a setup-mode unit is precisely the onboarding candidate.
///
/// The link is the device screen's own connection, borrowed via
/// [RabbitAirBleClient.attach]; disposing this panel releases only the
/// notification subscription.
class RabbitAirSetupInfoPanel extends ConsumerStatefulWidget {
  final IoTDevice device;

  /// The services the device screen already discovered, forwarded so the
  /// client skips a second discovery round-trip.
  final List<BleDiscoveredService> services;

  /// How often the live state is re-polled while the panel is visible. The
  /// controls panel does not poll at all (it refreshes on writes), so this
  /// cadence is this view's own: often enough that air quality reads live,
  /// rare enough to leave the single GATT channel mostly idle.
  final Duration pollInterval;

  /// The exchange timeout handed to the client — a parameter so a test does
  /// not wait out the vendor's 7 s.
  final Duration responseTimeout;

  const RabbitAirSetupInfoPanel({
    super.key,
    required this.device,
    required this.services,
    this.pollInterval = const Duration(seconds: 5),
    this.responseTimeout = const Duration(seconds: 7),
  });

  @override
  ConsumerState<RabbitAirSetupInfoPanel> createState() =>
      _RabbitAirSetupInfoPanelState();
}

class _RabbitAirSetupInfoPanelState
    extends ConsumerState<RabbitAirSetupInfoPanel> {
  RabbitAirBleClient? _client;
  Timer? _pollTimer;

  /// The per-connection setup-envelope id counter, from 0.
  int _nextId = 0;

  /// The cmd 255 answer's `data` object, verbatim.
  Map<String, Object?>? _info;

  /// The model code from the cmd 4 state, decoded to a name when known.
  int? _model;

  final Map<String, NetworkReadingDto?> _readings = {};

  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    unawaited(_client?.disconnect() ?? Future<void>.value());
    super.dispose();
  }

  /// (Re)start the conversation: fresh client, fresh id counter, info read,
  /// first state poll, then the poll timer. Retries rebuild from scratch
  /// because a failed attach leaves no usable subscription behind.
  Future<void> _start() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    final old = _client;
    _client = null;
    if (old != null) await old.disconnect();
    setState(() {
      _loading = true;
      _error = null;
    });
    final codec = ref.read(specCodecProvider);
    final client = _client = RabbitAirBleClient(
        ref.read(bleServiceProvider), codec,
        responseTimeout: widget.responseTimeout);
    _nextId = 0;
    try {
      await client.attach(widget.device.id, services: widget.services);
      await _readInfo();
      await _poll();
      if (!mounted) return;
      setState(() => _loading = false);
      _pollTimer =
          Timer.periodic(widget.pollInterval, (_) => unawaited(_poll()));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyErrorText(
          e,
          context: 'rabbit air setup info',
          fallback: 'Could not read the purifier. Try again.',
        );
      });
    }
  }

  /// One cleartext setup exchange: the `{id, cmd}` envelope — no `ts`, no
  /// encryption — and the raw reply text. A truthy `error` is the device
  /// refusing, surfaced as an exception.
  Future<String> _exchange(int cmd) async {
    final client = _client;
    if (client == null) {
      throw StateError('RabbitAirSetupInfoPanel exchange before attach');
    }
    final codec = ref.read(specCodecProvider);
    final envelope =
        await codec.renderRabbitAirSetupEnvelope(id: _nextId++, cmd: cmd);
    final reply = utf8.decode(await client.sendCommand(utf8.encode(envelope)));
    final decoded = jsonDecode(reply);
    final error = decoded is Map ? decoded['error'] : null;
    if (error != null && error != false) {
      throw RabbitAirBleException(
          'the purifier refused command $cmd (error: $error)');
    }
    return reply;
  }

  Future<void> _readInfo() async {
    final reply = await _exchange(255);
    final decoded = jsonDecode(reply);
    final data = decoded is Map ? decoded['data'] : null;
    if (data is Map && mounted) {
      setState(() => _info = data.cast());
    }
  }

  /// Poll the live state (cmd 4) and re-decode every entity — the same
  /// flattening and decoding the controls panel runs on its LAN replies. A
  /// failed poll stops the timer and raises the error state; the last good
  /// readings stay on screen.
  Future<void> _poll() async {
    try {
      final reply = await _exchange(4);
      final decoded = jsonDecode(reply);
      final data = decoded is Map ? decoded['data'] : null;
      if (data is Map) {
        _model = switch (data['model']) {
          final int m => m,
          final other => int.tryParse('$other'),
        };
      }
      final returned = rabbitAirStateFields(reply);
      final surface = ref.read(rabbitAirSpecSurfaceProvider).valueOrNull;
      if (surface != null) {
        final codec = ref.read(specCodecProvider);
        for (final entity in surface.entities) {
          _readings[entity.name] = await codec.readNetworkEntity(
            specYaml: surface.specYaml,
            entityName: entity.name,
            returned: returned,
          );
        }
      }
      if (mounted) setState(() {});
    } catch (e) {
      _pollTimer?.cancel();
      _pollTimer = null;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyErrorText(
          e,
          context: 'rabbit air setup info',
          fallback: 'The purifier stopped answering. Try again.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final surface = ref.watch(rabbitAirSpecSurfaceProvider).valueOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        if (_error != null) ...[
          Card(
            margin: EdgeInsets.zero,
            color: scheme.errorContainer,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(_error!,
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onErrorContainer)),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: FilledButton.tonalIcon(
                      onPressed: () => unawaited(_start()),
                      icon: const Icon(Icons.refresh),
                      label: const Text('Try again'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
        ],
        if (_loading && _info == null) ...[
          const SizedBox(height: 48),
          const Center(child: CircularProgressIndicator()),
          const SizedBox(height: 16),
          Center(
            child: Text('Asking the device...',
                style:
                    text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant)),
          ),
        ] else ...[
          if (_info != null) ...[
            _infoCard(),
            const SizedBox(height: 12),
          ],
          for (final entity
              in surface?.entities ?? const <NetworkEntityDto>[]) ...[
            RabbitAirReadingCard(
                entity: entity, reading: _readings[entity.name]),
            const SizedBox(height: 12),
          ],
        ],
        const SizedBox(height: 4),
        RabbitAirSetupCard(device: widget.device),
      ],
    );
  }

  /// The cmd 255 identity card: Thing ID, MAC, Wi-Fi firmware, and the model
  /// when the state read reported one this app knows.
  Widget _infoCard() {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final info = _info!;
    final mcu = info['mcu'];
    final rows = <(String, String)>[
      if (info['name'] case final String name when name.isNotEmpty)
        ('Thing ID', name),
      if (info['mac'] case final String mac when mac.isNotEmpty) ('MAC', mac),
      if (mcu != null) ('Wi-Fi firmware', 'v$mcu'),
      if (_modelName case final String model) ('Model', model),
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Purifier info',
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 110,
                      child: Text(label,
                          style: text.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w600)),
                    ),
                    Expanded(
                        child: SelectableText(value, style: text.bodySmall)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The state read's `model` code, named per the spec's state model (1 =
  /// MinusA2, 2 = BioGS 2.0, 3 = A3); null when absent or unknown — an
  /// unrecognized code is not a guess.
  String? get _modelName => switch (_model) {
        1 => 'MinusA2',
        2 => 'BioGS 2.0',
        3 => 'A3',
        _ => null,
      };
}

/// The card a "RabbitAirSetup" unit shows at the foot of its info view: this
/// purifier is waiting to be provisioned, and the readings above are the
/// answer to "is this the right device" — this card is the way into that.
class RabbitAirSetupCard extends StatelessWidget {
  final IoTDevice device;

  const RabbitAirSetupCard({super.key, required this.device});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: ListTile(
        leading: Icon(Icons.wifi_tethering, color: scheme.onSecondaryContainer),
        title: Text(
          'Finish setting up this purifier',
          style: text.titleSmall?.copyWith(
              fontWeight: FontWeight.w600, color: scheme.onSecondaryContainer),
        ),
        subtitle: Text(
          'It is in setup mode. Hand it your Wi-Fi over Bluetooth.',
          style: text.bodySmall?.copyWith(color: scheme.onSecondaryContainer),
        ),
        trailing: FilledButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RabbitAirSetupScreen(device: device),
            ),
          ),
          child: const Text('Set up Wi-Fi'),
        ),
      ),
    );
  }
}

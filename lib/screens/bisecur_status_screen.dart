// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/bisecur_client.dart';
import '../services/spec_codec.dart';
import '../src/rust/protocol/bisecur.dart';
import '../widgets/ad_banner_bar.dart';
import '../widgets/read_only_commands_card.dart';

/// Builds the client this screen reads through. A provider so a test can hand
/// it a fake instead of a socket.
final biSecurClientFactoryProvider =
    Provider<BiSecurClient Function(String host, int port, String mac)>(
      (ref) =>
          (host, port, mac) =>
              BiSecurGatewayClient(host: host, port: port, gatewayMac: mac),
    );

/// The doors behind a Hörmann BiSecur gateway: where each one is and what it
/// reports.
///
/// Read-only, and this screen has the most reason to be. An impulse moves a
/// heavy door, and there is no control here that sends one and no path from
/// here to one. It reads when asked, because the gateway resets a connection
/// polled too fast. The password lives in the text field while the screen is
/// open and is stored nowhere.
class BiSecurStatusScreen extends ConsumerStatefulWidget {
  final NetworkDevice device;
  final NetworkControls controls;
  final String? category;
  final String? specKey;

  const BiSecurStatusScreen({
    super.key,
    required this.device,
    required this.controls,
    this.category,
    this.specKey,
  });

  @override
  ConsumerState<BiSecurStatusScreen> createState() =>
      _BiSecurStatusScreenState();
}

class _BiSecurStatusScreenState extends ConsumerState<BiSecurStatusScreen> {
  static const _fallbackPort = 4000;

  final _user = TextEditingController();
  final _password = TextEditingController();
  ReadOnlySurfaceDto? _surface;
  BiSecurClient? _client;
  List<BiSecurPortReading>? _readings;
  String? _error;
  bool _reading = false;

  /// The discovery reply's `mac` attribute, which a frame's destination has to
  /// carry. A gateway found another way has none to give.
  String? get _mac {
    final mac = widget.device.txt['mac']?.trim();
    return mac == null || mac.isEmpty ? null : mac;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadSurface());
  }

  @override
  void dispose() {
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _loadSurface() async {
    try {
      final surface = await ref
          .read(specCodecProvider)
          .readOnlySurface(specYaml: widget.controls.specYaml);
      if (mounted) setState(() => _surface = surface);
    } on Object catch (_) {
      // The list of refused commands is a courtesy, and the readings do not
      // depend on it. Nothing the app can send changes if it is missing.
    }
  }

  Future<void> _read() async {
    final mac = _mac;
    if (mac == null || _reading) return;
    final user = _user.text.trim();
    if (user.isEmpty) {
      setState(() => _error = 'Enter a gateway user name first.');
      return;
    }
    setState(() {
      _reading = true;
      _error = null;
    });
    final client = _client ??= ref.read(biSecurClientFactoryProvider)(
      widget.device.host,
      widget.device.port ?? _surface?.defaultPort ?? _fallbackPort,
      mac,
    );
    try {
      final readings = await client.read(user: user, password: _password.text);
      if (!mounted) return;
      setState(() {
        _readings = readings;
        _reading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _reading = false;
        _error = friendlyErrorText(
          e,
          context: 'BiSecur read ${widget.device.host}',
          fallback: 'Could not read the gateway.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final readings = _readings;
    final surface = _surface;
    return Scaffold(
      bottomNavigationBar: DeviceAdBannerBar(
        category: widget.category,
        specKey: widget.specKey,
      ),
      appBar: AppBar(title: Text(widget.device.displayName)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            ReadOnlyNotice(advisory: surface?.safetyAdvisory),
            const SizedBox(height: 12),
            if (_mac == null)
              const Text(
                "The gateway's network announcement carried no hardware "
                'address, and every request has to name one. Scan again from '
                'the same network as the gateway.',
              )
            else ...[
              TextField(
                controller: _user,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Gateway user'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Password'),
              ),
              const SizedBox(height: 8),
              Text(
                'This gateway has no encryption, so the login crosses your '
                'network readable to anything on it. This app does not store '
                'the password. Give it a gateway user of its own, not the '
                'admin account.',
                style: text.bodySmall,
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _reading ? null : () => unawaited(_read()),
                icon: const Icon(Icons.refresh),
                label: Text(_reading ? 'Reading…' : 'Read door positions'),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                readings == null
                    ? _error!
                    : '$_error These are the last readings.',
                style: TextStyle(color: scheme.error),
              ),
            ],
            if (readings != null && readings.isEmpty) ...[
              const SizedBox(height: 12),
              const Text('The gateway lists no doors.'),
            ],
            for (final reading in readings ?? const <BiSecurPortReading>[]) ...[
              const SizedBox(height: 12),
              _DoorCard(reading: reading),
            ],
            const SizedBox(height: 12),
            if (surface != null)
              ReadOnlyCommandsCard(commands: surface.commands),
          ],
        ),
      ),
    );
  }
}

class _DoorCard extends StatelessWidget {
  final BiSecurPortReading reading;

  const _DoorCard({required this.reading});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final name = reading.groupName.isEmpty ? 'Door' : reading.groupName;
    final type = reading.port.typeName;
    final transition = reading.transition;
    final position = transition?.positionPercent;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(name, style: text.titleMedium),
            Text(
              'Port ${reading.port.id}${type == null ? '' : ' · $type'}',
              style: text.bodySmall,
            ),
            const SizedBox(height: 8),
            if (reading.note != null) Text(reading.note!),
            if (transition != null) ...[
              Text(
                position == null
                    ? 'Position not reported'
                    : '${position.toStringAsFixed(0)}% open',
              ),
              for (final flag in _flags(transition)) Text(flag),
            ],
          ],
        ),
      ),
    );
  }

  List<String> _flags(BiSecurTransitionDto t) => [
    if (t.driving) t.drivingTowardsClosed ? 'Moving towards closed' : 'Moving',
    if (t.fullyOpen) 'Fully open',
    if (t.fullyClosed) 'Fully closed',
    if (t.halfOpen) 'Half open',
    if (t.fault || t.statusError) 'The operator reports an error',
    if (t.notReferenced) 'End positions not set',
  ];
}

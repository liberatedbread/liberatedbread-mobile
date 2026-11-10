// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/juicenet_listener.dart';
import '../services/spec_codec.dart';
import '../src/rust/protocol/juicenet.dart';
import '../widgets/ad_banner_bar.dart';
import '../widgets/read_only_commands_card.dart';

/// Builds the listener this screen reads through. A provider so a test can
/// bind loopback.
final juiceNetListenerFactoryProvider =
    Provider<JuiceNetListener Function(int port, String? chargerHost)>(
      (ref) =>
          (port, chargerHost) =>
              JuiceNetListener(port: port, chargerHost: chargerHost),
    );

/// An Enel X JuiceBox's readings, heard as it streams them.
///
/// Read-only, and listen-only: the phone never replies, so it never sends the
/// CMD line that sets the charging current. The charger keeps charging at
/// its offline limit exactly as it has since the vendor's servers closed.
class JuiceNetStatusScreen extends ConsumerStatefulWidget {
  final NetworkDevice device;
  final NetworkControls controls;
  final String? category;
  final String? specKey;

  const JuiceNetStatusScreen({
    super.key,
    required this.device,
    required this.controls,
    this.category,
    this.specKey,
  });

  @override
  ConsumerState<JuiceNetStatusScreen> createState() =>
      _JuiceNetStatusScreenState();
}

class _JuiceNetStatusScreenState extends ConsumerState<JuiceNetStatusScreen> {
  /// `crate::protocol::juicenet::DEFAULT_LISTEN_PORT`: the charger's own
  /// fallback server port. Any port works.
  static const defaultPort = 8042;

  final _port = TextEditingController(text: '$defaultPort');
  ReadOnlySurfaceDto? _surface;
  JuiceNetListener? _listener;
  StreamSubscription<JuiceNetHeard>? _subscription;
  JuiceNetHeard? _latest;
  JuiceNetHeard? _lastRefused;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSurface());
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(_listener?.dispose());
    _port.dispose();
    super.dispose();
  }

  Future<void> _loadSurface() async {
    try {
      final surface = await ref
          .read(specCodecProvider)
          .readOnlySurface(specYaml: widget.controls.specYaml);
      if (mounted) setState(() => _surface = surface);
    } on Object catch (_) {
      // A courtesy list; the readings do not depend on it.
    }
  }

  Future<void> _start() async {
    final port = int.tryParse(_port.text.trim());
    if (port == null || port < 1 || port > 65535) {
      setState(() => _error = 'Enter a UDP port from 1 to 65535.');
      return;
    }
    final host = widget.device.host.trim();
    final listener = ref.read(juiceNetListenerFactoryProvider)(
      port,
      host.isEmpty ? null : host,
    );
    try {
      await listener.start();
    } on Object catch (e) {
      await listener.dispose();
      if (!mounted) return;
      setState(
        () => _error = friendlyErrorText(
          e,
          context: 'JuiceNet listen',
          fallback: 'Could not start listening.',
        ),
      );
      return;
    }
    if (!mounted) {
      await listener.dispose();
      return;
    }
    _subscription = listener.heard.listen((heard) {
      if (!mounted) return;
      setState(() {
        switch (heard.frame.kind) {
          case JuiceNetFrameKind.status || JuiceNetFrameKind.legacy:
            _latest = heard;
          case JuiceNetFrameKind.debug:
            break;
          case JuiceNetFrameKind.encrypted || JuiceNetFrameKind.invalid:
            _lastRefused = heard;
        }
      });
    });
    setState(() {
      _listener = listener;
      _error = null;
    });
  }

  Future<void> _stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await _listener?.dispose();
    if (mounted) setState(() => _listener = null);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final surface = _surface;
    final listening = _listener != null;
    final latest = _latest;
    final refused = _lastRefused;
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
            Text(
              'The charger sends its readings to one address and port. Point '
              "it at this phone's address on your network and the port below "
              '(the spec\'s setup notes give three ways), then listen. This app '
              'only listens: it never replies, so it cannot change the '
              'charging current.',
              style: text.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _port,
              enabled: !listening,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'UDP port'),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: () => unawaited(listening ? _stop() : _start()),
              icon: Icon(listening ? Icons.stop : Icons.hearing),
              label: Text(listening ? 'Stop listening' : 'Listen'),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
            if (listening && latest == null && refused == null) ...[
              const SizedBox(height: 12),
              const Text(
                'Waiting for the charger. It reports every 9 to 30 seconds.',
              ),
            ],
            if (refused != null && refused.frame.note != null) ...[
              const SizedBox(height: 12),
              Text(refused.frame.note!, style: TextStyle(color: scheme.error)),
            ],
            if (latest != null) ...[
              const SizedBox(height: 12),
              _ReadingCard(heard: latest),
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

class _ReadingCard extends StatelessWidget {
  final JuiceNetHeard heard;
  const _ReadingCard({required this.heard});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final f = heard.frame;
    String amps(double v) => '${v.toStringAsFixed(1)} A';
    final rows = <String>[
      if (f.currentAmps != null) 'Charging current: ${amps(f.currentAmps!)}',
      if (f.voltage != null) 'Line voltage: ${f.voltage!.toStringAsFixed(1)} V',
      if (f.powerWatts != null)
        'Charging power: ${f.powerWatts!.toStringAsFixed(0)} W',
      if (f.sessionWh != null) 'Session energy: ${f.sessionWh} Wh',
      if (f.lifetimeWh != null) 'Lifetime energy: ${f.lifetimeWh} Wh',
      if (f.temperatureC != null) 'Internal temperature: ${f.temperatureC} °C',
      if (f.frequencyHz != null)
        'Line frequency: ${f.frequencyHz!.toStringAsFixed(2)} Hz',
      if (f.ratedAmps != null) 'Rated current: ${f.ratedAmps} A',
      if (f.onlineLimitAmps != null)
        'Reported online limit: ${f.onlineLimitAmps} A',
      if (f.offlineLimitAmps != null)
        'Reported offline limit: ${f.offlineLimitAmps} A',
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              f.statusText ?? 'Status not reported',
              style: text.titleMedium,
            ),
            if (f.unitId != null)
              Text(
                'Unit ${f.unitId} · ${f.version ?? 'legacy'}',
                style: text.bodySmall,
              ),
            const SizedBox(height: 8),
            for (final row in rows) Text(row),
            if (f.note != null) Text(f.note!, style: text.bodySmall),
          ],
        ),
      ),
    );
  }
}

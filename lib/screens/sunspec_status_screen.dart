// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../models/network_device.dart';
import '../providers/network_control_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/sunspec_client.dart';
import '../services/spec_codec.dart';
import '../widgets/ad_banner_bar.dart';
import '../widgets/read_only_commands_card.dart';

/// Builds the client this screen reads through. A provider so a test can hand
/// it a fake instead of a socket.
final sunSpecClientFactoryProvider =
    Provider<SunSpecClient Function(String host, int port, int unitId)>(
      (ref) =>
          (host, port, unitId) =>
              ModbusSunSpecClient(host: host, port: port, unitId: unitId),
    );

/// A SolarEdge inverter's readings over Modbus TCP.
///
/// Read-only: there is no control on this screen and no path from it to one.
/// Polls every [pollInterval] while open, which is the solaredge-modbus-multi
/// default the spec records.
class SunSpecStatusScreen extends ConsumerStatefulWidget {
  final NetworkDevice device;
  final NetworkControls controls;
  final String? category;
  final String? specKey;
  final Duration pollInterval;

  const SunSpecStatusScreen({
    super.key,
    required this.device,
    required this.controls,
    this.category,
    this.specKey,
    this.pollInterval = const Duration(seconds: 10),
  });

  @override
  ConsumerState<SunSpecStatusScreen> createState() =>
      _SunSpecStatusScreenState();
}

class _SunSpecStatusScreenState extends ConsumerState<SunSpecStatusScreen> {
  static const _fallbackPort = 1502;

  ReadOnlySurfaceDto? _surface;
  SunSpecClient? _client;
  SunSpecReading? _reading;
  String? _error;
  bool _loading = true;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  Future<void> _start() async {
    try {
      final surface = await ref
          .read(specCodecProvider)
          .readOnlySurface(specYaml: widget.controls.specYaml);
      if (!mounted) return;
      setState(() => _surface = surface);
    } on Object catch (_) {
      // The list of refused commands is a courtesy, and the readings do not
      // depend on it. Nothing the app can send changes if it is missing.
    }
    if (!mounted) return;
    final device = widget.device;
    _client = ref.read(sunSpecClientFactoryProvider)(
      device.host,
      device.port ?? _surface?.defaultPort ?? _fallbackPort,
      ModbusSunSpecClient.unitIdFromTxt(device.txt),
    );
    await _read();
    if (!mounted) return;
    _poll = Timer.periodic(widget.pollInterval, (_) => unawaited(_read()));
  }

  Future<void> _read() async {
    final client = _client;
    if (client == null) return;
    if (mounted) setState(() => _loading = true);
    try {
      final reading = await client.read();
      if (!mounted) return;
      setState(() {
        _reading = reading;
        _error = null;
        _loading = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = friendlyErrorText(
          e,
          context: 'SunSpec read ${widget.device.host}',
          fallback: 'Could not read the inverter.',
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final reading = _reading;
    final surface = _surface;
    return Scaffold(
      bottomNavigationBar: DeviceAdBannerBar(
        category: widget.category,
        specKey: widget.specKey,
      ),
      appBar: AppBar(
        title: Text(widget.device.displayName),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loading ? null : () => unawaited(_read()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
          children: [
            ReadOnlyNotice(advisory: surface?.safetyAdvisory),
            const SizedBox(height: 12),
            if (_error != null) ...[
              Text(
                reading == null
                    ? _error!
                    : '$_error These are the last readings.',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
              const SizedBox(height: 12),
            ],
            if (reading == null && _error == null)
              const Row(
                children: [
                  SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 14),
                  Expanded(child: Text('Reading the inverter…')),
                ],
              ),
            if (reading != null) ...[
              _Section(title: 'Inverter', rows: _inverterRows(reading)),
              const SizedBox(height: 12),
              _meter(reading),
              const SizedBox(height: 12),
              _Section(
                title: 'Identity',
                rows: [
                  ('Manufacturer', reading.common.manufacturer),
                  ('Model', reading.common.model),
                  ('Firmware', reading.common.version),
                  ('Serial', reading.common.serial),
                ],
              ),
              const SizedBox(height: 12),
            ],
            if (surface != null)
              ReadOnlyCommandsCard(commands: surface.commands),
          ],
        ),
      ),
    );
  }

  Widget _meter(SunSpecReading reading) {
    final power = reading.meterPower;
    if (power == null) {
      return const _Section(
        title: 'Meter',
        rows: [('Meter 1', 'None answered at its address')],
      );
    }
    return _Section(
      title: 'Meter',
      rows: [
        if ((reading.meter?.role ?? '').isNotEmpty)
          ('Role', reading.meter!.role),
        ('Power (magnitude)', _value(power.magnitudeW, 'W', 1)),
      ],
      footnote:
          'Shown without a direction. SolarEdge does not say which sign means '
          'export, so this app does not guess whether power is flowing to or '
          'from the grid.',
    );
  }

  List<(String, String)> _inverterRows(SunSpecReading reading) {
    final i = reading.inverter;
    return [
      ('State', i.statusLabel ?? 'Unknown (${i.statusCode})'),
      ('AC power', _value(i.acPowerW, 'W', 0)),
      ('Lifetime energy', _value(reading.lifetimeEnergyWh, 'Wh', 0)),
      ('DC power', _value(i.dcPowerW, 'W', 0)),
      ('Heat sink', _value(i.heatSinkC, '°C', 1)),
      ('AC current', _value(i.acCurrentA, 'A', 2)),
      ('AC voltage (L-N)', _value(i.acVoltageAnV, 'V', 1)),
      ('Frequency', _value(i.acFrequencyHz, 'Hz', 2)),
    ];
  }

  String _value(double? value, String unit, int digits) =>
      value == null ? 'Not reported' : '${value.toStringAsFixed(digits)} $unit';
}

class _Section extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;
  final String? footnote;

  const _Section({required this.title, required this.rows, this.footnote});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: text.titleMedium),
            const SizedBox(height: 8),
            for (final (label, value) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text(label)),
                    const SizedBox(width: 12),
                    Flexible(child: Text(value, textAlign: TextAlign.end)),
                  ],
                ),
              ),
            if (footnote != null) ...[
              const SizedBox(height: 8),
              Text(footnote!, style: text.bodySmall),
            ],
          ],
        ),
      ),
    );
  }
}

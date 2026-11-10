// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import '../models/iot_device.dart';
import '../providers/read_only_ble_provider.dart';
import '../providers/saved_device_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/acinfinity_ble_client.dart';
import '../services/inmotion_ble_client.dart';
import '../services/pax_ble_client.dart';
import '../services/spec_codec.dart';
import '../services/yummly_ble_client.dart';
import '../src/rust/protocol/acinfinity.dart';
import 'read_only_commands_card.dart';

/// The panel for a read-only BLE handler's device.
class ReadOnlyBlePanel extends ConsumerWidget {
  final IoTDevice device;
  final ReadOnlyBleProfile profile;

  const ReadOnlyBlePanel({
    super.key,
    required this.device,
    required this.profile,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) =>
      switch (profile.handler) {
        yummlyHandler => _YummlyPanel(device: device, profile: profile),
        paxHandler => _PaxPanel(device: device, profile: profile),
        inMotionHandler => _InMotionPanel(device: device, profile: profile),
        _ => _AcInfinityPanel(device: device, profile: profile),
      };
}

/// What the two panels share: the notice and refused commands, and a session
/// that only starts when the user asks for it.
abstract class _WatchState<W extends ConsumerStatefulWidget, R>
    extends ConsumerState<W> {
  IoTDevice get device;
  ReadOnlyBleProfile get profile;

  ReadOnlySurfaceDto? surface;
  StreamSubscription<R>? _subscription;
  R? reading;
  String? error;
  bool watching = false;

  Stream<R> openSession();
  Future<void> closeSession();

  /// True when this device must not be connected to at all. There is then no
  /// start action on screen, and [start] refuses in case anything calls it.
  bool get refusesToConnect => false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSurface());
  }

  Future<void> _loadSurface() async {
    try {
      final loaded = await ref
          .read(specCodecProvider)
          .readOnlySurface(specYaml: profile.specYaml);
      if (mounted) setState(() => surface = loaded);
    } on Object catch (e) {
      Log.spec.debug('read-only surface did not load', error: e);
    }
  }

  void start() {
    if (refusesToConnect) return;
    setState(() {
      watching = true;
      error = null;
    });
    _subscription = openSession().listen(
      (next) {
        if (!mounted) return;
        setState(() => reading = next);
        unawaited(_remember());
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() {
          watching = false;
          error = friendlyErrorText(
            e,
            context: 'read-only BLE ${device.id}',
            fallback:
                'Could not read this device. Keep it in range and try '
                'again.',
          );
        });
      },
      onDone: () {
        if (mounted) setState(() => watching = false);
      },
    );
  }

  Future<void> stop() async {
    await _subscription?.cancel();
    _subscription = null;
    await closeSession();
    if (mounted) setState(() => watching = false);
  }

  bool _remembered = false;

  Future<void> _remember() async {
    if (_remembered) return;
    _remembered = true;
    try {
      final saved = ref.read(savedDevicesProvider.notifier);
      await saved.touch(
        id: device.id,
        name: device.displayName,
        seenAt: DateTime.now(),
      );
      await saved.recordMatch(
        id: device.id,
        category: profile.category,
        specKey: profile.specKey,
      );
    } on Object catch (e) {
      Log.ble.debug('could not save the read-only device', error: e);
    }
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    unawaited(closeSession());
    super.dispose();
  }

  Widget frame(BuildContext context, List<Widget> readings) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 40),
      children: [
        ReadOnlyNotice(advisory: surface?.safetyAdvisory),
        const SizedBox(height: 16),
        if (error != null) ...[
          Text(error!, style: TextStyle(color: scheme.error)),
          const SizedBox(height: 12),
        ],
        ...readings,
        const SizedBox(height: 16),
        if (!refusesToConnect) ...[
          FilledButton.icon(
            onPressed: () => watching ? unawaited(stop()) : start(),
            icon: Icon(watching ? Icons.stop : Icons.sensors),
            label: Text(watching ? 'Stop reading' : 'Start reading'),
          ),
          const SizedBox(height: 16),
        ],
        if (surface != null) ReadOnlyCommandsCard(commands: surface!.commands),
      ],
    );
  }
}

class _Rows extends StatelessWidget {
  final String title;
  final List<(String, String)> rows;

  const _Rows({required this.title, required this.rows});

  @override
  Widget build(BuildContext context) => Card(
    margin: EdgeInsets.zero,
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
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
        ],
      ),
    ),
  );
}

class _YummlyPanel extends ConsumerStatefulWidget {
  final IoTDevice device;
  final ReadOnlyBleProfile profile;

  const _YummlyPanel({required this.device, required this.profile});

  @override
  ConsumerState<_YummlyPanel> createState() => _YummlyPanelState();
}

class _YummlyPanelState extends _WatchState<_YummlyPanel, YummlyReading> {
  YummlyClient? _client;

  @override
  IoTDevice get device => widget.device;

  @override
  ReadOnlyBleProfile get profile => widget.profile;

  /// The spec's variant rule. XW3 shares this spec, and nobody known to it has
  /// ever run one, so a T3 is not even connected to.
  bool get _isT3 => widget.device.displayName.contains('T3');

  @override
  bool get refusesToConnect => _isT3;

  @override
  Stream<YummlyReading> openSession() {
    final client = _client = ref.read(yummlyClientProvider)(widget.device.id);
    return client.watch();
  }

  @override
  Future<void> closeSession() async {
    final client = _client;
    _client = null;
    await client?.close();
  }

  @override
  Widget build(BuildContext context) {
    if (_isT3) {
      return frame(context, const [
        Text(
          'This looks like a T3 dock. The T3 and P3 generation has never been '
          'run by anyone this project knows of, so this app does not connect '
          'to it. Only the T1 and P1 are read here.',
        ),
      ]);
    }
    final now = reading;
    return frame(context, [
      if (now != null)
        _Rows(
          title: 'Probe',
          rows: [
            ('Core', _temperature(now.coreF, 1, now.coreAtLimit)),
            ('Probe body', _temperature(now.bodyF, 0, now.bodyAtLimit)),
            if (now.dockBars != null) ('Dock battery', '${now.dockBars} of 4'),
            if (now.probeBars != null)
              ('Probe battery', '${now.probeBars} of 4'),
            if (now.probeName != null) ('Probe', now.probeName!),
            if (now.dockFirmware != null) ('Dock firmware', now.dockFirmware!),
          ],
        ),
      if (now?.stale ?? false) ...[
        const SizedBox(height: 12),
        const Text('No new reading for a while. These numbers are old.'),
      ],
      if (now != null) ...[
        const SizedBox(height: 12),
        Text(
          'The probe body is not the oven or grill temperature, and this '
          'sensor has not been calibrated. Confirm doneness with an instant-'
          'read thermometer.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    ]);
  }

  String _temperature(double? value, int digits, bool atLimit) {
    if (value == null) return 'Waiting';
    final shown = '${value.toStringAsFixed(digits)} °F';
    return atLimit ? '$shown (at its limit, may be hiding a fault)' : shown;
  }
}

class _AcInfinityPanel extends ConsumerStatefulWidget {
  final IoTDevice device;
  final ReadOnlyBleProfile profile;

  const _AcInfinityPanel({required this.device, required this.profile});

  @override
  ConsumerState<_AcInfinityPanel> createState() => _AcInfinityPanelState();
}

class _AcInfinityPanelState
    extends _WatchState<_AcInfinityPanel, AcInfinityReading> {
  AcInfinityClient? _client;

  @override
  IoTDevice get device => widget.device;

  @override
  ReadOnlyBleProfile get profile => widget.profile;

  @override
  Stream<AcInfinityReading> openSession() {
    final client = _client = ref.read(acInfinityClientProvider)(widget.device);
    return client.watch();
  }

  @override
  Future<void> closeSession() async {
    final client = _client;
    _client = null;
    await client?.close();
  }

  @override
  Widget build(BuildContext context) {
    final now = reading;
    if (now == null) return frame(context, const []);
    final status = now.status;
    final strip = status.layout == AcInfinityLayout.powerStrip;
    return frame(context, [
      if (now.stale) ...[
        const Text(
          'No new status for a while. This is the last one the controller '
          'sent, and its ports may have changed since.',
        ),
        const SizedBox(height: 12),
      ],
      if (status.caveat != null) ...[
        Text(status.caveat!, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 12),
      ],
      if (strip)
        _Rows(
          title: 'Sensors',
          rows: [
            for (final sensor in status.sensors)
              (
                sensor.name ?? 'Sensor ${sensor.sensorId}',
                _sensorValue(sensor),
              ),
            if (status.sensors.isEmpty) ('Sensors', 'None reported'),
          ],
        )
      else
        _Rows(
          title: 'Climate',
          rows: [
            ('Temperature', _hundredths(status.temperatureCentiC, '°C')),
            ('Humidity', _hundredths(status.humidityCentiPercent, '%')),
            ('VPD', _hundredths(status.vpdCentiKpa, 'kPa')),
          ],
        ),
      for (final port in status.ports) ...[
        const SizedBox(height: 12),
        _Rows(
          title: '${strip ? 'Outlet' : 'Port'} ${port.port}',
          rows: port.occupied == false && !strip
              ? const [('Plugged in', 'Nothing')]
              : _portRows(port, now.stored[port.port], strip: strip),
        ),
      ],
    ]);
  }

  /// A field the frame's layout does not state is said to be unstated, not
  /// shown as off or absent.
  List<(String, String)> _portRows(
    AcInfinityPortDto port,
    AcInfinityStoredDto? stored, {
    required bool strip,
  }) => [
    ('Mode', port.mode ?? 'Unknown (${port.modeCode})'),
    (
      'Output',
      switch (port.outputOn) {
        true => 'On',
        false => 'Off',
        null => 'Not stated for this controller',
      },
    ),
    // A strip outlet is a relay: levels live on a controller's ports.
    if (!strip) ('Level', port.level?.toString() ?? 'Not reported'),
    if (strip && port.occupied == false) ('Load', 'Nothing connected'),
    if (port.loadType != null) ('Load', port.loadType!),
    if (port.fault == true) ('Fault', 'Reported'),
    if (port.overcurrent == true) ('Overcurrent', 'Reported'),
    if (stored?.offLevel != null) ('Stored OFF level', '${stored!.offLevel}'),
    if (stored?.onLevelRaw != null)
      (
        'Stored ON byte',
        '0x${stored!.onLevelRaw!.toRadixString(16).padLeft(2, '0')}',
      ),
  ];

  String _hundredths(int? value, String unit) =>
      value == null ? 'No probe' : '${(value / 100).toStringAsFixed(2)} $unit';

  String _sensorValue(AcInfinitySensorDto sensor) {
    final value = sensor.valueHundredths;
    if (value == null) return 'No reading';
    final shown = (value / 100).toStringAsFixed(sensor.decimals);
    return sensor.unit == null ? shown : '$shown ${sensor.unit}';
  }
}

class _PaxPanel extends ConsumerStatefulWidget {
  final IoTDevice device;
  final ReadOnlyBleProfile profile;

  const _PaxPanel({required this.device, required this.profile});

  @override
  ConsumerState<_PaxPanel> createState() => _PaxPanelState();
}

class _PaxPanelState extends _WatchState<_PaxPanel, PaxReading> {
  PaxClient? _client;

  @override
  IoTDevice get device => widget.device;

  @override
  ReadOnlyBleProfile get profile => widget.profile;

  @override
  Stream<PaxReading> openSession() {
    final client = _client = ref.read(paxClientProvider)(widget.device.id);
    return client.watch();
  }

  @override
  Future<void> closeSession() async {
    final client = _client;
    _client = null;
    await client?.close();
  }

  @override
  Widget build(BuildContext context) {
    final now = reading;
    return frame(context, [
      if (now != null)
        _Rows(
          title: 'Status',
          rows: [
            (
              'Temperature',
              now.temperatureC == null
                  ? 'Waiting'
                  : '${now.temperatureC!.toStringAsFixed(1)} °C',
            ),
            (
              'Battery',
              now.batteryPercent == null
                  ? 'Waiting'
                  : '${now.batteryPercent} %',
            ),
          ],
        ),
      if (now?.stale ?? false) ...[
        const SizedBox(height: 12),
        const Text('No new reading for a while. These numbers are old.'),
      ],
      const SizedBox(height: 12),
      Text(
        'Reads temperature and battery only. The heater and the lock are '
        'never changed from this app. An Era Pro is not connected to: its '
        'encryption is not documented.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ]);
  }
}

class _InMotionPanel extends ConsumerStatefulWidget {
  final IoTDevice device;
  final ReadOnlyBleProfile profile;

  const _InMotionPanel({required this.device, required this.profile});

  @override
  ConsumerState<_InMotionPanel> createState() => _InMotionPanelState();
}

class _InMotionPanelState extends _WatchState<_InMotionPanel, InMotionReading> {
  InMotionClient? _client;

  @override
  IoTDevice get device => widget.device;

  @override
  ReadOnlyBleProfile get profile => widget.profile;

  @override
  Stream<InMotionReading> openSession() {
    final client = _client = ref.read(inMotionClientProvider)(widget.device.id);
    return client.watch();
  }

  @override
  Future<void> closeSession() async {
    final client = _client;
    _client = null;
    await client?.close();
  }

  @override
  Widget build(BuildContext context) {
    final now = reading;
    final telemetry = now?.telemetry;
    final totals = now?.totals;
    String fixed(double? value, int digits, String unit) => value == null
        ? 'Not reported'
        : '${value.toStringAsFixed(digits)} $unit';
    String celsius(int? value) => value == null ? 'No sensor' : '$value °C';
    return frame(context, [
      if (now != null)
        _Rows(
          title: now.model.name ?? 'Model ${now.model.code}',
          rows: [
            if (telemetry == null) ('Telemetry', 'Waiting'),
            if (telemetry != null) ...[
              ('Speed', fixed(telemetry.speedKmh, 1, 'km/h')),
              ('Battery', fixed(telemetry.batteryPercent, 0, '%')),
              ('Voltage', fixed(telemetry.voltageV, 1, 'V')),
              ('Current', fixed(telemetry.currentA, 1, 'A')),
              ('Trip', fixed(telemetry.tripKm, 2, 'km')),
              if (telemetry.remainingKm != null)
                ('Range left', fixed(telemetry.remainingKm, 1, 'km')),
              ('Speed limit now', fixed(telemetry.speedLimitKmh, 1, 'km/h')),
              ('MOSFETs', celsius(telemetry.mosTemperatureC)),
              ('Motor', celsius(telemetry.motorTemperatureC)),
              ('Board', celsius(telemetry.boardTemperatureC)),
            ],
            if (totals != null) ...[
              ('Odometer', fixed(totals.totalKm, 1, 'km')),
              (
                'Ride time',
                '${(totals.rideTimeS / 3600).toStringAsFixed(1)} h',
              ),
            ],
          ],
        ),
      if (now?.stale ?? false) ...[
        const SizedBox(height: 12),
        const Text('No new telemetry for a while. These numbers are old.'),
      ],
      const SizedBox(height: 12),
      Text(
        'Reads telemetry only, and only from V2 wheels. Nothing that changes '
        'the wheel is ever sent: what a wheel does with a command while '
        'someone rides it is not known. Do not read this while riding.',
        style: Theme.of(context).textTheme.bodySmall,
      ),
    ]);
  }
}

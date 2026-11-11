// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/health_reference.dart';
import '../../core/web_link.dart';
import '../../models/health_measurement_plan.dart';
import '../../providers/ble_provider.dart';
import '../../providers/health_history_provider.dart';
import '../../providers/health_measurement_codec_provider.dart';
import '../../services/health_measurement_codec.dart';
import '../../services/health_measurement_session.dart';
import '../../services/spec_codec.dart';
import 'measurement_trend_chart.dart';
import 'reference_guidance.dart';

class HealthMeasurementPanel extends ConsumerStatefulWidget {
  final String deviceId;
  final String specYaml;
  final DeviceSpecDto spec;
  final HealthMeasurementPlan plan;
  final DateTime Function()? now;
  final Duration pollInterval;
  final Duration staleAfter;
  final Duration syncTimeout;
  final LinkLauncher linkLauncher;

  const HealthMeasurementPanel({
    super.key,
    required this.deviceId,
    required this.specYaml,
    required this.spec,
    required this.plan,
    this.now,
    this.pollInterval = const Duration(seconds: 1),
    this.staleAfter = const Duration(seconds: 5),
    this.syncTimeout = const Duration(seconds: 15),
    this.linkLauncher = launchExternally,
  });

  @override
  ConsumerState<HealthMeasurementPanel> createState() =>
      _HealthMeasurementPanelState();
}

class _HealthMeasurementPanelState extends ConsumerState<HealthMeasurementPanel>
    with AutomaticKeepAliveClientMixin {
  late HealthMeasurementSession _session;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _startSession();
  }

  void _startSession() {
    _session = HealthMeasurementSession(
      ble: ref.read(bleServiceProvider),
      codec: ref.read(healthMeasurementCodecProvider),
      plan: widget.plan,
      deviceId: widget.deviceId,
      specYaml: widget.specYaml,
      now: widget.now,
      pollInterval: widget.pollInterval,
      staleAfter: widget.staleAfter,
      syncTimeout: widget.syncTimeout,
      store: ref.read(healthHistoryStoreProvider),
    )..start();
  }

  @override
  void didUpdateWidget(HealthMeasurementPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId != widget.deviceId ||
        oldWidget.specYaml != widget.specYaml ||
        oldWidget.plan.mode != widget.plan.mode ||
        oldWidget.plan.serviceUuid != widget.plan.serviceUuid ||
        oldWidget.plan.commandUuid != widget.plan.commandUuid ||
        oldWidget.plan.responseUuid != widget.plan.responseUuid) {
      _session.dispose();
      _startSession();
    }
  }

  @override
  void dispose() {
    _session.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: ListenableBuilder(
        listenable: _session,
        builder: (context, _) => _panel(context, _session.state),
      ),
    );
  }

  Widget _panel(BuildContext context, HealthMeasurementState state) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final pulse = widget.plan.kind == HealthMeasurementKind.pulseOximeter;
    final beurer = widget.spec.manufacturer.toLowerCase().contains('beurer');
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: Icon(
                    pulse ? Icons.air : Icons.favorite_outline,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pulse ? 'Pulse oximetry' : 'Blood pressure',
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        switch (widget.plan.mode) {
                          HealthMeasurementMode.livePoll =>
                            'Live samples · polled once a second',
                          HealthMeasurementMode.historySync =>
                            'Stored sessions · not a live stream',
                          HealthMeasurementMode.savedRecords =>
                            'Saved monitor readings · not cuff control',
                        },
                        style: text.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: state.phase == HealthSessionPhase.error
                      ? 'Retry'
                      : 'Refresh measurements',
                  onPressed: () => unawaited(_session.retry()),
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            const SizedBox(height: 16),
            if (state.phase == HealthSessionPhase.syncing)
              const Padding(
                padding: EdgeInsets.only(bottom: 12),
                child: _ProgressMessage(
                  message:
                      'Syncing stored sessions. Keep the oximeter in SYNC.',
                ),
              ),
            if (state.error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ErrorMessage(message: state.error!),
              ),
            if (widget.plan.mode == HealthMeasurementMode.livePoll)
              _livePulse(context, state, beurer)
            else if (widget.plan.mode == HealthMeasurementMode.historySync)
              _pulseHistory(context, state, beurer)
            else
              _bloodPressure(context, state, beurer),
            const SizedBox(height: 12),
            Text(
              'No cloud upload is triggered here. Measurements in this view are '
              'cleared when you leave the device screen.',
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }

  Widget _livePulse(
    BuildContext context,
    HealthMeasurementState state,
    bool beurer,
  ) {
    final sample = state.liveSample;
    if (sample == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (state.phase != HealthSessionPhase.error)
            const _ProgressMessage(
              message:
                  'Waiting for a fresh sample. Clip on the oximeter and '
                  'keep your hand still.',
            ),
          ..._earlierLiveSessions(context, state),
        ],
      );
    }
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (state.stale)
          const Padding(
            padding: EdgeInsets.only(bottom: 10),
            child: _ErrorMessage(
              message:
                  'Stale sample. The last value is shown, not a live reading.',
            ),
          ),
        Wrap(
          spacing: 20,
          runSpacing: 14,
          children: [
            _LargeReading(
              label: 'Oxygen saturation',
              value: _number(sample.spo2Percent),
              unit: '% SpO₂',
            ),
            _LargeReading(
              label: 'Pulse',
              value: _number(sample.pulseBpm),
              unit: 'bpm',
            ),
          ],
        ),
        if (sample.perfusionIndexPercent != null) ...[
          const SizedBox(height: 10),
          Text(
            'Perfusion index ${_number(sample.perfusionIndexPercent!)}%',
            style: text.bodyMedium,
          ),
        ],
        if (state.lastSampleAt != null) ...[
          const SizedBox(height: 6),
          Text(
            'Last sample ${_clockTime(state.lastSampleAt!)}',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
        if (state.liveTrend.length >= 2) ...[
          const SizedBox(height: 14),
          MeasurementTrendChart(
            title: 'SpO₂ this session',
            unit: '%',
            series: [
              MeasurementTrendSeries(
                label: 'SpO₂',
                values: [for (final s in state.liveTrend) s.spo2Percent],
              ),
            ],
          ),
          const SizedBox(height: 12),
          MeasurementTrendChart(
            title: 'Pulse this session',
            unit: 'bpm',
            series: [
              MeasurementTrendSeries(
                label: 'Pulse',
                values: [for (final s in state.liveTrend) s.pulseBpm],
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        HealthReferenceGuidance(
          kind: widget.plan.kind,
          nih: oxygenNihReference(sample.spo2Percent),
          manufacturer: beurer
              ? oxygenBeurerReference(sample.spo2Percent)
              : null,
          launcher: widget.linkLauncher,
        ),
        ..._earlierLiveSessions(context, state),
      ],
    );
  }

  /// Live sessions kept from earlier connections: each one's span and its
  /// least, most and average, newest first.
  List<Widget> _earlierLiveSessions(
    BuildContext context,
    HealthMeasurementState state,
  ) {
    final sessions = [...state.sessions]
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (sessions.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        title: Text('Earlier sessions (${sessions.length})'),
        children: [
          for (final session in sessions) _SessionCard(session: session),
        ],
      ),
      _savedFooter(context),
    ];
  }

  Widget _pulseHistory(
    BuildContext context,
    HealthMeasurementState state,
    bool beurer,
  ) {
    final sessions = [...state.sessions]
      ..sort((a, b) => b.startedAt.compareTo(a.startedAt));
    if (sessions.isEmpty) {
      if (state.phase == HealthSessionPhase.ready) {
        // The transfer ended and carried nothing: a spinner would wait
        // for sessions that are not coming.
        return const Text('The oximeter has no stored sessions.');
      }
      return state.phase == HealthSessionPhase.error
          ? const SizedBox.shrink()
          : const _ProgressMessage(
              message:
                  'No sessions received yet. Removing your finger starts '
                  'SYNC; from off, hold the function button for five seconds.',
            );
    }
    final latest = sessions.first;
    final chronological = [...sessions]
      ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${sessions.length} stored ${sessions.length == 1 ? 'session' : 'sessions'}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 10),
        _SessionCard(session: latest),
        if (chronological.length >= 2) ...[
          const SizedBox(height: 12),
          MeasurementTrendChart(
            title: 'SpO₂ session averages',
            unit: '%',
            series: [
              MeasurementTrendSeries(
                label: 'SpO₂',
                values: chronological
                    .map((session) => session.spo2Avg.toDouble())
                    .toList(),
              ),
            ],
          ),
          const SizedBox(height: 12),
          MeasurementTrendChart(
            title: 'Pulse session averages',
            unit: 'bpm',
            series: [
              MeasurementTrendSeries(
                label: 'Pulse',
                values: chronological
                    .map((session) => session.pulseAvgBpm.toDouble())
                    .toList(),
              ),
            ],
          ),
        ],
        const SizedBox(height: 14),
        HealthReferenceGuidance(
          kind: widget.plan.kind,
          nih: oxygenNihReference(latest.spo2Avg.toDouble()),
          manufacturer: beurer
              ? oxygenBeurerReference(latest.spo2Avg.toDouble())
              : null,
          launcher: widget.linkLauncher,
        ),
        if (sessions.length > 1) ...[
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text('Earlier sessions (${sessions.length - 1})'),
            children: [
              for (final session in sessions.skip(1))
                _SessionCard(session: session),
            ],
          ),
        ],
        if (state.skippedRecords > 0) ...[
          const SizedBox(height: 8),
          Text(
            state.skippedRecords == 1
                ? '1 stored record could not be read and was left out.'
                : '${state.skippedRecords} stored records could not be read '
                      'and were left out.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
        _savedFooter(context),
      ],
    );
  }

  /// Says where the readings above live, and lets the user remove them.
  Widget _savedFooter(BuildContext context) {
    if (!_session.hasSavedHistory) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Saved on this phone only.',
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: () => unawaited(_confirmClear(context)),
            child: const Text('Clear saved'),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClear(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear saved readings?'),
        content: const Text(
          'This removes the readings this app has kept for this device. '
          'The device\'s own memory is not changed, and an oximeter does not '
          'send a session twice.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _session.clearSaved();
  }

  Widget _bloodPressure(
    BuildContext context,
    HealthMeasurementState state,
    bool beurer,
  ) {
    final readings = [...state.bloodPressureReadings];
    if (readings.every(
      (reading) =>
          reading.measuredAt != null &&
          DateTime.tryParse(reading.measuredAt!) != null,
    )) {
      readings.sort((a, b) => b.measuredAt!.compareTo(a.measuredAt!));
    }
    if (readings.isEmpty) {
      return state.phase == HealthSessionPhase.error
          ? const SizedBox.shrink()
          : const _ProgressMessage(
              message:
                  'Waiting for a saved reading. Select a user on the '
                  'monitor, take a measurement and let the monitor save it.',
            );
    }
    final latest = readings.first;
    final trend = readings.where((reading) {
      return reading.measuredAt != null &&
          DateTime.tryParse(reading.measuredAt!) != null;
    }).toList()..sort((a, b) => a.measuredAt!.compareTo(b.measuredAt!));
    final trendGroups = <int?, List<BloodPressureReadingDto>>{};
    for (final reading in trend) {
      trendGroups.putIfAbsent(reading.userSlot, () => []).add(reading);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _BloodPressureReading(reading: latest, receivedAt: state.lastSampleAt),
        if (trend.length == readings.length && trend.length >= 2)
          for (final group in trendGroups.entries)
            if (group.value.length >= 2) ...[
              const SizedBox(height: 14),
              MeasurementTrendChart(
                title: group.key == null
                    ? trendGroups.length == 1
                          ? 'Recorded blood pressure'
                          : 'Recorded blood pressure · User not reported'
                    : 'Recorded blood pressure · User ${group.key}',
                unit: 'mmHg',
                series: [
                  MeasurementTrendSeries(
                    label: 'Systolic',
                    values: group.value
                        .map((reading) => reading.systolicMmhg)
                        .toList(),
                  ),
                  MeasurementTrendSeries(
                    label: 'Diastolic',
                    values: group.value
                        .map((reading) => reading.diastolicMmhg)
                        .toList(),
                  ),
                ],
              ),
            ],
        const SizedBox(height: 14),
        HealthReferenceGuidance(
          kind: widget.plan.kind,
          nih: bloodPressureNihReference(
            latest.systolicMmhg,
            latest.diastolicMmhg,
          ),
          manufacturer: beurer
              ? bloodPressureBeurerReference(
                  latest.systolicMmhg,
                  latest.diastolicMmhg,
                )
              : null,
          launcher: widget.linkLauncher,
        ),
        if (readings.length > 1) ...[
          const SizedBox(height: 8),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text('Earlier readings (${readings.length - 1})'),
            children: [
              for (final reading in readings.skip(1))
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _BloodPressureReading(reading: reading),
                ),
            ],
          ),
        ],
        _savedFooter(context),
      ],
    );
  }
}

class _LargeReading extends StatelessWidget {
  final String label;
  final String value;
  final String unit;

  const _LargeReading({
    required this.label,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: '$label $value $unit',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: text.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                value,
                style: text.displaySmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 5),
              Text(unit, style: text.titleSmall),
            ],
          ),
        ],
      ),
    );
  }
}

class _SessionCard extends StatelessWidget {
  final PulseOxSessionDto session;

  const _SessionCard({required this.session});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final start = DateTime.tryParse(session.startedAt);
    final end = DateTime.tryParse(session.endedAt);
    final seconds = start == null || end == null
        ? null
        : end.difference(start).inSeconds;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${_dateTime(session.startedAt)} – ${_clockTimeString(session.endedAt)}'
            '${seconds != null && seconds >= 0 ? ' · ${_duration(seconds)}' : ''}',
            style: text.labelMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 20,
            runSpacing: 8,
            children: [
              _SessionSummary(
                label: 'SpO₂ average',
                value: '${session.spo2Avg}%',
                range: '${session.spo2Min}–${session.spo2Max}% recorded',
              ),
              _SessionSummary(
                label: 'Pulse average',
                value: '${session.pulseAvgBpm} bpm',
                range:
                    '${session.pulseMinBpm}–${session.pulseMaxBpm} bpm recorded',
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SessionSummary extends StatelessWidget {
  final String label;
  final String value;
  final String range;

  const _SessionSummary({
    required this.label,
    required this.value,
    required this.range,
  });

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        Text(
          value,
          style: text.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          range,
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _BloodPressureReading extends StatelessWidget {
  final BloodPressureReadingDto reading;
  final DateTime? receivedAt;

  const _BloodPressureReading({required this.reading, this.receivedAt});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final measuredAt = reading.measuredAt == null
        ? null
        : DateTime.tryParse(reading.measuredAt!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          label:
              'Systolic ${_number(reading.systolicMmhg)}, diastolic '
              '${_number(reading.diastolicMmhg)} millimetres of mercury',
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Flexible(
                child: Text(
                  '${_number(reading.systolicMmhg)}/'
                  '${_number(reading.diastolicMmhg)}',
                  style: text.displaySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text('mmHg', style: text.titleMedium),
            ],
          ),
        ),
        Wrap(
          spacing: 16,
          runSpacing: 4,
          children: [
            if (reading.pulseBpm != null)
              Text('Pulse ${_number(reading.pulseBpm!)} bpm'),
            if (reading.meanArterialMmhg != null)
              Text('MAP ${_number(reading.meanArterialMmhg!)} mmHg'),
            if (reading.userSlot != null) Text('User slot ${reading.userSlot}'),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          measuredAt != null
              ? 'Measured ${_dateTime(reading.measuredAt!)}'
              : receivedAt != null
              ? 'Received by app ${_dateTimeValue(receivedAt!)}'
              : 'Timestamp not supplied by the monitor',
          style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
        ),
        if (reading.irregularHeartbeat != null)
          Text(
            reading.irregularHeartbeat!
                ? 'Irregular-heartbeat flag is set in this record'
                : 'Irregular-heartbeat flag is not set in this record',
            style: text.bodySmall?.copyWith(
              color: reading.irregularHeartbeat!
                  ? scheme.error
                  : scheme.onSurfaceVariant,
            ),
          ),
        if (reading.sufficientRest != null)
          Text(
            reading.sufficientRest!
                ? 'Monitor reports sufficient rest'
                : 'Monitor reports insufficient rest',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        if (reading.convertedFromKpa)
          Text(
            'Monitor record was in kPa; shown converted to mmHg.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
      ],
    );
  }
}

class _ProgressMessage extends StatelessWidget {
  final String message;

  const _ProgressMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(message)),
      ],
    );
  }
}

class _ErrorMessage extends StatelessWidget {
  final String message;

  const _ErrorMessage({required this.message});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: scheme.onErrorContainer),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: text.bodySmall?.copyWith(color: scheme.onErrorContainer),
            ),
          ),
        ],
      ),
    );
  }
}

String _number(double value) => value == value.roundToDouble()
    ? value.toStringAsFixed(0)
    : value.toStringAsFixed(1);

String _dateTime(String value) {
  final parsed = DateTime.tryParse(value);
  return parsed == null ? value : _dateTimeValue(parsed);
}

String _dateTimeValue(DateTime value) =>
    '${_monthNames[value.month - 1]} ${value.day}, ${value.year} · '
    '${_clockTime(value)}';

String _clockTimeString(String value) {
  final parsed = DateTime.tryParse(value);
  return parsed == null ? value : _clockTime(parsed);
}

String _clockTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}:'
    '${value.second.toString().padLeft(2, '0')}';

String _duration(int seconds) => seconds < 90
    ? '${seconds}s'
    : '${seconds ~/ 60}m ${(seconds % 60).toString().padLeft(2, '0')}s';

const _monthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

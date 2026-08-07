// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/find_device.dart';
import '../core/hex.dart';
import '../core/log.dart';
import '../models/ble_discovered_service.dart';
import '../providers/ble_provider.dart';
import '../providers/device_spec_match_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/ble_service.dart';

/// Hot/cold locator for a connected device: polls the connection's RSSI once
/// a second, shows a distance guess with the raw readings behind it, and —
/// when the device can beep or blink — offers one-tap alert buttons.
///
/// Reachable from the device screen's connected header, so the connection it
/// measures is owned by the screen underneath; this screen only reads RSSI
/// and writes alert commands, never connects or disconnects.
class FindDeviceScreen extends ConsumerStatefulWidget {
  final String deviceId;
  final String deviceName;
  final List<BleDiscoveredService> services;

  const FindDeviceScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    required this.services,
  });

  @override
  ConsumerState<FindDeviceScreen> createState() => _FindDeviceScreenState();
}

class _FindDeviceScreenState extends ConsumerState<FindDeviceScreen> {
  static const Duration _pollInterval = Duration(seconds: 1);

  /// RSSI read failures tolerated before the screen declares the signal
  /// lost. One failure can be transient; three in a row means the
  /// connection is gone (walked out of range, device powered off).
  static const int _maxConsecutiveFailures = 3;

  late final BleService _bleService;
  final RssiTracker _tracker = RssiTracker();
  Timer? _pollTimer;
  bool _readInFlight = false;
  int _consecutiveFailures = 0;
  bool _signalLost = false;

  /// Key of the alert action currently being sent, so exactly that button
  /// shows a busy state. Null when nothing is in flight.
  String? _busyActionKey;

  @override
  void initState() {
    super.initState();
    _bleService = ref.read(bleServiceProvider);
    _startPolling();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _consecutiveFailures = 0;
    _signalLost = false;
    _poll();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  Future<void> _poll() async {
    // Skip a tick rather than stack reads if the platform is slow to answer.
    if (_readInFlight || _signalLost) return;
    _readInFlight = true;
    try {
      final rssi = await _bleService.readRssi(widget.deviceId);
      if (!mounted) return;
      setState(() {
        _consecutiveFailures = 0;
        _tracker.add(rssi);
      });
    } catch (e) {
      if (!mounted) return;
      _consecutiveFailures += 1;
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
        Log.ble.warning(
            'find-device: $_consecutiveFailures consecutive RSSI read '
            'failures on ${widget.deviceId}; declaring the signal lost',
            error: e);
        setState(() {
          _signalLost = true;
          _pollTimer?.cancel();
          _pollTimer = null;
        });
      }
    } finally {
      _readInFlight = false;
    }
  }

  Future<void> _sendAction(FindAlertAction action, {bool stop = false}) async {
    final key = _actionKey(action, stop: stop);
    setState(() => _busyActionKey = key);
    try {
      final List<int> bytes;
      if (stop) {
        bytes = action.stopBytes!;
      } else if (action.commandName != null) {
        final encoded = await ref.read(specCodecProvider).encodeCommand(
          specYaml: action.specYaml,
          charUuid: action.charUuid,
          commandName: action.commandName!,
          params: const {},
        );
        bytes = encoded.toList();
      } else {
        bytes = action.bytes!;
      }
      await _bleService.writeCharacteristic(
        widget.deviceId,
        action.serviceUuid,
        action.charUuid,
        bytes,
      );
      if (!mounted) return;
      _showSnack(stop ? 'Stopped ${action.label}' : 'Sent ${action.label}');
    } catch (e) {
      if (!mounted) return;
      _showSnack(friendlyErrorText(
        e,
        context: 'find-device alert ${action.commandName ?? action.label}',
        fallback: 'The device did not accept the alert command.',
      ));
    } finally {
      if (mounted) setState(() => _busyActionKey = null);
    }
  }

  String _actionKey(FindAlertAction action, {required bool stop}) =>
      '${action.charUuid}:${action.commandName ?? action.label}'
      '${stop ? ':stop' : ''}';

  void _showSnack(String msg) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    // Same family key as DeviceControlPanel builds, so this watch hits the
    // already-resolved match instead of re-running matching.
    final serviceUuids = [
      for (final s in widget.services) normalizeUuid(s.uuid)
    ]..sort();
    final outcome = ref
        .watch(matchedDeviceSpecProvider(
          SpecMatchRequest(
            deviceId: widget.deviceId,
            deviceName: widget.deviceName,
            serviceUuids: serviceUuids,
          ),
        ))
        .valueOrNull;
    final match = outcome?.chosen;
    final actions = detectAlertActions(
      spec: match?.spec,
      specYaml: match?.yaml,
      services: widget.services,
    );

    return Scaffold(
      appBar: AppBar(
        // Two-line title, same treatment as the device screen: the action on
        // top, which device it applies to underneath.
        toolbarHeight: 72,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Find device'),
            Text(
              widget.deviceName,
              style: text.labelSmall?.copyWith(
                color: Theme.of(context).appBarTheme.foregroundColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Center(
              child: _ProximityGauge(
                tracker: _tracker,
                signalLost: _signalLost,
              ),
            ),
            const SizedBox(height: 16),
            if (!_signalLost) Center(child: _TrendLine(trend: _tracker.trend)),
            if (_signalLost) ...[
              const SizedBox(height: 8),
              _SignalLostCard(onRetry: () => setState(_startPolling)),
            ],
            const SizedBox(height: 24),
            _SignalDetailsCard(tracker: _tracker),
            const SizedBox(height: 24),
            // Actions render as soon as they're knowable: Immediate Alert
            // needs only the discovered services (available now), while
            // spec commands appear once the match resolves. Before the match
            // lands with zero sync actions there is nothing honest to say,
            // so the section waits rather than flashing the empty note.
            if (outcome != null || actions.isNotEmpty)
              _AlertActionsSection(
                actions: actions,
                busyActionKey: _busyActionKey,
                actionKeyOf: _actionKey,
                onSend: _sendAction,
              ),
            const SizedBox(height: 24),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 340),
                child: Text(
                  'Walk slowly and watch the signal — closer is stronger. '
                  'The distance is a rough guess from signal strength: '
                  'walls and bodies bend it, so treat it as hot/cold, not '
                  'a tape measure.',
                  textAlign: TextAlign.center,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    height: 1.5,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The hero readout: a ring that fills with signal strength, the distance
/// guess in the middle, and the qualitative bucket under it.
class _ProximityGauge extends StatelessWidget {
  final RssiTracker tracker;
  final bool signalLost;

  const _ProximityGauge({required this.tracker, required this.signalLost});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    final smoothed = tracker.smoothed;
    final fraction =
        signalLost || smoothed == null ? 0.0 : signalFraction(smoothed);
    final distance = tracker.estimatedDistanceMeters;

    final String headline;
    final String caption;
    if (signalLost) {
      headline = '—';
      caption = 'Signal lost';
    } else if (distance == null) {
      headline = '—';
      caption = 'Measuring...';
    } else {
      headline = formatApproxDistance(distance);
      caption = proximityLabel(distance);
    }

    return SizedBox(
      width: 232,
      height: 232,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: fraction),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        builder: (context, animated, child) => CustomPaint(
          painter: _GaugePainter(
            fraction: animated,
            track: scheme.outlineVariant.withValues(alpha: 0.45),
            accent: signalLost ? scheme.outline : scheme.secondary,
          ),
          child: child,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                headline,
                style: text.headlineMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                caption,
                style:
                    text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GaugePainter extends CustomPainter {
  final double fraction;
  final Color track;
  final Color accent;

  _GaugePainter({
    required this.fraction,
    required this.track,
    required this.accent,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 10;
    final rect = Rect.fromCircle(center: center, radius: radius);

    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..color = track,
    );

    if (fraction <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      fraction * 2 * math.pi,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10
        ..strokeCap = StrokeCap.round
        ..color = accent,
    );
  }

  @override
  bool shouldRepaint(_GaugePainter old) =>
      old.fraction != fraction || old.track != track || old.accent != accent;
}

/// Hot/cold arrow under the gauge, steering by the recent RSSI slope.
class _TrendLine extends StatelessWidget {
  final RssiTrend trend;

  const _TrendLine({required this.trend});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label, color) = switch (trend) {
      RssiTrend.closer => (
          Icons.trending_up,
          'Getting closer',
          scheme.secondary
        ),
      RssiTrend.farther => (
          Icons.trending_down,
          'Getting farther',
          scheme.onSurfaceVariant
        ),
      RssiTrend.steady => (
          Icons.trending_flat,
          'Signal steady',
          scheme.onSurfaceVariant
        ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        Text(
          label,
          style: Theme.of(context)
              .textTheme
              .bodyMedium
              ?.copyWith(color: color, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }
}

/// The raw numbers behind the guess. The gauge is the interpretation; this
/// card is the evidence, in dBm, so nothing about the estimate is a black
/// box.
class _SignalDetailsCard extends StatelessWidget {
  final RssiTracker tracker;

  const _SignalDetailsCard({required this.tracker});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    String dbm(num? v) => v == null ? '—' : '${v.round()} dBm';
    final distance = tracker.estimatedDistanceMeters;

    final rows = <(String, String)>[
      ('Live signal', dbm(tracker.latest)),
      ('Smoothed', dbm(tracker.smoothed)),
      ('Strongest', dbm(tracker.strongest)),
      ('Weakest', dbm(tracker.weakest)),
      ('Samples', tracker.hasSamples ? '${tracker.sampleCount}' : '—'),
      (
        'Distance guess',
        distance == null ? '—' : formatApproxDistance(distance)
      ),
    ];

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Signal (raw values)',
            style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 12),
          if (tracker.history.length >= 2) ...[
            _RssiSparkline(history: tracker.history),
            const SizedBox(height: 12),
          ],
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: text.bodyMedium
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ),
                  Text(
                    value,
                    style: text.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      // Tabular figures stop the column jittering as values
                      // update every second.
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Last ~30 raw readings as bars, newest on the right — the walking user's
/// hot/cold history at a glance.
class _RssiSparkline extends StatelessWidget {
  final List<int> history;

  const _RssiSparkline({required this.history});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SizedBox(
      height: 36,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (var i = 0; i < history.length; i++)
            Container(
              width: 4,
              height: 6 + signalFraction(history[i].toDouble()) * 30,
              margin: const EdgeInsets.only(right: 2),
              decoration: BoxDecoration(
                color: scheme.secondary.withValues(
                  alpha: i == history.length - 1 ? 1.0 : 0.55,
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        ],
      ),
    );
  }
}

/// Buttons that make the device announce itself. Sound/flash capability
/// comes from the matched spec's commands or the standard Immediate Alert
/// service — see [detectAlertActions].
class _AlertActionsSection extends StatelessWidget {
  final List<FindAlertAction> actions;
  final String? busyActionKey;
  final String Function(FindAlertAction, {required bool stop}) actionKeyOf;
  final Future<void> Function(FindAlertAction, {bool stop}) onSend;

  const _AlertActionsSection({
    required this.actions,
    required this.busyActionKey,
    required this.actionKeyOf,
    required this.onSend,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Make it noticeable',
          style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 10),
        if (actions.isEmpty)
          Text(
            'This device doesn\'t declare a sound or flash command this app '
            'can trigger, so listen for it the analog way.',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          )
        else
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final action in actions) ...[
                FilledButton.tonalIcon(
                  onPressed:
                      busyActionKey != null ? null : () => onSend(action),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 48),
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                  ),
                  icon: Icon(_iconFor(action.kind), size: 20),
                  label: Text(
                    busyActionKey == actionKeyOf(action, stop: false)
                        ? 'Sending...'
                        : action.label,
                  ),
                ),
                if (action.stopBytes != null)
                  OutlinedButton(
                    onPressed: busyActionKey != null
                        ? null
                        : () => onSend(action, stop: true),
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(0, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                    ),
                    child: Text(
                      busyActionKey == actionKeyOf(action, stop: true)
                          ? 'Stopping...'
                          : 'Stop ${action.label.toLowerCase()}',
                    ),
                  ),
              ],
            ],
          ),
      ],
    );
  }

  IconData _iconFor(FindAlertKind kind) => switch (kind) {
        FindAlertKind.sound => Icons.volume_up,
        FindAlertKind.flash => Icons.flashlight_on,
        FindAlertKind.alert => Icons.notifications_active,
      };
}

/// Shown when RSSI reads keep failing: the connection is very likely gone,
/// and pretending the last reading is live would send the user hunting a
/// stale number.
class _SignalLostCard extends StatelessWidget {
  final VoidCallback onRetry;

  const _SignalLostCard({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Icon(Icons.bluetooth_disabled, color: scheme.onTertiaryContainer),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Signal lost — the connection may have dropped. Move back '
              'toward where the device was and retry, or go back to '
              'reconnect.',
              style: text.bodySmall?.copyWith(
                color: scheme.onTertiaryContainer,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              minimumSize: const Size(0, 44),
              foregroundColor: scheme.onTertiaryContainer,
            ),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

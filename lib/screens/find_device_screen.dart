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

  /// The alert this screen raised that is (probably) still sounding, kept so
  /// leaving the screen can silence it. Null when nothing was raised, when
  /// it has been stopped, or when the action has no stop payload.
  FindAlertAction? _ringing;

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
    // Clear the in-flight latch too: a read left outstanding when polling
    // stopped would otherwise make every tick after Retry return at the
    // guard below, leaving a screen that looks live and never updates.
    _readInFlight = false;
    // Samples from before the gap describe a different place, possibly
    // minutes ago. Blending them in would show the pre-loss distance as if
    // live and can point the trend arrow backwards while the user walks.
    _tracker.reset();
    _poll();
    _pollTimer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  Future<void> _poll() async {
    // Skip a tick rather than stack reads if the platform is slow to answer.
    if (_readInFlight || _signalLost) return;
    _readInFlight = true;
    try {
      // Bounded independently of the transport: flutter_blue_plus takes a
      // process-wide BLE mutex whose *wait* is untimed, so a wedged platform
      // call elsewhere in the app could otherwise hold this latch forever
      // and silently freeze the readout on its last value.
      final rssi = await _bleService
          .readRssi(widget.deviceId)
          .timeout(_pollInterval * 2);
      if (!mounted) return;
      setState(() {
        _consecutiveFailures = 0;
        _tracker.add(rssi);
      });
    } catch (e) {
      if (!mounted) return;
      _consecutiveFailures += 1;
      // Logged on every failure, not just the third: an intermittent
      // fail/succeed pattern never reaches the threshold, and without these
      // lines it leaves no trace at all.
      Log.ble.warning(
          'find-device: RSSI read $_consecutiveFailures/'
          '$_maxConsecutiveFailures failed on ${widget.deviceId}',
          error: e);
      if (_consecutiveFailures >= _maxConsecutiveFailures) {
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
    // setState only schedules a rebuild, while onTap fires synchronously
    // during pointer dispatch — so two taps in one frame both see the stale
    // enabled state. Without this guard the second overwrites the first's
    // busy key and the first's completion re-enables every button while the
    // second write is still outstanding. Stop is exempt: silencing a device
    // that is already sounding must never queue behind another write.
    if (_busyActionKey != null && !stop) return;
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
      // Remember that this device is (probably) about to make noise BEFORE
      // the write goes out: recording it after meant a dispose during the
      // in-flight write saw no ring to silence, and the alert latched with
      // its only stop control gone. Pessimistic in both directions — a ring
      // write may have landed even when it reports an error, and a FAILED
      // stop must keep the ring on record so dispose still tries to silence
      // it; only a stop that succeeds clears it. A redundant stop write to
      // a quiet device is harmless, and the BLE stack serialises writes, so
      // a dispose-chained stop queues behind whatever is in flight.
      if (!stop && action.stopBytes != null) _ringing = action;
      await _bleService.writeCharacteristic(
        widget.deviceId,
        action.serviceUuid,
        action.charUuid,
        bytes,
      );
      if (stop) _ringing = null;
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

  /// Identity of one button. Includes the service UUID because
  /// [detectAlertActions] deliberately keys actions by the
  /// service+characteristic pair — a characteristic UUID alone can name two
  /// different endpoints, and collapsing them here would light up both
  /// buttons' busy state for one write.
  String _actionKey(FindAlertAction action, {required bool stop}) =>
      '${action.serviceUuid}/${action.charUuid}:'
      '${action.commandName ?? action.label}${stop ? ':stop' : ''}';

  void _showSnack(String msg) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    // An Immediate Alert level latches until it is written back to 0 — so a
    // key finder raised from this screen keeps buzzing after the user walks
    // away from it, and the only stop control is the one they just left.
    // Fire-and-forget (dispose can't await) and best-effort: if the link is
    // already gone, the device stopped anyway.
    final ringing = _ringing;
    _ringing = null;
    if (ringing?.stopBytes != null) {
      unawaited(
        _bleService
            .writeCharacteristic(
              widget.deviceId,
              ringing!.serviceUuid,
              ringing.charUuid,
              ringing.stopBytes!,
            )
            .catchError((Object _) {}),
      );
    }
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
    final matchAsync = ref.watch(matchedDeviceSpecProvider(
      SpecMatchRequest(
        deviceId: widget.deviceId,
        deviceName: widget.deviceName,
        serviceUuids: serviceUuids,
      ),
    ));
    // hasValue||hasError, not `valueOrNull != null`: a match that FAILED
    // (spec assets unreadable, pack load error) also has a null value, and
    // keying visibility off that alone made the whole section — including
    // the honest "no alert commands" note — silently vanish. hasValue also
    // survives the AsyncLoading of a recompute, so the section doesn't
    // flicker when a spec choice is saved.
    final matchSettled = matchAsync.hasValue || matchAsync.hasError;
    final outcome = matchAsync.valueOrNull;
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
            if (_signalLost) ...[
              const SizedBox(height: 8),
              _SignalLostCard(onRetry: () => setState(_startPolling)),
            ] else
              Center(child: _TrendLine(trend: _tracker.trend)),
            const SizedBox(height: 24),
            // signalLost is passed, not just read above: the card must stop
            // labelling the frozen last reading "Live signal" the moment the
            // gauge says the signal is gone, or it sends the user hunting a
            // number that is minutes old.
            _SignalDetailsCard(tracker: _tracker, signalLost: _signalLost),
            const SizedBox(height: 24),
            // Actions render as soon as they're knowable: Immediate Alert
            // needs only the discovered services (available now), while
            // spec commands appear once matching settles. Before it settles
            // with zero sync actions there is nothing honest to say, so the
            // section waits rather than flashing the empty note.
            if (matchSettled || actions.isNotEmpty)
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

    // The ring is a fixed 232pt circle, but the readout inside it scales with
    // the platform font size — at 2x it overflowed the box and the distance
    // and proximity label, the whole point of the screen, rendered behind
    // overflow stripes. Growing the box with the text keeps the ring circular
    // and the readout intact.
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final size = 232.0 * (scale > 1 ? scale : 1);
    // Respect the platform reduce-motion setting, as RadarScanner does: a
    // gauge that re-eases every second is exactly the motion that setting is
    // asking us to stop.
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    return SizedBox(
      width: size,
      height: size,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: fraction),
        duration:
            reduceMotion ? Duration.zero : const Duration(milliseconds: 350),
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
          child: Padding(
            // Keep the text off the ring itself at every scale.
            padding: EdgeInsets.symmetric(horizontal: size * 0.16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  headline,
                  textAlign: TextAlign.center,
                  style: text.headlineMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  caption,
                  textAlign: TextAlign.center,
                  style:
                      text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ],
            ),
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
      // "Steady" is a verdict; before there are samples to compare, the
      // honest line is that we're still collecting them.
      RssiTrend.unknown => (
          Icons.more_horiz,
          'Reading signal...',
          scheme.onSurfaceVariant
        ),
    };
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: 6),
        // Flexible so the label wraps instead of overflowing the row at
        // large text scales — at 2x it ran ~70px past a 360dp screen.
        Flexible(
          child: Text(
            label,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: color, fontWeight: FontWeight.w600),
          ),
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

  /// When true the readings are frozen at whatever the last successful poll
  /// saw, so the live rows report "—" and the section says the readings are
  /// stale rather than presenting them as current.
  final bool signalLost;

  const _SignalDetailsCard({required this.tracker, required this.signalLost});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    String dbm(num? v) => v == null ? '—' : '${v.round()} dBm';
    final distance = tracker.estimatedDistanceMeters;

    final rows = <(String, String)>[
      // The two rows that claim to be current go blank once the signal is
      // lost; the session's extremes and sample count stay, since they are
      // history and never claimed otherwise.
      ('Live signal', signalLost ? '—' : dbm(tracker.latest)),
      ('Smoothed', signalLost ? '—' : dbm(tracker.smoothed)),
      ('Strongest', dbm(tracker.strongest)),
      ('Weakest', dbm(tracker.weakest)),
      ('Samples', tracker.hasSamples ? '${tracker.sampleCount}' : '—'),
      (
        'Distance guess',
        signalLost || distance == null ? '—' : formatApproxDistance(distance)
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
                    // Never disabled by another send in flight. A ring write
                    // that is slow to ack leaves the device already
                    // sounding, and greying out the only control that
                    // silences it is the worst possible moment to do so.
                    onPressed: busyActionKey == actionKeyOf(action, stop: true)
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

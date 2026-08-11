// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../providers/hub_control_provider.dart';
import '../services/hub_http_client.dart';
import '../services/hue_pairing_service.dart';

/// The link-button pairing flow as a modal sheet: "press the round button",
/// a countdown for the ~45 s polling window, and the three ways it ends —
/// paired (pops with the [PairingResult]), timed out (offer another window),
/// or dismissed (pops with null; the poll is cancelled).
///
/// The sheet does not persist anything: the caller stores what the bridge
/// issued, keyed by bridgeid. That keeps this widget a pure view of the
/// pairing service, and the service testable without a keychain.
class HubPairingSheet extends ConsumerStatefulWidget {
  final String specYaml;
  final String host;
  final String bridgeId;

  /// The polling window and cadence. Real callers keep the service defaults;
  /// tests shrink them because the deadline runs on wall-clock time.
  final Duration window;
  final Duration interval;

  const HubPairingSheet({
    super.key,
    required this.specYaml,
    required this.host,
    required this.bridgeId,
    this.window = HuePairingService.defaultWindow,
    this.interval = HuePairingService.defaultInterval,
  });

  /// Show the sheet and run the flow. Null means dismissed or failed —
  /// nothing was issued.
  static Future<PairingResult?> show(
    BuildContext context, {
    required String specYaml,
    required String host,
    required String bridgeId,
  }) =>
      showModalBottomSheet<PairingResult>(
        context: context,
        // Dismissing IS the cancel gesture; the sheet cleans up its poll.
        isDismissible: true,
        showDragHandle: true,
        builder: (_) => HubPairingSheet(
          specYaml: specYaml,
          host: host,
          bridgeId: bridgeId,
        ),
      );

  @override
  ConsumerState<HubPairingSheet> createState() => _HubPairingSheetState();
}

class _HubPairingSheetState extends ConsumerState<HubPairingSheet> {
  Completer<void>? _cancelled;
  Timer? _ticker;
  int _secondsLeft = 0;
  bool _polling = false;
  String? _error;
  bool _timedOut = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _finishCancel();
    super.dispose();
  }

  void _finishCancel() {
    final cancelled = _cancelled;
    if (cancelled != null && !cancelled.isCompleted) cancelled.complete();
  }

  Future<void> _start() async {
    _finishCancel();
    final cancelled = Completer<void>();
    _cancelled = cancelled;
    _ticker?.cancel();
    setState(() {
      _polling = true;
      _error = null;
      _timedOut = false;
      _secondsLeft = widget.window.inSeconds;
    });
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsLeft = _secondsLeft > 0 ? _secondsLeft - 1 : 0);
    });

    try {
      final result = await ref.read(huePairingServiceProvider).pair(
            specYaml: widget.specYaml,
            host: widget.host,
            bridgeId: widget.bridgeId,
            window: widget.window,
            interval: widget.interval,
            cancelled: cancelled.future,
          );
      if (mounted) Navigator.of(context).pop(result);
    } on PairingTimeoutException {
      if (mounted) {
        setState(() {
          _polling = false;
          _timedOut = true;
        });
      }
    } on PairingCancelledException {
      // The dismissal already closed the sheet; nothing to show.
    } catch (e) {
      if (mounted) {
        setState(() {
          _polling = false;
          _error = friendlyErrorText(
            e,
            context: 'pairing',
            fallback: e is HubTlsException
                ? 'The bridge failed its security check — see the device '
                    'details for what changed.'
                : 'Could not reach the bridge. Check that it is powered '
                    'and on this network.',
          );
        });
      }
    } finally {
      _ticker?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;

    return SafeArea(
      // Scrollable so the tallest state (timeout, with its retry button)
      // fits whatever height the sheet is granted — small phones and large
      // accessibility fonts included.
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Pair with this bridge',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(
              'Press the round link button on top of the Hue Bridge. '
              'That press is the whole authorization — no account, and the '
              'pairing keeps working without Philips.',
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            if (_polling) ...[
              const Center(
                child: SizedBox(
                  width: 56,
                  height: 56,
                  child: CircularProgressIndicator(strokeWidth: 3),
                ),
              ),
              const SizedBox(height: 12),
              Center(
                child: Text(
                  'Waiting for the button… ${_secondsLeft}s',
                  style: text.bodyMedium,
                ),
              ),
            ] else if (_timedOut) ...[
              Icon(Icons.timer_off_outlined,
                  size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 8),
              Center(
                child: Text("Didn't see the button press.",
                    style: text.bodyMedium),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => unawaited(_start()),
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ] else if (_error != null) ...[
              Text(_error!,
                  style: text.bodyMedium?.copyWith(color: scheme.error)),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: () => unawaited(_start()),
                icon: const Icon(Icons.refresh),
                label: const Text('Try again'),
              ),
            ],
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        ),
      ),
    );
  }
}

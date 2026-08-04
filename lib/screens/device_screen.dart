// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import '../providers/ble_provider.dart';
import '../providers/ha_provider.dart';
import '../providers/saved_device_provider.dart';
import '../services/ble_service.dart';
import '../widgets/device_control_panel.dart';
import '../widgets/radar_scanner.dart';
import '../core/error_text.dart';

enum _ScreenState { connecting, discovering, ready, error, disconnected }

class DeviceScreen extends ConsumerStatefulWidget {
  final IoTDevice device;

  const DeviceScreen({super.key, required this.device});

  @override
  ConsumerState<DeviceScreen> createState() => _DeviceScreenState();
}

class _DeviceScreenState extends ConsumerState<DeviceScreen> {
  _ScreenState _state = _ScreenState.connecting;
  String? _error;
  List<BleDiscoveredService> _services = [];
  late final BleService _bleService;
  StreamSubscription<BleConnectionState>? _connSub;
  // True once connect() has established a link we still own. Guards teardown so
  // exactly one disconnect() runs per established connection.
  bool _connected = false;

  @override
  void initState() {
    super.initState();
    _bleService = ref.read(bleServiceProvider);
    _connect();
  }

  Future<void> _connect() async {
    // Drop any connection this screen still owns + cached services first, so a
    // retry or reconnect doesn't run against an already-connected peripheral
    // with a stale service cache.
    await _cleanupConnection();

    setState(() {
      _state = _ScreenState.connecting;
      _error = null;
    });

    try {
      await _bleService.connect(widget.device.id);
      // We now own a live connection — record it BEFORE the mounted check so an
      // unmount-during-connect still tears it down instead of leaking it.
      _connected = true;

      // If the screen was disposed while connect() was in flight, dispose()
      // couldn't disconnect (the peripheral wasn't connected yet); clean up the
      // now-live connection here instead of leaving it ownerless.
      if (!mounted) {
        await _cleanupConnection();
        return;
      }
      // Give the HA forwarder a friendly name for this device's entities.
      ref
          .read(haForwarderProvider)
          .noteDeviceName(widget.device.id, widget.device.displayName);

      // Persist on a *successful* connect, not on discovery: History should
      // list devices the user actually paired with, not everything that ever
      // appeared in a scan. Fire-and-forget — a preferences write failure must
      // not take down a live connection.
      unawaited(
        ref
            .read(savedDevicesProvider.notifier)
            .touch(
              id: widget.device.id,
              name: widget.device.displayName,
              seenAt: DateTime.now(),
            )
            .catchError((Object _) {}),
      );
      _watchConnection();
      setState(() => _state = _ScreenState.discovering);

      final services = await _bleService.discoverServices(widget.device.id);

      // Same hazard as above: discovery can return after unmount.
      if (!mounted) {
        await _cleanupConnection();
        return;
      }
      setState(() {
        _services = services;
        _state = _ScreenState.ready;
      });
    } catch (e) {
      // Drop any half-open link + cached services so the error path / Retry
      // starts from a clean slate (no-op if we never connected).
      await _cleanupConnection();
      if (mounted) {
        setState(() {
          _error = friendlyErrorText(
            e,
            context: 'connect/discover ${widget.device.id}',
            fallback: 'Could not connect to this device. Move closer, check '
                'it is powered on, then try again.',
          );
          _state = _ScreenState.error;
        });
      }
    }
  }

  /// Tear down the connection this screen owns: cancel the connection-state
  /// subscription and, if we established a link, disconnect it. Idempotent via
  /// the [_connected] guard so the unmount-cleanup and dispose() paths can't
  /// double-disconnect. Shared by the unmounted, discovery-failure, retry, and
  /// dispose paths so they all tear down identically.
  Future<void> _cleanupConnection() async {
    // Cancel is fire-and-forget: it synchronously stops delivery, and awaiting
    // subscription teardown can stall inside the widget-test fake zone.
    unawaited(_connSub?.cancel());
    _connSub = null;
    if (_connected) {
      _connected = false;
      await _bleService.disconnect(widget.device.id).catchError((Object _) {});
    }
  }

  /// Observe the live connection state so an unexpected disconnect flips the
  /// screen to a disconnected state (controls hidden, reconnect offered)
  /// instead of leaving stale controls that fail one-by-one.
  void _watchConnection() {
    _connSub?.cancel();
    _connSub = _bleService.connectionState(widget.device.id).listen((state) {
      if (!mounted) return;
      final lostConnection = state == BleConnectionState.disconnected ||
          state == BleConnectionState.disconnecting;
      if (lostConnection &&
          (_state == _ScreenState.ready ||
              _state == _ScreenState.discovering)) {
        setState(() => _state = _ScreenState.disconnected);
      }
    });
  }

  @override
  void dispose() {
    // Fire-and-forget teardown (dispose() can't await). Only disconnect a link
    // we actually own: if connect() is still in flight, _connected is false and
    // _connect()'s own !mounted branch will disconnect once it resolves, so we
    // neither leak the pending connection nor double-disconnect here.
    unawaited(_connSub?.cancel());
    _connSub = null;
    if (_connected) {
      _connected = false;
      // unawaited() does not swallow errors, so attach a catchError to keep a
      // throw during teardown from surfacing as an unhandled async error.
      unawaited(
        _bleService.disconnect(widget.device.id).catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        // The default 56pt toolbar clips a two-line title, which silently hid
        // the status row.
        toolbarHeight: 72,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.device.displayName),
            // A live status line under the name: connection state was
            // previously only inferable from whichever body state happened to
            // be on screen.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 7,
                  height: 7,
                  margin: const EdgeInsets.only(right: 6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Theme.of(context).appBarTheme.foregroundColor,
                  ),
                ),
                Text(
                  _statusLabel,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: Theme.of(context).appBarTheme.foregroundColor,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
      body: _buildBody(),
    );
  }

  String get _statusLabel => switch (_state) {
        _ScreenState.connecting => 'Connecting',
        _ScreenState.discovering => 'Discovering services',
        _ScreenState.ready => 'Connected',
        _ScreenState.error => 'Connection failed',
        _ScreenState.disconnected => 'Disconnected',
      };

  Widget _buildBody() {
    switch (_state) {
      // Pairing is two distinct steps and can take several seconds on real
      // hardware, so it gets a step list rather than an unlabelled spinner:
      // when it stalls, the user can see *which* step stalled.
      case _ScreenState.connecting:
        return const _PairingProgress(
          label: 'Connecting...',
          step: 0,
          deviceName: null,
        );

      case _ScreenState.discovering:
        return const _PairingProgress(
          label: 'Discovering services...',
          step: 1,
          deviceName: null,
        );

      case _ScreenState.error:
        return _StatusState(
          icon: Icons.error_outline,
          severity: _Severity.error,
          title: 'Connection failed',
          message: _error ?? 'Connection failed',
          actionLabel: 'Retry',
          onAction: _connect,
        );

      case _ScreenState.disconnected:
        return _StatusState(
          icon: Icons.bluetooth_disabled,
          severity: _Severity.warning,
          title: 'Device disconnected',
          message: 'The connection was lost. Move closer or check the device '
              'is powered on, then reconnect.',
          actionLabel: 'Reconnect',
          onAction: _connect,
        );

      case _ScreenState.ready:
        return Column(
          children: [
            _ConnectedHeader(
              name: widget.device.displayName,
              serviceCount: _services.length,
              onDisconnect: () async {
                await _cleanupConnection();
                if (!mounted) return;
                setState(() => _state = _ScreenState.disconnected);
              },
            ),
            Expanded(
              child: DeviceControlPanel(
                deviceId: widget.device.id,
                deviceName: widget.device.displayName,
                services: _services,
              ),
            ),
          ],
        );
    }
  }
}

/// Live summary above the controls: what's connected, how much was discovered,
/// and a way out.
///
/// Previously the only cue that a device was connected was the presence of
/// controls; disconnecting meant backing out of the screen.
class _ConnectedHeader extends StatelessWidget {
  final String name;
  final int serviceCount;
  final Future<void> Function() onDisconnect;

  const _ConnectedHeader({
    required this.name,
    required this.serviceCount,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(Icons.memory, color: scheme.onSecondaryContainer),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Container(
                      width: 7,
                      height: 7,
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.secondary,
                      ),
                    ),
                    Text(
                      'Connected  ·  $serviceCount service'
                      '${serviceCount == 1 ? '' : 's'}',
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: onDisconnect,
            style: TextButton.styleFrom(minimumSize: const Size(0, 44)),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
  }
}

/// Two-step pairing progress: connect, then discover services.
class _PairingProgress extends StatelessWidget {
  final String label;
  final int step;
  final String? deviceName;

  const _PairingProgress({
    required this.label,
    required this.step,
    required this.deviceName,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    const steps = ['Connecting', 'Discovering services'];

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const RadarScanner(scanning: true, size: 168),
            const SizedBox(height: 32),
            Text(
              label,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              'Keep the device powered on and nearby.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 28),
            for (var i = 0; i < steps.length; i++)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Done steps get a check, the active step a filled dot, and
                    // pending steps a hollow ring — readable without colour.
                    if (i < step)
                      Icon(Icons.check_circle,
                          size: 18, color: scheme.secondary)
                    else if (i == step)
                      SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: scheme.secondary,
                        ),
                      )
                    else
                      Icon(Icons.circle_outlined,
                          size: 18, color: scheme.outlineVariant),
                    const SizedBox(width: 10),
                    Text(
                      steps[i],
                      style: text.bodyMedium?.copyWith(
                        color: i <= step
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                        fontWeight:
                            i == step ? FontWeight.w600 : FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum _Severity { error, warning }

/// Full-screen connection status with a recovery action.
///
/// Mirrors the scan screen's empty-state layout so connect failures, drops and
/// empty scans all read as the same kind of moment instead of three different
/// one-off layouts. Severity picks the semantic colour role, so the states stay
/// legible in dark mode where the previous hardcoded red/orange/grey did not.
class _StatusState extends StatelessWidget {
  final IconData icon;
  final _Severity severity;
  final String title;
  final String message;
  final String actionLabel;
  final VoidCallback onAction;

  const _StatusState({
    required this.icon,
    required this.severity,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final isError = severity == _Severity.error;
    final disc = isError ? scheme.errorContainer : scheme.tertiaryContainer;
    final accent = isError ? scheme.onErrorContainer : scheme.onTertiaryContainer;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(color: disc, shape: BoxShape.circle),
              child: Icon(icon, size: 44, color: accent),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              textAlign: TextAlign.center,
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: text.bodyMedium?.copyWith(
                  color: scheme.onSurfaceVariant,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 28),
            ElevatedButton.icon(
              onPressed: onAction,
              icon: const Icon(Icons.refresh),
              label: Text(actionLabel),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size(0, 48),
                padding: const EdgeInsets.symmetric(horizontal: 24),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

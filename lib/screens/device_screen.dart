// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import '../providers/ble_provider.dart';
import '../providers/ha_provider.dart';
import '../services/ble_service.dart';
import '../widgets/device_control_panel.dart';
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
      appBar: AppBar(title: Text(widget.device.displayName)),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    switch (_state) {
      case _ScreenState.connecting:
        return const _CenteredProgress('Connecting...');

      case _ScreenState.discovering:
        return const _CenteredProgress('Discovering services...');

      case _ScreenState.error:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(_error ?? 'Connection failed',
                    style: const TextStyle(color: Colors.red),
                    textAlign: TextAlign.center),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        );

      case _ScreenState.disconnected:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.bluetooth_disabled,
                    size: 64, color: Colors.orange),
                const SizedBox(height: 16),
                const Text('Device disconnected',
                    style: TextStyle(fontSize: 18)),
                const SizedBox(height: 8),
                const Text(
                    'The connection was lost. Move closer or check the device '
                    'is powered on, then reconnect.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.grey)),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: _connect,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Reconnect'),
                ),
              ],
            ),
          ),
        );

      case _ScreenState.ready:
        return DeviceControlPanel(
          deviceId: widget.device.id,
          deviceName: widget.device.displayName,
          services: _services,
        );
    }
  }
}

class _CenteredProgress extends StatelessWidget {
  final String label;
  const _CenteredProgress(this.label);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 16),
          Text(label),
        ],
      ),
    );
  }
}

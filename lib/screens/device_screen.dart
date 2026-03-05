// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/ble_discovered_service.dart';
import '../models/iot_device.dart';
import '../providers/ble_provider.dart';
import '../services/ble_service.dart';
import '../widgets/device_control_panel.dart';

enum _ScreenState { connecting, discovering, ready, error }

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

  @override
  void initState() {
    super.initState();
    _connect();
  }

  Future<void> _connect() async {
    final bleService = ref.read(bleServiceProvider);

    setState(() {
      _state = _ScreenState.connecting;
      _error = null;
    });

    try {
      await bleService.connect(widget.device.id);

      if (!mounted) return;
      setState(() => _state = _ScreenState.discovering);

      final services = await bleService.discoverServices(widget.device.id);

      if (!mounted) return;
      setState(() {
        _services = services;
        _state = _ScreenState.ready;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _state = _ScreenState.error;
        });
      }
    }
  }

  @override
  void dispose() {
    ref.read(bleServiceProvider).disconnect(widget.device.id);
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
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Connecting...'),
            ],
          ),
        );

      case _ScreenState.discovering:
        return const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Discovering services...'),
            ],
          ),
        );

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

      case _ScreenState.ready:
        return DeviceControlPanel(
          deviceId: widget.device.id,
          deviceName: widget.device.displayName,
          services: _services,
        );
    }
  }
}

// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants.dart';
import '../providers/ble_provider.dart';
import '../services/device_manager.dart';
import 'device_screen.dart';

class ScanScreen extends ConsumerStatefulWidget {
  const ScanScreen({super.key});

  @override
  ConsumerState<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends ConsumerState<ScanScreen> {
  final DeviceManager _deviceManager = DeviceManager();
  bool _isScanning = false;
  String? _error;

  Future<void> _startScan() async {
    final bleService = ref.read(bleServiceProvider);

    setState(() {
      _isScanning = true;
      _error = null;
      _deviceManager.clear();
    });

    try {
      await for (final device in bleService.scan()) {
        if (!mounted) return;
        setState(() {
          _deviceManager.addOrUpdate(device);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isScanning = false;
        });
      }
    }
  }

  @override
  void dispose() {
    ref.read(bleServiceProvider).stopScan();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppConstants.appName),
        actions: [
          if (isMockMode)
            const Padding(
              padding: EdgeInsets.only(right: 12),
              child: Chip(label: Text('MOCK')),
            ),
        ],
      ),
      body: _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isScanning ? null : _startScan,
        icon: _isScanning
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: Colors.white),
              )
            : const Icon(Icons.search),
        label: Text(_isScanning ? 'Scanning...' : 'Scan'),
      ),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              style: const TextStyle(color: Colors.red),
              textAlign: TextAlign.center),
        ),
      );
    }

    if (_deviceManager.count == 0) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.bluetooth_searching, size: 64),
            SizedBox(height: 16),
            Text('Scan for BLE Devices', style: TextStyle(fontSize: 18)),
            SizedBox(height: 8),
            Text(AppConstants.appTagline,
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    final devices = _deviceManager.devices;
    return ListView.builder(
      itemCount: devices.length,
      itemBuilder: (context, index) {
        final device = devices[index];
        return ListTile(
          leading: Icon(
            device.isConnectable ? Icons.bluetooth : Icons.bluetooth_disabled,
            color: device.isNearby ? Colors.blue : Colors.grey,
          ),
          title: Text(device.displayName),
          subtitle: Text('RSSI: ${device.rssi} dBm'),
          trailing:
              device.isConnectable ? const Icon(Icons.chevron_right) : null,
          onTap: device.isConnectable
              ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => DeviceScreen(device: device)),
                  )
              : null,
        );
      },
    );
  }
}

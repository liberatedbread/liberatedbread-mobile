// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import '../providers/ble_provider.dart';

/// Raw characteristic widget — shows hex values and provides basic read/write.
/// This is the fallback for characteristics not matched to a device spec.
/// Once specs are connected via Rust, typed widgets (toggles, sliders, etc.)
/// will be rendered instead.
class RawCharacteristicWidget extends ConsumerStatefulWidget {
  final String deviceId;
  final String serviceUuid;
  final BleDiscoveredCharacteristic characteristic;

  const RawCharacteristicWidget({
    super.key,
    required this.deviceId,
    required this.serviceUuid,
    required this.characteristic,
  });

  @override
  ConsumerState<RawCharacteristicWidget> createState() =>
      _RawCharacteristicWidgetState();
}

class _RawCharacteristicWidgetState
    extends ConsumerState<RawCharacteristicWidget> {
  List<int>? _value;
  bool _loading = false;
  String? _error;
  StreamSubscription<List<int>>? _notifySub;

  @override
  void initState() {
    super.initState();
    if (widget.characteristic.canRead) {
      _read();
    }
    if (widget.characteristic.canNotify) {
      _subscribe();
    }
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    super.dispose();
  }

  Future<void> _read() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final bleService = ref.read(bleServiceProvider);
      final value = await bleService.readCharacteristic(
        widget.deviceId,
        widget.serviceUuid,
        widget.characteristic.uuid,
      );
      if (mounted) {
        setState(() {
          _value = value;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  void _subscribe() {
    final bleService = ref.read(bleServiceProvider);
    _notifySub = bleService
        .subscribeCharacteristic(
      widget.deviceId,
      widget.serviceUuid,
      widget.characteristic.uuid,
    )
        .listen(
      (value) {
        if (mounted) setState(() => _value = value);
      },
      onError: (e) {
        if (mounted) setState(() => _error = e.toString());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final char = widget.characteristic;
    final properties = <String>[];
    if (char.canRead) properties.add('R');
    if (char.canWrite) properties.add('W');
    if (char.canNotify) properties.add('N');

    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      title: Row(
        children: [
          Expanded(
            child: Text(
              char.uuid,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            ),
          ),
          ...properties.map((p) => Padding(
                padding: const EdgeInsets.only(left: 4),
                child: Chip(
                  label: Text(p, style: const TextStyle(fontSize: 10)),
                  padding: EdgeInsets.zero,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              )),
        ],
      ),
      subtitle: _buildValue(),
      trailing: char.canRead
          ? IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: _loading ? null : _read,
            )
          : null,
    );
  }

  Widget _buildValue() {
    if (_loading) {
      return const Text('Reading...',
          style: TextStyle(fontStyle: FontStyle.italic));
    }
    if (_error != null) {
      return Text('Error: $_error',
          style: const TextStyle(color: Colors.red, fontSize: 12));
    }
    if (_value == null) {
      return const Text('(no value)',
          style: TextStyle(color: Colors.grey, fontSize: 12));
    }
    return Text(
      bytesToHex(_value!),
      style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    );
  }
}

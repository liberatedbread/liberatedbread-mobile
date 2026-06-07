// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/value_format.dart';
import '../providers/ble_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';

/// Reads a spec-described characteristic and renders its decoded, named fields
/// (e.g. "Power state: on", "Brightness: 80") instead of raw hex. Subscribes
/// for live updates when the characteristic supports notify.
class DecodedValueWidget extends ConsumerStatefulWidget {
  final String deviceId;
  final String serviceUuid;
  final String specYaml;
  final CharacteristicDto specChar;
  final bool canRead;
  final bool canNotify;

  const DecodedValueWidget({
    super.key,
    required this.deviceId,
    required this.serviceUuid,
    required this.specYaml,
    required this.specChar,
    required this.canRead,
    required this.canNotify,
  });

  @override
  ConsumerState<DecodedValueWidget> createState() => _DecodedValueWidgetState();
}

class _DecodedValueWidgetState extends ConsumerState<DecodedValueWidget> {
  List<DecodedValueDto>? _values;
  bool _loading = false;
  String? _error;
  StreamSubscription<List<int>>? _notifySub;

  @override
  void initState() {
    super.initState();
    if (widget.canRead) _read();
    if (widget.canNotify) _subscribe();
  }

  @override
  void dispose() {
    _notifySub?.cancel();
    super.dispose();
  }

  Future<void> _decodeAndSet(List<int> bytes) async {
    final codec = ref.read(specCodecProvider);
    final decoded = await codec.decodeValue(
      specYaml: widget.specYaml,
      charUuid: widget.specChar.uuid,
      bytes: bytes,
    );
    if (mounted) {
      setState(() {
        _values = decoded;
        _loading = false;
        _error = null;
      });
    }
  }

  Future<void> _read() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ble = ref.read(bleServiceProvider);
      final bytes = await ble.readCharacteristic(
        widget.deviceId,
        widget.serviceUuid,
        widget.specChar.uuid,
      );
      await _decodeAndSet(bytes);
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
    final ble = ref.read(bleServiceProvider);
    _notifySub = ble
        .subscribeCharacteristic(
      widget.deviceId,
      widget.serviceUuid,
      widget.specChar.uuid,
    )
        .listen(
      (bytes) {
        unawaited(_decodeAndSet(bytes).catchError((Object e) {
          if (mounted) setState(() => _error = e.toString());
        }));
      },
      onError: (Object e) {
        if (mounted) setState(() => _error = e.toString());
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      title: Text(
        humanizeName(widget.specChar.name),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: _buildBody(),
      trailing: widget.canRead
          ? IconButton(
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: _loading ? null : _read,
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_loading && _values == null) {
      return const Text('Reading...',
          style: TextStyle(fontStyle: FontStyle.italic));
    }
    if (_error != null) {
      return Text('Error: $_error',
          style: const TextStyle(color: Colors.red, fontSize: 12));
    }
    final values = _values;
    if (values == null || values.isEmpty) {
      return const Text('(no value)',
          style: TextStyle(color: Colors.grey, fontSize: 12));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: values.map(_buildField).toList(),
    );
  }

  Widget _buildField(DecodedValueDto v) {
    final label = humanizeName(v.name);
    final pct = _batteryPercent(v);
    if (pct != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('$label: ${v.display}'),
            const SizedBox(height: 2),
            LinearProgressIndicator(value: (pct / 100).clamp(0.0, 1.0)),
          ],
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Text('$label: ${v.display}'),
    );
  }

  /// A 0..100 percentage for battery-style fields, else null.
  int? _batteryPercent(DecodedValueDto v) {
    if (!v.name.toLowerCase().contains('battery')) return null;
    final u = v.uintValue;
    return u?.toInt();
  }
}

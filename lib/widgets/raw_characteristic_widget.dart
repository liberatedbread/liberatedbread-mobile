// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import '../providers/ble_provider.dart';
import '../core/error_text.dart';

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

  final TextEditingController _writeController = TextEditingController();
  bool _writing = false;
  String? _writeError;
  String? _writeStatus;

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
    _writeController.dispose();
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
          _error = friendlyErrorText(
            e,
            context: 'read ${widget.characteristic.uuid}',
            fallback: 'Could not read this characteristic.',
          );
          _loading = false;
        });
      }
    }
  }

  Future<void> _write() async {
    final bytes = tryParseHex(_writeController.text);
    if (bytes == null) {
      setState(() {
        _writeError = 'Invalid hex (expected pairs, e.g. "01 aa")';
        _writeStatus = null;
      });
      return;
    }
    if (bytes.isEmpty) {
      setState(() {
        _writeError = 'Enter at least one byte';
        _writeStatus = null;
      });
      return;
    }

    setState(() {
      _writing = true;
      _writeError = null;
      _writeStatus = null;
    });

    try {
      final bleService = ref.read(bleServiceProvider);
      // The service picks write-with/without-response based on the
      // characteristic's advertised properties, so control chars that are
      // write-without-response only are handled correctly.
      await bleService.writeCharacteristic(
        widget.deviceId,
        widget.serviceUuid,
        widget.characteristic.uuid,
        bytes,
      );
      if (mounted) {
        setState(() {
          _writing = false;
          _writeStatus = 'Wrote ${bytesToHex(bytes)}';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _writing = false;
          _writeError = friendlyErrorText(
            e,
            context: 'write ${widget.characteristic.uuid}',
            fallback: 'The write was rejected by the device.',
          );
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
        if (mounted) {
          setState(() => _error = friendlyErrorText(
                e,
                context: 'notify ${widget.characteristic.uuid}',
                fallback: 'Live updates stopped.',
              ));
        }
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
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
        ),
        if (char.canWrite) _buildWriteRow(),
      ],
    );
  }

  Widget _buildWriteRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _writeController,
                  enabled: !_writing,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
                  decoration: const InputDecoration(
                    isDense: true,
                    labelText: 'Write hex',
                    hintText: 'e.g. 01 aa',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _writing ? null : _write(),
                ),
              ),
              const SizedBox(width: 8),
              _writing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : IconButton(
                      icon: const Icon(Icons.send, size: 20),
                      tooltip: 'Write',
                      onPressed: _write,
                    ),
            ],
          ),
          if (_writeError != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Error: $_writeError',
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
          if (_writeStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(_writeStatus!,
                  style: const TextStyle(color: Colors.green, fontSize: 12)),
            ),
        ],
      ),
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
    final ascii = asciiPreview(_value!);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          bytesToHex(_value!),
          style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
        ),
        if (ascii != null)
          Text(
            '"$ascii"',
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
      ],
    );
  }
}

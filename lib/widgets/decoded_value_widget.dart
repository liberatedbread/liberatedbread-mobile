// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/decoded_number.dart';
import '../core/value_format.dart';
import '../providers/ble_provider.dart';
import '../providers/ha_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';
import '../core/error_text.dart';

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
    final forwarder = ref.read(haForwarderProvider);
    final decoded = await codec.decodeValue(
      specYaml: widget.specYaml,
      charUuid: widget.specChar.uuid,
      bytes: bytes,
    );
    // Best-effort side channel to Home Assistant; never blocks or breaks
    // the local UI (the forwarder swallows its own errors).
    unawaited(forwarder.onDecodedValues(
      deviceId: widget.deviceId,
      specChar: widget.specChar,
      values: decoded,
    ));
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
          _error = friendlyErrorText(
            e,
            context: 'read ${widget.specChar.uuid}',
            fallback: 'Could not read this value.',
          );
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
          if (mounted) {
            setState(() => _error = friendlyErrorText(
                  e,
                  context: 'decode ${widget.specChar.uuid}',
                  fallback: 'Could not decode the latest value.',
                ));
          }
        }));
      },
      onError: (Object e) {
        if (mounted) {
          setState(() => _error = friendlyErrorText(
                e,
                context: 'notify ${widget.specChar.uuid}',
                fallback: 'Live updates stopped.',
              ));
        }
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
    final pct = _percentOf(v);
    final line = Text('$label: ${_valueText(v)}');
    if (pct == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 1),
        child: line,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          line,
          const SizedBox(height: 2),
          LinearProgressIndicator(value: (pct / 100).clamp(0.0, 1.0)),
        ],
      ),
    );
  }

  /// One decoded field as text, using everything the spec said about it.
  ///
  /// This view used to print `DecodedValueDto.display` — the raw wire integer
  /// — while `scale`, `value_offset`, `unit`, `values` and `unit_source` all
  /// crossed the FFI beside it and went unread. A SIG temperature therefore
  /// read "2350" here and "23.5 °C" on the entity card above it, from the
  /// same characteristic and the same spec.
  ///
  /// The code-table name keeps the raw code beside it, unlike the entity card
  /// which shows the name alone: this is the GATT browser, and someone
  /// reverse-engineering a device needs to see the byte that produced the
  /// word. Same "Label (value)" shape [allowedEntryLabel] uses for the write
  /// direction.
  String _valueText(DecodedValueDto v) {
    final number = decodedTextOf(v);
    final named = v.valueLabel;
    final body = named == null ? number : '$named ($number)';
    final unit = unitOf(v);
    if (unit != null) return '$body $unit';
    // A device-setting unit is real but unknowable from here, and saying
    // nothing would imply the number is dimensionless.
    return unitFollowsDeviceSetting(v)
        ? '$body (unit set on the device)'
        : body;
  }

  /// A 0..100 reading for percentage fields, else null.
  ///
  /// Driven by the spec's declared `unit` first — a field saying `unit: "%"`
  /// is a percentage whatever it is called — and only falls back to the name
  /// for the many bundled fields that carry no unit at all. The bar is drawn
  /// from the DECODED value, so a scaled percentage fills correctly.
  double? _percentOf(DecodedValueDto v) {
    final isPercent = v.unit == '%' || v.name.toLowerCase().contains('battery');
    if (!isPercent) return null;
    return decodedNumberOf(v);
  }
}

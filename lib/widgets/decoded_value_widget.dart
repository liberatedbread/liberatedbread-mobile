// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/decoded_number.dart';
import '../core/hex.dart';
import '../core/value_format.dart';
import '../providers/ble_provider.dart';
import '../providers/ha_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';
import '../core/error_text.dart';

/// Counts successful command writes per `deviceId|serviceUuid` (see
/// [serviceWriteKey]), so a decoded reading in the same service can read
/// again after one.
///
/// A light's Status sat on its first read under the command cards that had
/// just changed it — "Brightness: 80" after a send of 40 — unless the device
/// happened to notify. The writer bumps this; [DecodedValueWidget] and
/// `EntityValueBuilder` listen.
class ServiceWrites extends AutoDisposeFamilyNotifier<int, String> {
  @override
  int build(String key) => 0;

  void wrote() => state++;
}

final serviceWritesProvider = NotifierProvider.autoDispose
    .family<ServiceWrites, int, String>(ServiceWrites.new);

/// The [serviceWritesProvider] key for one device's service. Folded, so the
/// writer's and the reader's spellings of one UUID agree.
String serviceWriteKey(String deviceId, String serviceUuid) =>
    '$deviceId|${normalizeUuid(serviceUuid)}';

/// Writes one command and, once it lands, bumps [serviceWritesProvider] for
/// its service. Every spec-driven card that writes goes through here: only
/// the typed command card used to bump, so a brightness sent from the light
/// card — the main control once the light's own service folds away — left
/// the Status under that fold on its first read, "Brightness: 80" after 40.
///
/// Takes the [container] (`ProviderScope.containerOf`, taken before the
/// caller's first await) rather than a `WidgetRef`: the bump belongs to the
/// readings, not the writer, so it must land even when the writer unmounted
/// mid-write, and a ref throws once its widget is gone.
///
/// [stateServiceUuid] is the writing card's own state service, bumped too
/// when it differs: the card's reading (`EntityValueBuilder`) listens under
/// the service it READS, and an entity whose command and state sit in two
/// services would otherwise never hear about its own write.
Future<void> writeServiceCommand(
  ProviderContainer container, {
  required String deviceId,
  required String serviceUuid,
  required String charUuid,
  required List<int> bytes,
  String? stateServiceUuid,
}) async {
  await container
      .read(bleServiceProvider)
      .writeCharacteristic(deviceId, serviceUuid, charUuid, bytes);
  final keys = {
    serviceWriteKey(deviceId, serviceUuid),
    if (stateServiceUuid != null) serviceWriteKey(deviceId, stateServiceUuid),
  };
  for (final key in keys) {
    container.read(serviceWritesProvider(key).notifier).wrote();
  }
}

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

  /// Arrival order of the bytes being decoded, stamped when they arrive.
  /// Decodes run concurrently on FRB's worker pool, so a seed read's decode
  /// could finish after a later notification's and put the older reading
  /// back — on screen and, worse, forwarded to Home Assistant as current.
  /// A result stamped below [_appliedSeq] is dropped.
  int _arrivalSeq = 0;
  int _appliedSeq = 0;

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

  Future<void> _decodeAndSet(List<int> bytes, int seq) async {
    final codec = ref.read(specCodecProvider);
    final forwarder = ref.read(haForwarderProvider);
    final decoded = await codec.decodeValue(
      specYaml: widget.specYaml,
      charUuid: widget.specChar.uuid,
      bytes: bytes,
    );
    // Superseded by newer bytes: neither shown nor forwarded.
    if (seq < _appliedSeq) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _appliedSeq = seq;
    // Best-effort side channel to Home Assistant; never blocks or breaks
    // the local UI (the forwarder swallows its own errors).
    unawaited(
      forwarder.onDecodedValues(
        deviceId: widget.deviceId,
        specChar: widget.specChar,
        values: decoded,
      ),
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
    final issuedAt = _arrivalSeq;
    try {
      final ble = ref.read(bleServiceProvider);
      final bytes = await ble.readCharacteristic(
        widget.deviceId,
        widget.serviceUuid,
        widget.specChar.uuid,
      );
      await _decodeAndSet(bytes, ++_arrivalSeq);
    } catch (e) {
      // A late failure must not hide a newer live reading behind 'Error:'.
      if (mounted && _appliedSeq > issuedAt) {
        setState(() => _loading = false);
      } else if (mounted) {
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
            unawaited(
              _decodeAndSet(bytes, ++_arrivalSeq).catchError((Object e) {
                if (mounted) {
                  setState(
                    () => _error = friendlyErrorText(
                      e,
                      context: 'decode ${widget.specChar.uuid}',
                      fallback: 'Could not decode the latest value.',
                    ),
                  );
                }
              }),
            );
          },
          onError: (Object e) {
            if (mounted) {
              setState(
                () => _error = friendlyErrorText(
                  e,
                  context: 'notify ${widget.specChar.uuid}',
                  fallback: 'Live updates stopped.',
                ),
              );
            }
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    // Re-read after a command in this service lands: the write most likely
    // changed what this characteristic reports. One read, the same one the
    // refresh button makes, and only for a readable characteristic — a
    // notify-only one hears about the change from the device itself.
    ref.listen(
      serviceWritesProvider(
        serviceWriteKey(widget.deviceId, widget.serviceUuid),
      ),
      (_, _) {
        if (widget.canRead) _read();
      },
    );
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      title: Text(
        humanizeName(widget.specChar.name),
        style: const TextStyle(fontWeight: FontWeight.w600),
      ),
      subtitle: _buildBody(),
      trailing: widget.canRead
          ? IconButton(
              tooltip: 'Read ${widget.specChar.name} again',
              icon: const Icon(Icons.refresh, size: 18),
              onPressed: _loading ? null : _read,
            )
          : null,
    );
  }

  Widget _buildBody() {
    // Theme roles, not Colors.* literals: grey fails contrast on the light
    // surface and neither adapts to dark mode.
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (_loading && _values == null) {
      return const Text(
        'Reading...',
        style: TextStyle(fontStyle: FontStyle.italic),
      );
    }
    if (_error != null) {
      return Text(
        'Error: $_error',
        style: text.bodySmall?.copyWith(color: scheme.error),
      );
    }
    final values = _values;
    if (values == null || values.isEmpty) {
      return Text(
        '(no value)',
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
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
  /// same characteristic and the same spec. The transform now arrives already
  /// applied (`decodedText`, from `rust/src/codec/number.rs`), so the two
  /// surfaces cannot say different things about one reading.
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
  ///
  /// The name fallback is now fenced two ways, because on its own it was a
  /// claim about a RANGE made from a WORD. A field called
  /// `battery_voltage_mv` carries millivolts; it matched `battery`, and the
  /// GATT browser drew it a 0-100% bar pinned at full under a reading of
  /// 3700. So the fallback applies only where the spec said nothing about
  /// the unit — a field that declares `mV` has already told us it is not a
  /// percentage — and only where the decoded value actually falls in 0..100,
  /// which is the range the bar is drawing. A declared `unit: "%"` keeps its
  /// bar whatever it reads, out-of-range included: there the spec asserted
  /// the scale, and clamping shows the reading is off rather than hiding it.
  double? _percentOf(DecodedValueDto v) {
    final unit = v.unit;
    if (unit == '%') return decodedNumberOf(v);
    if (unit != null && unit.isNotEmpty) return null;
    if (unitFollowsDeviceSetting(v)) return null;
    if (!v.name.toLowerCase().contains('battery')) return null;
    final number = decodedNumberOf(v);
    if (number == null || !number.isFinite) return null;
    return (number < 0 || number > 100) ? null : number;
  }
}

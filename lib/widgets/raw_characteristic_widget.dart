// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/hex.dart';
import '../models/ble_discovered_service.dart';
import '../providers/ble_provider.dart';
import '../core/error_text.dart';
import '../core/mono_text.dart';

/// Raw characteristic widget — shows hex values and provides basic read/write.
/// This is the fallback for characteristics not matched to a device spec;
/// spec-matched characteristics render typed controls instead (see
/// TypedCharacteristicWidget / TypedCommandWidget).
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

/// Refuses, at the keyboard, any character [tryParseHex] could only ever
/// reject at send time (see [isHexInputPlausible], which shares the parser's
/// grammar so the two cannot drift).
///
/// The whole edit is refused, not filtered: stripping characters from a
/// paste turned '01 02 // comment' into '01 02 ce', valid bytes nobody
/// typed.
final _hexInputChars = TextInputFormatter.withFunction(
  (oldValue, newValue) =>
      isHexInputPlausible(newValue.text) ? newValue : oldValue,
);

class _RawCharacteristicWidgetState
    extends ConsumerState<RawCharacteristicWidget> {
  List<int>? _value;
  bool _loading = false;

  /// Why the last read failed, and why live updates stopped. Two fields,
  /// not one: a single `_error` was cleared only by a read and checked
  /// before the value, so one failed read (a read that needs pairing on a
  /// characteristic that notifies freely) hid every later notification
  /// behind a permanent 'Error:' line. A value that arrives replaces the
  /// failed read's gap, and a notify error does not hide the last value.
  String? _readError;
  String? _notifyError;
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
      _readError = null;
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
          _readError = friendlyErrorText(
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
      _revealResult();
      return;
    }
    if (bytes.isEmpty) {
      setState(() {
        _writeError = 'Enter at least one byte';
        _writeStatus = null;
      });
      _revealResult();
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
        _revealResult();
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
        _revealResult();
      }
    }
  }

  final _writeRowKey = GlobalKey();

  /// Scroll the whole write row, result line included, above the keyboard
  /// once the result is laid out. The field only scrolls ITSELF into view
  /// on a keystroke, and a submit moves no cursor, so a result appearing
  /// under a field already sitting on the keyboard's edge was cut in half.
  void _revealResult() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final row = _writeRowKey.currentContext;
      if (row == null || !row.mounted) return;
      Scrollable.ensureVisible(
        row,
        alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
        duration: const Duration(milliseconds: 150),
      );
    });
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
            // Data arriving means the stream is alive and the value on
            // screen is fresh: neither error still describes it.
            if (mounted) {
              setState(() {
                _value = value;
                _readError = null;
                _notifyError = null;
              });
            }
          },
          onError: (Object e) {
            if (mounted) {
              setState(
                () => _notifyError = friendlyErrorText(
                  e,
                  context: 'notify ${widget.characteristic.uuid}',
                  fallback: 'Live updates stopped.',
                ),
              );
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
          // The UUID gets the full width, with the property chips and the
          // refresh button beneath it: sharing a row with either wrapped a
          // 128-bit UUID mid-string (a trailing button still left one
          // character on a second line).
          title: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Scaled down, never ellipsized or wrapped: a truncated UUID
              // is useless, and one split across lines is hard to read off.
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  char.uuid,
                  style: monoTextStyleOf(fontSize: 12),
                  softWrap: false,
                ),
              ),
              if (properties.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 4,
                          runSpacing: 4,
                          children: [
                            for (final p in properties)
                              Chip(
                                label: Text(
                                  p,
                                  style: const TextStyle(fontSize: 10),
                                ),
                                padding: EdgeInsets.zero,
                                materialTapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                visualDensity: VisualDensity.compact,
                              ),
                          ],
                        ),
                      ),
                      if (char.canRead)
                        IconButton(
                          tooltip: 'Read this characteristic again',
                          icon: const Icon(Icons.refresh, size: 18),
                          onPressed: _loading ? null : _read,
                        ),
                    ],
                  ),
                ),
            ],
          ),
          subtitle: _buildValue(),
        ),
        if (char.canWrite) _buildWriteRow(),
      ],
    );
  }

  Widget _buildWriteRow() {
    // Theme roles, not Colors.* literals: grey and green fail contrast on the
    // light surface and none of them adapt to dark mode.
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    return Padding(
      key: _writeRowKey,
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      // Top-aligned: the result line under the field would otherwise pull
      // the send button down off the field it belongs to.
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: TextField(
              controller: _writeController,
              enabled: !_writing,
              style: monoTextStyleOf(fontSize: 13),
              // Hex, not prose: autocorrect, suggestions and smart dashes
              // mangle byte tokens and `-` separators. visiblePassword is
              // the plain keyboard with a digit row and no suggestion
              // strip; the number pad would have no a-f.
              autocorrect: false,
              enableSuggestions: false,
              smartDashesType: SmartDashesType.disabled,
              smartQuotesType: SmartQuotesType.disabled,
              keyboardType: TextInputType.visiblePassword,
              inputFormatters: [_hexInputChars],
              // Room below the field for a result line while typing: the
              // field scrolls only itself (plus this) above the keyboard.
              // A result appearing on submit is revealed by _revealResult.
              scrollPadding: const EdgeInsets.fromLTRB(20, 20, 20, 20 + 56),
              decoration: InputDecoration(
                isDense: true,
                labelText: 'Write hex',
                hintText: 'e.g. 01 aa',
                border: const OutlineInputBorder(),
                errorText: _writeError,
                errorMaxLines: 3,
                helperText: _writeStatus,
                helperMaxLines: 2,
                helperStyle: text.bodySmall?.copyWith(color: scheme.tertiary),
              ),
              onSubmitted: (_) => _writing ? null : _write(),
            ),
          ),
          const SizedBox(width: 8),
          _writing
              // Padded to the send button's 48px so the swap does not jump
              // now that the row is top-aligned.
              ? const Padding(
                  padding: EdgeInsets.all(15),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.send, size: 20),
                  tooltip: 'Write',
                  onPressed: _write,
                ),
        ],
      ),
    );
  }

  Widget _buildValue() {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (_loading) {
      return const Text(
        'Reading...',
        style: TextStyle(fontStyle: FontStyle.italic),
      );
    }
    final errors = [?_readError, ?_notifyError];
    final value = _value;
    if (value == null && errors.isEmpty) {
      return Text(
        '(no value)',
        style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      );
    }
    // The last value stays visible with any error beneath it, rather than
    // the error replacing it.
    final ascii = value == null ? null : asciiPreview(value);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Captioned: bare bytes under the R/W/N chips read as one more
        // property rather than what the device returned.
        if (value != null) ...[
          Text(
            'Value',
            style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
          Text(bytesToHex(value), style: monoTextStyleOf(fontSize: 13)),
        ],
        if (ascii != null)
          Text(
            '"$ascii"',
            style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
          ),
        for (final error in errors)
          Text(error, style: text.bodySmall?.copyWith(color: scheme.error)),
      ],
    );
  }
}

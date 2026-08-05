// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/error_text.dart';
import '../core/log.dart';
import '../providers/ble_provider.dart';
import '../providers/spec_codec_provider.dart';
import '../services/spec_codec.dart';

/// Usable bytes per BLE write for a given ATT MTU.
///
/// Payload is MTU minus the 3-byte ATT write header, floored at the BLE 4.0
/// minimum of 20 (an unreported MTU comes through as 23) and capped at 512 —
/// the largest attribute value BLE permits, and what vendors' own apps
/// request. Pure so the sizing is unit-testable.
int writePayloadForMtu(int mtu) => (mtu - 3).clamp(20, 512);

/// Copy an RGB888 frame onto a new canvas size, preserving the overlapping
/// region (anchored top-left) and filling new area with black.
///
/// Resizing must not eat the user's drawing: shrinking crops, growing pads.
/// Pure so the geometry is unit-testable.
Uint8List resizeFrame(
  Uint8List src,
  int oldWidth,
  int oldHeight,
  int newWidth,
  int newHeight,
) {
  final out = Uint8List(newWidth * newHeight * 3);
  final copyWidth = oldWidth < newWidth ? oldWidth : newWidth;
  final copyHeight = oldHeight < newHeight ? oldHeight : newHeight;
  for (var y = 0; y < copyHeight; y++) {
    for (var x = 0; x < copyWidth; x++) {
      final from = (y * oldWidth + x) * 3;
      final to = (y * newWidth + x) * 3;
      out[to] = src[from];
      out[to + 1] = src[from + 1];
      out[to + 2] = src[from + 2];
    }
  }
  return out;
}

/// Canvas sizes offered for a device whose real resolution is reported at
/// runtime, bounded by the spec's platform maximum.
///
/// Common LED-matrix sizes rather than a free-form field: the user is
/// matching a physical panel, and a short list beats a keyboard. Always
/// non-empty — a tiny maximum offers just itself. Pure for tests.
List<int> canvasSizeOptions(int? max) {
  const common = [8, 12, 16, 20, 24, 32, 48, 64];
  final bound = max ?? common.last;
  final options = [
    for (final size in common)
      if (size <= bound) size
  ];
  return options.isEmpty ? [bound] : options;
}

/// Animation-rate slider bounds and initial value in milliseconds per frame,
/// from the spec's declared limits with usable defaults where it is silent.
/// Pure for tests.
({int min, int max, int initial}) frameIntervalBoundsMs(ImageUploadDto spec) {
  final min = spec.minFrameIntervalMs ?? 50;
  final max = min > 2000 ? min : 2000;
  final initial = (spec.defaultFrameIntervalMs ?? 200).clamp(min, max);
  return (min: min, max: max, initial: initial);
}

/// Generic editor for pixel-display devices: draw a static image or an
/// animation and push it over BLE.
///
/// Entirely spec-driven — nothing here is specific to one brand. The spec's
/// `image_upload` feature declares the surface (resolution, animation
/// support, rate bounds) and its `protocol_handler` names the Rust encoder
/// that turns RGB frames into device writes, so a new pixel device gets this
/// UI by shipping a spec plus a handler, with no widget changes. Animations
/// are streamed: frames are encoded and written at the chosen interval until
/// stopped, which is also how rate control works — the interval slider IS the
/// animation rate.
class LedImageWidget extends ConsumerStatefulWidget {
  final String deviceId;
  final ImageUploadDto imageUpload;
  final String specYaml;

  const LedImageWidget({
    super.key,
    required this.deviceId,
    required this.imageUpload,
    required this.specYaml,
  });

  @override
  ConsumerState<LedImageWidget> createState() => _LedImageWidgetState();
}

/// Drawing palette. Black doubles as the eraser — LEDs off.
const List<Color> _palette = [
  Colors.white,
  Colors.red,
  Colors.orange,
  Colors.yellow,
  Colors.green,
  Colors.cyan,
  Colors.blue,
  Colors.purple,
  Colors.pink,
  Colors.black,
];

class _LedImageWidgetState extends ConsumerState<LedImageWidget> {
  late int _width;
  late int _height;
  final List<Uint8List> _frames = [];
  int _current = 0;
  bool _animationMode = false;
  late int _intervalMs;
  int _selectedColor = 1; // red: visible on the black default canvas
  Timer? _previewTimer;
  bool _streaming = false;
  bool _sending = false;
  int _frameSequence = 0;
  String? _error;

  ImageUploadDto get _spec => widget.imageUpload;

  @override
  void initState() {
    super.initState();
    // Fixed-resolution panels get their declared size; device-reported ones
    // start at a common small size the user can adjust.
    final sizes = canvasSizeOptions(_spec.maxWidth);
    _width = _spec.resolutionDeviceReported
        ? (sizes.contains(16) ? 16 : sizes.last)
        : (_spec.maxWidth ?? 16);
    final heights = canvasSizeOptions(_spec.maxHeight);
    _height = _spec.resolutionDeviceReported
        ? (heights.contains(16) ? 16 : heights.last)
        : (_spec.maxHeight ?? 16);
    _intervalMs = frameIntervalBoundsMs(_spec).initial;
    _frames.add(Uint8List(_width * _height * 3));
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _streaming = false;
    super.dispose();
  }

  void _paintCell(Offset local, double cellSize) {
    final x = (local.dx / cellSize).floor();
    final y = (local.dy / cellSize).floor();
    if (x < 0 || y < 0 || x >= _width || y >= _height) return;
    final color = _palette[_selectedColor];
    final index = (y * _width + x) * 3;
    final frame = _frames[_current];
    setState(() {
      frame[index] = (color.r * 255).round();
      frame[index + 1] = (color.g * 255).round();
      frame[index + 2] = (color.b * 255).round();
    });
  }

  void _resizeCanvas({int? width, int? height}) {
    final newWidth = width ?? _width;
    final newHeight = height ?? _height;
    setState(() {
      for (var i = 0; i < _frames.length; i++) {
        _frames[i] =
            resizeFrame(_frames[i], _width, _height, newWidth, newHeight);
      }
      _width = newWidth;
      _height = newHeight;
    });
  }

  bool get _atFrameLimit =>
      _spec.maxFrames != null && _frames.length >= _spec.maxFrames!;

  void _addFrame({required bool duplicate}) {
    if (_atFrameLimit) return;
    setState(() {
      _frames.insert(
        _current + 1,
        duplicate
            ? Uint8List.fromList(_frames[_current])
            : Uint8List(_width * _height * 3),
      );
      _current += 1;
    });
  }

  void _deleteFrame() {
    if (_frames.length <= 1) return;
    setState(() {
      _frames.removeAt(_current);
      if (_current >= _frames.length) _current = _frames.length - 1;
    });
  }

  void _togglePreview() {
    if (_previewTimer != null) {
      _previewTimer?.cancel();
      setState(() => _previewTimer = null);
      return;
    }
    setState(() {
      _previewTimer = Timer.periodic(Duration(milliseconds: _intervalMs), (_) {
        if (!mounted) return;
        setState(() => _current = (_current + 1) % _frames.length);
      });
    });
  }

  Future<void> _sendFrame(int index) async {
    final ble = ref.read(bleServiceProvider);
    // An unreported MTU shows up as the 23-byte floor, which encodes to the
    // spec-safe 20-byte payload; a real negotiated MTU shrinks write counts.
    var mtu = 23;
    try {
      mtu = await ble.mtu(widget.deviceId);
    } catch (_) {
      // Sizing for the floor is always safe, just slower.
    }
    final plan = await ref.read(specCodecProvider).encodeImageFrame(
          specYaml: widget.specYaml,
          width: _width,
          height: _height,
          rgb: _frames[index],
          frameIndex: _frameSequence++,
          maxPayloadPerWrite: writePayloadForMtu(mtu),
        );
    for (final write in plan.writes) {
      await ble.writeCharacteristic(
        widget.deviceId,
        plan.serviceUuid,
        plan.characteristicUuid,
        write,
      );
    }
  }

  Future<void> _sendCurrentFrame() async {
    setState(() {
      _sending = true;
      _error = null;
    });
    try {
      await _sendFrame(_current);
    } catch (e) {
      if (mounted) {
        setState(() => _error = friendlyErrorText(
              e,
              context: 'send frame to ${widget.deviceId}',
              fallback: 'Could not send the image to the device.',
            ));
      }
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  /// Stream the frame loop to the device until toggled off: encode + write a
  /// frame, wait out the remainder of the interval, advance, repeat. The
  /// interval slider therefore directly controls the on-device animation
  /// rate, including for devices (like Daniao's) whose animation support IS
  /// streamed frames.
  Future<void> _toggleStreaming() async {
    if (_streaming) {
      setState(() => _streaming = false);
      return;
    }
    setState(() {
      _streaming = true;
      _error = null;
    });
    Log.ble.info('streaming ${_frames.length}-frame animation to '
        '${widget.deviceId} every ${_intervalMs}ms');
    while (mounted && _streaming) {
      final started = DateTime.now();
      try {
        await _sendFrame(_current);
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _streaming = false;
          _error = friendlyErrorText(
            e,
            context: 'stream animation to ${widget.deviceId}',
            fallback: 'Could not stream the animation to the device.',
          );
        });
        return;
      }
      if (!mounted || !_streaming) break;
      setState(() => _current = (_current + 1) % _frames.length);
      final elapsed = DateTime.now().difference(started);
      final wait = Duration(milliseconds: _intervalMs) - elapsed;
      if (wait > Duration.zero) {
        await Future<void>.delayed(wait);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    if (!_spec.encodable) {
      // The capability is declared but no encoder exists in this build. Say
      // so honestly instead of hiding the surface or offering a dead button.
      return Card(
        margin: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.image_not_supported_outlined,
                  color: scheme.onSurfaceVariant),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'This device accepts images'
                  '${_spec.animation ? ' and animations' : ''}, but its '
                  'upload protocol '
                  '(${_spec.handler ?? 'undeclared'}) is not supported by '
                  'the app yet.',
                  style:
                      text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Card(
      margin: const EdgeInsets.fromLTRB(8, 4, 8, 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.grid_on, color: scheme.secondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'LED image',
                    style:
                        text.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
            // Its own row rather than sharing the title's: the two segments
            // don't fit beside the title on narrow phones.
            if (_spec.animation) ...[
              const SizedBox(height: 10),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Static')),
                  ButtonSegment(value: true, label: Text('Animation')),
                ],
                selected: {_animationMode},
                onSelectionChanged: _streaming
                    ? null
                    : (selection) =>
                        setState(() => _animationMode = selection.first),
              ),
            ],
            const SizedBox(height: 12),
            if (_spec.resolutionDeviceReported) ...[
              _CanvasSizeRow(
                width: _width,
                height: _height,
                maxWidth: _spec.maxWidth,
                maxHeight: _spec.maxHeight,
                enabled: !_streaming && !_sending,
                onWidthChanged: (w) => _resizeCanvas(width: w),
                onHeightChanged: (h) => _resizeCanvas(height: h),
              ),
              const SizedBox(height: 12),
            ],
            _PixelGridEditor(
              key: const Key('led-image-grid'),
              width: _width,
              height: _height,
              rgb: _frames[_current],
              onPaint: _paintCell,
            ),
            const SizedBox(height: 10),
            _PaletteRow(
              selected: _selectedColor,
              onSelected: (i) => setState(() => _selectedColor = i),
            ),
            if (_animationMode) ...[
              const SizedBox(height: 12),
              _FrameControls(
                frameCount: _frames.length,
                current: _current,
                atLimit: _atFrameLimit,
                busy: _streaming,
                previewing: _previewTimer != null,
                onSelect: (i) => setState(() => _current = i),
                onAdd: () => _addFrame(duplicate: false),
                onDuplicate: () => _addFrame(duplicate: true),
                onDelete: _deleteFrame,
                onTogglePreview: _togglePreview,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Text('Frame every ${_intervalMs}ms',
                      style: text.bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                  Expanded(
                    child: Slider(
                      value: _intervalMs.toDouble(),
                      min: frameIntervalBoundsMs(_spec).min.toDouble(),
                      max: frameIntervalBoundsMs(_spec).max.toDouble(),
                      onChanged: (v) => setState(() => _intervalMs = v.round()),
                    ),
                  ),
                ],
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                icon: Icon(_animationMode
                    ? (_streaming ? Icons.stop : Icons.play_arrow)
                    : Icons.upload),
                label: Text(_animationMode
                    ? (_streaming ? 'Stop streaming' : 'Stream to device')
                    : 'Send to device'),
                onPressed: _sending
                    ? null
                    : _animationMode
                        ? _toggleStreaming
                        : _sendCurrentFrame,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Width/height pickers for panels whose real resolution the device reports
/// at runtime and the app has not yet learned.
class _CanvasSizeRow extends StatelessWidget {
  final int width;
  final int height;
  final int? maxWidth;
  final int? maxHeight;
  final bool enabled;
  final ValueChanged<int> onWidthChanged;
  final ValueChanged<int> onHeightChanged;

  const _CanvasSizeRow({
    required this.width,
    required this.height,
    required this.maxWidth,
    required this.maxHeight,
    required this.enabled,
    required this.onWidthChanged,
    required this.onHeightChanged,
  });

  @override
  Widget build(BuildContext context) {
    Widget picker({
      required String label,
      required int value,
      required int? max,
      required ValueChanged<int> onChanged,
    }) {
      final options = canvasSizeOptions(max);
      return Expanded(
        child: DropdownButtonFormField<int>(
          initialValue: options.contains(value) ? value : options.first,
          decoration: InputDecoration(
            labelText: label,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          items: [
            for (final size in options)
              DropdownMenuItem(value: size, child: Text('$size')),
          ],
          onChanged: enabled ? (v) => v == null ? null : onChanged(v) : null,
        ),
      );
    }

    return Row(
      children: [
        picker(
          label: 'Width',
          value: width,
          max: maxWidth,
          onChanged: onWidthChanged,
        ),
        const SizedBox(width: 10),
        picker(
          label: 'Height',
          value: height,
          max: maxHeight,
          onChanged: onHeightChanged,
        ),
      ],
    );
  }
}

/// The paintable grid: taps and drags set pixels in the RGB byte buffer.
class _PixelGridEditor extends StatelessWidget {
  final int width;
  final int height;
  final Uint8List rgb;
  final void Function(Offset local, double cellSize) onPaint;

  const _PixelGridEditor({
    super.key,
    required this.width,
    required this.height,
    required this.rgb,
    required this.onPaint,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cellSize = constraints.maxWidth / width;
        final gridHeight = cellSize * height;
        return GestureDetector(
          onTapDown: (d) => onPaint(d.localPosition, cellSize),
          onPanUpdate: (d) => onPaint(d.localPosition, cellSize),
          child: CustomPaint(
            size: Size(constraints.maxWidth, gridHeight),
            painter: _GridPainter(
              width: width,
              height: height,
              rgb: rgb,
              gridColor: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
        );
      },
    );
  }
}

class _GridPainter extends CustomPainter {
  final int width;
  final int height;
  final Uint8List rgb;
  final Color gridColor;

  _GridPainter({
    required this.width,
    required this.height,
    required this.rgb,
    required this.gridColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.width / width;
    final fill = Paint();
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        final i = (y * width + x) * 3;
        fill.color = Color.fromARGB(0xFF, rgb[i], rgb[i + 1], rgb[i + 2]);
        canvas.drawRect(
          Rect.fromLTWH(x * cell, y * cell, cell, cell),
          fill,
        );
      }
    }
    final line = Paint()
      ..color = gridColor
      ..strokeWidth = 0.5;
    for (var x = 0; x <= width; x++) {
      canvas.drawLine(Offset(x * cell, 0), Offset(x * cell, size.height), line);
    }
    for (var y = 0; y <= height; y++) {
      canvas.drawLine(Offset(0, y * cell), Offset(size.width, y * cell), line);
    }
  }

  @override
  bool shouldRepaint(covariant _GridPainter old) =>
      old.rgb != rgb ||
      old.width != width ||
      old.height != height ||
      old.gridColor != gridColor;
}

/// Color swatches; the selected one gets a ring.
class _PaletteRow extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelected;

  const _PaletteRow({required this.selected, required this.onSelected});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Wrap(
      spacing: 8,
      children: [
        for (var i = 0; i < _palette.length; i++)
          GestureDetector(
            key: Key('led-palette-$i'),
            onTap: () => onSelected(i),
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _palette[i],
                shape: BoxShape.circle,
                border: Border.all(
                  color: i == selected ? scheme.primary : scheme.outlineVariant,
                  width: i == selected ? 3 : 1,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Frame chips plus add/duplicate/delete and a local preview toggle.
class _FrameControls extends StatelessWidget {
  final int frameCount;
  final int current;
  final bool atLimit;
  final bool busy;
  final bool previewing;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdd;
  final VoidCallback onDuplicate;
  final VoidCallback onDelete;
  final VoidCallback onTogglePreview;

  const _FrameControls({
    required this.frameCount,
    required this.current,
    required this.atLimit,
    required this.busy,
    required this.previewing,
    required this.onSelect,
    required this.onAdd,
    required this.onDuplicate,
    required this.onDelete,
    required this.onTogglePreview,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (var i = 0; i < frameCount; i++)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text('${i + 1}'),
                      selected: i == current,
                      onSelected: busy ? null : (_) => onSelect(i),
                    ),
                  ),
              ],
            ),
          ),
        ),
        IconButton(
          tooltip: 'Add frame',
          icon: const Icon(Icons.add),
          onPressed: busy || atLimit ? null : onAdd,
        ),
        IconButton(
          tooltip: 'Duplicate frame',
          icon: const Icon(Icons.copy),
          onPressed: busy || atLimit ? null : onDuplicate,
        ),
        IconButton(
          tooltip: 'Delete frame',
          icon: const Icon(Icons.delete_outline),
          onPressed: busy || frameCount <= 1 ? null : onDelete,
        ),
        IconButton(
          tooltip: previewing ? 'Stop preview' : 'Preview',
          icon: Icon(previewing ? Icons.pause : Icons.play_circle_outline),
          onPressed: busy ? null : onTogglePreview,
        ),
      ],
    );
  }
}

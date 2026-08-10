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
import 'led_designs.dart';

/// Usable bytes per BLE write for a given ATT MTU.
///
/// Payload is MTU minus the 3-byte ATT write header, floored at the BLE 4.0
/// minimum of 20 and capped at 512 (the largest attribute value BLE permits,
/// and what vendors' own apps request).
///
/// The reported MTU is trusted as-is. The one platform where the report lies
/// (flutter_blue_plus_linux never updates `mtuNow` from what BlueZ actually
/// negotiates) is corrected inside `RealBleService.mtu()`, next to the
/// `requestMtu` call that owns that platform knowledge — so a genuine 23 from
/// Android sizes to the 20-byte floor here and the image encoder rejects it
/// with an actionable "raise the ATT MTU" message, instead of this helper
/// assuming 512 and firing oversized writes at a link that cannot carry them.
/// Pure so the sizing is unit-testable.
int writePayloadForMtu(int mtu) => (mtu - 3).clamp(20, 512);

/// The TUTU doodle format's palette ceiling (see the daniao encoder): a frame
/// with more distinct colours than this cannot be sent at all.
const int maxFrameColors = 16;

/// Reduce [rgb] to at most [maxColors] distinct colours by keeping the
/// most-used ones and remapping every dropped colour to its nearest kept
/// neighbour (squared RGB distance).
///
/// The encoder REJECTS an over-palette frame rather than quantizing silently,
/// so what the device shows always matches the preview — which means the
/// preview itself must never exceed the palette. Every mutation that can push
/// a frame past the limit (painting a 17th colour onto a 16-colour design,
/// resize padding with black, loading a design) runs its result through this,
/// so the canvas the user sees IS the canvas the device gets.
///
/// [protect], a packed 0xRRGGBB value, is always kept when present in the
/// frame — the colour the user just painted must win over a least-used
/// background colour, or strokes would visibly come out wrong.
///
/// Returns [rgb] unchanged (same identity) when it already fits, which is
/// every frame outside the pathological cases. Pure for tests.
Uint8List quantizeFrame(Uint8List rgb, {int? protect}) {
  final counts = <int, int>{};
  for (var i = 0; i + 2 < rgb.length; i += 3) {
    final c = (rgb[i] << 16) | (rgb[i + 1] << 8) | rgb[i + 2];
    counts[c] = (counts[c] ?? 0) + 1;
  }
  if (counts.length <= maxFrameColors) return rgb;

  final byUse = counts.keys.toList()
    ..sort((a, b) => counts[b]!.compareTo(counts[a]!));
  final kept = <int>{};
  if (protect != null && counts.containsKey(protect)) kept.add(protect);
  for (final c in byUse) {
    if (kept.length >= maxFrameColors) break;
    kept.add(c);
  }

  int distance(int a, int b) {
    final dr = ((a >> 16) & 0xFF) - ((b >> 16) & 0xFF);
    final dg = ((a >> 8) & 0xFF) - ((b >> 8) & 0xFF);
    final db = (a & 0xFF) - (b & 0xFF);
    return dr * dr + dg * dg + db * db;
  }

  final remap = <int, int>{};
  for (final c in counts.keys) {
    if (kept.contains(c)) continue;
    var best = kept.first;
    var bestDist = distance(c, best);
    for (final k in kept) {
      final d = distance(c, k);
      if (d < bestDist) {
        best = k;
        bestDist = d;
      }
    }
    remap[c] = best;
  }

  final out = Uint8List.fromList(rgb);
  for (var i = 0; i + 2 < out.length; i += 3) {
    final c = (out[i] << 16) | (out[i + 1] << 8) | out[i + 2];
    final to = remap[c];
    if (to == null) continue;
    out[i] = (to >> 16) & 0xFF;
    out[i + 1] = (to >> 8) & 0xFF;
    out[i + 2] = to & 0xFF;
  }
  return out;
}

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

/// Starting canvas dimension for a device-reported panel the app hasn't
/// queried yet: a common small size, clamped to the spec's platform bound.
/// Pure for tests.
int initialCanvasSize(int? max) => max == null || max >= 16 ? 16 : max;

/// Parse a user-entered canvas dimension, clamped to `1..max`.
///
/// Free-form entry rather than a preset list: real panels report sizes like
/// 25x50, and forcing the nearest preset shears every row on the device (the
/// display buffer is row-major at the device's true width). Returns null for
/// non-numeric input so the caller can keep the previous size. Pure for
/// tests.
int? parseCanvasSize(String input, {int? max}) {
  final value = int.tryParse(input.trim());
  if (value == null) return null;
  return value.clamp(1, max ?? 255);
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

// AutomaticKeepAliveClientMixin: this State holds the user's drawing and the
// live streaming loop, and it lives inside the control panel's virtualized
// ListView — without keep-alive, scrolling the editor past the cache extent
// disposes it, silently stopping an active stream and discarding the frames.
class _LedImageWidgetState extends ConsumerState<LedImageWidget>
    with AutomaticKeepAliveClientMixin {
  late int _width;
  late int _height;
  final List<Uint8List> _frames = [];
  int _current = 0;
  bool _animationMode = false;
  late int _intervalMs;
  int _selectedColor = 1; // red: visible on the black default canvas
  Timer? _previewTimer;
  bool _streaming = false;

  /// Incremented on every stream start/stop. The streaming loop captures its
  /// epoch and exits when it no longer matches, so a stop followed by a quick
  /// restart cannot revive the old loop off the shared boolean and leave two
  /// loops interleaving writes.
  int _streamEpoch = 0;
  bool _sending = false;
  int _frameSequence = 0;

  /// Bumped on every edit that mutates pixel bytes in place, so the painter
  /// can detect changes the buffer identity cannot (see [_GridPainter]).
  int _paintRevision = 0;
  String? _error;

  /// Designs memoized for the current canvas size — regenerating them (three
  /// stripe buffers + two scaled images per open) on every popup tap is pure
  /// waste, since they only change when the canvas resizes.
  List<LedDesign>? _designsCache;
  int _designsW = -1;
  int _designsH = -1;

  List<LedDesign> get _designs {
    if (_designsCache == null || _designsW != _width || _designsH != _height) {
      _designsCache = defaultDesigns(_width, _height);
      _designsW = _width;
      _designsH = _height;
    }
    return _designsCache!;
  }

  ImageUploadDto get _spec => widget.imageUpload;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _applySpecDefaults();
  }

  /// Derive the canvas from the spec, discarding whatever was on it.
  ///
  /// Called from `initState` and again whenever the spec underneath changes.
  void _applySpecDefaults() {
    // Fixed-resolution panels get their declared size; device-reported ones
    // start at a common small size the user can adjust.
    _width = _spec.resolutionDeviceReported
        ? initialCanvasSize(_spec.maxWidth)
        : (_spec.maxWidth ?? 16);
    _height = _spec.resolutionDeviceReported
        ? initialCanvasSize(_spec.maxHeight)
        : (_spec.maxHeight ?? 16);
    _intervalMs = frameIntervalBoundsMs(_spec).initial;
    _frames
      ..clear()
      ..add(Uint8List(_width * _height * 3));
    _current = 0;
    _frameSequence = 0;
  }

  @override
  void didUpdateWidget(LedImageWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.specYaml == oldWidget.specYaml) return;
    // The panel mounts this under a constant key, so a spec change updates the
    // widget in place and this State survives it. Every geometry field is
    // derived once in initState, so without this a 16x16 editor would go on
    // encoding `width: 16, height: 16` against the new spec's YAML: a sheared
    // image on the panel, or `ImageDimensionsInvalid` surfaced as "Could not
    // send the image to the device" when the new maximum is smaller. Specs
    // change under a live screen when a remote spec pack refreshes and a
    // different candidate wins.
    //
    // The canvas resets rather than being carried across. It cannot be carried
    // honestly — the frames are sized for a surface that is no longer the one
    // being drawn on — and half-translating them would put a corrupted image
    // in front of the user under a name they did not pick.
    setState(() {
      _stopPreview();
      _streaming = false;
      _streamEpoch++;
      _error = null;
      _applySpecDefaults();
    });
  }

  @override
  void dispose() {
    _previewTimer?.cancel();
    _streaming = false;
    _streamEpoch++;
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
      final r = (color.r * 255).round();
      final g = (color.g * 255).round();
      final b = (color.b * 255).round();
      frame[index] = r;
      frame[index + 1] = g;
      frame[index + 2] = b;
      // Painting a 17th distinct colour onto a full-palette frame would make
      // it unsendable (the TUTU encoder rejects rather than quantizes).
      // Quantize with the brush colour protected: the stroke the user just
      // made wins, and the least-used colour merges into its nearest
      // neighbour — visible immediately, so preview and device stay equal.
      final quantized = quantizeFrame(frame, protect: (r << 16) | (g << 8) | b);
      if (!identical(quantized, frame)) _frames[_current] = quantized;
      _paintRevision++;
    });
  }

  void _resizeCanvas({int? width, int? height}) {
    final newWidth = width ?? _width;
    final newHeight = height ?? _height;
    if (newWidth == _width && newHeight == _height) return;
    setState(() {
      for (var i = 0; i < _frames.length; i++) {
        // Growing pads with black, which on a frame already using 16 colours
        // none of them black would be an unsendable 17th — protect the pad
        // colour (off LEDs are the point of padding) and let a least-used
        // colour merge instead.
        _frames[i] = quantizeFrame(
          resizeFrame(_frames[i], _width, _height, newWidth, newHeight),
          protect: 0x000000,
        );
      }
      _width = newWidth;
      _height = newHeight;
      _paintRevision++;
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

  void _stopPreview() {
    _previewTimer?.cancel();
    _previewTimer = null;
  }

  void _togglePreview() {
    if (_previewTimer != null) {
      setState(_stopPreview);
      return;
    }
    setState(_startPreviewTimer);
  }

  void _startPreviewTimer() {
    _previewTimer = Timer.periodic(Duration(milliseconds: _intervalMs), (_) {
      if (!mounted) return;
      setState(() => _current = (_current + 1) % _frames.length);
    });
  }

  /// Timer.periodic captures its Duration at creation, so a running preview
  /// must be re-armed when the rate slider moves — otherwise the preview
  /// keeps the stale cadence and misrepresents what streaming will send.
  void _setIntervalMs(int value) {
    setState(() {
      _intervalMs = value;
      if (_previewTimer != null) {
        _stopPreview();
        _startPreviewTimer();
      }
    });
  }

  /// Leaving animation mode must stop the preview: its only stop control
  /// unmounts in static mode, and a hidden timer would keep cycling frames
  /// under the user's cursor (and under Send).
  void _setAnimationMode(bool animation) {
    setState(() {
      _animationMode = animation;
      if (!animation) _stopPreview();
    });
  }

  /// Load a ready-made design onto the canvas, replacing the current frames.
  ///
  /// The design is generated for the current canvas size, so its frames drop in
  /// without a resize. A multi-frame (animation) design switches to animation
  /// mode when the device supports it, and otherwise loads only its first frame
  /// as a static image. Sequence resets to 0 so the next send re-opens the
  /// doodle session.
  void _loadDesign(LedDesign design) {
    final asAnimation = design.animation && _spec.animation;
    // Choose the frames first (static keeps one), THEN clamp to the spec's
    // frame cap — never below 1, so a maxFrames of 0 can't leave the canvas
    // empty and crash the indexing in build()/_sendCurrentFrame.
    var frames = asAnimation ? design.frames : design.frames.take(1).toList();
    final maxFrames = _spec.maxFrames;
    if (maxFrames != null && frames.length > maxFrames) {
      frames = frames.sublist(0, maxFrames < 1 ? 1 : maxFrames);
    }
    setState(() {
      _stopPreview();
      _error = null;
      _animationMode = asAnimation && frames.length > 1;
      // Designs are built to fit the palette, but quantize defensively: a
      // future design (or scaling artefact) that slipped past 16 colours
      // must not produce a canvas that cannot be sent.
      _frames
        ..clear()
        ..addAll(frames.map((f) => quantizeFrame(Uint8List.fromList(f))));
      _current = 0;
      _frameSequence = 0;
      _paintRevision++;
    });
  }

  /// Usable bytes per BLE write, resolved once per send/stream — the MTU is
  /// fixed for the life of the connection, so re-querying it per frame would
  /// only add an async hop inside the frame budget. An unreported MTU shows
  /// up as the 23-byte floor, which encodes to the spec-safe 20-byte payload.
  Future<int> _resolvePayloadPerWrite() async {
    var mtu = 23;
    try {
      mtu = await ref.read(bleServiceProvider).mtu(widget.deviceId);
    } catch (_) {
      // Sizing for the floor is always safe, just slower.
    }
    return writePayloadForMtu(mtu);
  }

  /// Tail of the frame-send queue. Every send chains onto it, so two sends
  /// can never interleave their ordered fragment writes on the
  /// characteristic. This matters beyond the epoch guard: stopping a stream
  /// only stops the LOOP — its in-flight frame keeps writing fragments, and
  /// the UI immediately re-enables Stream/Send, so an eager next send would
  /// otherwise splice into the old frame's fragment sequence.
  Future<void> _sendTail = Future<void>.value();

  /// Queue a send of the frame at [index].
  ///
  /// The pixels and the canvas size are read *here*, not inside the queued
  /// work: a send sits behind `_sendTail` and then awaits the encoder and one
  /// write per fragment, and the user can edit throughout. Indexing the live
  /// list on the far side of those awaits meant deleting a frame mid-send
  /// threw a RangeError out of the loop (or, one frame earlier, quietly sent
  /// whatever slid into that slot), and resizing the canvas encoded the old
  /// buffer against the new dimensions. What is queued is a snapshot of what
  /// the user asked to send.
  Future<void> _enqueueSend(int index, int payloadPerWrite) {
    // Snapshot the pixels by COPY: the encode runs later (behind _sendTail and
    // an MTU await) and the paint gesture stays live, so aliasing the frame
    // buffer would let an edit-in-progress leak into the frame being sent.
    final rgb = Uint8List.fromList(_frames[index]);
    final width = _width;
    final height = _height;
    // The spec YAML is part of the same snapshot, and leaving it out undid the
    // rest: `didUpdateWidget` resets the canvas when the spec changes, so a
    // send queued before the swap carried the OLD dimensions into
    // `widget.specYaml` read after it — the pre-swap geometry encoded against
    // the post-swap spec, which is exactly the sheared image this snapshot
    // exists to prevent, arrived at from the other direction.
    final specYaml = widget.specYaml;
    final send = _sendTail
        .then((_) => _sendFrame(rgb, width, height, specYaml, payloadPerWrite));
    // Callers observe failures through `send`; the tail itself must swallow
    // them or every later send would rethrow a stale error.
    _sendTail = send.then((_) {}, onError: (_) {});
    return send;
  }

  Future<void> _sendFrame(
    Uint8List rgb,
    int width,
    int height,
    String specYaml,
    int payloadPerWrite,
  ) async {
    // Pin this frame to the operation that launched it. A stop+restart (or a
    // new single send) bumps _streamEpoch and resets _frameSequence to 0; if a
    // prior in-flight frame lands after that reset, it must NOT write its stale
    // nextFrameIndex back, or the restart would skip the session-open.
    final epoch = _streamEpoch;
    final ble = ref.read(bleServiceProvider);
    final plan = await ref.read(specCodecProvider).encodeImageFrame(
          specYaml: specYaml,
          width: width,
          height: height,
          rgb: rgb,
          frameIndex: _frameSequence,
          maxPayloadPerWrite: payloadPerWrite,
        );
    for (final write in plan.writes) {
      // Each write names its own characteristic: the doodle flow opens the
      // session on the command channel and streams pixels on the bulk one.
      await ble.writeCharacteristic(
        widget.deviceId,
        plan.serviceUuid,
        write.characteristicUuid,
        write.bytes,
      );
    }
    if (epoch != _streamEpoch) {
      return; // a newer operation owns the sequence now
    }
    // Advance ONLY after every write lands, not before: if a write throws
    // mid-frame the session may not have opened, so the sequence must stay put
    // and the retry re-send frame 0 (which re-opens the session). Continue from
    // the plan's next index, not += 1 — a frame spanning several wire packets
    // consumes that many sequence numbers, and re-using them on the next frame
    // corrupts fragment reassembly on the device.
    _frameSequence = plan.nextFrameIndex;
  }

  Future<void> _sendCurrentFrame() async {
    setState(() {
      _sending = true;
      _error = null;
      // Start every discrete send at frame 0 so it re-opens the doodle session
      // (ui_end_sync + doodle_start). Without this, a send after a BLE reconnect
      // — or after a prior send failed partway — would carry frame_index > 0,
      // skip the session-open, and silently render nothing on a device no
      // longer in doodle mode. Bump the epoch too so a still-in-flight frame
      // from a previous operation can't write its stale sequence back over
      // this reset.
      _streamEpoch++;
      _frameSequence = 0;
    });
    try {
      await _enqueueSend(_current, await _resolvePayloadPerWrite());
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
      setState(() {
        _streaming = false;
        _streamEpoch++;
      });
      return;
    }
    // The epoch pins this loop to this activation: a stop + quick restart
    // bumps it, so an old loop parked in an await exits at its next check
    // instead of being revived by the shared boolean and doubling the send
    // rate with interleaved fragments.
    final epoch = ++_streamEpoch;
    setState(() {
      _streaming = true;
      _error = null;
      // Open the doodle session on this stream's first frame — and re-open it
      // for a stream restarted after a reconnect — by starting from frame 0.
      _frameSequence = 0;
      // The local preview advances _current on its own timer; left running
      // it would fight the stream loop's advance (with 2 frames the net is
      // zero — the device would receive the same frame forever).
      _stopPreview();
    });
    Log.ble.info('streaming ${_frames.length}-frame animation to '
        '${widget.deviceId} every ${_intervalMs}ms');
    final payloadPerWrite = await _resolvePayloadPerWrite();
    while (mounted && _streaming && epoch == _streamEpoch) {
      final started = DateTime.now();
      try {
        await _enqueueSend(_current, payloadPerWrite);
      } catch (e) {
        if (!mounted || epoch != _streamEpoch) return;
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
      if (!mounted || !_streaming || epoch != _streamEpoch) break;
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
    super.build(context); // AutomaticKeepAliveClientMixin contract.
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
                    : (selection) => _setAnimationMode(selection.first),
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
              revision: _paintRevision,
              onPaint: _paintCell,
            ),
            const SizedBox(height: 10),
            _PaletteRow(
              selected: _selectedColor,
              onSelected: (i) => setState(() => _selectedColor = i),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerLeft,
              child: PopupMenuButton<LedDesign>(
                enabled: !_streaming && !_sending,
                onSelected: _loadDesign,
                itemBuilder: (context) => [
                  for (final d in _designs)
                    PopupMenuItem(
                      value: d,
                      child:
                          Text(d.animation ? '${d.name} (animation)' : d.name),
                    ),
                ],
                // A plain Chip (no onPressed) so the PopupMenuButton owns the
                // tap; the button's `enabled` gates it while busy.
                child: const Chip(
                  avatar: Icon(Icons.palette_outlined, size: 18),
                  label: Text('Designs'),
                ),
              ),
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
              Builder(builder: (context) {
                final bounds = frameIntervalBoundsMs(_spec);
                return Row(
                  children: [
                    Text('Frame every ${_intervalMs}ms',
                        style: text.bodySmall
                            ?.copyWith(color: scheme.onSurfaceVariant)),
                    Expanded(
                      child: Slider(
                        value: _intervalMs.toDouble(),
                        min: bounds.min.toDouble(),
                        max: bounds.max.toDouble(),
                        onChanged: (v) => _setIntervalMs(v.round()),
                      ),
                    ),
                  ],
                );
              }),
            ],
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ],
            const SizedBox(height: 8),
            Builder(builder: (context) {
              // One mode table for icon, label AND action — three parallel
              // conditionals would have to be kept in sync by hand.
              final (icon, label, action) =
                  switch ((_animationMode, _streaming)) {
                (false, _) => (
                    Icons.upload,
                    'Send to device',
                    _sendCurrentFrame
                  ),
                (true, false) => (
                    Icons.play_arrow,
                    'Stream to device',
                    _toggleStreaming
                  ),
                (true, true) => (
                    Icons.stop,
                    'Stop streaming',
                    _toggleStreaming
                  ),
              };
              return SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  icon: Icon(icon),
                  label: Text(label),
                  onPressed: _sending ? null : action,
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// Width/height entry for panels whose real resolution the device reports at
/// runtime and the app has not yet learned.
///
/// Free-form numeric fields, not a preset list: real panels report sizes
/// like 25x50, and a near-miss width shears every transmitted row (the
/// device's display buffer is row-major at its true width). Values clamp to
/// 1..the spec's platform bound.
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
    Widget field({
      required Key key,
      required String label,
      required int value,
      required int? max,
      required ValueChanged<int> onChanged,
    }) {
      return Expanded(
        child: TextFormField(
          // Keyed by the committed value so an external change (or a clamp)
          // rebuilds the field showing the real size instead of stale text.
          key: key,
          initialValue: '$value',
          enabled: enabled,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
            labelText: max == null ? label : '$label (1-$max)',
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          // Commit on submit only: committing per keystroke would rebuild
          // the value-keyed field mid-typing ("25" would commit at "2" and
          // drop focus). Unparseable input keeps the previous canvas.
          onFieldSubmitted: (input) {
            final parsed = parseCanvasSize(input, max: max);
            if (parsed != null) onChanged(parsed);
          },
        ),
      );
    }

    return Row(
      children: [
        field(
          key: ValueKey('led-canvas-width-$width'),
          label: 'Width',
          value: width,
          max: maxWidth,
          onChanged: onWidthChanged,
        ),
        const SizedBox(width: 10),
        field(
          key: ValueKey('led-canvas-height-$height'),
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

  /// Monotonic edit counter; see [_GridPainter.shouldRepaint].
  final int revision;
  final void Function(Offset local, double cellSize) onPaint;

  const _PixelGridEditor({
    super.key,
    required this.width,
    required this.height,
    required this.rgb,
    required this.revision,
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
              revision: revision,
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

  /// Monotonic edit counter from the editor state. The pixel buffer is
  /// mutated IN PLACE, so comparing `rgb` by identity can never detect an
  /// edit — today an enclosing LayoutBuilder happens to force a repaint on
  /// every rebuild, but relying on that would make painting silently stop
  /// rendering the moment that wrapper changes. The revision makes the
  /// repaint decision explicit.
  final int revision;
  final Color gridColor;

  _GridPainter({
    required this.width,
    required this.height,
    required this.rgb,
    required this.revision,
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
      old.revision != revision ||
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

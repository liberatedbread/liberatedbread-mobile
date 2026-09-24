// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';
import '../providers/spec_codec_provider.dart';
import '../services/camera_feed_service.dart';
import '../services/spec_codec.dart';

/// Live camera view for a device whose spec declares a `camera:` block with an
/// `mjpeg_snapshot_poll` stream (the Snapmaker U1's built-in camera). Renders
/// nothing when the spec has no such camera, so it can sit unconditionally in a
/// device screen. Holds the WebSocket keepalive open for as long as it is
/// mounted, and tears it down on dispose.
///
/// Other transports (RTSP/HLS/WebRTC) are recognised but not rendered here —
/// the app ships no video player — so those fall through to "not shown".
///
/// Frames are held as one [ImageProvider] at a time. `Image.memory` keys the
/// global [ImageCache] on the bytes object, so a polled feed that handed each
/// frame straight to it left every decoded bitmap resident until the cache's
/// 100 MB ceiling forced the oldest out — ~30 s of a 720p feed at 1 fps, and
/// held for as long as the screen stayed open. Each new frame evicts the
/// previous provider, dispose evicts the last, and decoding is sized to the
/// card's own width so a 1280-wide snapshot is not decoded at 1280 to be drawn
/// at 360.
class CameraViewCard extends ConsumerStatefulWidget {
  final String specYaml;
  final String host;

  const CameraViewCard({super.key, required this.specYaml, required this.host});

  @override
  ConsumerState<CameraViewCard> createState() => _CameraViewCardState();
}

class _CameraViewCardState extends ConsumerState<CameraViewCard> {
  CameraStreamDto? _pollStream;
  StreamSubscription<Uint8List>? _sub;

  /// The latest frame, as the one provider the card owns — see the class
  /// note. Replaced, never accumulated.
  ImageProvider? _frame;

  /// The decode width for the next frame, in physical pixels: the card's
  /// laid-out width times the device pixel ratio, recorded by the layout
  /// pass so the next frame is decoded no larger than it will be drawn. Null
  /// until the card has laid out once, in which case a frame decodes at its
  /// native size.
  int? _cacheWidth;
  String? _error;
  Timer? _firstFrameTimeout;

  /// How long to wait for the first frame before telling the user the camera
  /// is not responding, rather than spinning forever on a declared-but-
  /// unreachable feed.
  static const _firstFrameGrace = Duration(seconds: 15);

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  Future<void> _resolve() async {
    try {
      final camera = await ref
          .read(specCodecProvider)
          .cameraForDevice(specYaml: widget.specYaml);
      if (!mounted) return;
      final poll = camera?.streams
          .where((s) => s.transport == 'mjpeg_snapshot_poll')
          .firstOrNull;
      setState(() => _pollStream = poll);
      if (poll != null) {
        _sub = ref
            .read(cameraFeedServiceProvider)
            .frames(
              host: widget.host,
              stream: poll,
              keepalive: camera!.keepalive,
            )
            .listen(
              (bytes) {
                if (!mounted) return;
                // A frame arrived: the feed works, so cancel the not-responding
                // timeout and clear any prior error.
                _firstFrameTimeout?.cancel();
                _firstFrameTimeout = null;
                _showFrame(bytes);
              },
              onError: (Object e) {
                Log.spec.debug('camera feed error', error: e);
              },
            );
        // The feed service swallows transient fetch failures and keeps polling,
        // so a camera that never answers surfaces no error — it would spin
        // forever. Time out the wait for the first frame and say so.
        _firstFrameTimeout = Timer(_firstFrameGrace, () {
          if (mounted && _frame == null) {
            setState(() => _error = 'The camera isn’t responding.');
          }
        });
      }
    } on Object catch (e) {
      Log.spec.warning('camera resolve failed', error: e);
      if (mounted) {
        setState(() => _error = 'Could not read the camera configuration.');
      }
    }
  }

  /// Swap the displayed frame for [bytes], and drop the one it replaces
  /// from the image cache.
  ///
  /// The provider is built here rather than in build(), because the cache
  /// key is the provider: the previous one has to be the very object that
  /// was drawn for its eviction to find the entry. `ResizeImage` wraps the
  /// bytes so the decode is sized to the card; its key wraps the inner key,
  /// which is why the eviction goes through the wrapper.
  void _showFrame(Uint8List bytes) {
    final previous = _frame;
    final next = ResizeImage.resizeIfNeeded(
      _cacheWidth,
      null,
      MemoryImage(bytes),
    );
    setState(() {
      _frame = next;
      _error = null;
    });
    if (previous != null) _evict(previous);
  }

  /// Best effort: an entry that is still decoding or was never inserted
  /// evicts as false, which is fine — the point is that nothing stays.
  static void _evict(ImageProvider provider) {
    unawaited(
      provider.evict().catchError((Object e) {
        Log.spec.debug('camera frame evict failed', error: e);
        return false;
      }),
    );
  }

  @override
  void dispose() {
    _firstFrameTimeout?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
    final last = _frame;
    _frame = null;
    if (last != null) _evict(last);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Draw nothing until we KNOW this device has a supported camera stream (or
    // reading its config errored). Rendering the card+spinner while resolving
    // flashed it on every network device screen, cameraless ones included.
    if (_pollStream == null && _error == null) {
      return const SizedBox.shrink();
    }
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final frame = _frame;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
            child: Row(
              children: [
                Icon(Icons.videocam_outlined, size: 18, color: scheme.primary),
                const SizedBox(width: 8),
                Text('Camera', style: text.titleSmall),
              ],
            ),
          ),
          AspectRatio(
            aspectRatio: 16 / 9,
            child: LayoutBuilder(
              builder: (context, constraints) {
                // Recorded, not setState'd: it is read when the NEXT frame
                // arrives, and the frame in hand is already sized.
                final width = constraints.maxWidth;
                if (width.isFinite && width > 0) {
                  _cacheWidth = (width * MediaQuery.devicePixelRatioOf(context))
                      .ceil();
                }
                return Container(
                  color: Colors.black,
                  alignment: Alignment.center,
                  child: _error != null
                      ? Text(
                          _error!,
                          style: text.bodySmall?.copyWith(color: scheme.error),
                        )
                      : frame != null
                      ? Image(
                          image: frame,
                          gaplessPlayback: true,
                          fit: BoxFit.contain,
                          errorBuilder: (_, _, _) => const Icon(
                            Icons.broken_image_outlined,
                            color: Colors.white54,
                          ),
                        )
                      : const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

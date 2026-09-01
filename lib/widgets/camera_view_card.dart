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
  Uint8List? _frame;
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
                host: widget.host, stream: poll, keepalive: camera!.keepalive)
            .listen(
          (bytes) {
            if (!mounted) return;
            // A frame arrived: the feed works, so cancel the not-responding
            // timeout and clear any prior error.
            _firstFrameTimeout?.cancel();
            _firstFrameTimeout = null;
            setState(() {
              _frame = bytes;
              _error = null;
            });
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

  @override
  void dispose() {
    _firstFrameTimeout?.cancel();
    unawaited(_sub?.cancel());
    _sub = null;
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
            child: Container(
              color: Colors.black,
              alignment: Alignment.center,
              child: _error != null
                  ? Text(_error!,
                      style: text.bodySmall?.copyWith(color: scheme.error))
                  : frame != null
                      ? Image.memory(
                          frame,
                          gaplessPlayback: true,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => const Icon(
                              Icons.broken_image_outlined,
                              color: Colors.white54),
                        )
                      : const SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          ),
        ],
      ),
    );
  }
}

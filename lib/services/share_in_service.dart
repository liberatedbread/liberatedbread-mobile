// Copyright 2026 Pigs Can Fly Labs LLC
// SPDX-License-Identifier: Apache-2.0
import 'dart:async';

import 'package:flutter/foundation.dart' show immutable;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/log.dart';

/// A photo or PDF another app shared into this one (Android's Share sheet,
/// "Open with", iOS "Open in") to be printed.
@immutable
class SharedFile {
  final Uint8List bytes;

  /// The MIME type the sharing app declared, when it declared one.
  final String? mime;

  /// The file's display name, when the platform knows it.
  final String? name;

  const SharedFile({required this.bytes, this.mime, this.name});
}

/// Files arriving from other apps. The native side copies the bytes while
/// its read permission lasts and holds a cold-start share until asked.
/// Platforms with no handler (Linux, tests) simply never deliver one.
class ShareInService {
  static const _channel = MethodChannel(
    'ca.pigscanfly.liberatedbread/share_in',
  );

  final _incoming = StreamController<SharedFile>.broadcast();

  ShareInService() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'shared') {
        final file = _decode(call.arguments);
        if (file != null) _incoming.add(file);
      }
    });
  }

  /// Shares that arrive while the app is running.
  Stream<SharedFile> get incoming => _incoming.stream;

  /// The share the app was launched with, once; null when there was none or
  /// the platform has no share handler.
  Future<SharedFile?> initialShare() async {
    try {
      return _decode(await _channel.invokeMethod<Object?>('initialShare'));
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      Log.app.warning('reading the shared file failed', error: e);
      return null;
    }
  }

  static SharedFile? _decode(Object? raw) {
    if (raw is! Map) return null;
    final bytes = raw['bytes'];
    if (bytes is! Uint8List || bytes.isEmpty) return null;
    return SharedFile(
      bytes: bytes,
      mime: raw['mime'] as String?,
      name: raw['name'] as String?,
    );
  }

  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_incoming.close());
  }
}

final shareInServiceProvider = Provider<ShareInService>((ref) {
  final service = ShareInService();
  ref.onDispose(service.dispose);
  return service;
});
